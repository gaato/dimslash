import std/[asyncdispatch, options, tables, unittest]
import dimscord

import ../src/dimslash/[types, registry, dispatch, wait]
import ./helpers

proc pressed(i: Interaction, userId: string): Interaction =
  result = i
  result.user = some User(id: userId)

suite "component waiters":
  test "button press completes the waiter with captures":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton("page:{n:int}", timeout = 5)
      check handler.componentWaiters.len == 1
      check await handler.handleInteraction(nil,
        mkComponentInteraction("page:3"))
      let press = await fut
      check press.isSome
      check press.get.captures["n"] == "3"
      check handler.componentWaiters.len == 0
    waitFor scenario()

  test "waiter wins over a registered handler and is one-shot":
    let handler = newTestHandler(newRecorder())
    var registryRan = 0
    handler.addButtonHandler("pick",
      proc (ctx: ComponentContext) {.async.} = inc registryRan)
    proc scenario() {.async.} =
      let fut = handler.waitForButton("pick", timeout = 5)
      check await handler.handleInteraction(nil, mkComponentInteraction("pick"))
      check (await fut).isSome
      check registryRan == 0
      # waiter is gone; the registered handler gets the next press
      check await handler.handleInteraction(nil, mkComponentInteraction("pick"))
      check registryRan == 1
    waitFor scenario()

  test "kind filter: a select does not complete a button waiter":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton("pick", timeout = 0.05)
      check not await handler.handleInteraction(nil,
        mkComponentInteraction("pick", mctSelectMenu, @["a"]))
      check (await fut).isNone
    waitFor scenario()

  test "select waiter accepts any select kind and sees values":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForSelect("menu", timeout = 5)
      check await handler.handleInteraction(nil,
        mkComponentInteraction("menu", mctRoleSelect, @["r1", "r2"]))
      let pick = await fut
      check pick.isSome
      check pick.get.interaction.data.get.values == @["r1", "r2"]
    waitFor scenario()

  test "user filter only matches the given user":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton("ok", timeout = 5, user = "alice")
      check not await handler.handleInteraction(nil,
        mkComponentInteraction("ok").pressed("bob"))
      check handler.componentWaiters.len == 1
      check await handler.handleInteraction(nil,
        mkComponentInteraction("ok").pressed("alice"))
      let press = await fut
      check press.isSome
      check press.get.interaction.user.get.id == "alice"
    waitFor scenario()

  test "message filter only matches components on that message":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton("ok", timeout = 5, message = "msg-1")
      var wrong = mkComponentInteraction("ok")
      wrong.message = some Message(id: "msg-2")
      check not await handler.handleInteraction(nil, wrong)
      var right = mkComponentInteraction("ok")
      right.message = some Message(id: "msg-1")
      check await handler.handleInteraction(nil, right)
      check (await fut).isSome
    waitFor scenario()

  test "multiple patterns: first match wins, waiter removed":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton(["confirm:yes", "confirm:no"],
                                      timeout = 5)
      check await handler.handleInteraction(nil,
        mkComponentInteraction("confirm:no"))
      let press = await fut
      check press.isSome
      check press.get.interaction.data.get.custom_id == "confirm:no"
    waitFor scenario()

  test "timeout returns none and removes the waiter":
    let handler = newTestHandler(newRecorder())
    let press = waitFor handler.waitForButton("never", timeout = 0.05)
    check press.isNone
    check handler.componentWaiters.len == 0

  test "unmatched custom_id leaves the waiter pending":
    let handler = newTestHandler(newRecorder())
    proc scenario() {.async.} =
      let fut = handler.waitForButton("page:{n:int}", timeout = 0.05)
      check not await handler.handleInteraction(nil,
        mkComponentInteraction("page:abc"))
      check handler.componentWaiters.len == 1
      check (await fut).isNone
    waitFor scenario()

suite "modal waiters":
  test "modal submit completes the waiter before the registry":
    let handler = newTestHandler(newRecorder())
    var registryRan = 0
    handler.addModalHandler("form:{id}",
      proc (ctx: ModalContext) {.async.} = inc registryRan)
    proc scenario() {.async.} =
      let fut = handler.waitForModal("form:{id}", timeout = 5)
      check await handler.handleInteraction(nil, mkModalInteraction("form:7"))
      let submitted = await fut
      check submitted.isSome
      check submitted.get.captures["id"] == "7"
      check registryRan == 0
      check handler.modalWaiters.len == 0
    waitFor scenario()

  test "modal timeout returns none":
    let handler = newTestHandler(newRecorder())
    let submitted = waitFor handler.waitForModal("never", timeout = 0.05)
    check submitted.isNone
    check handler.modalWaiters.len == 0

suite "scopedId":
  test "scoped ids are stable per interaction and tagged":
    let handler = newTestHandler(newRecorder())
    let ctx = InteractionContext(handler: handler,
      interaction: mkComponentInteraction("x"))
    check ctx.scopedId("confirm:yes") == "ds:confirm:yes:interaction-id"
    check ctx.scopedId("confirm:yes") == ctx.scopedId("confirm:yes")
    check ctx.scopedId("a") != ctx.scopedId("b")

suite "invokerId":
  test "member user wins, then user, then empty":
    var i = mkComponentInteraction("x")
    check invokerId(i) == ""
    i.user = some User(id: "u1")
    check invokerId(i) == "u1"
    i.member = some Member(user: User(id: "m1"))
    check invokerId(i) == "m1"
