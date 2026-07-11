# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Docs Deploy](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/pages-on-tag.yml?label=Docs%20Deploy)](https://github.com/gaato/dimslash/actions/workflows/pages-on-tag.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

A declarative, macro-powered interaction handler for
[dimscord](https://github.com/krisppurg/dimscord). Slash commands (with
full option metadata), context-menu commands, buttons, selects, modals,
and autocomplete — validated at compile time, synced with change
detection. On top of that: awaitable components (`waitForButton`),
ready-made confirm/paginate flows, checks & cooldowns, typed modal
forms, and embed/component builder blocks.

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
`descriptionLocalizations`, `cooldown` — plus `check` guard lines (see
below).

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

## Typed modal forms

`modalForm` declares a modal's inputs and its submit handler in one
block and returns a form you can open from any handler:

```nim
let feedback = handler.modalForm("feedback:{topic}", "Send feedback"):
  ## Subject
  subject {.maxLen: 100.}: string
  ## Rating (1-5)
  rating {.placeholder: "5".}: int
  ## Anything else?
  detail {.paragraph.}: Option[string]
  check rating in 1 .. 5, "The rating has to be between 1 and 5."
  submit:
    await ctx.reply(topic & ": " & subject & " → " & $rating,
                    ephemeral = true)

# elsewhere — capture values fill the pattern in order:
await ctx.showModal(feedback, "bug")
```

Text inputs are always text on the wire, so `int`/`float` fields are
parsed on submit — a bad value becomes a polite ephemeral reply
(`UserError`), not a crash. `Option[T]` fields are optional on Discord
and `none` when left empty. Field pragmas: `label`, `name`,
`placeholder`, `value`, `minLen`/`maxLen`, `paragraph`.

## Awaitable components

Instead of registering a handler, you can wait for the interaction
right where you are:

```nim
handler.slash("quiz", "Answer a quick question"):
  execute:
    let two = ctx.scopedId("quiz:2")    # custom_id unique to this invocation
    let four = ctx.scopedId("quiz:4")
    await ctx.reply("What is 2 + 2?", components = buttonsFor(two, four))
    let press = await ctx.waitForButton([two, four], timeout = 30)
    if press.isNone:
      await ctx.reply("Too slow!", ephemeral = true)
    else:
      await press.get.update("You pressed " & press.get.customId)
```

`waitForButton` / `waitForSelect` / `waitForModal` register a one-shot
waiter that is checked before the registry and removed once it fires;
they return `none` on timeout. The `ctx` variants only accept the
invoking user by default (pass `user = ""` for anyone; `message = …`
filters by host message). Responding to the returned context is your
job. Patterns work like everywhere else — `waitForButton("page:{n:int}")`
puts `n` in `press.get.captures`.

## Ready-made flows

```nim
if await ctx.confirm("Really delete **everything**?"):
  await ctx.reply("Done.", ephemeral = true)   # auto-followup

await ctx.paginate(guideEmbeds)   # ◀ 1 / 5 ▶
```

`confirm` sends yes/no buttons and returns `true` only for yes (`false`
on timeout); `paginate` serves page flips to the invoker and disables
its controls when the timeout passes. Both build on the waiters, edit
their own messages, and respect the reply state machine (they follow up
if you already responded). `disableAll(components)` is exported for
flows of your own. Interaction tokens live 15 minutes — keep timeouts
below that.

## Checks, cooldowns & user-facing errors

```nim
handler.slash("daily", "Claim your daily reward"):
  check ctx.inGuild, "This only works in a server."
  cooldown = (86_400, cbUser)
  execute:
    if alreadyClaimed(ctx.user.id):
      fail "You already claimed today. Greedy!"
    await ctx.reply("Here you go!")
```

- `check <cond>, "message"` (or a `check:` block) runs before `execute`
  and can see the declared options. On a command with subcommands it is
  inherited by every leaf.
- `cooldown = seconds` or `(seconds, cbUser|cbGuild|cbChannel|cbGlobal)`
  refuses reuse within the window (after the checks, so a failed check
  doesn't burn the cooldown). Works on `slash`/`user`/`message` and on
  `button`/`select`/`modal` blocks too.
- `fail "message"` raises `UserError` anywhere in a handler; the default
  error hook sends the message as an ephemeral reply instead of logging.

## Embed & component builders

```nim
let card = embed:
  title "Vote: " & motion
  description "You have 60 seconds."
  color 0x5865F2
  field "Ayes", "12", inline = true
  footer "one vote each"

let comps = rows:
  row:
    button "Aye", "vote:aye", style = bsSuccess
    button "Nay", "vote:nay", style = bsDanger
  row:
    select "vote:menu", placeholder = "Or pick here":
      option "Aye", "yes", desc = "For the motion"
      option "Nay", "no"

await ctx.reply(embeds = @[card], components = comps)
```

Named arguments pass straight through to dimscord's builders, entity
selects (`userSelect`, `roleSelect`, `mentionableSelect`,
`channelSelect`) are included, and Discord's layout rules (a select
menu owns its row) are enforced at compile time.

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
| `showModal(form, captures...)` / `showModal(id, title, components)` | open a `modalForm` or a hand-built modal |
| `suggest(choices)` | autocomplete suggestions (strings, pairs, ints, floats) |
| `confirm(...)` / `paginate(...)` / `waitFor*` | the flows and waiters described above |

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
- Flows, waiters, modal forms & builders: [examples/interactive_flows.nim](examples/interactive_flows.nim)

## Generating API docs

```bash
nimble docs
```

Output: [docs/dimslash.html](docs/dimslash.html)
