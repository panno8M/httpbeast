import unittest
include httpigeon/nest

from sugar import dump

proc generateRopeTmp(pattern: string, startIndex: Natural = 0): seq[MapperKnot] {.raises: [MappingError].} =
  ## Translates the string form of a pattern into a sequence of MapperKnot objects to be parsed against
  dump startIndex
  let token = block:
    var token: string
    const specialSectionStartChars = {pathSeparator, wildcard, startParam}
    discard pattern.parseUntil(token, specialSectionStartChars, startIndex)
    token

  # when "/pathto/{param}" and start == 0: newStartIndex points 0 of first '/'.
  # when "/pathto/{param}" and start == 1: newStartIndex points 8 of third '/'.
  # when "/pathto/{param}" and start == 8: newStartIndex points 9 of '{'.
  # anywhere, 
  var newStartIndex: Natural = startIndex + token.len
  dump token

  dump newStartIndex

  # no more wildcards or parameter defs, the rest is static text
  # Process when terminal section of the pattern is: "path"
  # not is: "{param}", "*", "{param}$", "*$"
  # E.g. "somewhere" of "/path/to/somewhere".
  if newStartIndex >= pattern.len:
    result = newSeq[MapperKnot](token.len)
    for i, c in token:
      result[i] = MapperKnot(kind:ptrnText, value:($c))
    return

  # we encountered a wildcard or parameter def, there could be more left
  let specialChar = pattern[newStartIndex]
  inc newStartIndex

  let scanner = case specialChar
  of pathSeparator: MapperKnot(kind:ptrnText, value:($pathSeparator))
  of wildcard:
    if pattern[newStartIndex] != greedyIndicator: MapperKnot(kind:ptrnWildcard)
    else:
      inc newStartIndex
      raiseMappingError (pattern.len != newStartIndex), "$ found before end of route"
      MapperKnot(kind:ptrnWildcard, isGreedy:true)
  of startParam:
    var paramName : string
    let paramNameSize = pattern.parseUntil(paramName, endParam, newStartIndex)
    inc newStartIndex, (paramNameSize+1)
    if pattern.len <= newStartIndex or pattern[newStartIndex] != greedyIndicator:
      MapperKnot(kind:ptrnParam, value:paramName)
    else:
      inc newStartIndex
      raiseMappingError (pattern.len != newStartIndex), "$ found before end of route"
      MapperKnot(kind:ptrnParam, value:paramName, isGreedy:true)
  else: raise newException(MappingError, "Unrecognized special character")

  var prefix = if token.len == 0: @[scanner]
    else: @[MapperKnot(kind:ptrnText, value:token), scanner]

  let suffix = generateRopeTmp(pattern, newStartIndex)

  func isEmptyKnotSequence(knotSeq: seq[MapperKnot]): bool =
    ## A knot sequence is empty if it A) contains no elements or B) it contains a single text element with no value
    result = (knotSeq.len == 0 or (knotSeq.len == 1 and knotSeq[0].kind == ptrnText and knotSeq[0].value == ""))

  return if suffix.isEmptyKnotSequence: prefix
    else: concat(prefix, suffix)

suite "generateRope":
  # echo generateRope("/path/to/somewhere").toString()
  # echo generateRope("/").toString()
  # echo generateRope("/path").toString()
  # echo generateRopeTmp("/path/to/{obj}")
  # echo generateRope("/path/to/*").toString()
  discard generateRope("/{user}")
  discard generateRope("/*$")
  discard generateRope("/*")

