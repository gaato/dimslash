import asyncdispatch
import os
import options
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
var handler = newInteractionHandler(discord, defaultGuildId = "")

handler.addSlash("sum", "Adds two integers") do (i: Interaction, a: int, b: int):
  await handler.reply(i, "sum=" & $(a + b))

handler.addSlash("maybe", "Example with optional arg") do (i: Interaction, x: Option[int]):
  if x.isSome:
    await handler.reply(i, "x=" & $x.get)
  else:
    await handler.reply(i, "x is missing")

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds}, content_intent = false)
