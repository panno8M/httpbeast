import options
import httpcore
from strutils import join
from sequtils import mapIt
import ../extensions
import ../basic

const
  acRequestOrigin*  = "Origin"
  acRequestMethod*  = "Access-Control-Request-Method"
  acRequestHeaders* = "Access-Control-Request-Headers"
  acAllowOrigin*    = "Access-Control-Allow-Origin"
  acAllowMethods*   = "Access-Control-Allow-Methods"
  acAllowHeaders*   = "Access-Control-Allow-Headers"
  acAllowMaxAge*    = "Access-Control-Max-Age"
  allowedOriginsDefault* = ["*"]
  allowedMethodsDefault* = [HttpGet, HttpPost, HttpHead]
  allowedHeadersDefault* = ["*"]

proc followCORS*( responseHeaders: var HttpHeaders;
                  requestHeaders: HttpHeaders;
                  allowedOrigins: openArray[string]     = allowedOriginsDefault;
                  allowedMethods: openArray[HttpMethod] = allowedMethodsDefault;
                  allowedHeaders: openArray[string]     = allowedHeadersDefault;
                ) =
  if responseHeaders == nil:
    responseHeaders = newHttpHeaders()

  if requestHeaders.hasKey(acRequestOrigin) and
      not responseHeaders.hasKey(acAllowOrigin):
    let reqOrigin = requestHeaders[acRequestOrigin]

    if "*" in allowedOrigins:
      responseHeaders[acAllowOrigin] = "*"
    else:
      for allowedOrigin in allowedOrigins:
        if allowedOrigin == reqOrigin:
          responseHeaders[acAllowOrigin] = allowedOrigin
          break

  if requestHeaders.hasKey(acRequestMethod) and
      not responseheaders.hasKey(acAllowMethods):
    responseHeaders[acAllowMethods] = allowedMethods.mapIt($it).join(", ")

  if requestHeaders.hasKey(acRequestHeaders) and
      not responseheaders.hasKey(acAllowHeaders):
    responseHeaders[acAllowHeaders] = allowedHeaders.join(", ")

proc corsSupportExt*(allowedOrigins: openArray[string] = allowedOriginsDefault): Extension {.gcsafe.} =
  var allowedOrigins: seq[string] = @allowedOrigins
  Extension(
    parseRegularResponse: some(proc(response: var HttpResponse; request: HttpRequest) {.closure.} =
      response.additionalHeaders.followCORS(request.headers, allowedOrigins)
    ),
    onRoutingFailure: some(proc(request: HttpRequest): Option[HttpResponse] {.closure.} =
      if request.httpMethod == HttpOptions:
        var additionalHeaders = newHttpHeaders()
        additionalHeaders.followCORS(request.headers, allowedOrigins)
        return some newResponse(additionalHeaders)
    ),
  )