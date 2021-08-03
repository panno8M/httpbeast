import httpbeast
import nest
import tables
import options
import types
export types
from sequtils import foldl
from strutils import join

proc toString*(headers: HttpHeaders): string =
  var headerStrings: seq[string]
  for key, val in headers.table.pairs:
    headerstrings.add key & ": " & val.foldl(a & "; " & b)
  return headerStrings.join("\n")

proc respond*(req: Request; response: HttpResponse) = req.respond(response.code, response.body, response.additionalHeaders)
proc newResponse*(
      code: HttpCode;
      body: string = "";
      additionalHeaders: HttpHeaders = nil;
    ): HttpResponse =
  HttpResponse(
    code: code,
    additionalHeaders: additionalHeaders,
    body: body
  )
proc newResponse*(body: string; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http200, body, additionalHeaders)
proc newResponse*(code: HttpCode; additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(code, "", additionalHeaders)
proc newResponse*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http200, "", additionalHeaders)