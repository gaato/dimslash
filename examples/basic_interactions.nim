import std/os

import dimslash
import example_support

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("ping", "Replies with pong",
    proc(ctx: SlashCommandContext) {.async.} =
      discard await ctx.respond("pong"))

  routes.userCommand("Inspect user",
    proc(ctx: UserCommandContext) {.async.} =
      discard await ctx.respond(ctx.target.username, ephemeral = true))

  routes.messageCommand("Quote",
    proc(ctx: MessageCommandContext) {.async.} =
      discard await ctx.respond("> " & ctx.target.content))
)

let
  token = getEnv("DISCORD_TOKEN")
  guildId = getEnv("DISCORD_GUILD_ID")
if token.len == 0:
  raise newException(ValueError, "set DISCORD_TOKEN before running this example")
if guildId.len == 0:
  raise newException(ValueError,
    "set DISCORD_GUILD_ID to a disposable test guild")

let binding = app.bindGateway(token, managedScopes = @[
  guildScope(GuildId(guildId))
])
waitFor runUntilInterrupted(binding)
