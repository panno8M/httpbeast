import tables
import httpcore
import strutils
import ../basic
import sugar
import options
import strformat
import sequtils

type BoundType = enum
  None, Nomal, End
proc isBound(str: ptr string; boundary: string; start: Natural): BoundType = 
  if str[start] != '-' or str[start+1] != '-': return None
  for i_boundary, ch in boundary:
    if str[start+2+i_boundary] != ch:
      return None
  if str[start+2+boundary.len+0] == '-' and
     str[start+2+boundary.len+1] == '-' and
     str[start+2+boundary.len+2] == '\c' and
     str[start+2+boundary.len+3] == '\l':
    return End
  if str[start+2+boundary.len] == '\c' and str[start+2+boundary.len+1] == '\l':
    return Nomal

  return None

proc multiPartFormData*( httpRequest: HttpRequest;
                         outErrorMsg: var string
                      #  ): seq[tuple[headers: TableRef[string, seq[string]]; body: string]] =
                       ): TableRef[string, tuple[headers: TableRef[string, seq[string]]; body: string]] =
  template returnWithError(msg: string): untyped =
    outErrorMsg = msg; return

  if not httpRequest.headers.hasKey("Content-Type"):
    returnWithError("request has no \"Content-Type\" header")

  let boundary = block:
    let contentType = httpRequest.headers["Content-Type"].split("; ")
    var
      hasIdentifier: bool
      boundary: string
    for ct in contentType:
      if ct == "multipart/form-data":
        hasIdentifier = true
      if ct[0] == 'b' and
        ct[1] == 'o' and
        ct[2] == 'u' and
        ct[3] == 'n' and
        ct[4] == 'd' and
        ct[5] == 'a' and
        ct[6] == 'r' and
        ct[7] == 'y' and
        ct[8] == '=':
        boundary = ct[9..^1]
      if hasIdentifier and boundary != "": break

    if not hasIdentifier:
      returnWithError("Content-Type must be multipart/form-data")
    if boundary == "":
      returnWithError("Boundary is not specified in Content-Type.")
    boundary

  if httpRequest.body.isNone:
    returnWithError("Request needs body")

  var body = httpRequest.body.get()

  # if body[0..<(4+boundary.len)] != &"--{boundary}\c\l" or
  #    body[^(6+boundary.len)..^1] != &"--{boundary}--\c\l":
  #   returnWithError("Invalid data structure")

  # var bodies = httpRequest.body.get()
  #   .split("--" & boundary & "\c\l")[1..^1]
  # bodies[^1] = bodies[^1][0..^(6+boundary.len)]

  # echo httpRequest.body
  # echo bodies

  type SearchMode = enum
    Bound, Header, Body
  var
    i: int
    resultData = newSeq[tuple[headers: TableRef[string, seq[string]]; body: string]]()
    mode = Bound
  while true:
    if i >= body.len:
      returnWithError("Invalid structure")

    case mode
    of Bound:
      case body.addr.isBound(boundary, i)
      of None: discard
      of Nomal:
        inc i, 2+boundary.len+1
        mode = Header
      of End:
        result = newTable[string, tuple[headers: TableRef[string, seq[string]], body: string]](resultData.len)
        for resultDatum in resultData:
          let name = resultDatum.headers["Content-Disposition"].filterIt(it[0..3] == "name")[0][6..^2]
          result[name] = resultDatum
        return result

    of Header:
      var
        tmp: tuple[name: string; contents: seq[string]] = ("", newSeq[string]())
        resultheader = newTable[string, seq[string]]()
      var i_header = i
      while true:
        case body[i_header+1]
        of ':':
          if body[i_header+2] == ' ':
            tmp.name = body[i..i_header]
            i = i_header+3

        of ';':
          if body[i_header+2] == ' ':
            tmp.contents.add body[i..i_header]
            i = i_header+3

        of '\c':
          if body[i_header+2] == '\l':
            tmp.contents.add body[i..i_header]
            i = i_header+3
            resultheader[tmp.name] = tmp.contents
            tmp = ("", newSeq[string]())

            if body[i_header+3] == '\c' and
               body[i_header+4] == '\l':
              resultData.add (resultHeader, "")
              i = i_header+4
              break
        else: discard

        inc i_header
        if i_header+4 == body.len:
          i = i_header+4
          break
      mode = Body

    of Body:
      for i_body in i..<(body.len-2):
        if body[i_body+1] == '\c' and
           body[i_body+2] == '\l' and
           body.addr.isBound(boundary, i_body+3) != None:
          resultData[^1].body = body[i..i_body]
          i = i_body+2
          break
      mode = Bound
    inc i
