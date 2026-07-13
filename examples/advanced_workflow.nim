import std/os

import dimslash
import example_support

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
