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