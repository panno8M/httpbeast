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

from strformat import
  `&`


type
  FdKind = enum
    Server
    Client
    Dispatcher

  RequestData = object
    ## - Client specific data.
    ## A queue of data that needs to be sent when the FD becomes writeable.
    responseBuffer: string
    ## The number of characters in `responseBuffer` that have been sent already.
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
    selector: Selector[FdEventHandle]
    client*: posix.SocketHandle
    # Determines where in the data buffer this request starts.
    # Only used for HTTP pipelining.
    start: int
    # Identifier used to distinguish requests.
    # Request has created by RequestData for each HTTP request (search "HTTP pipelining") so,
    # RequestData.requestID and Request.requestID is the same when they treat the same HTTP request.
    requestID: uint


  FdEventHandle = object
    case kind: FdKind ## Determines the fd kind (server, client, dispatcher)
    of Client:
      requestData: RequestData
    else: discard


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
      requestData: RequestData(
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

func isNeedsBody(httpMsg: openArray[char]): bool =
  # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
  # never need a body, so we just assume `start` at 0.
  let m = parseHttpMethod(httpMsg, start=0)
  m.isSome and m.get() in {HttpPost, HttpPut, HttpConnect, HttpPatch}

func hasHeaderTerminator(httpMsg: openArray[char]; outHeadersEndPos: var int): bool =
  # Find "\c\l\c\l" in the given string to indicate the end of the header.
  #
  #   Content-Type: text/plain\c\l\c\lHello, World!
  #                                   ^
  #   this proc returns the index of this char by "outHeadersEndPos".

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

func bodyInTransit(data: ptr RequestData): bool =
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
    inc requestCounter
    return requestCounter
  genRequestID

proc dateResponseHeader(): string = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc forgetCompletedRequest( selector: Selector[FdEventHandle];
                             fd: posix.SocketHandle
                           ) =
  # TODO: Logging that the socket was closed.

  template hasRequestInProcess(data: RequestData): bool =
    (not data.reqFut.isNil) and (not data.reqFut.finished)

  # TODO: Can POST body be sent with Connection: Close?
  var reqData = block:
    var data: ptr FdEventHandle = addr selector.getData(fd)
    if data.kind != Client: return
    data.requestData

  if reqData.hasRequestInProcess:
    # Close the socket only once the `onRequest` callback completes.
    reqData.reqFut.addCallback (_: Future[void]) => fd.close()
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
    let reqData {.inject.} = req.selector.getData(req.client).requestData.addr
    assert reqData.headersFinished, "Selector not ready to send."
    if reqData.requestID != req.requestID:
      raise HttpBeastDefect(msg: "You are attempting to send data to a stale request.")

    let otherHeaders = if likely(headers.len == 0): "" else: "\c\L" & headers
    var
      text = (
        "HTTP/1.1 $#\c\L" &
        "Content-Length: $#\c\LServer: $#\c\LDate: $#$#\c\L\c\L$#"
      ) % [$code, $body.len, serverInfo, dateResponseHeader(), otherHeaders, body]

    reqData.responseBuffer.add(text)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc httpMethod(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).requestData.httpMsg, req.start)

proc processEvents( selector: Selector[FdEventHandle];
                    keys: tuple[arr: array[64, ReadyKey], cnt: int];
                    onRequest: OnRequest;
                  ) =
  for rKey in keys.arr[0..<keys.cnt]:
    var fdEvent: ptr FdEventHandle = selector.getData(rKey.fd).addr
    # Handle error events first.
    if Event.Error in rKey.events:
      if isDisconnectionError({SocketFlag.SafeDisconn}, rKey.errorCode):
        forgetCompletedRequest(selector, SocketHandle(rKey.fd))
        break
      raiseOSError(rKey.errorCode)

    case fdEvent.kind
    of Server:
      when defined debugProcess:
        echo "[I/O]: server"
      let fd = posix.SocketHandle(rKey.fd)
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
      when defined debugProcess:
        echo "[I/O]: dispatcher"
      # Run the dispatcher loop.
      assert rKey.events == {Event.Read}
      asyncdispatch.poll(0)

    of Client:
      let clientFd = posix.SocketHandle(rKey.fd)
      if Event.Read in rKey.events:
        when defined debugProcess:
          echo "[I/O]: client.read"
        let reqDataSkeleton = fdEvent.requestData.addr
        var buf: array[256, char]
        # Read until EAGAIN. We take advantage of the fact that the client
        # will wait for a response after they send a request. So we can
        # comfortably continue reading until the message ends with \c\l
        # \c\l.
        while true:
          let recvLen = clientFd.recv(buf[0].addr, buf.len, 0.cint)
          if recvLen == -1: # Error!
            let lastError = osLastError()
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
              break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              forgetCompletedRequest(selector, clientFd)
              break
            raiseOSError(lastError)
          if recvLen == 0:
            forgetCompletedRequest(selector, clientFd)
            break

          block Write_buffer_to_our_data:
            let alreadyReceivedLen = reqDataSkeleton.httpMsg.len
            reqDataSkeleton.httpMsg.setLen(alreadyReceivedLen + recvLen)
            for i in 0..<recvLen:
              reqDataSkeleton.httpMsg[alreadyReceivedLen+i] = buf[i]

          var headersEndPos: int
          if reqDataSkeleton.httpMsg.hasHeaderTerminator(headersEndPos):

            # First line and headers for request received.
            reqDataSkeleton.headersEndPos = headersEndPos
            reqDataSkeleton.headersFinished = true
            when not defined(release):
              if reqDataSkeleton.responseBuffer.len != 0:
                logging.warn("sendQueue isn't empty.")
              if reqDataSkeleton.bytesResponded != 0:
                logging.warn("bytesSent isn't empty.")

            let waitingForBody = reqDataSkeleton.httpMsg.isNeedsBody and reqDataSkeleton.bodyInTransit()
            if unlikely(waitingForBody): continue

            for start in reqDataSkeleton.httpMsg.findHeadersBeginnings:
              # For pipelined requests, we need to reset this flag.
              reqDataSkeleton.headersFinished = true
              reqDataSkeleton.requestID = genRequestID()

              let request = Request(
                selector: selector,
                client: clientFd,
                start: start,
                requestID: reqDataSkeleton.requestID,
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

              when defined debugProcess:
                echo &"Got Request to { parsePath(request.selector.getData(request.client).requestData.httpMsg, request.start) } from: {reqDataSkeleton.ip}"

              reqDataSkeleton.reqFut = onRequest(request)
              template validateResponse(): untyped =
                if reqDataSkeleton.requestID == request.requestID:
                  reqDataSkeleton.headersFinished = false
              if reqDataSkeleton.reqFut.isNil:
                validateResponse()
              else:
                reqDataSkeleton.reqFut.addCallback proc(fut: Future[void]) =
                  onRequestFutureComplete(fut, selector, clientFd)
                  validateResponse()

          if recvLen != buf.len:
            # Assume there is nothing else for us right now and break.
            break
      elif Event.Write in rKey.events:
        when defined debugProcess:
          echo "[I/O]: client.write"
        let reqDataFilled = fdEvent.requestData.addr
        assert reqDataFilled.responseBuffer.len > 0
        assert reqDataFilled.bytesResponded < reqDataFilled.responseBuffer.len
        # Write the sendQueue.
        let leftover = reqDataFilled.responseBuffer.len-reqDataFilled.bytesResponded
        let sentLen = clientFd.send(
          reqDataFilled.responseBuffer[reqDataFilled.bytesResponded].addr,
          leftover, 0)
        if sentLen == -1: # Error!
          let lastError = osLastError()
          if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
            break
          if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
            forgetCompletedRequest(selector, clientFd)
            break
          raiseOSError(lastError)

        inc reqDataFilled.bytesResponded, sentLen

        if reqDataFilled.responseBuffer.len == reqDataFilled.bytesResponded:
          reqDataFilled.bytesResponded = 0
          reqDataFilled.responseBuffer.setLen(0)
          reqDataFilled.httpMsg.setLen(0)
          selector.updateHandle(clientFd, {Event.Read})
      else:
        assert false

