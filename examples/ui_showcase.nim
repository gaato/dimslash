import std/os

import dimslash
import example_support

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("classic", "Shows classic components",
    proc(ctx: SlashCommandContext) {.async.} =
      var message = classicMessage("Choose an action")
      message.rows = @[
        actionRow(
          button("Continue", "continue-classic", style = Primary),
          linkButton("Documentation", "https://nim-lang.org"))
      ]
      discard await ctx.respond(message.messageBody))

  routes.slash("v2", "Shows a Components V2 message",
    proc(ctx: SlashCommandContext) {.async.} =
      let message = componentsV2(@[
        textDisplay("# Components V2"),
        v2ActionRow(button("Continue", "continue-v2"))
      ])
      discard await ctx.respond(message.messageBody))

  routes.button("continue-classic",
    proc(ctx: ComponentContext) {.async.} =
      discard await ctx.update("continued"))

  routes.button("continue-v2",
    proc(ctx: ComponentContext) {.async.} =
      discard await ctx.update(componentsV2(@[
        textDisplay("# Continued")
      ]).messageBody))
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
