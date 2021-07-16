import unittest, uri
import httpcore
import httpigeon/nest

suite "Basic Mapping":
  proc testHandler() = echo "test"

  test "Root":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/")
    let result = r.route(HttpGet, parseUri("/"))
    check(result.handler == testHandler)

  test "Multiple mappings with a root":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/")
    r.map(testHandler, HttpGet, "/foo/bar")
    r.map(testHandler, HttpGet, "/baz")
    let result1 = r.route(HttpGet, parseUri("/"))
    check(result1.handler == testHandler)
    let result2 = r.route(HttpGet, parseUri("/foo/bar"))
    check(result2.handler == testHandler)
    let result3 = r.route(HttpGet, parseUri("/baz"))
    check(result3.handler == testHandler)

  test "Multiple mappings without a root":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/foo/bar")
    r.map(testHandler, HttpGet, "/baz")
    let result1 = r.route(HttpGet, parseUri("/foo/bar"))
    check(result1.handler == testHandler)
    let result2 = r.route(HttpGet, parseUri("/baz"))
    check(result2.handler == testHandler)

  test "Duplicate root":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/")
    let result = r.route(HttpGet, parseUri("/"))
    check(result.handler == testHandler)
    expect MappingError:
      r.map(testHandler, HttpGet, "/")

  test "Ends with wildcard":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/*")
    let result = r.route(HttpGet, parseUri("/wildcard1"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)

  test "Ends with param":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/{param1}")
    let result = r.route(HttpGet, parseUri("/value1"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)
    check(result.arguments.pathArgs.getOrDefault("param1") == "value1")

  test "Wildcard in middle":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/*/test")
    let result = r.route(HttpGet, parseUri("/wildcard1/test"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)

  test "Param in middle":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/{param1}/test")
    let result = r.route(HttpGet, parseUri("/value1/test"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)
    check(result.arguments.pathArgs.getOrDefault("param1") == "value1")

  test "Param + wildcard":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/{param1}/*")
    let result = r.route(HttpGet, parseUri("/value1/test"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)
    check(result.arguments.pathArgs.getOrDefault("param1") == "value1")

  test "Wildcard + param":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/*/{param1}")
    let result = r.route(HttpGet, parseUri("/somevalue/value1"))
    check(result.status == routingSuccess)
    check(result.handler == testHandler)
    check(result.arguments.pathArgs.getOrDefault("param1") == "value1")

  test "Trailing slash has no effect":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/some/url/")
    let result1 = r.route(HttpGet, parseUri("/some/url"))
    check(result1.status == routingSuccess)
    let result2 = r.route(HttpGet, parseUri("/some/url/"))
    check(result2.status == routingSuccess)

  test "Trailing slash doesn't make a unique mapping":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/some/url/")
    expect MappingError:
      r.map(testHandler, HttpGet, "/some/url")

  test "Varying param names don't make a unique mapping":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/has/{paramA}")
    expect MappingError:
      r.map(testHandler, HttpGet, "/has/{paramB}")

  test "Param vs wildcard don't make a unique mapping":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/has/{param}")
    expect MappingError:
      r.map(testHandler, HttpGet, "/has/*")

  test "Greedy params must go at the end of a mapping":
    let r = newRouter[proc()]()
    expect MappingError:
      r.map(testHandler, HttpGet, "/has/{p1}$/{p2}")

  test "Greedy wildcards must go at the end of a mapping":
    let r = newRouter[proc()]()
    expect MappingError:
      r.map(testHandler, HttpGet, "/has/*$/*")

  test "Wildcards only match one URL section":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/has/*/one")
    let result = r.route(HttpGet, parseUri("/has/a/b/one"))
    check(result.status == routingFailure)

  test "Invalid characters in URL":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/test/{param}")
    let result = r.route(HttpGet, parseUri("/test/!/"))
    check(result.status == routingFailure)

  test "Remaining path consumption with parameter":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/test/{param}$")
    let result = r.route(HttpGet, parseUri("/test/foo/bar/baz"))
    check(result.status == routingSuccess)

  test "Remaining path consumption with wildcard":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/test/*$")
    let result = r.route(HttpGet, parseUri("/test/foo/bar/baz"))
    check(result.status == routingSuccess)

  test "Map subpath after path":
    let r = newRouter[proc()]()
    r.map(testHandler, HttpGet, "/hello")
    r.map(testHandler, HttpGet, "/") # Should not raise
