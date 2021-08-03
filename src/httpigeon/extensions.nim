import options
import types

type
  Extension* = object
    onRoutingFailure*: Option[proc(req: HttpRequest): Option[HttpResponse]]
    parseRegularResponse*: Option[proc(response: var HttpResponse; request: HttpRequest)]
    perThreadInitialization*: Option[proc(){.gcsafe.}]