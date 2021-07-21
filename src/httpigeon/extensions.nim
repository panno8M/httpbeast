import options
import httpbeast
import basic

type
  Extension* = object
    onRoutingFailure*: Option[proc(req: Request): Option[Response]]