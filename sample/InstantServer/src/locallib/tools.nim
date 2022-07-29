import httpcore
import httpigeon/types
import httpigeon/extensions/[
  responseutils,
  dbOperation
]

import json
import jwt
import bcrypt

import times
import options
import tables
import strutils
import sequtils
from strformat import `&`

type
  AuthError* = object of IOError
  RequestError* = object of IOError
  UserInfo* = object
    userid*: Option[Natural]
    username*: string
    passwordHashed*: string
  WorkOverview* = object
    work_id*: Natural
    work_title*: string
  WorkDetail* = object
    title*: string
    desc*: string
    author*: string
    when true:
      tags*: seq[string]
    else: discard
  Comment* = object
    comment_id*: Natural
    comment*: string
    author*: string

proc authError*(msg: string) {.noreturn, noinline.} =
  ## raises an DbError exception with message `msg`.
  var e: ref AuthError
  new(e)
  e.msg = msg
  raise e
proc requestError*(msg: string) {.noreturn, noinline.} =
  ## raises an DbError exception with message `msg`.
  var e: ref RequestError
  new(e)
  e.msg = msg
  raise e

proc `==`*(a, b: UserInfo): bool =
  a.username == b.username and
  a.passwordHashed == b.passwordHashed

const
  appName = "webProAssignment"
  bcryptSalt = "$2a$10$BF27pt5ozVp3XuofoRPwb"
  jwtSecret = bcryptSalt
  iptLim = (
    username: (min: Natural(5), max: Natural(60)),
    password: (min: Natural(8), max: Natural(60)),
  )

proc errorJsonResp*(code: HttpCode; msg: string): HttpResponse {.inline.} =
  newJsonResponse(code, %*{"msg": msg})
proc ok_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http200, msg)
proc badRequest_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http400, msg)
proc unauthorized_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http400, msg)
proc notFound_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http404, msg)
proc conflict_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http409, msg)
proc internalServerError_withJsonMsg*(msg: string): HttpResponse {.inline.} =
  errorJsonResp(Http500, msg)

proc hashPassword*(rawPassword: string): string {.inline.} =
  rawPassword.hash(bcryptSalt)

# SECTION Authentication
proc defineAuthJWT*(userid: Natural): JWT {.inline.} =
  result = (%*{
    "header": {
      "alg": "HS256",
      "typ": "JWT",
    },
    "claims": {
      "user_id": userid,
      "iss": appName,
    }
  }).toJWT()
  result.sign(jwtSecret)

proc setAuthCookie*(headers: var HttpHeaders; token: JWT; maxAge: TimeInterval = 1.days) =
  headers["Set-Cookie"] = @[
    &"token={token}",
    "HttpOnly",
    "path=/",
    &"""Expires={(now()+maxAge).utc.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")}""",
  ]
proc setAuthCookie*(headers: var HttpHeaders; userid: Natural; maxAge: TimeInterval = 1.days) =
  headers.setAuthCookie defineAuthJWT userid, maxAge

proc authenticate*( responseHeaders: var HttpHeaders;
                      requestHeaders: HttpHeaders;
                      maxAge = 1.days): Natural {.raises: [AuthError].} =
  ## リクエストが正しい認証情報を持っているか:
  ##  * Cookieにトークンが設定されており、かつ不正なものでない、
  ##  * X-Required-Withヘッダが設定されている、
  ##  * 存在するuserである、
  ## を確認し、passされた場合、認証Cookieの有効期限を更新するためのSet-Cookieを
  ## レスポンスヘッダに付与しuseridを返す。
  ## passされなかった場合、AuthError例外を発生させる。

  let userid: Natural = block:
    block CSRF_measures:
      if not requestHeaders.hasKey("X-Requested-With"):
        authError("Invalid requiest")

    let jwt = block Get_jwt_from_cookies:
      let cookies =
        try: requestHeaders["Cookie"]
        except KeyError: authError("No JWT token given")
      var jwtStr: string
      for cookie in seq[string](cookies):
        if cookie[0] == 't' and
           cookie[1] == 'o' and
           cookie[2] == 'k' and
           cookie[3] == 'e' and
           cookie[4] == 'n' and
           cookie[5] == '=':
          jwtStr = cookie[6..^1]
          break
      try: jwtStr.toJWT()
      except: authError("Invalid JWT token")

    try:
      if not jwt.verify(jwtSecret, HS256):
        authError("Invalid JWT token")
      jwt.claims["user_id"].node.getInt()
    except: authError("Invalid JWT token")

  let useridStored = try: dbHandle[].getValue(sql"SELECT (user_id) FROM users WHERE user_id=?", userid)
    except DbError: authError("Unknown user")
  if useridStored.isEmptyOrWhiteSpace: authError("Unknown user")

  try: responseHeaders.setAuthCookie(userid, maxAge)
  except: authError("Failed to Authentication")

  return userid
#!SECTION

proc extractUserInfo*(body: Option[string]): UserInfo {.raises: [RequestError].} =
  let
    bodyJson =
      try: body.get().parseJson()
      except: requestError("Request body is required")
    username =
      try: bodyJson["username"].getStr()
      except: requestError("username field is required")
    passwordRaw =
      try: bodyJson["password"].getStr()
      except: requestError("password field is required")

  if username.len < iptLim.username.min:
    requestError("username must be least " & $iptLim.username.min & " characters long.")
  if username.len > iptLim.username.max:
    requestError("username must be most " & $iptLim.username.max & " characters long.")
  if passwordRaw.len < iptLim.password.min:
    requestError("password must be least " & $iptLim.password.min & " characters long.")
  if passwordRaw.len > iptLim.password.max:
    requestError("password must be most " & $iptLim.password.max & " characters long.")
  UserInfo(
    username: username,
    passwordHashed: passwordRaw.hashPassword()
  )

# SECTION database utils
proc insertUser*(db: ptr DbConn; userInfo: UserInfo) {.inline, raises: [DbError].} =
  db[].exec(sql"INSERT INTO users (user_name, user_password) VALUES (?, ?)",
    userInfo.username, userInfo.passwordHashed)

proc selectUsernameById*(db: ptr DbConn; userid: Natural): string {.inline, raises: [DbError].} =
  db[].getValue(sql"SELECT (user_name) FROM users WHERE user_id=?", userid)

proc selectUserByName*(db: ptr DbConn; username: string): UserInfo {.inline, raises: [DbError].} =
  let row = db[].getRow(sql"SELECT user_id, user_password FROM users WHERE user_name=?", username)
  echo repr row
  try: UserInfo(
    userid: row[0].parseInt().Natural.some,
    passwordHashed: row[1],
    username: username)
  except ValueError: dbError("Unknown user_id")

proc insertWork*(db: ptr DbConn; title, desc, imageType: string; userid: Natural): Natural {.inline, raises: [DbError].} =
  db[].insertId(sql"INSERT INTO works (work_title, work_desc, user_id, content_type) VALUES (?, ?, ?, ?)",
    title, desc, userid, imageType)

proc selectWorkOverviews*(db: ptr DbConn): seq[WorkOverview] {.inline, raises: [DbError].} =
  try: db[].getAllRows(sql"SELECT work_id, work_title FROM works")
    .mapIt(WorkOverview(work_id: it[0].parseInt(), work_title: it[1]))
  except ValueError: dbError("Unknown work_id")

when true:
  proc selectWorkDetail*(db: ptr DbConn; workid: Natural): WorkDetail {.raises: [DbError].} =
    let workDetailRow = db[].getRow(sql"SELECT work_title, work_desc, user_id FROM works WHERE work_id=?", workid)
    let authorName = db[].getValue(sql"SELECT user_name FROM users WHERE user_id=?", workDetailRow[2])
    let tags = db[].getAllRows(sql"""
      SELECT tags.tag_name
      FROM rWorksTags LEFT JOIN tags
      USING (tag_id)
      WHERE rWorksTags.work_id=?""", workid).mapIt(it[0])
    WorkDetail(
      title: workDetailRow[0],
      desc: workDetailRow[1],
      author: authorName,
      tags: tags
    )
else:
  proc selectWorkDetail*(db: ptr DbConn; workid: Natural): WorkDetail {.raises: [DbError].} =
    let workDetailRow = db[].getRow(sql"SELECT work_title, work_desc, user_id FROM works WHERE work_id=?", workid)
    let authorName = db[].getValue(sql"SELECT user_name FROM users WHERE user_id=?", workDetailRow[2])
    WorkDetail(
      title: workDetailRow[0],
      desc: workDetailRow[1],
      author: authorName,
    )

proc selectWorkContentType*(db: ptr DbConn; workid: Natural): string {.raises: [DbError]} =
  db[].getValue(sql"SELECT content_type FROM works WHERE work_id=?", workid)

proc selectCommentsOf*(db: ptr DbConn; workid: Natural): seq[Comment] {.raises: [DbError]}=
  try: db[].getAllRows(sql"""
    SELECT comments.comment_id,  comments.comment_content, users.user_name
    FROM comments
    LEFT JOIN commentsAuth
    USING (comment_id)
    LEFT JOIN users
    USING (user_id)
    WHERE work_id=?""", workid)
      .mapIt(Comment(comment_id: it[0].parseInt(), comment: it[1], author: it[2]))
  except ValueError: dbError("Unknown comment_id")

proc insertGuestComment*(db: ptr DbConn; comment: string; workid: Natural) {.raises: [DbError].} =
  db[].exec(sql"INSERT INTO comments (comment_content, work_id) VALUE (?, ?)", comment, workid)

proc insertUserComment*(db: ptr DbConn; comment: string; workid: Natural; userid: Natural): Natural {.raises: [DbError].} =
  try:
    db[].startTransaction()
    let commentid = db[].insertId(sql"INSERT INTO comments (comment_content, work_id) VALUE (?, ?)", comment, workid)
    db[].exec(sql"INSERT INTO commentsAuth (comment_id, user_id) VALUE (?, ?)", commentid, userid)
    db[].commit()
  except DbError:
    db[].rollback()
    dbError(getCurrentExceptionMsg())

proc bindTagsTo*(db: ptr DbConn; workid: Natural; tags: openArray[string]) =
  for tag in tags:
    var tagid = db[].getValue(sql"SELECT tag_id FROM tags WHERE tag_name=?", tag)
    if tagid == "":
      tagid = $db[].insertId(sql"INSERT INTO tags (tag_name) VALUES (?)", tag)
    db[].exec(sql"INSERT INTO rWorksTags (work_id, tag_id) VALUES (?, ?)", workid, tagid)

#!SECTION