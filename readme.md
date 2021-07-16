# httpbeast

A highly performant, multi-threaded HTTP 1.1 server written in Nim. 

This is a project to get the fastest possible HTTP server written in pure Nim. It is currently in the [top 10 in the TechEmpower benchmarks](https://www.techempower.com/benchmarks/#section=data-r18&hw=ph&test=json).

**Note:** This HTTP server does not support Windows.

## Features

Current features include:

* Built on the Nim ``selectors`` module which makes efficient use of epoll on
  Linux and kqueue on macOS.
* Automatic parallelization, just make sure to compile with ``--threads:on``.
* Support for HTTP pipelining.
* On-demand parser so that only the requested data is parsed.
* Integration with Nim's ``asyncdispatch`` allowing async/await to be used in
  the request callback whenever necessary.


# Nest
RESTful routing with Nim!

[![Build Status](https://travis-ci.org/kedean/nest.svg?branch=master)](https://travis-ci.org/kedean/nest)

## Intro
Nest is a high performance URL mapper/router built in Nim.

At the moment, Nest needs a work and is not ready for production. Feedback is appreciated moving forward!

Nest is *not* a web application framework, only a router. Everything besides routing must be implemented by some other code.

## Usage
See examples/ for example usage. Note that using this against Nim's built in asynchttpserver is not required, and it is just used for the examples.

## Compilation
To run the example code, use the following invocation:
```nim
nim c -r examples/basic.nim
```
Threads are not required for nest to run, but the examples use threads (in nim.cfg) to prove that they can be used.

## Features
- Map against any HTTP method and path
- Server-agnostic
- URL parameter capture
- Query string parameter capture
- Plays nice with various logging systems
- Does not impose restrictions on your handler methods
- Fully unit tested

## Future Features
- Benchmarking
- Adding consumes/produces constraints
- Removing dependency on HTTP, allow routing on other transport protocols
- Guarantee thread safety