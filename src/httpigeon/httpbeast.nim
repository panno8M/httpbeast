import net, nativesockets, httpcore, asyncdispatch, strutils, posix, tables
import sugar
from sequtils import foldl
from selectors import Selector
                    , Event
                    , ReadyKey
                    , newSelector
                    , registerHandle
                    , updateHandle
                    , unregister
                    , getData
                    , getFd
                    , selectInto
                    , contains

from os import osLastError
             , osErrorMsg
             , raiseOSError
from osproc import countProcessors
from options import Option
                  , isNone
                  , isSome
                  , none
                  , some
                  , get
from logging import Logger
                  , getHandlers
                  , warn
                  , addHandler
from strformat import `&`
from deques import len

import times # TODO this shouldn't be required. Nim bug?

export httpcore

import parser

type
  FdKind = enum
    Server, Client, Dispatcher

  Data = object
    fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
    ## - Client specific data.
    ## A queue of data that needs to be sent when the FD becomes writeable.
    respondQueue: string
    ## The number of characters in `sendQueue` that have been sent already.
    bytesResponded: int
    ## Big chunk of data read from client during request.
    httpMsg: string
    ## Determines whether `httpMsg` contains "\c\l\c\l".
    headersFinished: bool
    ## Determines position of the end of "\c\l\c\l".
    headersEndPos: int
    ## The address that a `client` connects from.
    ip: string
    ## Future for onRequest handler (may be nil).
    reqFut: Future[void]
    ## Identifier for current request. Mainly for better detection of cross-talk.
    requestID: uint

  Request* = object
    selector: Selector[Data]
    client*: posix.SocketHandle
    # Determines where in the data buffer this request starts.
    # Only used for HTTP pipelining.
    start: int
    # Identifier used to distinguish requests.
    requestID: uint

  OnRequest* = proc (req: Request): Future[void] {.gcsafe.}

  Settings* = object
    port*: Port
    bindAddr*: string
    domain*: Domain
    numThreads: Natural
    loggers: seq[Logger]
    reusePort: bool
      ## controls whether to fail with "Address already in use".
      ## Setting this to false will raise when `threads` are on.

  HttpBeastDefect* = ref object of Defect

const
  serverInfo = "Httpigeon"

# procs that decide num of threads to use ===
type NumThreadsDeterminate = proc(): Natural {.noSideEffect.}
let automatic*: NumThreadsDeterminate =
  func(): Natural =
    result = when not compileOption("threads"): 1
    else: countProcessors()
    assert result != 0, "Cannot get the number of threads available automatic. Set it to by manually."
func manually*(num: Natural): NumThreadsDeterminate =
  return proc(): Natural = num
# ===========================================
proc newSettings*(port = Port(8080),
                   bindAddr = "",
                   numThreadsDeterminate = automatic,
                   domain = Domain.AF_INET,
                   reusePort = true,
                  ): Settings =
  Settings(
    port: port,
    bindAddr: bindAddr,
    domain: domain,
    numThreads: numThreadsDeterminate(),
    loggers: getHandlers(),
    reusePort: reusePort,
  )

func initData(fdKind: FdKind, ip = ""): Data =
  Data(fdKind: fdKind,
       respondQueue: "",
       bytesResponded: 0,
       httpMsg: "",
       headersFinished: false,
       headersEndPos: -1, ## By default we assume the fast case: end of data.
       ip: ip
      )

func onRequestFutureComplete(theFut: Future[void],
                             selector: Selector[Data], fd: int) =
  if theFut.failed:
    raise theFut.error

func isNeedsBody(httpMsg: string): bool =
  # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
  # never need a body, so we just assume `start` at 0.
  let m = parseHttpMethod(httpMsg, start=0)
  m.isSome() and m.get() in {HttpPost, HttpPut, HttpConnect, HttpPatch}

func hasCorrectHeaders(httpMsg: string; outHeadersEndPos: var int): bool =
  # Look for \c\l\c\l, the terminal of headers, inside the contents.
  # Content-Type: text/plain\c\l\c\lHello, World!
  #                                 ^
  #       The pos of it, in this case "H", is called terminal in this proc.

  template isTerminal(cEndPos#[ = candidate end pos ]#: int): bool =
    httpMsg[cEndPos-4] == '\c' and httpMsg[cEndPos-3] == '\l' and
    httpMsg[cEndPos-2] == '\c' and httpMsg[cEndPos-1] == '\l'

  block Short_circuit_when_the_contents_has_only_headers:
    if httpMsg.len.isTerminal:
      outHeadersEndPos= httpMsg.len
      return true

  if likely(not httpMsg.isNeedsBody): return

  var candidateEndPos = 4
  template hasTerminatorPiece(cEndPos: int): bool = httpMsg[cEndPos-1] in {'\c', '\l'}
  while candidateEndPos <= httpMsg.len:
    if not candidateEndPos.hasTerminatorPiece: inc candidateEndPos, 4; continue
    if not candidateEndPos.isTerminal: inc candidateEndPos; continue

    outHeadersEndPos = candidateEndPos
    return true

func bodyInTransit(data: ptr Data): bool =
  assert data.httpMsg.isNeedsBody, "Calling bodyInTransit now is inefficient."
  assert data.headersFinished

  if data.headersEndPos == -1: return false

  var trueLen = parseContentLength(data.httpMsg, start=0)

  let bodyLen = data.httpMsg.len - data.headersEndPos
  # TODO: Error handring when Content-Length of request header is wrong.
  assert bodyLen <= trueLen
  return bodyLen != trueLen

let genRequestID = block:
  var requestCounter: uint = 0
  proc genRequestID(): uint =
    if requestCounter == high(uint):
      requestCounter = 0
    requestCounter += 1
    return requestCounter
  genRequestID

var serverDate {.threadvar.}: string
proc updateDate(_: AsyncFD): bool =
  result = false # Returning true signifies we want timer to stop.
  serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc handleClientClosure(selector: Selector[Data],
                             fd: posix.SocketHandle|int) =
  # TODO: Logging that the socket was closed.

  # TODO: Can POST body be sent with Connection: Close?
  var data: ptr Data = addr selector.getData(fd)
  let isRequestComplete = data.reqFut.isNil or data.reqFut.finished
  if isRequestComplete:
    # The `onRequest` callback isn't in progress, so we can close the socket.
    selector.unregister(fd)
    fd.SocketHandle.close()
  else:
    # Close the socket only once the `onRequest` callback completes.
    data.reqFut.addCallback (_: Future[void]) => fd.SocketHandle.close()
    # Unregister fd so that we don't receive any more events for it.
    # Once we do so the `data` will no longer be accessible.
    selector.unregister(fd)


proc respondAsIs_unsafe*(req: Request, data: string) {.inline.} =
  ## Sends the specified data on the request socket.
  ##
  ## This function can be called as many times as necessary.
  ##
  ## It does not
  ## check whether the socket is in a state that can be written so be
  ## careful when using it.
  if req.client notin req.selector: return

  block:
    let requestData {.inject.} = req.selector.getData(req.client).addr
    requestData.respondQueue.add(data)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc respond*(req: Request, code: HttpCode, body: string, headers="") =
  ## Responds with the specified HttpCode and body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.

  if req.client notin req.selector: return

  block:
    let requestData {.inject.} = req.selector.getData(req.client).addr
    assert requestData.headersFinished, "Selector not ready to send."
    if requestData.requestID != req.requestID:
      raise HttpBeastDefect(msg: "You are attempting to send data to a stale request.")

    let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
    var
      text = (
        "HTTP/1.1 $#\c\L" &
        "Content-Length: $#\c\LServer: $#\c\LDate: $#$#\c\L\c\L$#"
      ) % [$code, $body.len, serverInfo, serverDate, otherHeaders, body]

    requestData.respondQueue.add(text)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc respond*(req: Request, code: HttpCode, body: string, headers: HttpHeaders) =
  var headerstrings: seq[string]
  for key, val in headers.table.pairs:
    headerstrings.add key & ": " & val.foldl(a & "; " & b)
  req.respond code, body, headerstrings.join("\c\L")

proc respond*(req: Request, code: HttpCode) =
  ## Responds with the specified HttpCode. The body of the response
  ## is the same as the HttpCode description.
  req.respond(code, $code)

proc respond*(req: Request, body: string, code = Http200) {.inline.} =
  ## Sends a HTTP 200 OK response with the specified body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.
  req.respond(code, body)

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).httpMsg, req.start)

proc isValidateRequest(req: Request): bool =
  ## Handles protocol-mandated responses.
  ##
  ## Returns ``false`` when the request has been handled.
  # From RFC7231: "When a request method is received
  # that is unrecognized or not implemented by an origin server, the
  # origin server SHOULD respond with the 501 (Not Implemented) status
  # code."
  if req.httpMethod().isSome(): return true


proc processEvents(selector: Selector[Data],
                   readyKeys: array[64, ReadyKey], count: int,
                   onRequest: OnRequest,
                  ) =
  for rKey in readyKeys[0..<count]:
    let fd = rKey.fd
    var data: ptr Data = addr(selector.getData(fd))
    # Handle error events first.
    if Event.Error in rKey.events:
      if isDisconnectionError({SocketFlag.SafeDisconn}, rKey.errorCode):
        handleClientClosure(selector, fd)
        break
      raiseOSError(rKey.errorCode)

    case data.fdKind
    of Server:
      if Event.Read in rKey.events:
        let (client, address) = fd.SocketHandle.accept()
        if client == osInvalidSocket:
          let lastError = osLastError()

          if lastError.int32 == EMFILE:
            warn("Ignoring EMFILE error: ", osErrorMsg(lastError))
            return

          raiseOSError(lastError)
        setBlocking(client, false)
        selector.registerHandle(client, {Event.Read}, initData(Client, ip=address))
      else:
        assert false, "Only Read events are expected for the server"
    of Dispatcher:
      # Run the dispatcher loop.
      assert rKey.events == {Event.Read}
      asyncdispatch.poll(0)
    of Client:
      if Event.Read in rKey.events:
        const size = 256
        var buf: array[size, char]
        # Read until EAGAIN. We take advantage of the fact that the client
        # will wait for a response after they send a request. So we can
        # comfortably continue reading until the message ends with \c\l
        # \c\l.
        while true:
          let ret = recv(fd.SocketHandle, addr buf[0], size, 0.cint)
          if ret == 0:
            handleClientClosure(selector, fd)
            break
          if ret == -1:
            # Error!
            let lastError = osLastError()
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
              break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              handleClientClosure(selector, fd)
              break
            raiseOSError(lastError)

          # Write buffer to our data.
          let origLen = data.httpMsg.len
          data.httpMsg.setLen(origLen + ret)
          for i in 0 ..< ret: data.httpMsg[origLen+i] = buf[i]

          if data.httpMsg.hasCorrectHeaders((var headersEndPos: int; headersEndPos)):
            # First line and headers for request received.
            data.headersEndPos = headersEndPos
            data.headersFinished = true
            when not defined(release):
              if data.respondQueue.len != 0:
                logging.warn("sendQueue isn't empty.")
              if data.bytesResponded != 0:
                logging.warn("bytesSent isn't empty.")

            let waitingForBody = data.httpMsg.isNeedsBody and bodyInTransit(data)
            if likely(not waitingForBody):
              for start in data.httpMsg.findHeadersBeginnings:
                # For pipelined requests, we need to reset this flag.
                data.headersFinished = true
                data.requestID = genRequestID()

                let request = Request(
                  selector: selector,
                  client: fd.SocketHandle,
                  start: start,
                  requestID: data.requestID,
                )

                template validateResponse(): untyped =
                  if data.requestID == request.requestID:
                    data.headersFinished = false

                if not request.isValidateRequest(): request.respond(Http501)
                else:
                  data.reqFut = onRequest(request)
                  if data.reqFut.isNil: validateResponse()
                  else:
                    data.reqFut.addCallback(
                      proc (fut: Future[void]) =
                        onRequestFutureComplete(fut, selector, fd)
                        validateResponse()
                    )

          if ret != size:
            # Assume there is nothing else for us right now and break.
            break
      elif Event.Write in rKey.events:
        assert data.respondQueue.len > 0
        assert data.bytesResponded < data.respondQueue.len
        # Write the sendQueue.
        let leftover = data.respondQueue.len-data.bytesResponded
        let ret = send(fd.SocketHandle, addr data.respondQueue[data.bytesResponded],
                       leftover, 0)
        if ret == -1:
          # Error!
          let lastError = osLastError()
          if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
            break
          if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
            handleClientClosure(selector, fd)
            break
          raiseOSError(lastError)

        data.bytesResponded.inc(ret)

        if data.respondQueue.len == data.bytesResponded:
          data.bytesResponded = 0
          data.respondQueue.setLen(0)
          data.httpMsg.setLen(0)
          selector.updateHandle(fd.SocketHandle, {Event.Read})
      else:
        assert false


proc eventLoop(params: (OnRequest, Settings)) =
  ## running in each threads.
  let (onRequest, settings) = params

  for logger in settings.loggers:
    addHandler(logger)

  let selector = newSelector[Data]()

  let server = newSocket(settings.domain)
  server.setSockOpt(OptReuseAddr, true)
  if compileOption("threads") and not settings.reusePort:
    raise HttpBeastDefect(msg: "--threads:on requires reusePort to be enabled in settings")
  server.setSockOpt(OptReusePort, settings.reusePort)
  server.bindAddr(settings.port, settings.bindAddr)
  server.listen()
  server.getFd().setBlocking(false)
  selector.registerHandle(server.getFd(), {Event.Read}, initData(Server))

  let disp = getGlobalDispatcher()
  selector.registerHandle(getIoHandler(disp).getFd(), {Event.Read},
                          initData(Dispatcher))

  # Set up timer to get current date/time.
  discard updateDate(0.AsyncFD)
  asyncdispatch.addTimer(1000, false, updateDate)

  var events: array[64, ReadyKey]
  while true:
    let ret = selector.selectInto(-1, events)
    processEvents(selector, events, ret, onRequest)

    # Ensure callbacks list doesn't grow forever in asyncdispatch.
    # See https://github.com/nim-lang/Nim/issues/7532.
    # Not processing callbacks can also lead to exceptions being silently
    # lost!
    if unlikely(asyncdispatch.getGlobalDispatcher().callbacks.len > 0):
      asyncdispatch.poll(0)



proc path*(req: Request): Option[string] {.inline.} =
  ## Parses the request's data to find the request target.
  if unlikely(req.client notin req.selector): return
  parsePath(req.selector.getData(req.client).httpMsg, req.start)

proc headers*(req: Request): Option[HttpHeaders] =
  ## Parses the request's data to get the headers.
  if unlikely(req.client notin req.selector): return
  parseHeaders(req.selector.getData(req.client).httpMsg, req.start)

proc body*(req: Request): Option[string] =
  ## Retrieves the body of the request.
  let pos = req.selector.getData(req.client).headersEndPos
  if pos == -1: return none(string)
  result = req.selector.getData(req.client).httpMsg[pos..^1].some()

  when not defined release:
    let length =
      if req.headers.get().hasKey("Content-Length"):
        req.headers.get()["Content-Length"].parseInt()
      else:
        0
    assert result.get().len == length

proc ip*(req: Request): string =
  ## Retrieves the IP address that the request was made from.
  req.selector.getData(req.client).ip

proc forget*(req: Request) =
  ## Unregisters the underlying request's client socket from httpbeast's
  ## event loop.
  ##
  ## This is useful when you want to register ``req.client`` in your own
  ## event loop, for example when wanting to integrate httpbeast into a
  ## websocket library.
  assert req.selector.getData(req.client).requestID == req.requestID
  req.selector.unregister(req.client)


proc run*(onRequest: OnRequest, settings: Settings) =
  ## Starts the HTTP server and calls `onRequest` for each request.
  ##
  ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
  ## unlike most asynchronous procedures in Nim, it can return ``nil``
  ## for better performance, when no async operations are needed.

  echo &"Starting {settings.numThreads} threads"

  case settings.numThreads:
  of 0: quit "numThread has set to 0. Set it to valid value."
  of 1: # run as single-thread app.
    eventLoop((onRequest, settings))
  else: # run as multi-thread app.
    var threads = newSeq[Thread[(OnRequest, Settings)]](settings.numThreads)
    for thread in threads.mitems:
      createThread(thread, eventLoop, (onRequest, settings))
    echo &"Listening on port {settings.port}" # This line is used in the tester to signal readiness.
    joinThreads(threads)

proc run*(onRequest: OnRequest) {.inline.} =
  ## Starts the HTTP server with default settings. Calls `onRequest` for each
  ## request.
  ##
  ## See the other ``run`` proc for more info.
  run(onRequest, newSettings())

when false:
  proc close*(port: Port) =
    ## Closes an httpbeast server that is running on the specified port.
    ##
    ## **NOTE:** This is not yet implemented.

    assert false
    # TODO: Figure out the best way to implement this. One way is to use async
    # events to signal our `eventLoop`. Maybe it would be better not to support
    # multiple servers running at the same time?
