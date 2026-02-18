## Command registry — the central store for all registered interaction handlers.
##
## `CommandRegistry` groups `RegisteredCommand` objects by `CommandKind`.
## You normally don't interact with this module directly; the DSL helpers
## (`addSlash`, `addUser`, …) and `handleInteraction` call into it.
##
## Key concepts
## ============
##
## - **Names are normalised** — all lookups are case-insensitive (lowercased).
## - **Duplicates are rejected** — re-registering the same name raises
##   `ValueError`, preventing silent overwrites.
## - **Autocomplete uses composite keys** — fallback handlers use
##   ``"commandname"``; option-specific handlers use ``"commandname#optionname"``.
##   `findAutocomplete` tries the specific key first, then falls back.
##
## Example: manual registration and lookup
## ----------------------------------------
## .. code-block:: nim
##   import dimslash
##
##   var reg = newRegistry()
##   reg.register RegisteredCommand(
##     kind: ckSlash, name: "ping", description: "Pong!",
##     callback: proc (s: Shard, i: Interaction) {.async.} = discard
##   )
##   let cmd = reg.find(ckSlash, "ping")
##   assert cmd.name == "ping"
##
##   # Iteration:
##   for name, cmd in reg.pairs(ckSlash):
##     echo name, " -> ", cmd.description

import std/[tables, strutils]

import ./types

proc newRegistry*(): CommandRegistry =
  ## Creates an empty `CommandRegistry` with all kind-buckets initialised.
  runnableExamples "-d:ssl":
    import dimslash/types, std/tables
    let reg = newRegistry()
    doAssert len(reg.slash) == 0
    doAssert len(reg.user) == 0
  #==#
  CommandRegistry(
    slash: initOrderedTable[string, RegisteredCommand](),
    user: initOrderedTable[string, RegisteredCommand](),
    message: initOrderedTable[string, RegisteredCommand](),
    button: initOrderedTable[string, RegisteredCommand](),
    select: initOrderedTable[string, RegisteredCommand](),
    modal: initOrderedTable[string, RegisteredCommand](),
    autocomplete: initOrderedTable[string, RegisteredCommand](),
  )

proc normalizeName(name: string): string =
  ## Internal helper: lowercases `name` for case-insensitive lookup.
  name.toLowerAscii()

proc autocompleteKey(commandName, optionName: string): string =
  ## Builds the composite key used for autocomplete lookup.
  ##
  ## - ``autocompleteKey("search", "")``       → ``"search"``   (fallback)
  ## - ``autocompleteKey("search", "query")``  → ``"search#query"`` (specific)
  let c = normalizeName(commandName)
  let o = normalizeName(optionName)
  if o.len == 0: c else: c & "#" & o

proc register*(registry: CommandRegistry, command: RegisteredCommand) =
  ## Inserts `command` into the appropriate bucket of `registry`.
  ##
  ## Raises `ValueError` when a command with the same (normalised) name
  ## already exists in that bucket — this prevents silent overwrites.
  runnableExamples "-d:ssl":
    import dimslash/types, std/[asyncdispatch, tables]
    import dimscord

    var reg = newRegistry()
    reg.register RegisteredCommand(
      kind: ckSlash, name: "hello", description: "Say hello",
      callback: proc (s: Shard, i: Interaction) {.async.} = discard
    )
    doAssert len(reg.slash) == 1

    # Duplicate registration raises:
    doAssertRaises(ValueError):
      reg.register RegisteredCommand(
        kind: ckSlash, name: "hello", description: "duplicate",
        callback: proc (s: Shard, i: Interaction) {.async.} = discard
      )
  #==#
  let key =
    if command.kind == ckAutocomplete:
      autocompleteKey(command.name, command.optionName)
    else:
      normalizeName(command.name)
  case command.kind
  of ckSlash:
    if registry.slash.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.slash[key] = command
  of ckUser:
    if registry.user.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.user[key] = command
  of ckMessage:
    if registry.message.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.message[key] = command
  of ckButton:
    if registry.button.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.button[key] = command
  of ckSelect:
    if registry.select.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.select[key] = command
  of ckModal:
    if registry.modal.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.modal[key] = command
  of ckAutocomplete:
    if registry.autocomplete.hasKey(key): raise newException(ValueError, "duplicate command registration: " & command.name)
    registry.autocomplete[key] = command

proc find*(registry: CommandRegistry, kind: CommandKind, name: string): RegisteredCommand =
  ## Looks up the `RegisteredCommand` for `kind` + `name` (case-insensitive).
  ##
  ## Raises `HandlerError(hekNotFound)` when no match exists.
  runnableExamples "-d:ssl":
    import dimslash/types, std/asyncdispatch
    import dimscord

    var reg = newRegistry()
    reg.register RegisteredCommand(
      kind: ckUser, name: "Info", description: "",
      callback: proc (s: Shard, i: Interaction) {.async.} = discard
    )
    let found = reg.find(ckUser, "info")  # case-insensitive
    doAssert found.name == "Info"

    doAssertRaises(HandlerError):
      discard reg.find(ckUser, "nonexistent")
  #==#
  let key =
    if kind == ckAutocomplete:
      autocompleteKey(name, "")
    else:
      normalizeName(name)
  case kind
  of ckSlash:
    if not registry.slash.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.slash[key]
  of ckUser:
    if not registry.user.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.user[key]
  of ckMessage:
    if not registry.message.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.message[key]
  of ckButton:
    if not registry.button.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.button[key]
  of ckSelect:
    if not registry.select.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.select[key]
  of ckModal:
    if not registry.modal.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.modal[key]
  of ckAutocomplete:
    if not registry.autocomplete.hasKey(key): raise newNotFoundError("command not found: " & name)
    registry.autocomplete[key]

proc findAutocomplete*(registry: CommandRegistry, name: string, optionName = ""): RegisteredCommand =
  ## Looks up an autocomplete handler for `name` and focused `optionName`.
  ##
  ## Resolution order:
  ## 1. If `optionName` is non-empty, try the specific key
  ##    ``"name#optionname"``.
  ## 2. Fall back to the generic key ``"name"``.
  ## 3. Raise `HandlerError(hekNotFound)` if neither exists.
  ##
  ## This two-level lookup lets you register a general autocomplete handler
  ## and override it for individual options:
  ##
  ## .. code-block:: nim
  ##   # Generic fallback
  ##   handler.addAutocomplete("search") do:
  ##     await handler.suggest(i, @["fallback"])
  ##
  ##   # Option-specific override (takes priority for "query")
  ##   handler.addAutocompleteForOption("search", "query") do:
  ##     await handler.suggest(i, @["specific"])
  let specific = autocompleteKey(name, optionName)
  if optionName.len > 0 and registry.autocomplete.hasKey(specific):
    return registry.autocomplete[specific]

  let generic = autocompleteKey(name, "")
  if registry.autocomplete.hasKey(generic):
    return registry.autocomplete[generic]

  raise newNotFoundError("command not found: " & name)

iterator pairs*(registry: CommandRegistry, kind: CommandKind): (string, RegisteredCommand) =
  ## Yields `(name, RegisteredCommand)` pairs for every command of `kind`.
  ##
  ## Useful for serialising registered commands into the Discord bulk-overwrite
  ## payload (see `sync.nim`).
  case kind
  of ckSlash:
    for pair in registry.slash.pairs: yield pair
  of ckUser:
    for pair in registry.user.pairs: yield pair
  of ckMessage:
    for pair in registry.message.pairs: yield pair
  of ckButton:
    for pair in registry.button.pairs: yield pair
  of ckSelect:
    for pair in registry.select.pairs: yield pair
  of ckModal:
    for pair in registry.modal.pairs: yield pair
  of ckAutocomplete:
    for pair in registry.autocomplete.pairs: yield pair
