import logging
import options, asyncdispatch

import httpigeon/httpbeast


let logFile = open("tests/logFile.tmp", fmWrite)
var fileLog = newFileLogger(logFile)
addHandler(fileLog)

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      info("Requested /")
      flushFile(logFile)  # Only errors above lvlError auto-flush
      req.respond("Hello World")
    else:
      error("404")
      req.respond(Http404)

block:
  let settings = newSettings()

  run(onRequest, settings)
  logFile.close()
