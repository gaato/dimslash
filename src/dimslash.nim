## Typed Discord application commands and interaction flows for Nim.
##
## DimSlash separates immutable application definition from live runtime state:
##
## * `DiscordApp` owns the route table and error policy. Its factory closure is
##   evaluated exactly once.
## * `AppBinding` owns one gateway connection, command scopes, cooldown buckets,
##   collectors, and shutdown/drain state.
## * Each specialized context is a request-scoped response capability for one
##   interaction. It must acknowledge exactly once before its handler returns.
##
## Defining and starting an app
## ============================
##
## Typed slash parameters derive Discord's command schema and are decoded before
## the handler runs. `Option[T]` and default values create optional options.
## Parameter pragmas add descriptions and constraints.
##
## .. code-block:: nim
##   import std/[os, strutils]
##   import dimslash
##
##   let app = newDiscordApp(proc(routes: var Routes) =
##     routes.slash("greet", "Greets a person",
##       proc(ctx: SlashCommandContext;
##            person {.description: "Person to greet".}: string;
##            count {.min: 1, max: 5.}: int = 1) {.async.} =
##         discard await ctx.respond(
##           ("Hello, " & person & "! ").repeat(count)))
##
##     routes.userCommand("Inspect user",
##       proc(ctx: UserCommandContext) {.async.} =
##         discard await ctx.respond(ctx.target.username, ephemeral = true))
##   )
##
##   let binding = app.bindGateway(getEnv("DISCORD_TOKEN"),
##     managedScopes = @[globalScope()], gatewayIntents = {Guilds})
##   waitFor binding.start()
##
## Explicit response state
## =======================
##
## `respond`, `update`, `showModal`, `launchActivity`, and autocomplete
## `complete` compete for the one initial response. `deferReply` and
## `deferUpdate` acknowledge first and permit a later `editOriginal`. Message
## producing operations consistently return `Future[Message]`; ACK-only,
## deletion, modal, and autocomplete operations return `Future[void]`.
##
## A definite initial-response rejection leaves the context pending so an error
## policy may choose another legal response. An ambiguous transport failure moves
## it to `OutcomeUnknown`; further mutations are refused because Discord may have
## accepted the first request.
##
## Components, modals, and short-lived flows
## ==========================================
##
## Persistent button, select, and modal routes use custom-ID patterns such as
## `ticket:{ticketId:int}`. A handler reads captures with `capture` or
## `captureInt`. Short-lived collectors are separate and win before persistent
## routes; context collectors default to the invoking user.
##
## .. code-block:: nim
##   routes.slash("feedback", "Opens feedback form",
##     proc(ctx: SlashCommandContext) {.async.} =
##       await ctx.showModal(modalDialog("feedback:submit", "Feedback",
##         textInput("reason", "Reason", ParagraphText))))
##
##   routes.modal("feedback:submit",
##     proc(ctx: ModalContext; reason: string) {.async.} =
##       discard await ctx.respond("Thanks: " & reason, ephemeral = true))
##
## `confirm` and `paginate` build common collector-based flows. Components V2
## builders are separate from classic messages, and an original response changed
## to Components V2 cannot later be converted back to classic content.
##
## Errors and shutdown
## ===================
##
## Route checks run before cooldown acquisition. Catchable handler failures are
## passed to the app's `ErrorHandler`; `Defect` values bypass it. A handler that
## returns while still `Pending` is treated as `MissingInitialResponseError`.
##
## `requestStop` immediately rejects new dispatch and wakes collectors. `stop`
## then drains active handlers before ending the gateway session; `detach` drains
## and restores prior gateway hooks without closing the shared client.

import std/[asyncdispatch, json, options]
import dimslash/api

export api, asyncdispatch, json, options
