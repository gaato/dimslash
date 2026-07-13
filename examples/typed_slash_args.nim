import std/[os, strutils]

import dimslash
import example_support

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("greet", "Greets somebody",
    proc(ctx: SlashCommandContext;
         name {.description: "Who to greet", minLen: 1, maxLen: 40.}: string;
         count {.description: "How many times", min: 1, max: 5.}: int = 1;
         excited {.description: "Use exclamation marks".}: bool = true)
        {.async.} =
      let punctuation = if excited: "!" else: "."
      discard await ctx.respond(("Hello, " & name & punctuation & " ").repeat(
        count)))
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
