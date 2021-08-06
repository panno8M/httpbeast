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
  allowedOriginsDefault*: array[0, string] = []
  allowedMethodsDefault* = [HttpGet, HttpPost, HttpHead]
  allowedHeadersDefault*: array[0, string] = []

proc followCORS*( responseHeaders: var HttpHeaders;
                  requestHeaders: HttpHeaders;
                  allowedOrigins: openArray[string]     = allowedOriginsDefault;
                  allowedMethods: openArray[HttpMethod] = allowedMethodsDefault;
                  allowedHeaders: openArray[string]     = allowedHeadersDefault;
                ) =
  assert not (responseHeaders.isNil or requestHeaders.isNil)

  block Set_Allow_Origin:
    if responseHeaders.hasKey(acAllowOrigin) or
        not requestHeaders.hasKey(acRequestOrigin):
      break Set_Allow_Origin

    let reqOrigin = requestHeaders[acRequestOrigin]

    if allowedOrigins.len == 0:
      responseHeaders[acAllowOrigin] = "*"
      break Set_Allow_Origin

    for allowedOrigin in allowedOrigins:
      if allowedOrigin == reqOrigin:
        responseHeaders[acAllowOrigin] = allowedOrigin
        break Set_Allow_Origin

  block Set_Allow_Methods:
    if responseheaders.hasKey(acAllowMethods) or
        not requestHeaders.hasKey(acRequestMethod):
      break Set_Allow_Methods

    responseHeaders[acAllowMethods] = allowedMethods.mapIt($it).join(", ")

  block Set_Allow_Headers:
    if responseheaders.hasKey(acAllowHeaders) or
        not requestHeaders.hasKey(acRequestHeaders):
      break Set_Allow_Headers

    if allowedHeaders.len == 0:
      responseHeaders[acAllowHeaders] = "*"
      break Set_Allow_Headers

    responseHeaders[acAllowHeaders] = allowedHeaders.join(", ")

proc corsSupportExt*(allowedOrigins: openArray[string] = allowedOriginsDefault): Extension {.gcsafe.} =
  var allowedOrigins: seq[string] = @allowedOrigins
  Extension(
    parseRegularResponse: some( proc(response: var HttpResponse; request: HttpRequest) {.closure.} =
      response.additionalHeaders.followCORS(request.headers, allowedOrigins)
    ),
    onRoutingFailure: some( proc(request: HttpRequest): Option[HttpResponse] {.closure.} =
      if request.httpMethod == HttpOptions:
        var additionalHeaders = newHttpHeaders()
        additionalHeaders.followCORS(request.headers, allowedOrigins)
        return some newResponse(additionalHeaders)
    ),
  )