import options
import httpbeast
import basic

type
  Extension* = object
    onRoutingFailure*: Option[proc(req: HttpRequest): Option[HttpResponse]]
    parseRegularResponse*: Option[proc(response: var HttpResponse; request: HttpRequest)]