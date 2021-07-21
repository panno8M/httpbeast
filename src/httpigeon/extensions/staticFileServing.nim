import options
import sugar
import os
import ../extensions
import ../httpbeast
import ../basic

const supportedExt =
  [ ""
  , ".html"
  , ".css"
  , ".js"
  ]
proc staticFileServingExt*(docsRoot: string): Extension {.gcsafe.} =
  Extension(
    onRoutingFailure: some(proc(req: Request): Option[Response] {.gcsafe, thread.} =
      var path = docsRoot/req.path.get()
      if splitFile(path).ext notin supportedExt: return
      if (var file: File; file).open(path):
        return newResponse(file.readAll()).some
  ))