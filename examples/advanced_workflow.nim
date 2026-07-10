## Subcommands, permissions, deferred replies, pattern buttons, and a
## modal-driven workflow.

import std/[asyncdispatch, os, strformat, strutils, tables]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
let handler = newInteractionHandler(discord)

var todos: seq[tuple[text: string, done: bool]]

handler.slash("todo", "A tiny todo list"):
  sub "add", "Add an item":
    ## what to do
    text {.minLen: 1, maxLen: 80.}: string
    execute:
      todos.add (text, false)
      let id = todos.high
      await ctx.reply(fmt"Added #{id}: {text}",
        components = @[newActionRow(
          newButton("Done", fmt"todo:done:{id}"),
          newButton("Delete", fmt"todo:del:{id}"))])
  sub "list", "Show all items":
    execute:
      if todos.len == 0:
        await ctx.reply("Nothing to do!", ephemeral = true)
      else:
        var lines: seq[string]
        for id, (text, done) in todos:
          lines.add fmt"""#{id} [{(if done: "x" else: " ")}] {text}"""
        await ctx.reply(lines.join("\n"))

handler.slash("admin", "Admin tools"):
  permissions = {permManageGuild}
  contexts = {ictGuild}
  group "member", "Member management":
    sub "warn", "Warn a member":
      ## who to warn
      target: User
      ## the reason
      reason: string = "no reason given"
      execute:
        await ctx.reply(fmt"{target.username} warned: {reason}",
                        ephemeral = true)
  sub "slow", "Something that takes a while":
    execute:
      await ctx.deferReply(ephemeral = true)
      await sleepAsync(2000)
      await ctx.reply("Done thinking!")   # edits the placeholder

handler.button("todo:done:{id:int}"):
  if id in 0 .. todos.high:
    todos[id].done = true
    await ctx.update(fmt"#{id} completed: {todos[id].text}",
                     components = @[])
  else:
    await ctx.reply("That item is gone.", ephemeral = true)

handler.button("todo:del:{id:int}"):
  if id in 0 .. todos.high:
    todos.delete(id)
  await ctx.update("Deleted.", components = @[])

handler.slash("feedback", "Send us feedback"):
  execute:
    await ctx.showModal("feedback:general", "Feedback", @[
      newTextInput("subject", "Subject", maxLen = 80),
      newTextInput("details", "Details", tisParagraph, required = false)])

handler.modal("feedback:{kind}"):
  let subject = ctx.field("subject").get("(no subject)")
  await ctx.reply(fmt"Thanks for the {kind} feedback about: {subject}",
                  ephemeral = true)

handler.onUnknown = proc (ctx: InteractionContext) {.async.} =
  echo "unhandled interaction kind: ", ctx.interaction.kind

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds},
                             content_intent = false)
