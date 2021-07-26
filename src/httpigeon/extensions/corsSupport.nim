import options
import httpcore
from strutils import join
from sequtils import mapIt
import ../extensions
import ../basic

template followCORS(responseHeaders: HttpHeaders): untyped =
  const allowedMethods = [HttpGet, HttpPost, HttpHead]
  const allowedHeaders = "*"
  if responseHeaders == nil:
    responseHeaders = newHttpHeaders()
  if request.headers.hasKey("Origin"):
    let reqOrigin = request.headers["Origin"]
    for allowedOrigin in allowedOrigins:
      if reqOrigin == allowedOrigin:
        responseHeaders["Access-Control-Allow-Origin"] = allowedOrigin
        break
  if request.headers.hasKey("Access-Control-Request-Method"):
    responseHeaders["Access-Control-Allow-Methods"] = allowedMethods.mapIt($it).join(", ")
  if request.headers.hasKey("Access-Control-Request-Headers"):
    responseHeaders["Access-Control-Allow-Headers"] = allowedHeaders

proc corsSupportExt*(allowedOrigins: openArray[string]): Extension {.gcsafe.} =
  var allowedOrigins: seq[string] = @allowedOrigins
  Extension(
    parseRegularResponse: some(proc(response: var HttpResponse; request: HttpRequest) {.closure.} =
      response.additionalHeaders.followCORS()
    ),
    onRoutingFailure: some(proc(request: HttpRequest): Option[HttpResponse] {.closure.} =
      if request.httpMethod == HttpOptions:
        var additionalHeaders = newHttpHeaders()
        additionalHeaders.followCORS()
        return some newResponse(additionalHeaders)
    ),
  )