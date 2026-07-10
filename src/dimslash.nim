## **dimslash** — a declarative interaction handler for
## `dimscord <https://github.com/krisppurg/dimscord>`_.
##
## Commands are declared in compile-time-checked blocks; option metadata
## (descriptions, choices, min/max, autocomplete) is synced to Discord,
## and handlers receive a context object with typed accessors and
## state-aware response helpers.
##
## .. code-block:: nim
##   import dimscord, dimslash, std/[asyncdispatch, options]
##
##   let discord = newDiscordClient("TOKEN")
##   let handler = newInteractionHandler(discord)
##
##   handler.slash("roll", "Roll a die"):
##     ## number of sides
##     sides {.min: 2, max: 1000.}: int = 6
##     execute:
##       await ctx.reply("You rolled a " & $rand(1 .. sides))
##
##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
##     discard await handler.syncCommands()
##
##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
##     discard await handler.handleInteraction(s, i)
##
##   waitFor discord.startSession(gateway_intents = {giGuilds})
##
## Module map:
##
## - `dsl <dimslash/dsl.html>`_ — the `slash`/`user`/`message`/`button`/
##   `select`/`modal` declaration macros
## - `context <dimslash/context.html>`_ — response helpers (`reply`,
##   `deferReply`, `update`, `suggest`, …) and interaction accessors
## - `dispatch <dimslash/dispatch.html>`_ — `handleInteraction`
## - `sync <dimslash/sync.html>`_ — `syncCommands` with change detection
## - `types <dimslash/types.html>`_ — the data model
## - `registry <dimslash/registry.html>`_ / `extract
##   <dimslash/extract.html>`_ — programmatic registration and payload
##   extraction (the DSL's building blocks)

import std/[asyncdispatch, options, tables]
import dimslash/[types, extract, registry, context, dispatch, dsl, rest, sync]

export types, extract, registry, context, dispatch, dsl, rest, sync
# the DSL is unusable without these, so spare every bot the imports
export asyncdispatch, options, tables
