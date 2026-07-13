import dimslash

var exampleStopRequested {.volatile.}: bool

proc requestExampleStop() {.noconv.} =
  exampleStopRequested = true

proc runUntilInterrupted*(binding: AppBinding): Future[void] {.async.} =
  ## Runs an example until the gateway ends or Ctrl+C asks the binding to drain
  ## handlers and disconnect cleanly.
  exampleStopRequested = false
  setControlCHook(requestExampleStop)
  let session = binding.start()
  proc stopWhenRequested(): Future[void] {.async.} =
    while not exampleStopRequested and not session.finished:
      await sleepAsync(50)
    if exampleStopRequested:
      await binding.stop()
  let shutdown = stopWhenRequested()
  try:
    await session
    await shutdown
  finally:
    unsetControlCHook()
