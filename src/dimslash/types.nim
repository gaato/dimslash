## Core type definitions for **dimslash**.
##
## This module defines the enumerations, error hierarchy, handler object, and
## registry that together form the backbone of the interaction handling pipeline.
## You typically do **not** import this module directly — `import dimslash`
## re-exports everything.
##
## Error handling
## ==============
##
## dimslash signals dispatch problems through `HandlerError`, a
## subtype of `CatchableError` that carries a `HandlerErrorKind` for
## programmatic matching.
##
## .. code-block:: nim
##   try:
##     discard await handler.handleInteraction(s, i)
##   except HandlerError as e:
##     case e.kind
##     of hekNotFound:
##       echo "no handler registered for this command"
##     of hekNotImplemented:
##       echo "this interaction kind is not supported yet"
##     of hekInvalidInteraction:
##       echo "malformed interaction payload"
##
## Architecture overview
## =====================
##
## .. code-block::
##
##   InteractionHandler
##     ├── discord: DiscordClient     ─ REST / gateway
##     ├── defaultGuildId: string     ─ default guild for sync
##     ├── registry: CommandRegistry  ─ command lookup tables
##     │     ├── slash   ─ OrderedTable[string, RegisteredCommand]
##     │     ├── user
##     │     ├── message
##     │     ├── button
##     │     ├── select
##     │     ├── modal
##     │     └── autocomplete
##     └── slashOptionNames           ─ metadata for autocomplete linking

import std/[tables, asyncdispatch]
import dimscord


type
  CommandKind* = enum
    ## Discriminates the interaction kind a command is registered for.
    ##
    ## Each variant maps to one Discord interaction type or sub-type:
    ##
    ## ================  ================================  ===================
    ## Variant           Discord concept                   DSL helper
    ## ================  ================================  ===================
    ## `ckSlash`         ``/command`` slash command         `addSlash`
    ## `ckUser`          Apps > User context menu           `addUser`
    ## `ckMessage`       Apps > Message context menu        `addMessage`
    ## `ckButton`        Button component press             `addButton`
    ## `ckSelect`        Select-menu component              `addSelect`
    ## `ckModal`         Modal submit                       `addModal`
    ## `ckAutocomplete`  Autocomplete callback              `addAutocomplete`
    ## ================  ================================  ===================
    ckSlash
    ckUser
    ckMessage
    ckButton
    ckSelect
    ckModal
    ckAutocomplete

  HandlerErrorKind* = enum
    ## Categorises errors raised during interaction dispatch.
    ##
    ## =========================  ==============================================
    ## Variant                    Meaning
    ## =========================  ==============================================
    ## `hekNotImplemented`        The interaction kind is not yet supported.
    ## `hekNotFound`              No handler was registered for the command.
    ## `hekInvalidInteraction`    The payload is malformed or missing fields.
    ## =========================  ==============================================
    ##
    ## Catch `HandlerError` and inspect its `kind` field to react differently:
    ##
    ## .. code-block:: nim
    ##   except HandlerError as e:
    ##     if e.kind == hekNotFound:
    ##       await handler.reply(i, "Unknown command")
    hekNotImplemented
    hekNotFound
    hekInvalidInteraction

  HandlerError* = object of CatchableError
    ## Structured error type carrying a `HandlerErrorKind`.
    ## Catch it to distinguish between "not found" vs "not implemented" etc.
    ##
    ## .. code-block:: nim
    ##   try:
    ##     discard await handler.handleInteraction(s, i)
    ##   except HandlerError as e:
    ##     case e.kind
    ##     of hekNotFound: echo "unknown command"
    ##     of hekNotImplemented: echo "not yet supported"
    ##     of hekInvalidInteraction: echo "bad payload"
    kind*: HandlerErrorKind

  InteractionHandler* = ref object
    ## Top-level object that wires a `DiscordClient` to a `CommandRegistry`.
    ##
    ## There should typically be **one** handler per bot process.  Create it
    ## with `newInteractionHandler`, register commands via the DSL, sync
    ## them with `registerCommands`, then pipe incoming interactions through
    ## `handleInteraction`.
    ##
    ## .. code-block:: nim
    ##   let discord = newDiscordClient("TOKEN")
    ##   var handler = newInteractionHandler(discord, defaultGuildId = "123456")
    ##
    ##   handler.addSlash("ping", "Pong!") do:
    ##     await handler.reply(i, "pong")
    ##
    ##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
    ##     await handler.registerCommands()
    ##
    ##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
    ##     discard await handler.handleInteraction(s, i)
    discord*: DiscordClient
      ## The dimscord client used to call the REST API.
    defaultGuildId*: string
      ## If non-empty, `registerCommands()` targets this guild by default
      ## instead of the global scope.  Guild-scoped commands update instantly;
      ## global commands can take up to 1 hour to propagate.
    registry*: CommandRegistry
      ## Internal command registry.  Prefer the DSL helpers (`addSlash`,
      ## `addUser`, `addButton`, …) to populate it.
    slashOptionNames*: OrderedTable[string, seq[string]]
      ## Known slash option names per command (normalised).  Populated
      ## automatically by `addSlash` and consumed by
      ## `addAutocompleteForOption` for validation.

  CommandHandlerProc* = proc (s: Shard, i: Interaction): Future[void] {.closure.}
    ## Signature every command callback must match.
    ## The `Shard` gives gateway context; the `Interaction` carries the
    ## request payload.

  RegisteredCommand* = object
    ## Value object stored in the registry for each registered command.
    ##
    ## You rarely construct this yourself — the DSL macros build it
    ## internally.  Fields are public for introspection.
    kind*: CommandKind       ## What kind of interaction this command handles.
    name*: string            ## Command or custom-id name (lowercased in registry).
    optionName*: string      ## Focused option name (autocomplete only; empty for fallback).
    description*: string     ## Description shown in the Discord UI (slash only).
    guildId*: string         ## If non-empty, restrict sync to this guild.
    callback*: CommandHandlerProc ## The handler to invoke at dispatch time.

  CommandRegistry* = ref object
    ## Holds registered commands, bucketed by `CommandKind`.
    ##
    ## Prefer `registry.register` / `registry.find` over direct table
    ## access.  The `pairs` iterator lets you enumerate all commands of a
    ## given kind, which is used by `sync.nim` to build the bulk-overwrite
    ## payload.
    ##
    ## Each table uses the **normalised** (lowercased) command name as key.
    ## For autocomplete, the key format is ``"commandname"`` for fallback
    ## handlers and ``"commandname#optionname"`` for option-specific ones.
    slash*: OrderedTable[string, RegisteredCommand]
    user*: OrderedTable[string, RegisteredCommand]
    message*: OrderedTable[string, RegisteredCommand]
    button*: OrderedTable[string, RegisteredCommand]
    select*: OrderedTable[string, RegisteredCommand]
    modal*: OrderedTable[string, RegisteredCommand]
    autocomplete*: OrderedTable[string, RegisteredCommand]

proc newNotImplementedError*(message: string): ref HandlerError =
  ## Creates a `HandlerError` with `hekNotImplemented`.
  runnableExamples "-d:ssl":
    let err = newNotImplementedError("buttons are not supported yet")
    doAssert err.kind == hekNotImplemented
    doAssert err.msg == "buttons are not supported yet"
  #==#
  result = newException(HandlerError, message)
  result.kind = hekNotImplemented

proc newNotFoundError*(message: string): ref HandlerError =
  ## Creates a `HandlerError` with `hekNotFound`.
  runnableExamples "-d:ssl":
    let err = newNotFoundError("command not found: foo")
    doAssert err.kind == hekNotFound
  #==#
  result = newException(HandlerError, message)
  result.kind = hekNotFound

proc newInvalidInteractionError*(message: string): ref HandlerError =
  ## Creates a `HandlerError` with `hekInvalidInteraction`.
  runnableExamples "-d:ssl":
    let err = newInvalidInteractionError("missing option: name")
    doAssert err.kind == hekInvalidInteraction
  #==#
  result = newException(HandlerError, message)
  result.kind = hekInvalidInteraction

proc ensureImplemented*(kind: CommandKind) =
  ## Raises `HandlerError(hekNotImplemented)` when `kind` is not yet
  ## supported.
  ##
  ## Current release supports all `CommandKind` values, so this proc is a
  ## no-op and is kept for future compatibility.
  runnableExamples "-d:ssl":
    # Implemented kinds — no error:
    ensureImplemented(ckSlash)
    ensureImplemented(ckUser)
    ensureImplemented(ckMessage)
    ensureImplemented(ckButton)
    ensureImplemented(ckSelect)
    ensureImplemented(ckModal)
    ensureImplemented(ckAutocomplete)
  #==#
  discard kind
