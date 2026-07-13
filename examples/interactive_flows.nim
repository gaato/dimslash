import std/os

import dimslash

let report = modalDialog("report", "Send a report",
  textInput("reason", "Reason", style = ParagraphText))

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("report", "Opens a report form",
    proc(ctx: SlashCommandContext) {.async.} =
      await ctx.showModal(report))

  routes.modal("report",
    proc(ctx: ModalContext;
         reason {.description: "Reason".}: string) {.async.} =
      discard await ctx.respond(
        "Received: " & reason,
        ephemeral = true))

  routes.slash("confirm", "Asks for confirmation",
    proc(ctx: SlashCommandContext) {.async.} =
      if await ctx.confirm("Continue with the operation?"):
        discard await ctx.followup("Confirmed.", ephemeral = true))

  routes.slash("work", "Demonstrates an explicit deferred response",
    proc(ctx: SlashCommandContext) {.async.} =
      await ctx.deferReply(ephemeral = true)
      discard await ctx.editOriginal("finished")
      discard await ctx.followup("audit record created"))
)

waitFor app.bindGateway(getEnv("DISCORD_TOKEN")).start()
