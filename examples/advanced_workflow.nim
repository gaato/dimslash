import std/os

import dimslash

proc handleError(ctx: InteractionContext;
                 error: ref CatchableError): Future[ErrorAction] {.async.} =
  if error of UserRejectionError:
    return ErrorAction(kind: RespondEphemeral,
      message: cast[ref UserRejectionError](error).userMessage)
  echo "interaction failed: ", error.msg
  return ErrorAction(kind: RespondEphemeral,
                     message: "The command failed.")

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("admin", "Performs an administrative action",
    proc(ctx: SlashCommandContext;
         confirmed {.description: "Confirm the action".}: bool) {.async.} =
      if not confirmed:
        raise userRejection("Confirmation is required.")
      discard await ctx.respond("done", ephemeral = true))

  routes.checkSlash("admin",
    proc(ctx: SlashCommandContext): Future[CheckDecision] {.async.} =
      if ctx.inGuild: return allow()
      return deny("This command is only available in a server."))
  routes.cooldownSlash("admin", cooldownRule(5_000, UserCooldown))
,
  onError = handleError)

let binding = app.bindGateway(getEnv("DISCORD_TOKEN"), managedScopes = @[
  guildScope(GuildId(getEnv("DISCORD_GUILD_ID")))
])
waitFor binding.start()
