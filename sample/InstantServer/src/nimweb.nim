import locallib/tools
import httpigeon
import httpigeon/extensions/[
  staticFileServing,
  corsSupport,
  responseutils,
  contentUtils,
  dbOperation
]
import options
import tables
import json
import times
import sequtils
import strutils
from strformat import `&`
from os import fileExists, sleep, osLastError, osErrorMsg, `/`, splitFile

const
  allowedImageType = ["jpeg", "x-png", "png", "svg+xml", "gif"].mapIt(&"image/{it}")
  workStoreDir = "works"

var pigeon = newPigeon(
  serverSettings = newSettings(),
  extensions = some @[
    staticFileServingExt(docsRoot = "client/htdocs", mode = SPA),
    corsSupportExt(
      allowedOrigins = [
        "http://localhost:8080",
        "http://192.168.3.20:8080",
        # The port assigned to webpack development server
        "http://localhost:8081",
      ]
    ),
    dbOperationExt(
      connection = "localhost:3306",
      user       = "userA20DC016",
      password   = "userA20DC016",
      database   = "dbA20DC016")
  ],
)


# Authentication
pigeon.mappingOn "/api/v1/users/":
  on HttpPost: # sign up
    let userInfo =
      try: request.body.extractUserInfo()
      except RequestError: return badRequest_withJsonMsg(getCurrentExceptionMsg())

    try: dbHandle.insertUser(userInfo)
    except DbError: return conflict_withJsonMsg("User name confilict")

    ok()

  # Resources that require authentication are place in this directory.
  /"me":
    # Delete uesr
    on HttpDelete: return notFound()

  /"me/auth":
    on HttpGet: # Respond whether the user is already signed in.
      var authHeaders = newHttpHeaders()
      let userid =
        try: authHeaders.authenticate(request.headers)
        except AuthError: return ok_withJsonMsg(getCurrentExceptionMsg())

      let username =
        try: dbHandle.selectUsernameById(userid)
        except DbError: return badRequest_withJsonMsg("Unknown user")
      ok(%* {"username": username}, authHeaders)

    on HttpPost: # sign in
      let userInfo =
        try: request.body.extractUserInfo()
        except RequestError: return badRequest_withJsonMsg(getCurrentExceptionMsg())

      let userInfoStored =
        try: dbHandle.selectUserByName(userInfo.username)
        except: return badRequest_withJsonMsg("Unknown user")

      if userInfo != userInfoStored:
        return badRequest_withJsonMsg("Unknown user")

      var authHeaders = newHttpHeaders()
      authHeaders.setAuthCookie(userInfoStored.userid.get())
      ok(authHeaders)

    on HttpDelete: # Log Out
      var authHeaders = newHttpHeaders()
      try: authHeaders.authenticate(request.headers, maxAge = 0.seconds)
      except AuthError:
        return unauthorized_withJsonMsg(getCurrentExceptionMsg())

      ok(authHeaders)

# The resources about the user's works
pigeon.mappingOn "/api/v1/users/me/works/":
  on HttpPost: # Post the work
    var additionalHeaders = newHttpHeaders()
    let userid =
      try: additionalHeaders.authenticate(request.headers)
      except AuthError: return unauthorized_withJsonMsg(getCurrentExceptionMsg())

    let formData =
      try: request.multiPartFormData()
      except ParseRequestError: return badRequest_withJsonMsg(getCurrentExceptionMsg())

    var
      info =
        try: formData["info"].body.parseJson()
        except: return badRequest_withJsonMsg("info section is required")
      workPart =
        try: formData["work"]
        except: return badRequest_withJsonMsg("work section is required")

    var imageType: string
    let requestImageType =
      try: workPart.headers["Content-Type"][0]
      except: return badRequest_withJsonMsg("Content-Type header is required in work section")
    for it in allowedImageType:
      if it == requestImageType:
        imageType = it
        break

    if imageType.isEmptyOrWhitespace:
      return badRequest_withJsonMsg("Invalid Image")

    var
      title =
        try: info["title"].getStr()
        except KeyError: return badRequest_withJsonMsg("title field is required in info section")
      desc =
        try: info["desc"].getStr()
        except KeyError: return badRequest_withJsonMsg("desc field is required in info section")
      tags =
        try: info["tags"].getElems().mapIt(it.getStr()).deduplicate().filterIt(not it.isEmptyOrWhitespace)
        except KeyError: return badRequest_withJsonMsg("tags field is required in info section")
      work = workPart.body

    let workid =
      try:
        dbHandle.startTransaction()
        var workid = dbHandle.insertWork(title, desc, imageType, userid)
        dbHandle.bindTagsTo(workid, tags)

        block:
          var f = open(workStoreDir/($workid), fmWrite)
          defer: f.close()
          var wroteLen = f.writeChars(work, 0, Natural(work.len))
          if wroteLen != work.len:
            dbHandle.rollback()
            return internalServerError_withJsonMsg("failed to upload work")

        dbHandle.commit()
        workid

      except DbError:
        dbHandle.rollback()
        return internalServerError_withJsonMsg("failed to upload work")

    additionalHeaders["Location"] = &"/api/v1/works/{workid}"
    ok(additionalheaders)

  /"{workid}":
    # delete work
    on HttpDelete: notFound()

# Public Resources
pigeon.mappingOn "/api/v1/":
  /"works":
    on HttpGet: # Get all works list
      try: ok(%* dbHandle.selectWorkOverviews())
      except: internalServerError()

    /"{workid}":
      on HttpGet: # Respond the work
        let workid =
          try: request.pathArgs["workid"].parseInt().Natural
          except ValueError: return notFound()
        try: ok(%* dbHandle.selectWorkDetail(workid))
        except DbError: notFound()

      /"image": # Respond the work's image
        on HttpGet:
          let
            workContent = block:
              let workPath = workStoreDir/request.pathArgs["workid"]
              if fileExists(workPath):
                var file = (workPath).open()
                defer: file.close()
                file.readAll()
              else: return notFound()
            workid =
              try: request.pathArgs["workid"].parseInt().Natural
              except ValueError: return notFound()
            contentType =
              try: dbHandle.selectWorkContentType(workid)
              except DbError: return notFound()
          ok(workContent, newHttpHeaders({"Content-Type": contentType}))

      /"comments":
        on HttpGet: # Respond the comments tied to the work
          let
            workid =
              try: request.pathArgs["workid"].parseint().Natural
              except ValueError: return notFound()
            resp =
              try: dbHandle.selectCommentsOf(workid)
              except DbError: return internalServerError()

          newJsonResponse(%* resp)

        on HttpPost:
          if request.body.isNone:
            return badRequest()
          var
            commentJson =
              try: request.body.get().parseJson()
              except: return badRequest()
            workid =
              try: commentJson["work_id"].getInt()
              except KeyError: return badRequest()
            comment =
              try: commentJson["comment"].getStr()
              except KeyError: return badRequest()
          if workid == 0 or comment.isEmptyOrWhiteSpace:
            return badRequest()

          try:
            var authHeaders = newHttpHeaders()
            let userid = authHeaders.authenticate(request.headers)
            try: dbHandle.insertUserComment(comment, workid, userid)
            except DbError: return internalServerError()
            ok(authHeaders)

          except AuthError:
            try: dbHandle.insertGuestComment(comment, workid)
            except DbError: return internalServerError()
            ok()

  /"tags":
    on HttpGet: notFound()

pigeon.mappingOn "/api/v1/resources/{resource}":
  on HttpGet:
    let path = request.pathArgs["resource"]
    if not fileExists("resources"/path):
      return notFound()

    let
      contentType = case path.splitFile().ext
        of ".svg": "image/svg+xml"
        else: return notFound()
      body = block:
        var file = ("resources"/path).open(fmRead)
        defer: file.close()
        file.readAll()

    ok(body, newHttpHeaders({"Content-Type": contentType}))

pigeon.run()