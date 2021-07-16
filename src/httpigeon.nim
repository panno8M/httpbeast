import httpigeon/httpbeast
import nest

export httpbeast, nest

type Response* = object
  code*: HttpCode
  additionalHeaders*: HttpHeaders
  body*: string

proc newResponse*(
      code: HttpCode;
      additionalHeaders: HttpHeaders;
      body: string;
    ): Response =
  Response(
    code: code,
    additionalHeaders: additionalHeaders,
    body: body
  )
proc newResponse*(body: string): Response = newResponse(Http200, newHttpHeaders(), body)
proc newResponse*(additionalHeaders: HttpHeaders; body: string): Response = newResponse(Http200, additionalHeaders, body)

proc respond*(req: Request; response: Response) = req.respond(response.code, response.body, response.additionalHeaders)

template `$:`*(keyValuePairs: openArray[tuple[key: string, val: string]]): HttpHeaders = newHttpHeaders(keyValuePairs)

type RequestHandler* = proc(
    req: Request;
    args: RoutingArgs;
  ): Response {.gcsafe.}