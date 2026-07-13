import std/os

import dimslash

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

waitFor app.bindGateway(getEnv("DISCORD_TOKEN")).start()
