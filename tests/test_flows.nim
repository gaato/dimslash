import std/[asyncdispatch, json, options, tables, unittest]
import dimscord

import ../src/dimslash/[types, extract, context, dispatch, wait, flows]
import ./helpers

proc mkCtx(rec: Recorder): SlashContext =
  var i = mkSlashInteraction("cmd",
    initTable[string, ApplicationCommandInteractionDataOption]())
  i.user = some User(id: "alice")
  SlashContext(handler: newTestHandler(rec), interaction: i)

proc press(customId, userId: string): Interaction =
  result = mkComponentInteraction(customId)
  result.user = some User(id: userId)

suite "disableAll":
  test "deep copies and disables interactive components only":
    let row = newActionRow(
      newButton("Yes", "yes", bsSuccess),
      newButton("No", "no", bsDanger))
    let disabled = disableAll(@[row])
    check disabled[0].kind == mctActionRow
    check disabled[0].disabled.isNone
    for b in disabled[0].components:
      check b.disabled == some true
    # originals untouched
    for b in row.components:
      check b.disabled == some false

suite "confirm":
  test "yes press returns true and disables the buttons":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    proc scenario() {.async.} =
      let fut = ctx.confirm("Really?", timeout = 5)
      check await ctx.handler.handleInteraction(nil,
        press("ds:confirm:yes:interaction-id", "alice"))
      check await fut
    waitFor scenario()
    check rec.names == @["createResponse", "createResponse"]
    check rec.calls[0].args["data"]["content"].getStr == "Really?"
    check rec.calls[0].args["data"]["flags"].getInt == cast[int]({mfEphemeral})
    check rec.calls[1].args["kind"].getInt == int irtUpdateMessage
    for b in rec.calls[1].args["data"]["components"][0]["components"]:
      check b["disabled"].getBool
    check ctx.handler.componentWaiters.len == 0

  test "no press returns false":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    proc scenario() {.async.} =
      let fut = ctx.confirm("Sure?", timeout = 5)
      check await ctx.handler.handleInteraction(nil,
        press("ds:confirm:no:interaction-id", "alice"))
      check not await fut
    waitFor scenario()

  test "another user's press is ignored":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    proc scenario() {.async.} =
      let fut = ctx.confirm("Sure?", timeout = 0.05)
      check not await ctx.handler.handleInteraction(nil,
        press("ds:confirm:yes:interaction-id", "mallory"))
      check not await fut
    waitFor scenario()

  test "timeout returns false and disables via @original":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    check not waitFor ctx.confirm("Anyone?", timeout = 0.05)
    check rec.names == @["createResponse", "editResponse"]
    check rec.calls[1].args["messageId"].getStr == "@original"

  test "sent as a followup when the interaction was already answered":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    proc scenario() {.async.} =
      await ctx.reply("first")
      check not await ctx.confirm("And now?", timeout = 0.05)
    waitFor scenario()
    check rec.names == @["createResponse", "createFollowup", "editResponse"]
    # the timeout edit targets the followup message, not @original
    check rec.calls[2].args["messageId"].getStr == "followup-msg"

suite "paginate":
  test "single page sends without controls":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    waitFor ctx.paginate(@[Embed(title: some "only")])
    check rec.names == @["createResponse"]
    check rec.calls[0].args["data"]["components"].len == 0

  test "next flips the page, timeout disables the controls":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    let pages = @[Embed(title: some "p1"), Embed(title: some "p2")]
    proc scenario() {.async.} =
      let fut = ctx.paginate(pages, timeout = 0.1)
      check await ctx.handler.handleInteraction(nil,
        press("ds:page:next:interaction-id", "alice"))
      await fut  # no further press: times out and disables
    waitFor scenario()
    check rec.names == @["createResponse", "createResponse", "editResponse"]
    check rec.calls[0].args["data"]["embeds"][0]["title"].getStr == "p1"
    check rec.calls[1].args["kind"].getInt == int irtUpdateMessage
    check rec.calls[1].args["data"]["embeds"][0]["title"].getStr == "p2"
    check ctx.handler.componentWaiters.len == 0

  test "prev at the first page stays put":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    let pages = @[Embed(title: some "p1"), Embed(title: some "p2")]
    proc scenario() {.async.} =
      let fut = ctx.paginate(pages, timeout = 0.1)
      check await ctx.handler.handleInteraction(nil,
        press("ds:page:prev:interaction-id", "alice"))
      await fut
    waitFor scenario()
    check rec.calls[1].args["data"]["embeds"][0]["title"].getStr == "p1"

  test "empty pages raise":
    let rec = newRecorder()
    let ctx = mkCtx(rec)
    expect DimslashError:
      waitFor ctx.paginate(@[])
