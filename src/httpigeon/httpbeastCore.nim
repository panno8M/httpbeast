import parser

import
  httpcore,
  nativesockets,
  net,
  asyncdispatch,
  selectors,
  posix,
  tables,
  options,
  logging
  
from os import
  osLastError,
  osErrorMsg,
  raiseOSError

from times import
  now,
  utc,
  format

from sugar import
  `=>`

from strutils import
  `%`


type
  FdKind = enum
    Server
    Client
    Dispatcher

  ClientData = object
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

  FdEventHandle = object
    case kind: FdKind ## Determines the fd kind (server, client, dispatcher)
    of Client:
      clientData: ClientData
    else: discard

  Request* = object
    selector: Selector[FdEventHandle]
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
    reusePort: bool
      ## controls whether to fail with "Address already in use".
      ## Setting this to false will raise when `threads` are on.
    loggers: seq[Logger]

  HttpBeastDefect* = ref object of Defect

const
  serverInfo = "Httpigeon"


func newFdEventHandle(kind: FdKind; ip = ""): FdEventHandle =
  case kind
  of Client:
    FdEventHandle(
      kind: kind,
      clientData: ClientData(
        headersEndPos: -1, ## By default we assume the fast case: end of data.
        ip: ip,
        ),
      )
  else:
    FdEventHandle(kind: kind)

proc onRequestFutureComplete( theFut: Future[void];
                              selector: Selector[FdEventHandle];
                              fd: SocketHandle;
                            ) =
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

func bodyInTransit(data: ptr ClientData): bool =
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

proc dateResponseHeader(): string = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc forgetCompletedRequest( selector: Selector[FdEventHandle];
                             fd: posix.SocketHandle
                           ) =
  # TODO: Logging that the socket was closed.

  template hasRequestInProcess(data: ClientData): bool =
    (not data.reqFut.isNil) and (not data.reqFut.finished)

  # TODO: Can POST body be sent with Connection: Close?
  var data: ptr FdEventHandle = addr selector.getData(fd)
  if data.kind != Client: return

  if data.clientData.hasRequestInProcess:
    # Close the socket only once the `onRequest` callback completes.
    data.clientData.reqFut.addCallback (_: Future[void]) => fd.close()
    # Unregister fd so that we don't receive any more events for it.
    # Once we do so the `data` will no longer be accessible.
    selector.unregister(fd)
  else:
    # The `onRequest` callback isn't in progress, so we can close the socket.
    selector.unregister(fd)
    fd.close()

proc respond(req: Request; code: HttpCode; body, headers = "") =
  ## Responds with the specified HttpCode and body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.

  if req.client notin req.selector: return

  block:
    let data {.inject.} = req.selector.getData(req.client).addr
    template requestData(): untyped = data.clientData
    assert requestData.headersFinished, "Selector not ready to send."
    if requestData.requestID != req.requestID:
      raise HttpBeastDefect(msg: "You are attempting to send data to a stale request.")

    let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
    var
      text = (
        "HTTP/1.1 $#\c\L" &
        "Content-Length: $#\c\LServer: $#\c\LDate: $#$#\c\L\c\L$#"
      ) % [$code, $body.len, serverInfo, dateResponseHeader(), otherHeaders, body]

    requestData.respondQueue.add(text)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc httpMethod(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).clientData.httpMsg, req.start)

proc processEvents( selector: Selector[FdEventHandle];
                    keys: tuple[arr: array[64, ReadyKey], cnt: int];
                    onRequest: OnRequest;
                  ) =
  for rKey in keys.arr[0..<keys.cnt]:
    let fd = posix.SocketHandle(rKey.fd)
    var fdEvent: ptr FdEventHandle = addr(selector.getData(fd))
    # Handle error events first.
    if Event.Error in rKey.events:
      if isDisconnectionError({SocketFlag.SafeDisconn}, rKey.errorCode):
        forgetCompletedRequest(selector, fd)
        break
      raiseOSError(rKey.errorCode)

    case fdEvent.kind
    of Server:
      assert Event.Read in rKey.events,
        "Only Read events are expected for the server"

      let (client, address) = fd.accept()
      if client == osInvalidSocket:
        let lastError = osLastError()

        if lastError.int32 == EMFILE:
          warn("Ignoring EMFILE error: ", osErrorMsg(lastError))
          return

        raiseOSError(lastError)
      client.setBlocking(false)
      selector.registerHandle(
        client,
        {Event.Read},
        newFdEventHandle(Client, ip=address))

    of Dispatcher:
      # Run the dispatcher loop.
      assert rKey.events == {Event.Read}
      asyncdispatch.poll(0)

    of Client:
      let clientData = fdEvent.clientData.addr
      if Event.Read in rKey.events:
        const size = 256
        var buf: array[size, char]
        # Read until EAGAIN. We take advantage of the fact that the client
        # will wait for a response after they send a request. So we can
        # comfortably continue reading until the message ends with \c\l
        # \c\l.
        while true:
          let ret = recv(fd, addr buf[0], size, 0.cint)
          if ret == -1: # Error!
            let lastError = osLastError()
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
              break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              forgetCompletedRequest(selector, fd)
              break
            raiseOSError(lastError)
          if ret == 0:
            forgetCompletedRequest(selector, fd)
            break

          # Write buffer to our data.
          let origLen = clientData.httpMsg.len
          clientData.httpMsg.setLen(origLen + ret)
          for i in 0 ..< ret: clientData.httpMsg[origLen+i] = buf[i]

          if clientData.httpMsg.hasCorrectHeaders((var headersEndPos: int; headersEndPos)):
            # First line and headers for request received.
            clientData.headersEndPos = headersEndPos
            clientData.headersFinished = true
            when not defined(release):
              if clientData.respondQueue.len != 0:
                logging.warn("sendQueue isn't empty.")
              if clientData.bytesResponded != 0:
                logging.warn("bytesSent isn't empty.")

            let waitingForBody = clientData.httpMsg.isNeedsBody and clientData.bodyInTransit()
            if unlikely(waitingForBody): continue

            for start in clientData.httpMsg.findHeadersBeginnings:
              # For pipelined requests, we need to reset this flag.
              clientData.headersFinished = true
              clientData.requestID = genRequestID()

              let request = Request(
                selector: selector,
                client: fd,
                start: start,
                requestID: clientData.requestID,
              )

              proc isValidateRequest(req: Request): bool =
                ## Handles protocol-mandated responses.
                ##
                ## Returns ``false`` when the request has been handled.
                # From RFC7231: "When a request method is received
                # that is unrecognized or not implemented by an origin server, the
                # origin server SHOULD respond with the 501 (Not Implemented) status
                # code."
                if req.httpMethod().isSome(): return true

              if not request.isValidateRequest():
                request.respond(Http501)
                continue

              clientData.reqFut = onRequest(request)
              template validateResponse(): untyped =
                if clientData.requestID == request.requestID:
                  clientData.headersFinished = false
              if clientData.reqFut.isNil:
                validateResponse()
              else:
                clientData.reqFut.addCallback proc(fut: Future[void]) =
                  onRequestFutureComplete(fut, selector, fd)
                  validateResponse()

          if ret != size:
            # Assume there is nothing else for us right now and break.
            break
      elif Event.Write in rKey.events:
        assert clientData.respondQueue.len > 0
        assert clientData.bytesResponded < clientData.respondQueue.len
        # Write the sendQueue.
        let leftover = clientData.respondQueue.len-clientData.bytesResponded
        let ret = send(fd, addr clientData.respondQueue[clientData.bytesResponded],
                       leftover, 0)
        if ret == -1:
          # Error!
          let lastError = osLastError()
          if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
            break
          if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
            forgetCompletedRequest(selector, fd)
            break
          raiseOSError(lastError)

        clientData.bytesResponded.inc(ret)

        if clientData.respondQueue.len == clientData.bytesResponded:
          clientData.bytesResponded = 0
          clientData.respondQueue.setLen(0)
          clientData.httpMsg.setLen(0)
          selector.updateHandle(fd, {Event.Read})
      else:
        assert false

