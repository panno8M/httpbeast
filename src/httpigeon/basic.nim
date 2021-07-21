import httpbeast
import nest
import tables
from sequtils import foldl
from strutils import join
type
  RequestHandler* = proc(
      req: Request;
      args: RoutingArgs;
    ): Response {.gcsafe.}

  Response* = object
    code*: HttpCode
    additionalHeaders*: HttpHeaders
    body*: string

proc toString*(headers: HttpHeaders): string =
  var headerStrings: seq[string]
  for key, val in headers.table.pairs:
    headerstrings.add key & ": " & val.foldl(a & "; " & b)
  return headerStrings.join("\n")

proc respond*(req: Request; response: Response) = req.respond(response.code, response.body, response.additionalHeaders)
proc newResponse*(
      code: HttpCode;
      body: string = "";
      additionalHeaders: HttpHeaders = nil;
    ): Response =
  Response(
    code: code,
    additionalHeaders: additionalHeaders,
    body: body
  )
proc newResponse*(body: string; additionalHeaders: HttpHeaders = nil): Response {.inline.} = newResponse(Http200, body, additionalHeaders)
proc newResponse*(code: HttpCode; additionalHeaders: HttpHeaders): Response {.inline.} = newResponse(code, "", additionalHeaders)
proc newResponse*(additionalHeaders: HttpHeaders): Response {.inline.} = newResponse(Http200, "", additionalHeaders)