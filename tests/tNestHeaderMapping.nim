import unittest, uri, httpcore
import httpigeon/nest

suite "Header Mapping":
  proc testHandler() = echo "test"

  test "Root with content-type header":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/", newHttpHeaders({"content-type": "text/plain"}))
    let goodResult = r.route(HttpGet, parseUri("/"), newHttpHeaders({"content-type": "text/plain"}))
    check(goodResult.status == routingSuccess)
    let badResult = r.route(HttpGet, parseUri("/"), newHttpHeaders({"content-type": "text/html"}))
    check(badResult.status == routingFailure)

  test "Parameterized with content-type header":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/test/{param1}", newHttpHeaders({"content-type": "text/plain"}))
    let goodResult = r.route(HttpGet, parseUri("/test/foo"), newHttpHeaders({"content-type": "text/plain"}))
    check(goodResult.status == routingSuccess)
    let badResult = r.route(HttpGet, parseUri("/test/foo"), newHttpHeaders({"content-type": "text/html"}))
    check(badResult.status == routingFailure)

  test "Root with multiple header constraints":
    let r = newRouter[proc()]()
    r.map(
      testHandler,
      HttpGet,
      "/",
      newHttpHeaders({
        "host": "localhost",
        "content-type": "text/plain"
      })
    )
    let goodResult = r.route(HttpGet, parseUri("/"), newHttpHeaders({"content-type": "text/plain", "host": "localhost"}))
    check(goodResult.status == routingSuccess)
    let wrongContentType = r.route(HttpGet, parseUri("/"), newHttpHeaders({"content-type": "text/html", "host": "localhost"}))
    check(wrongContentType.status == routingFailure)
    let wrongHost = r.route(HttpGet, parseUri("/"), newHttpHeaders({"content-type": "text/plain", "host": "127.0.0.1"}))
    check(wrongHost.status == routingFailure)

  test "Header constraints don't conflict with other mappings":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/constrained", newHttpHeaders({"content-type": "text/plain"}))
    r.map(testHandler, HttpGet, "/unconstrained")

    let constrainedRouteWithHeader = r.route(HttpGet, parseUri("/constrained"), newHttpHeaders({"content-type": "text/plain"}))
    check(constrainedRouteWithHeader.status == routingSuccess)
    let constrainedRouteNoHeader = r.route(HttpGet, parseUri("/constrained"))
    check(constrainedRouteNoHeader.status == routingFailure)
    let unconstrainedRouteWithHeader = r.route(HttpGet, parseUri("/unconstrained"), newHttpHeaders({"content-type": "text/plain"}))
    check(unconstrainedRouteWithHeader.status == routingSuccess)
    let unconstrainedRouteNoHeader = r.route(HttpGet, parseUri("/unconstrained"))
    check(unconstrainedRouteNoHeader.status == routingSuccess)
