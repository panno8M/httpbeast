# Package

version       = "0.1.0"
author        = "panno"
description   = "An HTTP server based on httpBeast and nest."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 0.18.0"

# Test dependencies
requires "asynctools#0e6bdc3ed5bae8c7cc9"

task helloworld, "Compiles and executes the hello world server.":
  exec "nim c -d:release --gc:boehm -r tests/helloworld"

task dispatcher, "Compiles and executes the dispatcher test server.":
  exec "nim c -d:release --gc:boehm -r tests/dispatcher"

