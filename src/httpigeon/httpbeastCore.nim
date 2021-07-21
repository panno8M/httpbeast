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

  Data = object
    ## Future for onRequest handler (may be nil).
    reqFut: Future[void]
    ## Identifier for current request. Mainly for better detection of cross-talk.
    requestID: uint
    case fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
    of Client:
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
    else: discard

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
    reusePort: bool
      ## controls whether to fail with "Address already in use".
      ## Setting this to false will raise when `threads` are on.
    loggers: seq[Logger]

  HttpBeastDefect* = ref object of Defect

const
  serverInfo = "Httpigeon"


func newData(fdKind: FdKind; ip = ""): Data =
  case fdKind
  of Client:
    Data(fdKind: fdKind,
         headersEndPos: -1, ## By default we assume the fast case: end of data.
         ip: ip
        )
  else:
    Data(fdKind: fdKind)

proc onRequestFutureComplete( theFut: Future[void];
                              selector: Selector[Data];
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

proc dateResponseHeader(): string = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc forgetCompletedRequest( selector: Selector[Data];
                             fd: posix.SocketHandle
                           ) =
  # TODO: Logging that the socket was closed.

  proc hasRequestInProcess(data: ptr Data): bool =
    case data.fdKind
    of Client:
      (not data.reqFut.isNil) and (not data.reqFut.finished)
    else: false

  # TODO: Can POST body be sent with Connection: Close?
  var data: ptr Data = addr selector.getData(fd)
  if data.hasRequestInProcess:
    # Close the socket only once the `onRequest` callback completes.
    data.reqFut.addCallback (_: Future[void]) => fd.close()
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
    let requestData {.inject.} = req.selector.getData(req.client).addr
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
  parseHttpMethod(req.selector.getData(req.client).httpMsg, req.start)

proc processEvents( selector: Selector[Data];
                    keys: tuple[arr: array[64, ReadyKey], cnt: int];
                    onRequest: OnRequest;
                  ) =
  for rKey in keys.arr[0..<keys.cnt]:
    let fd = posix.SocketHandle(rKey.fd)
    var data: ptr Data = addr(selector.getData(fd))
    # Handle error events first.
    if Event.Error in rKey.events:
      if isDisconnectionError({SocketFlag.SafeDisconn}, rKey.errorCode):
        forgetCompletedRequest(selector, fd)
        break
      raiseOSError(rKey.errorCode)

    case data.fdKind
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
      selector.registerHandle(client, {Event.Read}, newData(Client, ip=address))

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
            if unlikely(waitingForBody): continue

            for start in data.httpMsg.findHeadersBeginnings:
              # For pipelined requests, we need to reset this flag.
              data.headersFinished = true
              data.requestID = genRequestID()

              let request = Request(
                selector: selector,
                client: fd,
                start: start,
                requestID: data.requestID,
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

              data.reqFut = onRequest(request)
              template validateResponse(): untyped =
                if data.requestID == request.requestID:
                  data.headersFinished = false
              if data.reqFut.isNil:
                validateResponse()
              else:
                data.reqFut.addCallback proc(fut: Future[void]) =
                  onRequestFutureComplete(fut, selector, fd)
                  validateResponse()

          if ret != size:
            # Assume there is nothing else for us right now and break.
            break
      elif Event.Write in rKey.events:
        assert data.respondQueue.len > 0
        assert data.bytesResponded < data.respondQueue.len
        # Write the sendQueue.
        let leftover = data.respondQueue.len-data.bytesResponded
        let ret = send(fd, addr data.respondQueue[data.bytesResponded],
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

        data.bytesResponded.inc(ret)

        if data.respondQueue.len == data.bytesResponded:
          data.bytesResponded = 0
          data.respondQueue.setLen(0)
          data.httpMsg.setLen(0)
          selector.updateHandle(fd, {Event.Read})
      else:
        assert false

