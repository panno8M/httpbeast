import options, asyncdispatch

import httpigeon/httpbeast

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.respond("Hello World")
    else:
      req.respond(Http404)

run(onRequest)