import options, asyncdispatch, httpclient

import httpigeon/httpbeast

proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      var client = newAsyncHttpClient()
      let content = await client.getContent("http://localhost:8080/content")
      req.respond($content)
    of "/content":
      req.respond("Hi there!")
    else:
      req.respond(Http404)
  elif req.httpMethod == some(HttpPost):
    case req.path.get()
    of "/":
      req.respond("Successful POST! Data=" & $req.body.get().len)
    else:
      req.respond(Http404)

run(onRequest)