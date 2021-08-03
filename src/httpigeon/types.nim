import httpcore
import options
import strtabs

type
  HttpRequest* = object
    raw*: string
    httpMethod*: HttpMethod
    ip*: string
    path*: string
    pathArgs*: StringTableRef
    queryArgs*: StringTableRef
    headers*: HttpHeaders
    body*: Option[string]
  HttpResponse* = object
    code*: HttpCode
    additionalHeaders*: HttpHeaders
    body*: string

  RequestHandler* = proc(
      request: HttpRequest
    ): HttpResponse {.gcsafe.}