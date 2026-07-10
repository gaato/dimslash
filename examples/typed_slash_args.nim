## Typed slash options: every supported type, constraints, choices,
## defaults, and autocomplete.

import std/[asyncdispatch, os, sequtils, strformat, strutils]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
let handler = newInteractionHandler(discord)

handler.slash("sum", "Adds two numbers"):
  ## first number
  a: int
  ## second number
  b: int = 0
  execute:
    await ctx.reply(fmt"{a} + {b} = {a + b}")

handler.slash("order", "Order something from the menu"):
  ## what to order
  item {.choices: {"Coffee": "coffee", "Tea": "tea", "Cake": "cake"}.}: string
  ## how many (1-10)
  amount {.min: 1, max: 10.}: int = 1
  ## note for the kitchen
  note {.maxLen: 100.}: Option[string]
  execute:
    var msg = fmt"{amount}x {item}"
    if note.isSome:
      msg &= " (" & note.get & ")"
    await ctx.reply(msg)

handler.slash("inspect", "Shows what got resolved"):
  ## a user
  who: Option[User]
  ## a member (guild data for a user)
  member: Option[Member]
  ## a role
  role: Option[Role]
  ## a text channel
  channel {.channels: {ctGuildText}.}: Option[Channel]
  ## a user or a role
  pingable: Option[Mentionable]
  ## any file
  file: Option[Attachment]
  execute:
    var lines: seq[string]
    if who.isSome: lines.add "user: " & who.get.username
    if member.isSome: lines.add "nick: " & member.get.nick.get("(none)")
    if role.isSome: lines.add "role: " & role.get.name
    if channel.isSome: lines.add "channel: #" & channel.get.name
    if pingable.isSome:
      lines.add case pingable.get.kind
        of mkUser: "mentionable user: " & pingable.get.user.username
        of mkRole: "mentionable role: " & pingable.get.role.name
    if file.isSome: lines.add "file: " & file.get.filename
    if lines.len == 0: lines.add "nothing passed"
    await ctx.reply(lines.join("\n"), ephemeral = true)

const languages = @["nim", "python", "rust", "typescript", "haskell"]

handler.slash("search", "Search with autocomplete"):
  ## programming language
  lang: string
  autocomplete lang:
    let typed = ctx.focusedValue.toLowerAscii
    await ctx.suggest(languages.filterIt(typed in it))
  execute:
    await ctx.reply("You searched for " & lang)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds},
                             content_intent = false)
