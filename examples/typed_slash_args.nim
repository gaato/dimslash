import std/[os, strutils]

import dimslash

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

waitFor app.bindGateway(getEnv("DISCORD_TOKEN")).start()
