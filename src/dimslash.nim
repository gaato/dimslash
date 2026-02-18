## **dimslash** — Interaction-first command handler for `dimscord <https://github.com/krisppurg/dimscord>`_.
##
## dimslash provides a declarative, type-safe way to register and dispatch
## Discord interactions (slash commands, user/message context-menu commands,
## buttons, selects, modals, and autocomplete).
##
## Getting started
## ===============
##
## 1. Create a `DiscordClient` and wrap it in an `InteractionHandler`.
## 2. Register commands with the DSL helpers (`addSlash`, `addUser`, …).
## 3. Call `registerCommands` once the gateway is ready.
## 4. Forward incoming interactions to `handleInteraction`.
##
## Minimal example
## ---------------
##
## .. code-block:: nim
##   import dimscord, asyncdispatch, os
##   import dimslash
##
##   let discord = newDiscordClient(getEnv("DISCORD_TOKEN"))
##   var handler = newInteractionHandler(discord, defaultGuildId = "YOUR_GUILD_ID")
##
##   # Slash command — simple
##   handler.addSlash("ping", "Replies with pong") do:
##     await handler.reply(i, "pong")
##
##   # Slash command — typed parameters
##   handler.addSlash("sum", "Adds integers") do (i: Interaction, a: int, b: int):
##     await handler.reply(i, "sum = " & $(a + b))
##
##   # User context-menu command
##   handler.addUser("userinfo") do:
##     let user = i.member.get.user
##     await handler.reply(i, "User: " & user.username)
##
##   # Message context-menu command
##   handler.addMessage("quote") do:
##     await handler.reply(i, "You quoted a message!")
##
##   # Button handler
##   handler.addButton("action:confirm") do:
##     await handler.reply(i, "Confirmed!")
##
##   # Select-menu handler
##   handler.addSelect("color_picker") do:
##     let choices = i.selectValues
##     await handler.reply(i, "You picked: " & choices.join(", "))
##
##   # Modal submit handler
##   handler.addModal("feedback_form") do:
##     let answer = i.modalValue("feedback_text").get("(empty)")
##     await handler.reply(i, "Thanks! " & answer)
##
##   # Autocomplete — fallback for any option of "sum"
##   handler.addAutocomplete("sum") do:
##     await handler.suggest(i, @["1", "2", "3"])
##
##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
##     await handler.registerCommands()
##
##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
##     discard await handler.handleInteraction(s, i)
##
##   waitFor discord.startSession(gateway_intents = {giGuilds})
##
## Architecture
## ============
##
## ::
##
##   InteractionHandler
##   ├── CommandRegistry   (stores all registered commands)
##   ├── DSL helpers       (addSlash, addUser, addButton …)
##   ├── Dispatch          (handleInteraction routes to callbacks)
##   ├── Sync              (registerCommands pushes to Discord API)
##   └── Context helpers   (reply, deferResponse, followup, suggest)
##
## Module overview
## ===============
##
## ==================  =======================================================
## Module              Description
## ==================  =======================================================
## `types`             Core types: `InteractionHandler`, `CommandRegistry`, …
## `dsl`               DSL helpers: `addSlash`, `addUser`, `addMessage`, …
## `slashargs`         Typed extraction of slash-command options
## `componentargs`     Helpers for component/modal payload extraction
## `registry`          Internal command store
## `dispatch`          Routes interactions to registered handlers
## `sync`              Bulk-overwrites commands to Discord
## `context`           Reply / defer / followup helpers
## ==================  =======================================================

import dimscord
import std/tables

import dimslash/types
import dimslash/registry
import dimslash/dsl
import dimslash/dispatch
import dimslash/sync
import dimslash/context
import dimslash/slashargs
import dimslash/componentargs

export types
export registry
export dsl
export dispatch
export sync
export context
export slashargs
export componentargs

proc newInteractionHandler*(discord: DiscordClient, defaultGuildId = ""): InteractionHandler =
  ## Creates a new `InteractionHandler` wired to the given `DiscordClient`.
  ##
  ## The handler is the central object — it owns the `CommandRegistry`,
  ## provides the DSL helpers, dispatches incoming interactions, and
  ## synchronises commands to Discord.
  ##
  ## Parameters
  ## ----------
  ## - `discord` – a dimscord `DiscordClient` (must already be constructed).
  ## - `defaultGuildId` – when non-empty, `registerCommands()` targets this
  ##   guild by default.  Guild-scoped commands update instantly; global
  ##   commands (empty string) can take up to an hour.
  ##
  ## Typical usage
  ## -------------
  ## .. code-block:: nim
  ##   let discord = newDiscordClient(getEnv("DISCORD_TOKEN"))
  ##   var handler = newInteractionHandler(discord, defaultGuildId = "123456789")
  ##
  ##   # 1. Register commands
  ##   handler.addSlash("ping", "Pong!") do:
  ##     await handler.reply(i, "pong")
  ##
  ##   # 2. Sync in onReady
  ##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
  ##     await handler.registerCommands()
  ##
  ##   # 3. Dispatch in interactionCreate
  ##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  ##     discard await handler.handleInteraction(s, i)
  runnableExamples "-r:off -d:ssl":
    import dimscord
    let discord = newDiscordClient("TOKEN")

    # Global commands (may take up to 1 hour to propagate):
    var global = newInteractionHandler(discord)

    # Guild-scoped commands (instant update, great for development):
    var dev = newInteractionHandler(discord, defaultGuildId = "123456789")
  #==#
  result = InteractionHandler(
    discord: discord,
    defaultGuildId: defaultGuildId,
    registry: newRegistry(),
    slashOptionNames: initOrderedTable[string, seq[string]]()
  )
