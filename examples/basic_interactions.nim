## Minimal setup: a slash command, a user command, and a message command.

import std/[asyncdispatch, os]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let bot = newBot(token)

bot.slash("ping", "Replies with pong"):
  execute:
    await ctx.reply("pong")

bot.slash("greet", "Greets someone"):
  ## who to greet
  who: User
  ## greet privately?
  quiet: Option[bool]
  execute:
    await ctx.reply("Hello, " & who.username & "!",
                    ephemeral = quiet.get(false))

bot.user("User info"):
  await ctx.reply("That's " & ctx.target.username, ephemeral = true)

bot.message("Quote"):
  await ctx.reply("> " & ctx.target.content)

waitFor bot.start()
