import ../basic
import httpcore
import json

proc newJsonResponse*(code: HttpCode; body: JsonNode; additionalHeaders: HttpHeaders): HttpResponse =
  var additionalHeaders = additionalHeaders
  if additionalHeaders.isNil: additionalHeaders = newHttpHeaders()
  additionalHeaders["Content-Type"] = "application/json"
  newResponse(code, $body, additionalHeaders)
proc newJsonResponse*(code: HttpCode; body: JsonNode): HttpResponse {.inline.} =
  newJsonResponse(code, body, newHttpHeaders())
proc newJsonResponse*(body: JsonNode; additionalHeaders: HttpHeaders): HttpResponse {.inline.} =
  newJsonResponse(Http200, body, additionalHeaders)
proc newJsonResponse*(body: JsonNode): HttpResponse {.inline.} =
  newJsonResponse(Http200, body, newHttpHeaders())

proc ok*(body: JsonNode; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} =
  newJsonResponse(Http200, body, additionalHeaders)
proc badRequest*(body: JsonNode; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} =
  newJsonResponse(Http400, body, additionalHeaders)
proc notFound*(body: JsonNode; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} =
  newJsonResponse(Http404, body, additionalHeaders)
proc internalServerError*(body: JsonNode; additionalHeaders: HttpHeaders = nil): HttpResponse {.inline.} =
  newJsonResponse(Http500, body, additionalHeaders)