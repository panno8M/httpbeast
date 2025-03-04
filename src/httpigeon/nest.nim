## HTTP router based on routing trees

import strutils, parseutils, strtabs, sequtils, httpcore
import critbits
import URI

export URI, strtabs

#
# Type Declarations
#

const
  pathSeparator = '/'
  allowedCharsInUrl = {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', pathSeparator}
  wildcard = '*'
  startParam = '{'
  endParam = '}'
  greedyIndicator = '$'
  allowedCharsInPattern = allowedCharsInUrl + {wildcard, startParam, endParam, greedyIndicator}

type
  PatternMatchingType = enum ## Kinds of elements that may appear in a mapping
    ptrnWildcard
    ptrnParam
    ptrnText
    ptrnStartHeaderConstraint
    ptrnEndHeaderConstraint

  # Structures for setting up the mappings
  MapperKnot = object ## A token within a URL to be mapped. The URL is broken into 'knots' that make up a 'rope' (``seq[MapperKnot]``)
    isGreedy : bool
    case kind : PatternMatchingType
    of ptrnParam, ptrnText:
      value : string
    of ptrnStartHeaderConstraint:
      headerName : string
    else: discard

  # Structures for holding fully parsed mappings
  PatternNode[H] = ref object ## A node within a routing tree, usually constructed from a ``MapperKnot``
    isGreedy : bool
    case kind : PatternMatchingType # TODO: should be able to extend MapperKnot to get this, compiler wont let me, investigate further. Nim compiler bug maybe?
      of ptrnParam, ptrnText:
        value : string
      of ptrnStartHeaderConstraint:
        headerName : string
      else: discard
    case isLeaf : bool #a leaf node is one with no children
      of false:
        children : seq[PatternNode[H]]
      else: discard
    case isTerminator : bool # a terminator is a node that can be considered a mapping on its own, matching could stop at this node or continue. If it is not a terminator, matching can only continue
      of true:
        handler : H
      else: discard


  # Router Structures
  Router*[H] = ref object ## Container that holds HTTP mappings to handler procs
    verbTrees : CritBitTree[PatternNode[H]]

  RoutingArgs* = object ## Arguments extracted from a request while routing it
    pathArgs* : StringTableRef
    queryArgs* : StringTableRef

  RoutingResultType* = enum ## Possible results of a routing operation
    routingSuccess
    routingFailure
  RoutingResult*[H] = object ## Encapsulates the results of a routing operation
    case status* : RoutingResultType
    of routingSuccess:
      handler* : H
      arguments* : RoutingArgs
    else: discard

  # Exceptions
  MappingError* = object of ValueError ## Indicates an error while creating a new mapping

func raiseMappingError(condition: bool; msg: string) =
  if condition: raise newException(MappingError, msg)

#
# Stringification / other operators
#
func `$`(piece : MapperKnot) : string =
  case piece.kind
  of ptrnParam, ptrnText:
    result = $(piece.kind) & ":" & piece.value
  of ptrnWildcard, ptrnEndHeaderConstraint:
    result = $(piece.kind)
  of ptrnStartHeaderConstraint:
    result = $(piece.kind) & ":" & piece.headerName
func `$`[H](node : PatternNode[H]) : string =
  case node.kind
  of ptrnParam, ptrnText:
    result = $(node.kind) & ":value=" & node.value & ", "
  of ptrnWildcard, ptrnEndHeaderConstraint:
    result = $(node.kind) & ":"
  of ptrnStartHeaderConstraint:
    result = $(node.kind) & ":" & node.headerName & ", "
  result = result & "leaf=" & $node.isLeaf & ", terminator=" & $node.isTerminator & ", greedy=" & $node.isGreedy

func `==`[H](node : PatternNode[H], knot : MapperKnot) : bool =
  result = (node.kind == knot.kind)

  if result:
    result = case node.kind
    of ptrnText, ptrnParam: node.value == knot.value
    of ptrnStartHeaderConstraint: node.headerName == knot.headerName
    else: result

#
# Debugging routines
#

func printRoutingTree[H](node : PatternNode[H], tabs = 0) =
  debugEcho ' '.repeat(tabs), $node
  if not node.isLeaf:
    for child in node.children:
      child.printRoutingTree(tabs+1)
func printRoutingTree*[H](router : Router[H]) =
  for verb, tree in router.verbTrees:
    debugEcho verb.toUpper()
    tree.printRoutingTree()

#
# Constructors
#
func newRouter*[H]() : Router[H] =
  ## Creates a new ``Router`` instance
  result = Router[H](verbTrees:CritBitTree[PatternNode[H]]())

#
# Rope procedures. A rope is a chain of tokens representing the url
#

func ensureCorrectRoute(path: string): string {.raises:[MappingError].} =
  ## Verifies that this given path is a valid path, strips trailing slashes, and guarantees leading slashes
  if not path.allCharsInSet(allowedCharsInPattern):
    raise newException(MappingError, "Illegal characters occurred in the mapped pattern, please restrict to alphanumerics, or the following: - . _ ~ /")

  # Pass the case: "/"
  if path.len == 1 and path[0] == '/': return path

  result = path
  # Parse the case: "path/to/some/" -> "path/to/some"
  if result[^1] == pathSeparator: result = result[0..^2]
  # Parse the case: "path/to/some" -> "/path/to/some"
  if result[0] != pathSeparator: result.insert("/")

func generateRope(pattern: string, startIndex: Natural = 0): seq[MapperKnot] {.raises: [MappingError].} =
  ## Translates the string form of a pattern into a sequence of MapperKnot objects to be parsed against
  let plainPathToken = block:
    var token: string
    const specialSectionStartChars = {pathSeparator, wildcard, startParam}
    discard pattern.parseUntil(token, specialSectionStartChars, startIndex)
    token

  # when "/pathto/{param}" and start == 0: newStartIndex points 0 of first '/'.
  # when "/pathto/{param}" and start == 1: newStartIndex points 8 of third '/'.
  # when "/pathto/{param}" and start == 9: newStartIndex points 9 of '{'.
  # when "/pathto/{param}" and start == 16: newStartIndex points 16 of end.
  let specialCharIdx: Natural = startIndex + plainPathToken.len

  # no more wildcards or parameter defs, the rest is static text
  # Process when terminal section of the pattern is: "path"
  # not is: "{param}", "*", "{param}$", "*$"
  # E.g. "somewhere" of "/path/to/somewhere".
  if specialCharIdx >= pattern.len:
    result = newSeq[MapperKnot](plainPathToken.len)
    for i, c in plainPathToken:
      result[i] = MapperKnot(kind:ptrnText, value:($c))
    return

  # we encountered a wildcard or parameter def, there could be more left
  # var newStartIndex = succ specialCharIdx
  let (scanner, endOfSection) = case pattern[specialCharIdx]
  of pathSeparator: (MapperKnot(kind:ptrnText, value:($pathSeparator)), specialCharIdx+1)
  of wildcard:
    if specialCharIdx+1 < pattern.len and pattern[specialCharIdx+1] == greedyIndicator:
      raiseMappingError (specialCharIdx+2 != pattern.len), "$ found before end of route"
      (MapperKnot(kind:ptrnWildcard, isGreedy:true), specialCharIdx+2)
    else: (MapperKnot(kind:ptrnWildcard), specialCharIdx+1)
  of startParam:
    var paramName: string
    let paramNameSize = pattern.parseUntil(paramName, endParam, specialCharIdx+1)
    let endOfSection = specialCharIdx+paramNameSize+2
    # ../somepath/{param}/some
    #             ^ specialCharIdx
    # And, paramSize == len(param) == 5
    # So, endOfSection points:
    # ../somepath/{param}/some
    #                    ^ this.
    if endOfSection < pattern.len and pattern[endOfSection] == greedyIndicator:
      raiseMappingError (pattern.len != endOfSection+1), "$ found before end of route"
      (MapperKnot(kind:ptrnParam, value:paramName, isGreedy:true), endOfSection+1)
    else:
      (MapperKnot(kind:ptrnParam, value:paramName), endOfSection)
  else: raise newException(MappingError, "Unrecognized special character")

  var prefix = if plainPathToken.len == 0: @[scanner]
    else: @[MapperKnot(kind:ptrnText, value:plainPathToken), scanner]

  let suffix = generateRope(pattern, endOfSection)

  func isEmpty(knotSeq: seq[MapperKnot]): bool =
    ## A knot sequence is empty if it A) contains no elements or B) it contains a single text element with no value
    result = (knotSeq.len == 0 or (knotSeq.len == 1 and knotSeq[0].kind == ptrnText and knotSeq[0].value == ""))

  return if suffix.isEmpty: prefix
    else: concat(prefix, suffix)


#
# Node procedures. A pattern node represents part of a chain representing a matchable path
#

proc terminatingPatternNode[H](
  oldNode : PatternNode[H],
  knot : MapperKnot,
  handler : H
) : PatternNode[H] {.raises: [MappingError].} =
  ## Turns the given node into a terminating node ending at the given knot/handler pair. If it is already a terminator, throws an exception
  if oldNode.isTerminator: # Already mapped
    raise newException(MappingError, "Duplicate mapping detected")
  result = case knot.kind
  of ptrnText:
    PatternNode[H](kind: ptrnText, value: knot.value, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)
  of ptrnParam:
    PatternNode[H](kind: ptrnParam, value: knot.value, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler, isGreedy : knot.isGreedy)
  of ptrnWildcard:
    PatternNode[H](kind: ptrnWildcard, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler, isGreedy : knot.isGreedy)
  of ptrnEndHeaderConstraint:
    PatternNode[H](kind: ptrnEndHeaderConstraint, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)
  of ptrnStartHeaderConstraint:
    PatternNode[H](kind: ptrnStartHeaderConstraint, headerName: knot.headerName, isLeaf: oldNode.isLeaf, isTerminator: true, handler: handler)

  result.handler = handler

  if not result.isLeaf:
    result.children = oldNode.children

proc parentalPatternNode[H](oldNode : PatternNode[H]) : PatternNode[H] =
  ## Turns the given node into a parent node. If it not a leaf node, this returns a new copy of the input.
  result = case oldNode.kind
  of ptrnText:
    PatternNode[H](kind: ptrnText, value: oldNode.value, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)
  of ptrnParam:
    PatternNode[H](kind: ptrnParam, value: oldNode.value, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator, isGreedy: oldNode.isGreedy)
  of ptrnWildcard:
    PatternNode[H](kind: ptrnWildcard, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator, isGreedy: oldNode.isGreedy)
  of ptrnEndHeaderConstraint:
    PatternNode[H](kind: ptrnEndHeaderConstraint, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)
  of ptrnStartHeaderConstraint:
    PatternNode[H](kind: ptrnStartHeaderConstraint, headerName: oldNode.headerName, isLeaf: false, children: newSeq[PatternNode[H]](), isTerminator: oldNode.isTerminator)

  if result.isTerminator:
    result.handler = oldNode.handler

func indexOf[H](nodes : seq[PatternNode[H]], knot : MapperKnot) : int =
  ## Finds the index of nodes that matches the given knot. If none is found, returns -1
  for index, child in nodes:
    if child == knot:
      return index
  return -1 #the 'not found' value

func chainTree[H](rope : seq[MapperKnot], handler : H) : PatternNode[H] =
  ## Creates a tree made up of single-child nodes that matches the given rope. The last node in the tree is a terminator with the given handler.
  let knot = rope[0]
  let lastKnot = (rope.len == 1) #since this is a chain tree, the only leaf node is the terminator node, so they are mutually linked, if this is true then it is both

  result = case knot.kind
  of ptrnText:
    PatternNode[H](kind: ptrnText, value: knot.value, isLeaf: lastKnot, isTerminator: lastKnot)
  of ptrnParam:
    PatternNode[H](kind: ptrnParam, value: knot.value, isLeaf: lastKnot, isTerminator: lastKnot, isGreedy: knot.isGreedy)
  of ptrnWildcard:
    PatternNode[H](kind: ptrnWildcard, isLeaf: lastKnot, isTerminator: lastKnot, isGreedy: knot.isGreedy)
  of ptrnEndHeaderConstraint:
    PatternNode[H](kind: ptrnEndHeaderConstraint, isLeaf: lastKnot, isTerminator: lastKnot)
  of ptrnStartHeaderConstraint:
    PatternNode[H](kind: ptrnStartHeaderConstraint, headerName: knot.headerName, isLeaf: lastKnot, isTerminator: lastKnot)

  if lastKnot:
    result.handler = handler
  else:
    result.children = @[chainTree(rope[1.. ^1], handler)] #continue the chain

proc merge[H](
  node : PatternNode[H],
  rope : seq[MapperKnot],
  handler : H
) : PatternNode[H] {.raises: [MappingError].} =
  ## Merges the given sequence of MapperKnots into the given tree as a new mapping. This does not mutate the given node, instead it will return a new one
  if rope.len == 1: # Terminating knot reached, finish the merge
    result = terminatingPatternNode(node, rope[0], handler)
  else:
    let currentKnot = rope[0]
    let nextKnot = rope[1]
    let remainder = rope[1.. ^1]

    assert node == currentKnot

    var childIndex = -1
    if node.isLeaf: #node isn't a parent yet, make it one to continue the process
      result = parentalPatternNode(node)
    else:
      result = node
      childIndex = node.children.indexOf(nextKnot)

    if childIndex == -1: # the next knot doesn't map to a child of this node, needs to me directly translated into a deep tree (one branch per level)
      result.children.add(chainTree(remainder, handler)) # make a node containing everything remaining and inject it
    else:
      result.children[childIndex] = merge(result.children[childIndex], remainder, handler)

func contains[H](
  node : PatternNode[H],
  rope : seq[MapperKnot]
) : bool  =
  ## Determines whether or not merging rope into node will create a mapping conflict
  if rope.len == 0: return
  let knot = rope[0]

  # Is this node equal to the knot?
  result = if node.kind == knot.kind:
    case node.kind
    of ptrnText: node.value == knot.value
    of ptrnStartHeaderConstraint: node.headerName == knot.headerName
    else: true
  else:
    if
      (node.kind == ptrnWildcard and knot.kind == ptrnParam) or
      (node.kind == ptrnParam and knot.kind == ptrnWildcard) or
      (node.kind == ptrnWildcard and knot.kind == ptrnText) or
      (node.kind == ptrnParam and knot.kind == ptrnText) or
      (node.kind == ptrnText and knot.kind == ptrnParam) or
      (node.kind == ptrnText and knot.kind == ptrnWildcard):
      true
    else: false

  if not node.isLeaf and result: # if the node has kids, is at least one qual?
    if node.children.len > 0:
      result = false # false until proven otherwise
      for child in node.children:
        if child.contains(rope[1.. ^1]): # does the child match the rest of the rope?
          result = true
          break
  elif node.isLeaf and rope.len > 1: # the node is a leaf but we want to map further to it, so it won't conflict
    result = false

#
# Mapping procedures
#

proc map*[H](
  router : Router[H],
  handler : H,
  httpMethod: HttpMethod,
  pattern : string,
  headers : HttpHeaders = nil
) =
  ## Add a new mapping to the given ``Router`` instance
  var rope = generateRope(ensureCorrectRoute(pattern)) # initial rope

  if not headers.isNil: # extend the rope with any header constraints
    for key, value in pairs(headers):
      rope.add(MapperKnot(kind:ptrnStartHeaderConstraint, headerName:key))
      rope = concat(rope, generateRope(value))
      rope.add(MapperKnot(kind:ptrnEndHeaderConstraint))

  var nodeToBeMerged : PatternNode[H]
  if router.verbTrees.hasKey($httpMethod):
    nodeToBeMerged = router.verbTrees[$httpMethod]
    if nodeToBeMerged.contains(rope):
      raise newException(MappingError, "Duplicate mapping encountered: " & pattern)
  else:
    nodeToBeMerged = PatternNode[H](kind:ptrnText, value:($pathSeparator), isLeaf:true, isTerminator:false)

  router.verbTrees[$httpMethod] = nodeToBeMerged.merge(rope, handler)

#
# Data extractors and utilities
#

proc extractEncodedParams(input : string) : StringTableRef =
  var index = 0
  result = newStringTable()

  while index < input.len:
    var paramValuePair : string
    let pairSize = input.parseUntil(paramValuePair, '&', index)

    index += pairSize + 1

    let equalIndex = paramValuePair.find('=')

    if equalIndex == -1: #no equals, just a boolean "existance" variable
      result[paramValuePair] = "" #just insert a record into the param table to indicate that it exists
    else: #is a 'setter' parameter
      let paramName = paramValuePair[0..equalIndex-1]
      let paramValue = paramValuePair[equalIndex+1..^1]
      result[paramName] = paramValue

#
# Compression routines, compression makes matching more efficient. Once compressed, a router is immutable
#
proc compress[H](node : PatternNode[H]) : PatternNode[H] =
  ## Finds sequences of single ptrnText nodes and combines them to reduce the depth of the tree
  if node.isLeaf: #if it's a leaf, there are clearly no descendents, and if it is a terminator then compression will alter the behavior
    return node
  elif node.kind == ptrnText and not node.isTerminator and node.children.len == 1:
    let compressedChild = compress(node.children[0])
    if compressedChild.kind == ptrnText:
      result = compressedChild
      result.value = node.value & compressedChild.value
      return

  result = node
  result.children = map(result.children, compress)

proc compress*[H](router : Router[H]) =
  ## Compresses the entire contents of the given ``Router``. Successive calls will recompress, but may not be efficient, so use this only when mapping is complete for the best effect
  for index, existing in pairs(router.verbTrees):
    router.verbTrees[index] = compress(existing)

#
# Procedures to match against paths
#

proc matchTree[H](
  head : PatternNode[H],
  path : string,
  headers : HttpHeaders,
  pathIndex : int = 0,
  pathArgs : StringTableRef = newStringTable()
) : RoutingResult[H] =
  ## Check whether the given path matches the given tree node starting from pathIndex
  var node = head
  var pathIndex = pathIndex

  block matching:
    while pathIndex >= 0:
      case node.kind
      of ptrnText:
        if path.continuesWith(node.value, pathIndex):
          pathIndex += node.value.len
        else:
          break matching
      of ptrnWildcard:
        if node.isGreedy:
          pathIndex = path.len
        else:
          pathIndex = path.find(pathSeparator, pathIndex) #skip forward to the next separator
          if pathIndex == -1:
            pathIndex = path.len
      of ptrnParam:
        if node.isGreedy:
          pathArgs[node.value] = path[pathIndex.. ^1]
          pathIndex = path.len
        else:
          let newPathIndex = path.find(pathSeparator, pathIndex) #skip forward to the next separator
          if newPathIndex == -1:
            pathArgs[node.value] = path[pathIndex.. ^1]
            pathIndex = path.len
          else:
            pathArgs[node.value] = path[pathIndex..newPathIndex - 1]
            pathIndex = newPathIndex
      of ptrnStartHeaderConstraint:
        for child in node.children:
          var p = ""
          if not headers.isNil:
            p = toString(headers.getOrDefault(node.headerName))
          let childResult = child.matchTree(
            path=p,
            pathIndex=0,
            headers=headers
          )

          if childResult.status == routingSuccess:
            for key, value in childResult.arguments.pathArgs:
              pathArgs[key] = value
            return RoutingResult[H](
              status:routingSuccess,
              handler:childResult.handler,
              arguments:RoutingArgs(pathArgs:pathArgs)
            )
        return RoutingResult[H](status:routingFailure)
      of ptrnEndHeaderConstraint:
        if node.isTerminator and node.isLeaf:
          return RoutingResult[H](
            status:routingSuccess,
            handler:node.handler,
            arguments:RoutingArgs(pathArgs:pathArgs)
          )

      if pathIndex == path.len and node.isTerminator: #the path was exhausted and we reached a node that has a handler
        return RoutingResult[H](
          status:routingSuccess,
          handler:node.handler,
          arguments:RoutingArgs(pathArgs:pathArgs)
        )
      elif not node.isLeaf: #there is children remaining, could match against children
        if node.children.len == 1: #optimization for single child that just points the node forward
          node = node.children[0]
        else: #more than one child
          assert node.children.len != 0
          for child in node.children:
            result = child.matchTree(path, headers, pathIndex, pathArgs)
            if result.status == routingSuccess:
              return
          break matching #none of the children matched, assume no match
      else: #its a leaf and we havent' satisfied the path yet, let the last line handle returning
        break matching

  result = RoutingResult[H](status:routingFailure)

proc route*[H](
  router : Router[H],
  requestMethod : HttpMethod,
  requestUri : URI,
  requestHeaders : HttpHeaders = newHttpHeaders(),
) : RoutingResult[H] =
  ## Find a mapping that matches the given request description
  try:
      if router.verbTrees.hasKey($requestMethod):
        result = matchTree(router.verbTrees[$requestMethod], ensureCorrectRoute(requestUri.path), requestHeaders)

        if result.status == routingSuccess:
          result.arguments.queryArgs = extractEncodedParams(requestUri.query)
      else:
        result = RoutingResult[H](status:routingFailure)
  except MappingError:
    result = RoutingResult[H](status:routingFailure)