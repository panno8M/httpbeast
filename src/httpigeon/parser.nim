import options, httpcore, parseutils

func parseHttpMethod*(httpMsg: string, start: int): Option[HttpMethod] =
  ## Parses the httpMsg to find the request HttpMethod.

  # HTTP methods are case sensitive.
  # (RFC7230 3.1.1. "The request method is case-sensitive.")

  case httpMsg[start]
  of 'D':
    if httpMsg[start+1] == 'E' and httpMsg[start+2] == 'L' and
       httpMsg[start+3] == 'E' and httpMsg[start+4] == 'T' and
       httpMsg[start+5] == 'E':
      return some(HttpDelete)
  of 'G':
    if httpMsg[start+1] == 'E' and httpMsg[start+2] == 'T':
      return some(HttpGet)
  of 'H':
    if httpMsg[start+1] == 'E' and httpMsg[start+2] == 'A' and httpMsg[start+3] == 'D':
      return some(HttpHead)
  of 'O':
    if httpMsg[start+1] == 'P' and httpMsg[start+2] == 'T' and
       httpMsg[start+3] == 'I' and httpMsg[start+4] == 'O' and
       httpMsg[start+5] == 'N' and httpMsg[start+6] == 'S':
      return some(HttpOptions)
  of 'P':
    case httpMsg[start+1]
    of 'A':
      if httpMsg[start+2] == 'T' and httpMsg[start+3] == 'C' and httpMsg[start+4] == 'H':
        return some(HttpPatch)
    of 'O':
      if httpMsg[start+2] == 'S' and httpMsg[start+3] == 'T':
        return some(HttpPost)
    of 'U':
      if httpMsg[start+2] == 'T':
        return some(HttpPut)
    else: discard
  else: discard

  return none(HttpMethod)

func parsePath*(httpMsg: string, start: int): Option[string] =
  ## Parses the request path from the specified httpMsg.
  if unlikely(httpMsg.len == 0): return

  # Find the first ' '.
  # We can actually start ahead a little here. Since we know
  # the shortest HTTP method: 'GET'/'PUT'.
  var i = start+2
  while httpMsg[i] notin {' ', '\0'}: i.inc()

  if likely(httpMsg[i] == ' '):
    # Find the second ' '.
    i.inc() # Skip first ' '.
    let start = i
    while httpMsg[i] notin {' ', '\0'}: i.inc()

    if likely(httpMsg[i] == ' '):
      return some(httpMsg[start..<i])
  else:
    return none(string)

func parseHeaders*(httpMsg: string, start: int): Option[HttpHeaders] =
  if unlikely(httpMsg.len == 0): return
  var pairs: seq[(string, string)] = @[]

  var i = start
  # Skip first line containing the method, path and HTTP version.
  while httpMsg[i] != '\l': i.inc

  i.inc # Skip \l

  var value = false
  var current: (string, string) = ("", "")
  while i < httpMsg.len:
    case httpMsg[i]
    of ':':
      if value: current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0:
          current[1].add(httpMsg[i])
      else:
        current[0].add(httpMsg[i])
    of '\c':
      discard
    of '\l':
      if current[0].len == 0:
        # End of headers.
        return some(newHttpHeaders(pairs))

      pairs.add(current)
      value = false
      current = ("", "")
    else:
      if value:
        current[1].add(httpMsg[i])
      else:
        current[0].add(httpMsg[i])
    i.inc()

  return none(HttpHeaders)

func parseContentLength*(httpMsg: string, start: int): int =
  result = 0

  let headers = httpMsg.parseHeaders(start)
  if headers.isNone(): return

  if unlikely(not headers.get().hasKey("Content-Length")): return

  discard headers.get()["Content-Length"].parseSaturatedNatural(result)

iterator findHeadersBeginnings*(httpMsg: string): int =
  ## Yields the start position of each request in `httpMsg`.
  ##
  ## This is only necessary for support of HTTP pipelining. The assumption
  ## is that there is a request at position `0`, and that there MAY be another
  ## request further in the httpMsg buffer.
  yield 0

  var cBound = 4 # "c" means candidate.
  template isBound(cBound: int): bool =
    httpMsg[cBound-4] == '\c' and httpMsg[cBound-3] == '\l' and
    httpMsg[cBound-2] == '\c' and httpMsg[cBound-1] == '\l'
  template hasBoundPiece(cBound: int): bool = httpMsg[cBound-1] in {'\c', '\l'}
  while cBound <= len(httpMsg):
    if not cBound.hasBoundPiece: inc cBound, 4; continue
    if not cBound.isBound: inc cBound; continue

    let bound = cBound
    inc cBound, 4

    if likely(bound == len(httpMsg)): break
    if parseHttpMethod(httpMsg, bound).isNone(): continue
    yield bound

  # while cBound < len(httpMsg):
  #   if cBound.isBound:
  #     let bound = cBound
  #     if likely(bound == len(httpMsg)): break
  #     if parseHttpMethod(httpMsg, bound).isNone(): continue
  #     yield bound
  #     inc cBound, 4
  #   inc cBound
