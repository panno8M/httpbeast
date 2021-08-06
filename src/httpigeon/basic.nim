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
proc newResponse*(code: HttpCode; additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(code, "", additionalHeaders)
proc newResponse*(body: string; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http200, body, additionalHeaders)
proc newResponse*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http200, "", additionalHeaders)

proc ok*(body = ""; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http200, body, additionalHeaders)
proc ok*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http200, "", additionalHeaders)

proc badRequest*(body = ""; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http400, body, additionalHeaders)
proc badRequest*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http400, "", additionalHeaders)

proc notFound*(body = ""; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http404, body, additionalHeaders)
proc notFound*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http404, "", additionalHeaders)

proc internalServerError*(body = ""; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} = newResponse(Http500, body, additionalHeaders)
proc internalServerError*(additionalHeaders: HttpHeaders): HttpResponse {.inline.} = newResponse(Http500, "", additionalHeaders)