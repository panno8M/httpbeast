import options, asyncdispatch, json

import httpigeon/httpbeast

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})
      req.respond(Http200, data)
    of "/plaintext":
      const data = "Hello, World!"
      const headers = "Content-Type: text/plain"
      req.respond(Http200, data, headers)
    else:
      req.respond(Http404)

run(onRequest)