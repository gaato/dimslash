import std/[asyncdispatch, json, options, tables, unittest]
import dimscord

import ../src/dimslash/[types, context, builders]
import ./helpers

proc mkSlashCtx(rec: Recorder): SlashContext =
  SlashContext(handler: newTestHandler(rec),
               interaction: mkSlashInteraction("cmd",
                 initTable[string, ApplicationCommandInteractionDataOption]()))

proc mkComponentData(customId: string): ApplicationCommandInteractionData =
  ApplicationCommandInteractionData(
    resolved: emptyResolved(),
    interaction_type: idtMessageComponent,
    component_type: mctButton,
    custom_id: customId)

proc mkComponentCtx(rec: Recorder): ComponentContext =
  var i = baseInteraction(mkComponentData("btn"))
  i.kind = itMessageComponent
  ComponentContext(handler: newTestHandler(rec), interaction: i)

suite "reply state machine":
  test "first reply sends initial response":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("hello")
    check rec.names == @["createResponse"]
    let call = rec.calls[0].args
    check call["kind"].getInt == int irtChannelMessageWithSource
    check call["data"]["content"].getStr == "hello"
    check ctx.state == rsResponded

  test "second reply becomes a followup":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("first")
    waitFor ctx.reply("second")
    check rec.names == @["createResponse", "createFollowup"]
    check rec.calls[1].args["content"].getStr == "second"

  test "reply after deferReply edits the placeholder":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.deferReply()
    check rec.calls[0].args["kind"].getInt ==
      int irtDeferredChannelMessageWithSource
    check ctx.state == rsDeferred
    waitFor ctx.reply("done")
    check rec.names == @["createResponse", "editResponse"]
    check rec.calls[1].args["messageId"].getStr == "@original"
    check rec.calls[1].args["content"].getStr == "done"
    check ctx.state == rsResponded

  test "ephemeral sets the flag":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("secret", ephemeral = true)
    let flags = rec.calls[0].args["data"]["flags"]
    check flags.getInt == cast[int]({mfEphemeral})

  test "ephemeral defer carries the flag":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.deferReply(ephemeral = true)
    check rec.calls[0].args["data"]["flags"].getInt == cast[int]({mfEphemeral})

  test "double defer raises":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.deferReply()
    expect DimslashError:
      waitFor ctx.deferReply()

  test "unset allowed_mentions spells out Discord defaults":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("hi <@123>")
    let am = rec.calls[0].args["data"]["allowed_mentions"]
    check am["parse"].len == 3

suite "followup / edit / original / delete":
  test "followup returns the created message":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    let msg = waitFor ctx.followup("later", ephemeral = true)
    check msg.id == "followup-msg"
    check rec.calls[0].args["flags"].getInt == cast[int]({mfEphemeral})

  test "edit and delete target @original by default":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    discard waitFor ctx.edit("new content")
    waitFor ctx.delete()
    discard waitFor ctx.original()
    check rec.names == @["editResponse", "deleteResponse", "getResponse"]
    check rec.calls[0].args["hasContent"].getBool
    for (_, args) in rec.calls:
      check args["messageId"].getStr == "@original"

suite "component responses":
  test "update sends irtUpdateMessage":
    let rec = newRecorder()
    let ctx = mkComponentCtx(rec)
    waitFor ctx.update("updated")
    check rec.calls[0].args["kind"].getInt == int irtUpdateMessage
    check ctx.state == rsResponded

  test "deferUpdate then update edits the original":
    let rec = newRecorder()
    let ctx = mkComponentCtx(rec)
    waitFor ctx.deferUpdate()
    check rec.calls[0].args["kind"].getInt == int irtDeferredUpdateMessage
    waitFor ctx.update("later")
    check rec.names == @["createResponse", "editResponse"]

  test "update after responding raises":
    let rec = newRecorder()
    let ctx = mkComponentCtx(rec)
    waitFor ctx.update("once")
    expect DimslashError:
      waitFor ctx.update("twice")

suite "Components V2 responses":
  test "reply sets the V2 flag and sends only layout components":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    let ui = layout:
      text "# Hello"
      row:
        button "Continue", "continue"
    waitFor ctx.reply(ui, ephemeral = true)
    let data = rec.calls[0].args["data"]
    check data["flags"].getInt ==
      cast[int]({mfEphemeral, mfIsComponentsV2})
    check not data["hasContent"].getBool
    check not data.hasKey("content")
    check data["embeds"].len == 0
    check data["components"].len == 2
    check data["components"][0]["type"].getInt == int mctTextDisplay
    check data["components"][1]["type"].getInt == int mctActionRow

  test "reply keeps its state-aware edit and followup behavior":
    let ui = layout:
      text "Done"

    let deferredRec = newRecorder()
    let deferred = mkSlashCtx(deferredRec)
    waitFor deferred.deferReply()
    waitFor deferred.reply(ui)
    check deferredRec.names == @["createResponse", "editResponse"]
    check deferredRec.calls[1].args["flags"].getInt ==
      cast[int]({mfIsComponentsV2})
    check not deferredRec.calls[1].args["hasContent"].getBool

    let followupRec = newRecorder()
    let responded = mkSlashCtx(followupRec)
    waitFor responded.reply(ui)
    waitFor responded.reply(ui)
    check followupRec.names == @["createResponse", "createFollowup"]
    check followupRec.calls[1].args["flags"].getInt ==
      cast[int]({mfIsComponentsV2})
    check not followupRec.calls[1].args["hasContent"].getBool

  test "followup and edit return messages and preserve V2 flags":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    let ui = layout:
      container accent = 0x123456:
        text "Card"
    let sent = waitFor ctx.followup(ui)
    let edited = waitFor ctx.edit(ui, messageId = "message-id")
    check sent.id == "followup-msg"
    check edited.id == "edited-msg"
    check rec.calls[0].args["flags"].getInt ==
      cast[int]({mfIsComponentsV2})
    check rec.calls[1].args["flags"].getInt ==
      cast[int]({mfIsComponentsV2})
    check not rec.calls[0].args["hasContent"].getBool
    check not rec.calls[1].args["hasContent"].getBool
    check rec.calls[1].args["messageId"].getStr == "message-id"

  test "component update supports immediate and deferred V2 layouts":
    let ui = layout:
      text "Updated"

    let immediateRec = newRecorder()
    let immediate = mkComponentCtx(immediateRec)
    waitFor immediate.update(ui)
    check immediateRec.calls[0].args["kind"].getInt == int irtUpdateMessage
    check immediateRec.calls[0].args["data"]["flags"].getInt ==
      cast[int]({mfIsComponentsV2})

    let deferredRec = newRecorder()
    let deferred = mkComponentCtx(deferredRec)
    waitFor deferred.deferUpdate()
    waitFor deferred.update(ui)
    check deferredRec.names == @["createResponse", "editResponse"]
    check deferredRec.calls[1].args["flags"].getInt ==
      cast[int]({mfIsComponentsV2})

  test "V2 overloads structurally exclude legacy content and embeds":
    let ctx = mkSlashCtx(newRecorder())
    let componentCtx = mkComponentCtx(newRecorder())
    let ui = layout:
      text "Only components"
    check not compiles(ctx.reply(ui, content = "not allowed"))
    check not compiles(ctx.reply(ui, tts = true))
    check not compiles(ctx.followup(ui, embeds = @[Embed()]))
    check not compiles(ctx.followup(ui,
      files = @[DiscordFile(name: "report.txt", body: "body")]))
    check not compiles(ctx.followup(ui, tts = true))
    check not compiles(ctx.edit(ui, content = "not allowed"))
    check not compiles(componentCtx.update(ui, embeds = @[Embed()]))

suite "modal open":
  test "showModal responds with the modal":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.showModal("feedback", "Feedback", @[])
    check rec.names == @["createModal"]
    check rec.calls[0].args["custom_id"].getStr == "feedback"
    check ctx.state == rsResponded

  test "showModal after reply raises":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("hi")
    expect DimslashError:
      waitFor ctx.showModal("feedback", "Feedback", @[])

suite "autocomplete suggest":
  proc mkAutoCtx(rec: Recorder): AutocompleteContext =
    var i = mkSlashInteraction("cmd",
      toOpts(strOpt("query", "hel", focused = true)))
    i.kind = itAutoComplete
    AutocompleteContext(handler: newTestHandler(rec), interaction: i,
      options: i.data.get.options, focusedName: "query")

  test "string suggestions use the text as value":
    let rec = newRecorder()
    let ctx = mkAutoCtx(rec)
    check ctx.focusedValue == "hel"
    waitFor ctx.suggest(@["hello", "help"])
    let choices = rec.calls[0].args["choices"]
    check choices.len == 2
    check choices[0]["name"].getStr == "hello"
    check choices[0]["value"].getStr == "hello"

  test "labelled int and float suggestions":
    let rec = newRecorder()
    let ctx = mkAutoCtx(rec)
    waitFor ctx.suggest({"one": 1, "two": 2})
    check rec.calls[0].args["choices"][0]["value"].getInt == 1
    let rec2 = newRecorder()
    let ctx2 = mkAutoCtx(rec2)
    waitFor ctx2.suggest({"pi": 3.14})
    check rec2.calls[0].args["choices"][0]["value"].getFloat == 3.14

  test "suggestions are trimmed to 25":
    let rec = newRecorder()
    let ctx = mkAutoCtx(rec)
    var many: seq[string]
    for i in 1 .. 40:
      many.add "item" & $i
    waitFor ctx.suggest(many)
    check rec.calls[0].args["choices"].len == 25

  test "double suggest raises":
    let rec = newRecorder()
    let ctx = mkAutoCtx(rec)
    waitFor ctx.suggest(@["a"])
    expect DimslashError:
      waitFor ctx.suggest(@["b"])

suite "accessors":
  test "user falls back between member and user":
    var i = mkSlashInteraction("cmd",
      initTable[string, ApplicationCommandInteractionDataOption]())
    i.user = some User(id: "u1", username: "dm-user")
    let ctx = SlashContext(interaction: i)
    check ctx.user.username == "dm-user"
    check not ctx.inGuild

    var gi = mkSlashInteraction("cmd",
      initTable[string, ApplicationCommandInteractionDataOption]())
    gi.guild_id = some "g1"
    gi.member = some Member(user: User(id: "u2", username: "guild-user"))
    let gctx = SlashContext(interaction: gi)
    check gctx.user.username == "guild-user"
    check gctx.inGuild
    check gctx.guildId.get == "g1"

  test "context-menu targets":
    var resolved = emptyResolved()
    resolved.users["u9"] = User(id: "u9", username: "bob")
    let data = ApplicationCommandInteractionData(
      resolved: resolved,
      interaction_type: idtApplicationCommand,
      id: "cmd-id", name: "Profile", kind: atUser, target_id: "u9")
    let ctx = UserContext(interaction: baseInteraction(data))
    check ctx.target.username == "bob"
    check ctx.targetMember.isNone

suite "default error hook":
  test "replies ephemerally when nothing was sent":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor defaultOnError(ctx, newException(ValueError, "boom"))
    check rec.names == @["createResponse"]
    check rec.calls[0].args["data"]["flags"].getInt == cast[int]({mfEphemeral})

  test "does not reply when already responded":
    let rec = newRecorder()
    let ctx = mkSlashCtx(rec)
    waitFor ctx.reply("already")
    waitFor defaultOnError(ctx, newException(ValueError, "boom"))
    check rec.names == @["createResponse"]
