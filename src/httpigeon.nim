import macros
from strformat import `&`

import httpigeon/httpbeast
import httpigeon/nest

export httpbeast, nest

type Response* = object
  code*: HttpCode
  additionalHeaders*: HttpHeaders
  body*: string

proc newResponse*(
      code: HttpCode;
      additionalHeaders: HttpHeaders;
      body: string;
    ): Response =
  Response(
    code: code,
    additionalHeaders: additionalHeaders,
    body: body
  )
proc newResponse*(body: string): Response = newResponse(Http200, newHttpHeaders(), body)
proc newResponse*(additionalHeaders: HttpHeaders; body: string): Response = newResponse(Http200, additionalHeaders, body)

proc respond*(req: Request; response: Response) = req.respond(response.code, response.body, response.additionalHeaders)

template `$:`*(keyValuePairs: openArray[tuple[key: string, val: string]]): HttpHeaders = newHttpHeaders(keyValuePairs)

type RequestHandler* = proc(
    req: Request;
    args: RoutingArgs;
  ): Response {.gcsafe.}


macro mappingOn*[T](router: Router[T]; path = "/"; body: untyped): untyped =
  type RequestHook = object
    httpMethod: NimNode
    processBody: NimNode
  type NestHook = object
    path: NimNode
    body: NimNode
  var requestHooks = newSeq[RequestHook]()
  var nestHooks = newSeq[NestHook]()
  result = newStmtList()
  for topStmt in body:
    case topStmt.kind:
    of nnkCommand:
      if topStmt[0].kind == nnkIdent and topStmt[0].eqIdent "on":
        let requestHookDef = topStmt
        requestHookDef[1].expectKind nnkIdent
        requestHookDef[2].expectKind nnkStmtList
        requestHooks.add RequestHook(
          httpMethod: requestHookDef[1],
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
    for requestHook in requestHooks:
      result.add newCall(
        newIdentNode("map"),
        router,
        newNimNode(nnkLambda)
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(newNimNode(nnkFormalParams)
            .add(newIdentNode("Response"))
            .add(newIdentDefs(newIdentNode("req"), newIdentNode("Request")))
            .add(newIdentDefs(newIdentNode("args"), newIdentNode("RoutingArgs")))
          )
          .add(newEmptyNode())
          .add(newEmptyNode())
          .add(requestHook.processBody),
        requestHook.httpMethod,
        newStrLitNode(path.strVal),
      )
      echo &"mapping: {path.strVal} => {requestHook.httpMethod}"
    for nestHook in nestHooks:
      result.add newCall(
        newIdentNode("mappingOn"),
        router,
        newStrLitNode(path.strVal & nestHook.path.strVal & "/"),
        nestHook.body,
      )

macro mapping*[T](router: Router[T]; body: untyped): untyped =
  newStmtList(
    newCall(
      newIdentNode("mappingOn"),
      router,
      newStrLitNode("/"),
      body,
    )
  )