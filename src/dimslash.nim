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
##   let bot = newBot("TOKEN")
##
##   bot.slash("roll", "Roll a die"):
##     ## number of sides
##     sides {.min: 2, max: 1000.}: int = 6
##     execute:
##       await ctx.reply("You rolled a " & $rand(1 .. sides))
##
##   waitFor bot.start()
##
## Module map:
##
## - `dsl <dimslash/dsl.html>`_ — the `slash`/`user`/`message`/`button`/
##   `select`/`modal`/`modalForm` declaration macros (with `check` lines
##   and `cooldown` settings)
## - `context <dimslash/context.html>`_ — response helpers (`reply`,
##   `deferReply`, `update`, `showModal`, `suggest`, …) and interaction
##   accessors
## - `wait <dimslash/wait.html>`_ — awaitable interactions
##   (`waitForButton`, `waitForSelect`, `waitForModal`, `scopedId`)
## - `flows <dimslash/flows.html>`_ — ready-made flows (`confirm`,
##   `paginate`, `disableAll`)
## - `builders <dimslash/builders.html>`_ — the `embed`/`row`/`rows`
##   builder macros
## - `dispatch <dimslash/dispatch.html>`_ — `handleInteraction`
## - `sync <dimslash/sync.html>`_ — `syncCommands` with change detection
## - `bot <dimslash/bot.html>`_ — `newBot`/`install`/`start` lifecycle sugar
## - `types <dimslash/types.html>`_ — the data model
## - `registry <dimslash/registry.html>`_ / `extract
##   <dimslash/extract.html>`_ — programmatic registration and payload
##   extraction (the DSL's building blocks)

import std/[asyncdispatch, options, tables]
import dimslash/[types, extract, registry, context, dispatch, dsl, rest,
                 sync, wait, flows, builders, bot]

export types, extract, registry, context, dispatch, dsl, rest, sync,
       wait, flows, builders, bot
# the DSL is unusable without these, so spare every bot the imports
export asyncdispatch, options, tables
