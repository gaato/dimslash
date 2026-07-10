## Minimal setup: a slash command, a user command, and a message command.

import std/[asyncdispatch, os]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
let handler = newInteractionHandler(discord)

handler.slash("ping", "Replies with pong"):
  execute:
    await ctx.reply("pong")

handler.slash("greet", "Greets someone"):
  ## who to greet
  who: User
  ## greet privately?
  quiet: Option[bool]
  execute:
    await ctx.reply("Hello, " & who.username & "!",
                    ephemeral = quiet.get(false))

handler.user("User info"):
  await ctx.reply("That's " & ctx.target.username, ephemeral = true)

handler.message("Quote"):
  await ctx.reply("> " & ctx.target.content)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  for scope in await handler.syncCommands():
    echo "synced ", scope.commandCount, " commands (updated: ",
      scope.updated, ")"

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds},
                             content_intent = false)
