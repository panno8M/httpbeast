import macros
import asyncdispatch
import options
import tables
import strutils
from uri import parseUri
from strformat import `&`

import httpigeon/httpbeast
import httpigeon/nest
import httpigeon/extensions
import httpigeon/basic

export httpbeast, nest, basic
type
  Pigeon* = ref object
    router: Router[RequestHandler]
    serverSettings: Settings
    extensions: Option[seq[Extension]]

var routerPtr: ptr Router[RequestHandler]

func newPigeon*(serverSettings = newSettings(); extensions: Option[seq[Extension]] = none(seq[Extension])): Pigeon =
  Pigeon(router: newRouter[RequestHandler](),
    serverSettings: serverSettings,
    extensions: extensions)

func parseBody*(body: string): Table[string, string] =
  if body == "": return
  let params = body.split("&")
  for param in params:
    var keyval = param.split("=", 1)
    if keyval.len < 2: continue
    result[keyval[0]] = keyval[1]

proc run*(pigeon: Pigeon) =
  pigeon.router.compress()
  routerPtr = pigeon.router.addr
  proc onRequest(req: Request) {.gcsafe, async.}  =
    if req.httpMethod.isNone or req.path.isNone: req.respond(Http404)
    let routingResult = routerPtr[].route(req.httpMethod.get(), req.path.get().parseUri())


    var httpRequest = block:
      let
        httpMethod = req.httpMethod
        path = req.path
        headers = req.headers

      if httpMethod.isNone or path.isNone or headers.isNone:
        req.respond(Http400)

      HttpRequest(
        raw: req.rawMessage,
        httpMethod: httpMethod.get(),
        ip: req.ip,
        path: path.get(),
        headers: headers.get(),
        body: req.body,
      )

    if routingResult.status == routingFailure:
      var responseFailure: HttpResponse = newResponse(Http404)
      if pigeon.extensions.isSome:
        # discard
        for ext in pigeon.extensions.get():
          if ext.onRoutingFailure.isSome:
            {.gcsafe.}:
              let oResponse = ext.onRoutingFailure.get()(httpRequest)
              if oResponse.isSome:
                responseFailure = oResponse.get()
      req.respond(responseFailure)
      return

    httpRequest.pathArgs = routingResult.arguments.pathArgs
    httpRequest.queryArgs = routingResult.arguments.queryArgs

    req.respond if pigeon.extensions.isNone:
      routingResult.handler(httpRequest)
    else:
      var response = routingResult.handler(httpRequest)
      for ext in pigeon.extensions.get():
        if ext.parseRegularResponse.isSome:
          {.gcsafe.}:
            ext.parseRegularResponse.get()(response, httpRequest)
      response

  run(onRequest, pigeon.serverSettings, pigeon.extensions)

proc map*(pigeon: Pigeon; handler: RequestHandler; httpMethod: HttpMethod; pattern: string; headers: HttpHeaders = nil) =
  pigeon.router.map(handler, httpMethod, pattern, headers)

template `$:`*(keyValuePairs: openArray[tuple[key: string, val: string]]): HttpHeaders = newHttpHeaders(keyValuePairs)

macro mappingOn*(pigeon: Pigeon; path = "/"; body: untyped): untyped =
  type RequestHook = object
    httpMethod: NimNode
    # process: NimNode
    processBody: NimNode
  type NestHook = object
    path: NimNode
    body: NimNode
  var requestHooks = newSeq[RequestHook]()
  var nestHooks = newSeq[NestHook]()
  for topStmt in body:
    case topStmt.kind:
    of nnkCommand:
      if topStmt[0].kind == nnkIdent and topStmt[0].eqIdent "on":
        let requestHookDef = topStmt
        requestHookDef[1].expectKind nnkIdent
        requestHookDef[2].expectKind nnkStmtList
        requestHooks.add RequestHook(
          httpMethod: requestHookDef[1],
          # process: requestHookDef[2][0],
          processBody: requestHookDef[2],
        )
    of nnkPrefix:
      if topStmt[0].kind == nnkIdent and topStmt[0].eqIdent "/":
        let nestDef = topStmt
        nestDef[1].expectKind nnkStrLit
        nestDef[2].expectKind nnkStmtList
        nestHooks.add NestHook(
          path: nestDef[1],
          body: nestDef[2],
        )

    else: discard
  block rendering:
    result = newStmtList()
    for requestHook in requestHooks:
      result.add newCall(
        newIdentNode("map"),
        pigeon,
        # requestHook.process,
        newNimNode(nnkLambda)
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(newNimNode(nnkFormalParams)
            .add(newIdentNode("HttpResponse"))
            .add(newIdentDefs(newIdentNode("request"), newIdentNode("HttpRequest")))
          )
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(requestHook.processBody),
        requestHook.httpMethod,
        newStrLitNode(path.strVal),
      )
      echo &"mapping: {($requestHook.httpMethod)[4..^1]:6}: {path.strVal}"
    for nestHook in nestHooks:
      result.add newCall(
        newIdentNode("mappingOn"),
        pigeon,
        newStrLitNode(path.strVal & nestHook.path.strVal & "/"),
        nestHook.body,
      )

macro mapping*(pigeon: Pigeon; body: untyped): untyped =
  newStmtList(
    newCall(
      newIdentNode("mappingOn"),
      pigeon,
      newStrLitNode("/"),
      body,
    )
  )