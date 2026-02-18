import asyncdispatch
import os
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
var handler = newInteractionHandler(discord, defaultGuildId = "")

handler.addSlash("ping", "Replies with pong") do:
  await handler.reply(i, "pong")

handler.addUser("userinfo", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "user command")
)

handler.addMessage("quote", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "message command")
)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds}, content_intent = false)
