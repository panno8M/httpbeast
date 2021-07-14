import options, httpcore

proc parseHttpMethod_default(data: string, start: int): Option[HttpMethod] =
  case data[start]
  of 'G':
    if data[start+1] == 'E' and data[start+2] == 'T':
      return some(HttpGet)
  of 'H':
    if data[start+1] == 'E' and data[start+2] == 'A' and data[start+3] == 'D':
      return some(HttpHead)
  of 'P':
    if data[start+1] == 'O' and data[start+2] == 'S' and data[start+3] == 'T':
      return some(HttpPost)
    if data[start+1] == 'U' and data[start+2] == 'T':
      return some(HttpPut)
    if data[start+1] == 'A' and data[start+2] == 'T' and
       data[start+3] == 'C' and data[start+4] == 'H':
      return some(HttpPatch)
  of 'D':
    if data[start+1] == 'E' and data[start+2] == 'L' and
       data[start+3] == 'E' and data[start+4] == 'T' and
       data[start+5] == 'E':
      return some(HttpDelete)
  of 'O':
    if data[start+1] == 'P' and data[start+2] == 'T' and
       data[start+3] == 'I' and data[start+4] == 'O' and
       data[start+5] == 'N' and data[start+6] == 'S':
      return some(HttpOptions)
  else: discard

  return none(HttpMethod)

proc parseHttpMethod_nestCase(data: string, start: int): Option[HttpMethod] =
  ## Parses the data to find the request HttpMethod.

  # HTTP methods are case sensitive.
  # (RFC7230 3.1.1. "The request method is case-sensitive.")
  case data[start]
  of 'G':
    if data[start+1] == 'E' and data[start+2] == 'T':
      return some(HttpGet)
  of 'H':
    if data[start+1] == 'E' and data[start+2] == 'A' and data[start+3] == 'D':
      return some(HttpHead)
  of 'P':
    case data[start+1]
    of 'O':
      if data[start+2] == 'S' and data[start+3] == 'T':
        return some(HttpPost)
    of 'U':
      if data[start+2] == 'T':
        return some(HttpPut)
    of 'A':
      if data[start+2] == 'T' and data[start+3] == 'C' and data[start+4] == 'H':
        return some(HttpPatch)
    else: discard
  of 'D':
    if data[start+1] == 'E' and data[start+2] == 'L' and
       data[start+3] == 'E' and data[start+4] == 'T' and
       data[start+5] == 'E':
      return some(HttpDelete)
  of 'O':
    if data[start+1] == 'P' and data[start+2] == 'T' and
       data[start+3] == 'I' and data[start+4] == 'O' and
       data[start+5] == 'N' and data[start+6] == 'S':
      return some(HttpOptions)
  else: discard

  return none(HttpMethod)

proc parseHttpMethod_nestCase_stringComp(data: string, start: int): Option[HttpMethod] =
  template `@`(a: int): untyped = (start+a)
  template `~`(a, b: int): untyped = ((start+a)..(start+b))
  case data[@0]
  of 'G':
    if data[1~2] == "ET": return some(HttpGet)
  of 'H':
    if data[1~3] == "EAD": return some(HttpHead)
  of 'P':
    case data[@1]
    of 'O':
      if data[2~3] == "ST": return some(HttpPost)
    of 'U':
      if data[@2] == 'T': return some(HttpPut)
    of 'A':
      if data[2~4] == "TCH": return some(HttpPatch)
    else: discard
  of 'D':
    if data[1~5] == "ELETE": return some(HttpDelete)
  of 'O':
    if data[1~6] == "PTIONS": return some(HttpOptions)
  else: discard

  return none(HttpMethod)

proc parseHttpMethod_nestCase_withTemplate(data: string, start: int): Option[HttpMethod] =
  ## Parses the data to find the request HttpMethod.

  # HTTP methods are case sensitive.
  # (RFC7230 3.1.1. "The request method is case-sensitive.")
  proc continueWith(data: string, start: int, target: string): bool{.inline.} =
    for i in 0..<target.len:
      if data[start+i] != target[i]: return false
    return true

  case data[start]
  of 'G':
    if data.continueWith(start+1, "ET"): return some(HttpGet)
  of 'H':
    if data.continueWith(start+1, "EAD"): return some(HttpHead)
  of 'P':
    case data[start+1]
    of 'O':
      if data.continueWith(start+2, "ST"): return some(HttpPost)
    of 'U':
      if data[start+2] == 'T': return some(HttpPut)
    of 'A':
      if data.continueWith(start+2, "TCH"): return some(HttpPatch)
    else: discard
  of 'D':
    if data.continueWith(start+1, "ELETE"): return some(HttpDelete)
  of 'O':
    if data.continueWith(start+1, "PTIONS"): return some(HttpOptions)
  else: discard

  return none(HttpMethod)

import unittest
from times import cpuTime
from sequtils import newSeqWith
from strformat import `&`
from math import sum
suite "parseHttpMethod benchmark":
  const repeatTimes = 10
  let testData = [
    """GET /user/me HTTP/1.1""",
    """PATCH /user/me HTTP/1.1""",
    """OPTIONS /user/me HTTP/1.1""",
    """AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA /user/me HTTP/1.1""",
    """A /user/me HTTP/1.1""",
    """OPTIONZZZZZZz /user/me HTTP/1.1""",
  ]
  let parsers = [
    parseHttpMethod_default,
    parseHttpMethod_nestCase,
    parseHttpMethod_nestCase_stringComp,
    parseHttpMethod_nestCase_withTemplate,
  ]
  for testDatum in testData:
    echo "[case] ", testDatum
    var resultTimes = newSeqWith(parsers.len, newSeq[float](repeatTimes))
    for i_repeat in 0..<repeatTimes:
      for i_p, parser in parsers:
        let timeBegin = cpuTime()
        for i in 0..50000:
          discard parser(testDatum, 0)
        resultTimes[i_p][i_repeat] = cpuTime()-timeBegin

    for i, results in resultTimes:
      echo &"#{i}: {results.sum()/results.len.float}"
