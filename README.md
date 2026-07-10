# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Docs Deploy](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/pages-on-tag.yml?label=Docs%20Deploy)](https://github.com/gaato/dimslash/actions/workflows/pages-on-tag.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

A declarative, macro-powered interaction handler for
[dimscord](https://github.com/krisppurg/dimscord). Slash commands (with
full option metadata), context-menu commands, buttons, selects, modals,
and autocomplete — validated at compile time, synced with change
detection.

> **日本語版**: [README.ja.md](README.ja.md)

## Installation

```bash
nimble install dimslash
```

## Quick start

```nim
import dimscord, dimslash, std/random

let discord = newDiscordClient("TOKEN")
let handler = newInteractionHandler(discord)

handler.slash("roll", "Roll a die"):
  ## number of sides
  sides {.min: 2, max: 1000.}: int = 6
  execute:
    await ctx.reply("You rolled a " & $rand(1 .. sides))

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds})
```

The `## doc` comment becomes the option description in the Discord UI,
`min`/`max` become real constraints, and the default makes the option
optional on Discord while `sides` stays a plain `int` in your code.

## The slash block

```nim
handler.slash("order", "Order from the menu"):
  guild = "GUILD_ID"                 # optional command settings
  permissions = {permManageGuild}
  ## what to order
  item {.choices: {"Coffee": "coffee", "Tea": "tea"}.}: string
  ## how many
  amount {.min: 1, max: 10.}: int = 1
  ## note for the kitchen
  note {.maxLen: 100.}: Option[string]
  execute:
    await ctx.reply($amount & "x " & item, ephemeral = true)
```

**Option types**: `string`, `int`, `float`, `bool`, `User`, `Member`,
`Role`, `Channel`, `Mentionable`, `Attachment` — plus `Option[T]` of any
of them, or a default value (optional on Discord, non-`Option` in Nim).

**Option pragmas**: `desc`, `name` (wire-name override), `min`/`max`,
`minLen`/`maxLen`, `choices`, `channels`, `nameLoc`/`descLoc`.

**Command settings** (`key = value` lines): `guild`, `permissions`,
`nsfw`, `contexts`, `integrations`, `nameLocalizations`,
`descriptionLocalizations`.

Everything is validated at compile time: Discord's name rules, option
ordering (required before optional), duplicate names, choice limits,
group depth, autocomplete targets. A typo'd pragma or a misordered
option is a compile error, not a 400 at runtime.

## Subcommands

```nim
handler.slash("admin", "Admin tools"):
  permissions = {permManageGuild}
  group "member", "Member management":
    sub "warn", "Warn a member":
      ## who to warn
      target: User
      execute:
        await ctx.reply(target.username & " warned", ephemeral = true)
  sub "audit", "Show the audit log":
    execute:
      await ctx.reply("...")
```

## Autocomplete

```nim
handler.slash("search", "Search the docs"):
  ## search query
  query: string
  autocomplete query:                 # compile-time checked option link
    await ctx.suggest(allDocs.filterIt(ctx.focusedValue in it))
  execute:
    await ctx.reply("Results for " & query)
```

The option is automatically flagged `autocomplete: true` when synced, so
Discord actually fires the interaction.

## Components and modals

custom_ids can carry typed captures — `{name}` (string) and `{name:int}`
— which become variables in the handler body:

```nim
handler.button("page:{n:int}"):
  await ctx.update(pages[n], components = pager(n))

handler.select("role_picker"):
  await ctx.reply("You chose: " & ctx.values.join(", "))

handler.modal("feedback:{topic}"):
  await ctx.reply("Thanks for the " & topic & " feedback: " &
                  ctx.field("subject").get("(none)"))

handler.user("User info"):            # context-menu commands
  await ctx.reply("That's " & ctx.target.username, ephemeral = true)

handler.message("Quote"):
  await ctx.reply("> " & ctx.target.content)
```

## The context object

Every handler receives `ctx` with typed accessors (`ctx.user`,
`ctx.member`, `ctx.guildId`, `ctx.target`, `ctx.values`, `ctx.fields`,
…) and state-aware response helpers:

| Helper | What it does |
| --- | --- |
| `reply(...)` | initial response → placeholder edit → followup, automatically |
| `deferReply(ephemeral)` | "thinking…" placeholder |
| `followup(...)` / `edit(...)` / `delete()` / `original()` | followup & @original management |
| `update(...)` / `deferUpdate()` | edit the message a component sits on |
| `showModal(id, title, components)` | open a modal (`newTextInput` builds the inputs) |
| `suggest(choices)` | autocomplete suggestions (strings, pairs, ints, floats) |

All content-bearing helpers accept `content`, `embeds`, `components`,
`attachments`, `files`, `allowedMentions`, `ephemeral`, `tts`.

Handler exceptions go to `handler.onError` (default: log + ephemeral
error reply; set to `nil` to re-raise), unregistered interactions to
`handler.onUnknown`.

## Command sync with diffing

`syncCommands()` fetches what Discord has per scope (global and each
guild), compares it against your registered commands, and only PUTs when
something changed — no more full overwrite on every boot. Use
`syncCommands(force = true)` to overwrite unconditionally.

```nim
proc onReady(s: Shard, r: Ready) {.event(discord).} =
  for scope in await handler.syncCommands():
    echo scope.scope, ": ", scope.commandCount,
      " commands, updated=", scope.updated
```

## Migrating from 0.0.x

0.1.0 is a full rewrite with a new API:

| 0.0.x | 0.1.0 |
| --- | --- |
| `addSlash("x", "d") do (i: Interaction, a: int): ...` | `slash("x", "d"): ## desc` + `a: int` + `execute:` |
| `handler.reply(i, "text")` | `ctx.reply("text")` |
| `addUser` / `addMessage` | `user` / `message` blocks (`ctx.target`) |
| `addButton` / `addSelect` / `addModal` | `button` / `select` / `modal` blocks with `{capture}` patterns |
| `addAutocomplete(...)` / `addAutocompleteForOption` | `autocomplete <option>:` inside the slash block |
| `selectValues(i)` / `modalValue(i, id)` | `ctx.values` / `ctx.field(id)` |
| `registerCommands()` | `syncCommands()` (now with option metadata + diffing) |
| `handler.deferResponse(i)` / `followup` | `ctx.deferReply()` / `ctx.followup(...)` |

Notably, 0.0.x never sent option metadata to Discord at all — typed
arguments didn't show up in the Discord UI. 0.1.0 fixes that.

## Examples

- Minimal setup: [examples/basic_interactions.nim](examples/basic_interactions.nim)
- Every option type: [examples/typed_slash_args.nim](examples/typed_slash_args.nim)
- Subcommands, patterns & modals: [examples/advanced_workflow.nim](examples/advanced_workflow.nim)
- Buttons, selects & embeds: [examples/ui_showcase.nim](examples/ui_showcase.nim)

## Generating API docs

```bash
nimble docs
```

Output: [docs/dimslash.html](docs/dimslash.html)
