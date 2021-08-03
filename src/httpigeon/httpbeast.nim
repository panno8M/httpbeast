include httpbeastCore
from sequtils import foldl
from strformat import `&`
from strutils import join, parseInt
from osproc import countProcessors
from deques import len
import options

import extensions

export httpCore

# API definition ...
# ==================


proc respondAsIs_unsafe*(req: Request; data: string) {.inline.} =
  ## Sends the specified data on the request socket.
  ##
  ## This function can be called as many times as necessary.
  ##
  ## It does not
  ## check whether the socket is in a state that can be written so be
  ## careful when using it.
  if req.client notin req.selector: return

  let reqData {.inject.} = req.selector.getData(req.client).requestData.addr
  reqData.responseBuffer.add(data)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

##############
export respond # (req: Request; code: HttpCode; body, headers = "")
##############

proc respond*(req: Request; code: HttpCode; body = ""; headers: HttpHeaders) =
  var headerstrings: seq[string]
  if headers != nil:
    for key, val in headers.table.pairs:
      headerstrings.add key & ": " & val.foldl(a & "; " & b)
  req.respond code, body, headerstrings.join("\c\L")

proc respond*(req: Request; body: string; code = Http200) {.inline.} =
  ## Sends a HTTP 200 OK response with the specified body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.
  req.respond(code, body)

proc rawMessage*(req: Request): string {.inline.} =
  req.selector.getData(req.client).requestData.httpMsg

#################
export httpMethod
#################

proc path*(req: Request): Option[string] {.inline.} =
  ## Parses the request's data to find the request target.
  if unlikely(req.client notin req.selector): return
  parsePath(req.selector.getData(req.client).requestData.httpMsg, req.start)

proc headers*(req: Request): Option[HttpHeaders] =
  ## Parses the request's data to get the headers.
  if unlikely(req.client notin req.selector): return
  parseHeaders(req.selector.getData(req.client).requestData.httpMsg, req.start)

proc body*(req: Request): Option[string] =
  ## Retrieves the body of the request.
  let reqData = req.selector.getData(req.client).requestData
  let pos = reqData.headersEndPos
  if pos == -1: return none(string)
  result = reqData.httpMsg[pos..^1].some()

  when not defined release:
    let length =
      if req.headers.get().hasKey("Content-Length"):
        req.headers.get()["Content-Length"].parseInt()
      else: 0
    assert result.get().len == length

proc ip*(req: Request): string =
  ## Retrieves the IP address that the request was made from.
  req.selector.getData(req.client).requestData.ip

proc forget*(req: Request) =
  ## Unregisters the underlying request's client socket from httpbeast's
  ## event loop.
  ##
  ## This is useful when you want to register ``req.client`` in your own
  ## event loop, for example when wanting to integrate httpbeast into a
  ## websocket library.
  assert req.selector.getData(req.client).requestData.requestID == req.requestID
  req.selector.unregister(req.client)


# procs that decide num of threads to use ===
type NumThreadsDeterminate* = proc(): Natural
let useAllAvailable*: NumThreadsDeterminate =
  func(): Natural =
    result = when not compileOption("threads"): 1
    else: countProcessors()
    if result == 0:
      raise HttpBeastDefect(msg:"Cannot get the number of threads available automatic. Set it to by manually")
func manually*(num: Natural): NumThreadsDeterminate =
  return func(): Natural =
    case num:
    of 0: raise HttpBeastDefect(msg:" The server cannot run because num is set to 0.")
    of 1: num
    else:
      when not compileOption("threads"):
        raise HttpBeastDefect(msg:"To run in multi-threaded mode, you need to add the --thread:on compile option")
      num

proc newSettings*( port = Port(8080);
                   bindAddr = "";
                   domain = Domain.AF_INET;
                   reusePort = true;
                 ): Settings =
  Settings(
    port: port,
    bindAddr: bindAddr,
    domain: domain,
    loggers: getHandlers(),
    reusePort: reusePort,
  )


proc runInThread*(params: (OnRequest, Settings, Option[seq[Extension]])) =
  ## running in each threads.
  let (onRequest, settings, oExtensions) = params

  for logger in settings.loggers:
    addHandler(logger)

  let server = block make_server_socket:
    let sock = newSocket(settings.domain)
    sock.getFd().setBlocking(false)
    sock.setSockOpt(OptReuseAddr, true)
    sock.setSockOpt(OptReusePort, settings.reusePort)
    sock.bindAddr(settings.port, settings.bindAddr)
    sock.listen()
    sock

  let selector = newSelector[FdEventHandle]()
  selector.registerHandle(
    server.getFd(),
    {Event.Read},
    newFdEventHandle(Server))

  let disp = getGlobalDispatcher()
  selector.registerHandle(
    getIoHandler(disp).getFd(),
    {Event.Read},
    newFdEventHandle(Dispatcher))

  if oExtensions.isSome:
    let extensions = oExtensions.get()
    for extension in extensions:
      if extension.perThreadInitialization.isSome():
        {.gcsafe.}:
          extension.perThreadInitialization.get()()

  var ret: array[64, ReadyKey]
  while true:
    const noTimeOut = -1
    let cntret = selector.selectInto(noTimeOut, ret)
    processEvents(selector, (ret, cntret), onRequest)

    # Ensure callbacks list doesn't grow forever in asyncdispatch.
    # See https://github.com/nim-lang/Nim/issues/7532.
    # Not processing callbacks can also lead to exceptions being silently
    # lost!
    if unlikely(asyncdispatch.getGlobalDispatcher().callbacks.len > 0):
      asyncdispatch.poll(0)


proc run*( onRequest: OnRequest;
           settings = newSettings();
           extensions = none(seq[Extension]);
           numThreadsDeterminate = useAllAvailable;
         ) =
  ## Starts the HTTP server and calls `onRequest` for each request.
  ##
  ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
  ## unlike most asynchronous procedures in Nim, it can return ``nil``
  ## for better performance, when no async operations are needed.

  let numThreads = numThreadsDeterminate()

  echo &"Starting {numThreads} threads"

  case numThreads:
  of 0: raise HttpBeastDefect(msg:"numThread has set to 0. Set it to valid value")
  of 1: # run as single-thread app.
    runInThread((onRequest, settings, extensions))
  else: # run as multi-thread app.
    if not settings.reusePort:
      raise HttpBeastDefect(msg: "--threads:on requires reusePort to be enabled in settings")

    var threads = newSeq[Thread[(OnRequest, Settings, Option[seq[Extension]])]](numThreads)
    for thread in threads.mitems:
      createThread(thread, runInThread, (onRequest, settings, extensions))
    echo &"Listening on port {settings.port}" # This line is used in the tester to signal readiness.
    joinThreads(threads)

when false:
  proc close*(port: Port) =
    ## Closes an httpbeast server that is running on the specified port.
    ##
    ## **NOTE:** This is not yet implemented.

    assert false
    # TODO: Figure out the best way to implement this. One way is to use async
    # events to signal our `eventLoop`. Maybe it would be better not to support
    # multiple servers running at the same time?