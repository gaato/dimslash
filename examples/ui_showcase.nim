import std/os

import dimslash

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("classic", "Shows classic components",
    proc(ctx: SlashCommandContext) {.async.} =
      var message = classicMessage("Choose an action")
      message.rows = @[
        actionRow(
          button("Continue", "continue", style = Primary),
          linkButton("Documentation", "https://nim-lang.org"))
      ]
      discard await ctx.respond(message.messageBody))

  routes.slash("v2", "Shows a Components V2 message",
    proc(ctx: SlashCommandContext) {.async.} =
      let message = componentsV2(@[
        textDisplay("# Components V2"),
        v2ActionRow(button("Continue", "continue"))
      ])
      discard await ctx.respond(message.messageBody))

  routes.button("continue",
    proc(ctx: ComponentContext) {.async.} =
      discard await ctx.update("continued"))
)

waitFor app.bindGateway(getEnv("DISCORD_TOKEN")).start()
