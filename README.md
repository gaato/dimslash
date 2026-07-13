# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

A typed Discord interaction framework for Nim, backed by
[dimscord](https://github.com/krisppurg/dimscord).

The current API deliberately separates three things:

- `DiscordApp`: an immutable route definition
- `AppBinding`: one running gateway connection and its lifecycle
- request-scoped `Context` objects: interaction data and response state

See [README.ja.md](README.ja.md) for Japanese.

## Quick start

```nim
import dimslash

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("greet", "Greets somebody",
    proc(ctx: SlashCommandContext;
         name {.description: "Who to greet".}: string;
         count {.min: 1, max: 5.}: int = 1) {.async.} =
      discard await ctx.respond((name & "! ").repeat(count)))
)

let binding = app.bindGateway("TOKEN")
waitFor binding.start()
```

The route factory runs once. Handler signatures are the source of both the
Discord command schema and runtime option decoding. Services can be captured
normally by the factory closure.

## Explicit responses

DimSlash does not guess whether a call means an initial response, an edit, or
a followup:

```nim
routes.slash("work", "Does some work",
  proc(ctx: SlashCommandContext) {.async.} =
    await ctx.deferReply(ephemeral = true)
    let original = await ctx.editOriginal("done")
    let notification = await ctx.followup("more details")
    echo original.id, " ", notification.id)
```

Message-producing operations consistently return `Future[Message]`:
`respond`, `update`, `editOriginal`, `editFollowup`, `followup`, and
`original`. ACK-only
operations such as `deferReply`, `deferUpdate`, autocomplete completion, and
opening a modal return `Future[void]`.

An initial network failure whose acceptance is uncertain moves the context to
`OutcomeUnknown`. Further response mutations are then rejected instead of
risking a duplicate acknowledgement. DimSlash never auto-defers or retries an
interaction response.

## Components and modals

```nim
let app = newDiscordApp(proc(routes: var Routes) =
  routes.button("page:{number:int}",
    proc(ctx: ComponentContext) {.async.} =
      discard await ctx.update("page " & $ctx.captureInt("number")))

  routes.select("language",
    proc(ctx: ComponentContext) {.async.} =
      discard await ctx.update("selected: " & ctx.values.join(", ")))

  routes.modal("report:{number:int}",
    proc(ctx: ModalContext;
         reason {.description: "Reason".}: string;
         score {.description: "Score".}: Option[int]) {.async.} =
      discard await ctx.respond(reason & ":" & $score.get(0)))
)
```

Classic action rows, Components V2 layouts, and modal inputs are separate
types. A Components V2 original message cannot be edited back into classic
content.

Open a modal only from a context that Discord permits:

```nim
await ctx.showModal(modalDialog("report:7", "Report",
  textInput("reason", "Reason", style = ParagraphText,
    description = "Explain what happened"),
  textInput("score", "Score", required = false)))
```

Modal payloads use Discord's current `Label` components. A modal submission
also exposes `source`: command-origin modals may send a new response, while a
component-origin modal may additionally call `update` or `deferUpdate` on its
source message.

## Checks, cooldowns, and short-lived flows

Checks are async closures attached to immutable routes. Live cooldown buckets
belong to the binding, and a rejected check never consumes a cooldown:

```nim
routes.checkSlash("admin/ban",
  proc(ctx: SlashCommandContext): Future[CheckDecision] {.async.} =
    if ctx.inGuild: return allow()
    return deny("server only"))

routes.cooldownSlash("admin/ban", cooldownRule(5_000, UserCooldown))
```

Collectors are intentionally separate from persistent routes. They are
one-shot, user-filtered by default when started from a context, and are closed
when the binding stops:

```nim
if await ctx.confirm("Continue?"):
  discard await ctx.followup("confirmed")

let press = await ctx.waitForButton("page:{number:int}", timeoutMs = 30_000)
```

`paginate` provides the corresponding embed paginator. A pending collector
wins before a persistent component or modal route.

## Message models

Classic messages support owned embeds, action rows, selects, allowed mentions,
and in-memory uploads. Components V2 provides text displays, sections, media
galleries, file displays, separators, containers, and action rows:

```nim
var body = classicMessage("report")
body.files = @[uploadedFile("report.txt", reportContents, "Daily report")]
discard await ctx.respond(body.messageBody)

discard await ctx.respond(componentsV2(@[
  textDisplay("# Release"),
  container([v2ActionRow(button("Install", "install"))])
]).messageBody)
```

Message edits are replacements: omitted classic content and attachments are
explicitly cleared. Once an original message becomes Components V2, it cannot
be converted back to classic content. `launchActivity` is an initial response
and returns an owned `ActivityInstance`.

## Autocomplete and context menus

```nim
routes.autocomplete("search", "query",
  proc(ctx: AutocompleteContext) {.async.} =
    await ctx.complete([
      choice("Nim", "nim"),
      choice("Rust", "rust")
    ]))

routes.userCommand("Inspect user",
  proc(ctx: UserCommandContext) {.async.} =
    discard await ctx.respond(ctx.target.username, ephemeral = true))

routes.messageCommand("Quote",
  proc(ctx: MessageCommandContext) {.async.} =
    discard await ctx.respond("> " & ctx.target.content))
```

## Lifecycle and command scopes

Binding options are ordinary constructor arguments; there is no mandatory
configuration object:

```nim
let binding = app.bindGateway("TOKEN", managedScopes = @[
  globalScope(),
  guildScope(GuildId("123"))
], gatewayIntents = {Guilds, GuildMessages},
   messageContentIntent = false)
```

Every listed scope is authoritative and bulk-overwritten, including with an
empty command list. Unlisted scopes are untouched.

`requestStop` and `requestDetach` are non-blocking signals. `stop` and
`detach` stop accepting new interactions and wait without a timeout for all
active handlers to finish; `detach` then restores the previous dimscord event
callbacks.

## Error handling

Handlers may raise `UserRejectionError` (or `userRejection(message)`) for an
expected refusal. The default error handler turns it into an ephemeral
response. Other `CatchableError`s receive a generic ephemeral response;
autocomplete receives an empty choice list. `Defect`s are intentionally not
caught.

If a handler returns while its response is still `Pending`, DimSlash raises
`MissingInitialResponseError` through the same error policy. Silent completion
is therefore never accidental.

## Raw interaction boundary

The gateway binding consumes the raw `INTERACTION_CREATE` JSON from
dimscord's `on_dispatch` event. DimSlash-owned `Interaction`, `Message`,
`User`, and ID types form the public model; dimscord's parsed interaction
objects are not part of the public contract.

## Development

```fish
nimble test
nim c -d:ssl -d:release --path:src src/dimslash.nim
```

Requires Nim 2.0.6 or newer.
