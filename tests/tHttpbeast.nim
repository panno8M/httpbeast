import asynctools, asyncdispatch, os, httpclient, strutils, asyncnet

from osproc import execCmd
from strformat import `&`

var serverProcess: AsyncProcess

proc readLoop(process: AsyncProcess, findSuccess: bool) {.async.} =
  while process.running:
    var buf = newString(256)
    let len = await readInto(process.outputHandle, addr buf[0], 256)
    buf.setLen(len)
    if findSuccess:
      if "Listening on" in buf:
        asyncCheck readLoop(process, false)
        return
      echo(buf.strip)
    else:
      echo("Process:", buf.strip())

  echo("Process terminated")
  # asynctools should probably export this:
  # process.close()

proc startServer(file: string) {.async.} =
  var file = "examples/httpbeast" / file
  if not serverProcess.isNil and serverProcess.running:
    serverProcess.terminate()
    # TODO: https://github.com/cheatfate/asynctools/issues/9
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
    serverProcess = nil

  # The nim process doesn't behave well when using `-r`, if we kill it, the
  # process continues running...
  doAssert execCmd(&"nimble c -y {file} 2>&1") == QuitSuccess

  serverProcess = startProcess(file.changeFileExt(ExeExt))
  await readLoop(serverProcess, true)
  await sleepAsync(2000)

import unittest
proc tests() {.async.} =
  await startServer("helloworld.nim")

  test "Simple GET":
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080/")
    check resp.code == Http200
    let body = await resp.body
    check body == "Hello World"

  await startServer("dispatcher.nim")

  test "'await' usage in dispatcher":
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080")
    check resp.code == Http200
    let body = await resp.body
    check body == "Hi there!"

  test "Simple POST":
    let client = newAsyncHttpClient()
    let resp = await client.post("http://localhost:8080", body="hello")
    check resp.code == Http200
    let body = await resp.body
    check body == "Successful POST! Data=5"

  await startServer("simpleLog.nim")

  let logFilename = "tests/logFile.tmp"
  test "configured loggers are passed to each thread":
    block:
      let client = newAsyncHttpClient()
      let resp = await client.get("http://localhost:8080")
      check resp.code == Http200
      check logFilename.readLines(1) == @["INFO Requested /"]

    block:
      let client = newAsyncHttpClient()
      let resp = await client.get("http://localhost:8080/404")
      check resp.code == Http404
      check logFilename.readLines(2) == @["INFO Requested /", "ERROR 404"]

  doAssert tryRemoveFile(logFilename)

  # Verify cross-talk doesn't occur
  await startServer("crosstalk.nim")
  suite "crosstalk":
    test "section 1":
      var client = newAsyncSocket()
      await client.connect("localhost", Port(8080))
      await client.send("GET /1 HTTP/1.1\c\l\c\l")
      client.close()

      client = newAsyncSocket()
      await client.connect("localhost", Port(8080))
      await client.send("GET /2 HTTP/1.1\c\l\c\l")

      check (await client.recvLine()) == "HTTP/1.1 200 OK"
      check (await client.recvLine()) == "Content-Length: 10"
      check (await client.recvLine()).startsWith("Server")
      check (await client.recvLine()).startsWith("Date:")
      check (await client.recvLine()) == "\c\l"

      let delayedBody = await client.recv(10)
      doAssert(delayedBody == "Delayed /2", "We must get the ID we asked for.")
      client.close()

    test "section 2":
      var client = newAsyncSocket()
      await client.connect("localhost", Port(8080))
      await client.send("GET /close_me/1 HTTP/1.1\c\l\c\l")
      check (await client.recv(1)) == ""
      client.close()

      client = newAsyncSocket()
      defer: client.close()
      await client.connect("localhost", Port(8080))
      await client.send("GET /close_me/2 HTTP/1.1\c\l\c\l")
      check (await client.recvLine()) == "HTTP/1.1 200 OK"
      check (await client.recvLine()) == "Content-Length: 19"
      check (await client.recvLine()).startsWith("Server")
      check (await client.recvLine()).startsWith("Date:")
      check (await client.recvLine()) == "\c\l"
      const expectedResponse = "Delayed /close_me/2"
      let delayedBody = await client.recv(expectedResponse.len)
      check delayedBody == expectedResponse

when isMainModule:
  try:
    waitFor tests()
  finally:
    discard execCmd("kill -15 " & $serverProcess.processID()) 
