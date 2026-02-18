# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Docs Deploy](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/pages-on-tag.yml?label=Docs%20Deploy)](https://github.com/gaato/dimslash/actions/workflows/pages-on-tag.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

An interaction-first command handler for [dimscord](https://github.com/krisppurg/dimscord). Register Slash, User, and Message commands declaratively with a dimscmd-like feel.

> **日本語版**: [README.ja.md](README.ja.md)

## Installation
```bash
nimble install dimslash
```

## Quick start
```nim
import dimscord, asyncdispatch
import dimslash

let discord = newDiscordClient("TOKEN")
var handler = newInteractionHandler(discord)

handler.addSlash("ping", "Replies with pong") do:
  await handler.reply(i, "pong")

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds})
```

## Typed Slash Args (dimscmd-like)
Slash option values are automatically extracted into typed parameters.

```nim
handler.addSlash("sum", "Adds two numbers") do (i: Interaction, a: int, b: int):
  await handler.reply(i, $(a + b))

handler.addSlash("maybe", "Example with optional arg") do (i: Interaction, x: Option[int]):
  if x.isSome:
    await handler.reply(i, "x=" & $x.get)
  else:
    await handler.reply(i, "x is missing")
```

Supported types in the first release:
- `string`
- `int`
- `bool`
- `float`
- `User`
- `Role`
- `Option[T]` (for any of the above)

You can also pass an explicit callback with `addSlashProc`.

## Examples
- Minimal setup: [examples/basic_interactions.nim](examples/basic_interactions.nim)
- Typed args: [examples/typed_slash_args.nim](examples/typed_slash_args.nim)
- Components & modal: [examples/scaffold_interactions.nim](examples/scaffold_interactions.nim)
- Advanced workflow: [examples/advanced_workflow.nim](examples/advanced_workflow.nim)
- UI showcase (button/select/modal): [examples/ui_showcase.nim](examples/ui_showcase.nim)

## Button / Select / Modal DSL
These can be declared with `do` blocks and are dispatched by `custom_id`.

```nim
handler.addButton("confirm:delete", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "button clicked")
)

handler.addSelect("pick:role", proc (s: Shard, i: Interaction) {.async.} =
  let picked = selectValues(i)
  await handler.reply(i, "picked=" & $picked)
)

handler.addModal("feedback:modal", proc (s: Shard, i: Interaction) {.async.} =
  let feedback = modalValue(i, "feedback")
  await handler.reply(i, feedback.get(""))
)

handler.addAutocomplete("sum", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "1", input & "2", input & "3"])
)

# option-scoped handler (focused option == "query")
handler.addAutocomplete("search", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-repo", input & "-user"])
, optionName = "query")

# validated option link (requires slash option metadata from addSlash)
handler.addSlash("search", "Search repositories") do (i: Interaction, query: string):
  discard

handler.addAutocompleteForOption("search", "query", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-repo", input & "-user"])
)
```

Useful helpers:
- `customId(i)`
- `selectValues(i)`
- `modalValues(i)`
- `modalValue(i, fieldCustomId)`
- `focusedOptionName(i)` / `focusedOptionValue(i)`
- `suggest(i, choices)`

## Generating API docs
```bash
nimble docs
```

Output:
- [docs/dimslash.html](docs/dimslash.html)
