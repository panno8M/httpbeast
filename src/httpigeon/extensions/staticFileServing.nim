import options
import sugar
import os
import ../extensions
import ../httpbeast
import ../basic

type Mode* = enum
  Normal
  SPA

const supportedExt =
  [ ""
  , ".html"
  , ".css"
  , ".js"
  ]
proc staticFileServingExt*(docsRoot: string; mode = Normal): Extension {.gcsafe.} =
  Extension(
    onRoutingFailure: some(proc(req: HttpRequest): Option[HttpResponse] {.gcsafe, thread.} =
      var headers = newHttpHeaders()

      let path = docsRoot/req.path
      let ext = splitFile(path).ext
      if ext notin supportedExt: return none(HttpResponse)
      if (var file: File; file).open(path):
        case ext
        of ".js":
          headers["Content-Type"] = "application/json"
        return newResponse(file.readAll()).some

      if ext == "" and (var file: File; file).open(path/"index.html"):
          headers["Content-Type"] = @["text/html", "charset=UTF-8"]
          return newResponse(file.readAll()).some


      case mode:
      of Normal: discard
      of SPA:
        let rootIndex = docsRoot/"index.html"
        if (var file: File; file).open(rootIndex):
          return newResponse(file.readAll(), headers).some

  ))