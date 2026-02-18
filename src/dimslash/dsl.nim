## DSL for declaratively registering interaction commands.
##
## This is the primary API surface of **dimslash**.  It provides template /
## macro wrappers that let you add commands with minimal boilerplate.
##
## Quick reference
## ---------------
## ============================  ====================================================
## Helper                        Purpose
## ============================  ====================================================
## ``addSlash``                  Slash command with typed parameter extraction
## ``addSlashProc``              Slash command from a raw ``CommandHandlerProc``
## ``addUser``                   User context-menu command
## ``addMessage``                Message context-menu command
## ``addButton``                 Button component handler
## ``addSelect``                 Select-menu component handler
## ``addModal``                  Modal submit handler
## ``addAutocomplete``           Autocomplete handler (fallback or option-scoped)
## ``addAutocompleteForOption``  Autocomplete handler with option-name validation
## ============================  ====================================================
##
## Every ``add*`` helper comes in **two flavours**:
##
## 1. **Proc overload** — accepts a ``CommandHandlerProc`` directly.
## 2. **Template overload** — accepts a ``do:`` block that auto-injects
##    ``s: Shard`` and ``i: Interaction`` into scope.
##
## ``addSlash`` is a **macro** that additionally generates typed
## ``requireSlashArg`` / ``getSlashArg`` calls from the do-block
## parameters.
##
## Lifecycle
## ---------
## ::
##   1. Register  — handler.addSlash / addUser / addButton / …
##   2. Sync      — handler.registerCommands()   (onReady)
##   3. Dispatch  — handler.handleInteraction(s, i)
##
## Minimal bot
## -----------
## .. code-block:: nim
##   import dimscord, asyncdispatch, os
##   import dimslash
##
##   let discord = newDiscordClient(getEnv("DISCORD_TOKEN"))
##   var handler = newInteractionHandler(discord)
##
##   handler.addSlash("ping", "Replies with pong") do:
##     await handler.reply(i, "pong")
##
##   handler.addSlash("sum", "Adds two numbers") do (i: Interaction, a: int, b: int):
##     await handler.reply(i, $(a + b))
##
##   handler.addUser("userinfo") do:
##     await handler.reply(i, "user: " & i.member.get.user.username)
##
##   handler.addButton("my_button") do:
##     await handler.reply(i, "Button clicked!")
##
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

import asyncdispatch
import dimscord
import macros
import std/[strutils, tables]

import ./types
import ./registry
import ./slashargs

proc addCommand(handler: InteractionHandler, kind: CommandKind, name, description: string,
                callback: CommandHandlerProc, guildId = "", optionName = "") =
  ## Internal helper — builds a `RegisteredCommand` and delegates to
  ## `registry.register`.  All public ``add*`` helpers ultimately call
  ## this proc.
  handler.registry.register RegisteredCommand(
    kind: kind,
    name: name,
    optionName: optionName,
    description: description,
    guildId: guildId,
    callback: callback
  )

proc normalizeOptionNameLocal(name: string): string =
  name.toLowerAscii().replace("_", "")

proc registerSlashOptionNames*(handler: InteractionHandler, commandName: string,
                               optionNames: openArray[string]) =
  ## Stores the known slash option parameter names for `commandName`.
  ##
  ## Called automatically by `addSlash` after parsing the do-block formals.
  ## The stored names are used by `addAutocompleteForOption` to validate
  ## that the option being linked actually exists in the slash definition.
  ##
  ## Names are normalised (lower-cased, underscores removed) before storage.
  let key = commandName.toLowerAscii()
  var normalized: seq[string] = @[]
  for item in optionNames:
    let option = normalizeOptionNameLocal(item)
    if option.len == 0:
      continue
    if option notin normalized:
      normalized.add option
  handler.slashOptionNames[key] = normalized

proc slashOptionNames*(handler: InteractionHandler, commandName: string): seq[string] =
  ## Returns the normalised option names registered for `commandName`.
  ## Returns an empty seq when no names are recorded.
  let key = commandName.toLowerAscii()
  if handler.slashOptionNames.hasKey(key):
    return handler.slashOptionNames[key]
  @[]

proc hasSlashOption*(handler: InteractionHandler, commandName, optionName: string): bool =
  ## Returns ``true`` when `optionName` is a known parameter of
  ## `commandName`.  Both values are normalised before comparison.
  let key = commandName.toLowerAscii()
  if not handler.slashOptionNames.hasKey(key):
    return false
  let normalized = normalizeOptionNameLocal(optionName)
  normalized in handler.slashOptionNames[key]

proc addSlashProc*(handler: InteractionHandler, name, description: string,
                   callback: CommandHandlerProc, guildId = "") =
  ## Registers a slash command from an explicit `CommandHandlerProc`.
  ##
  ## You must supply a non-empty `description` (Discord rejects empty ones
  ## for slash commands).  For the ergonomic do-block syntax use the
  ## `addSlash` macro instead.
  ##
  ## .. code-block:: nim
  ##   handler.addSlashProc("ping", "Pong!",
  ##     proc (s: Shard, i: Interaction) {.async.} =
  ##       await handler.reply(i, "pong")
  ##   )
  if description.len == 0:
    raise newException(ValueError, "slash command description must not be empty")
  handler.addCommand(ckSlash, name, description, callback, guildId)

proc addUser*(handler: InteractionHandler, name: string,
              callback: CommandHandlerProc, guildId = "") =
  ## Registers a user context-menu command.
  ##
  ## User commands appear under **Apps > name** when right-clicking a user.
  ## No description is shown in the Discord UI for context-menu commands.
  ##
  ## See the template overload below for the do-block syntax.
  handler.addCommand(ckUser, name, "", callback, guildId)

template addUser*(handler: InteractionHandler, name: string,
                  body: untyped{nkStmtList}) =
  ## Registers a user context-menu command using a do-block.
  ##
  ## Inside the block, `s` (Shard) and `i` (Interaction) are implicitly
  ## available.
  ##
  ## .. code-block:: nim
  ##   handler.addUser("userinfo") do:
  ##     let user = i.member.get.user
  ##     await handler.reply(i, "User: " & user.username)
  handler.addUser(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

template addUser*(handler: InteractionHandler, name, guildId: string,
                  body: untyped{nkStmtList}) =
  ## Registers a guild-scoped user context-menu command using a do-block.
  ##
  ## .. code-block:: nim
  ##   handler.addUser("userinfo", "123456789") do:
  ##     await handler.reply(i, "guild-scoped user command")
  handler.addUser(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    guildId = guildId
  )

proc addMessage*(handler: InteractionHandler, name: string,
                 callback: CommandHandlerProc, guildId = "") =
  ## Registers a message context-menu command.
  ##
  ## Message commands appear under **Apps > name** when right-clicking a
  ## message.
  handler.addCommand(ckMessage, name, "", callback, guildId)

template addMessage*(handler: InteractionHandler, name: string,
                     body: untyped{nkStmtList}) =
  ## Registers a message context-menu command using a do-block.
  ##
  ## .. code-block:: nim
  ##   handler.addMessage("quote") do:
  ##     await handler.reply(i, "You quoted a message!")
  handler.addMessage(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

template addMessage*(handler: InteractionHandler, name, guildId: string,
                     body: untyped{nkStmtList}) =
  ## Registers a guild-scoped message context-menu command using a do-block.
  handler.addMessage(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    guildId = guildId
  )

proc isOptionType(n: NimNode): bool {.compileTime.} =
  n.kind == nnkBracketExpr and $n[0] == "Option"

proc isNamedType(n: NimNode, name: string): bool {.compileTime.} =
  case n.kind
  of nnkIdent, nnkSym:
    n.strVal == name
  else:
    false

macro addSlash*(handler: InteractionHandler, name, description: string,
                parameters: varargs[untyped]): untyped =
  ## Registers a slash command with automatic typed parameter extraction.
  ##
  ## This is the recommended way to add slash commands.  The macro inspects
  ## the `do` block's formal parameters and generates `requireSlashArg` /
  ## `getSlashArg` calls at compile time.
  ##
  ## **Supported parameter types:**
  ## - `string`, `int`, `bool`, `float` – required, extracted via `requireSlashArg`.
  ## - `User`, `Role` – resolved objects, also required.
  ## - `Option[T]` for any of the above – optional, extracted via `getSlashArg`.
  ## - `Interaction` – bound to the raw interaction object (no extraction).
  ## - `Shard` – bound to the gateway shard (no extraction).
  ##
  ## **Named parameters:**
  ## - `guildId = "..."` – restrict the command to a specific guild.
  ##
  ## Simple command (no typed params)
  ## --------------------------------
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("ping", "Replies with pong") do:
  ##     await handler.reply(i, "pong")
  ##
  ## Typed parameters
  ## ----------------
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("sum", "Adds two numbers") do (i: Interaction, a: int, b: int):
  ##     await handler.reply(i, "sum = " & $(a + b))
  ##
  ## Optional parameters
  ## -------------------
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("greet", "Greets someone") do (i: Interaction, name: Option[string]):
  ##     let who = if name.isSome: name.get else: "world"
  ##     await handler.reply(i, "Hello, " & who & "!")
  ##
  ## Guild-scoped command
  ## --------------------
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("admin", "Admin only", guildId = "123456789") do (i: Interaction):
  ##     await handler.reply(i, "admin only")
  runnableExamples "-r:off -d:ssl":
    import dimscord, asyncdispatch, options
    import dimslash

    let discord = newDiscordClient("TOKEN")
    var h = newInteractionHandler(discord)

    # Typed parameters:
    h.addSlash("sum", "Adds two numbers") do (i: Interaction, a: int, b: int):
      await h.reply(i, $(a + b))

    # Optional parameter:
    h.addSlash("greet", "Greets someone") do (i: Interaction, name: Option[string]):
      let who = if name.isSome: name.get else: "world"
      await h.reply(i, "Hello, " & who & "!")
  #==#
  var doNode: NimNode = nil
  var bareBody: NimNode = nil
  var guildId = newLit("")

  for arg in parameters:
    case arg.kind
    of nnkDo, nnkLambda:
      doNode = arg
    of nnkStmtList:
      bareBody = arg
    of nnkExprEqExpr:
      if $arg[0] == "guildId" or $arg[0] == "guildID":
        guildId = arg[1]
      else:
        error("Unknown named parameter: " & $arg[0], arg)
    else:
      error("Unknown addSlash parameter node kind: " & $arg.kind, arg)

  if doNode.isNil and bareBody.isNil:
    error("addSlash requires a do block")

  let formalParams = if doNode.isNil: newNimNode(nnkFormalParams) else: doNode[3]
  let body = if doNode.isNil: bareBody else: doNode[6]
  let shardIdent = genSym(nskParam, "s")
  let interactionIdent = genSym(nskParam, "i")
  var declaredNames: seq[string] = @[]
  var optionNamesNode = newNimNode(nnkBracket)

  var parseStmts = newStmtList()
  for paramIndex in 1..<formalParams.len:
    let def = formalParams[paramIndex]
    if def.kind != nnkIdentDefs:
      error("Unsupported parameter definition", def)
    let paramType = def[1]
    for j in 0..<(def.len - 2):
      let paramNameNode = def[j]
      let paramName = $paramNameNode
      declaredNames.add paramName
      let normalizedName = newLit(paramName.toLowerAscii().replace("_", ""))

      if isNamedType(paramType, "Interaction"):
        parseStmts.add quote do:
          let `paramNameNode` = `interactionIdent`
        continue

      if isNamedType(paramType, "Shard"):
        parseStmts.add quote do:
          let `paramNameNode` = `shardIdent`
        continue

      optionNamesNode.add newLit(paramName)

      if paramType.isOptionType():
        let innerType = paramType[1]
        parseStmts.add quote do:
          let `paramNameNode` = getSlashArg(`interactionIdent`, `normalizedName`, `innerType`)
      else:
        parseStmts.add quote do:
          let `paramNameNode` = requireSlashArg(`interactionIdent`, `normalizedName`, `paramType`)

  var aliasStmts = newStmtList()
  if "s" notin declaredNames:
    aliasStmts.add quote do:
      let s {.inject, used.} = `shardIdent`
  if "i" notin declaredNames:
    aliasStmts.add quote do:
      let i {.inject, used.} = `interactionIdent`

  let callback = quote do:
    proc (`shardIdent`: Shard, `interactionIdent`: Interaction) {.async, closure.} =
      `aliasStmts`
      `parseStmts`
      `body`

  result = quote do:
    addSlashProc(`handler`, `name`, `description`, `callback`, guildId = `guildId`)
    registerSlashOptionNames(`handler`, `name`, `optionNamesNode`)

proc addButton*(handler: InteractionHandler, customId: string,
                callback: CommandHandlerProc) =
  ## Registers a handler for a button component identified by `customId`.
  ##
  ## When a user clicks a button whose ``custom_id`` matches, dimslash
  ## routes the ``itMessageComponent`` interaction to this handler.
  ##
  ## **Tip:** if both a button and select handler share the same
  ## ``customId``, the dispatcher tries button first.  See the
  ## dispatch module docs for the full fallback logic.
  handler.addCommand(ckButton, customId, "", callback)

template addButton*(handler: InteractionHandler, customId: string,
                    body: untyped{nkStmtList}) =
  ## Registers a button handler using a do-block.
  ##
  ## ``s`` and ``i`` are injected automatically.
  ##
  ## .. code-block:: nim
  ##   handler.addButton("confirm:delete") do:
  ##     await handler.reply(i, "Deleted!")
  handler.addButton(customId,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

proc addSelect*(handler: InteractionHandler, customId: string,
                callback: CommandHandlerProc) =
  ## Registers a handler for a select-menu component identified by `customId`.
  ##
  ## Use `componentargs.selectValues` inside the handler to extract the
  ## user's selections.
  ##
  ## .. code-block:: nim
  ##   handler.addSelect("role_picker") do:
  ##     let values = i.selectValues
  ##     await handler.reply(i, "You picked: " & values.join(", "))
  handler.addCommand(ckSelect, customId, "", callback)

template addSelect*(handler: InteractionHandler, customId: string,
                    body: untyped{nkStmtList}) =
  ## Registers a select-menu handler using a do-block.
  handler.addSelect(customId,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

proc addModal*(handler: InteractionHandler, customId: string,
               callback: CommandHandlerProc) =
  ## Registers a handler for a modal submit identified by `customId`.
  ##
  ## When a user submits a modal whose ``custom_id`` matches, dimslash
  ## routes the ``itModalSubmit`` interaction here.  Use
  ## `componentargs.modalValues` / `componentargs.modalValue` inside
  ## the handler to extract submitted text inputs.
  ##
  ## .. code-block:: nim
  ##   handler.addModal("feedback_form") do:
  ##     let fields = i.modalValues
  ##     await handler.reply(i, "Thanks for your feedback!")
  handler.addCommand(ckModal, customId, "", callback)

template addModal*(handler: InteractionHandler, customId: string,
                   body: untyped{nkStmtList}) =
  ## Registers a modal-submit handler using a do-block.
  handler.addModal(customId,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

proc addAutocomplete*(handler: InteractionHandler, name: string,
                      callback: CommandHandlerProc, guildId = "", optionName = "") =
  ## Registers an autocomplete handler for the slash command `name`.
  ##
  ## - **Fallback handler** (``optionName`` is empty) — invoked whenever
  ##   the user types in *any* option of the given command and no
  ##   option-specific handler matches.
  ## - **Option-specific handler** (``optionName`` provided) — invoked
  ##   only when the focused option matches.
  ##
  ## Resolution order (see also `registry.findAutocomplete`):
  ## 1. Exact match on ``name + optionName``.
  ## 2. Fallback match on ``name`` alone.
  ## 3. ``hekNotFound`` error.
  handler.addCommand(ckAutocomplete, name, "", callback, guildId, optionName)

proc addAutocompleteForOption*(handler: InteractionHandler, name, optionName: string,
                               callback: CommandHandlerProc, guildId = "") =
  ## Registers an option-specific autocomplete handler with **validation**.
  ##
  ## Unlike ``addAutocomplete`` with an ``optionName`` argument, this proc
  ## verifies that ``optionName`` was declared in the ``addSlash`` do-block
  ## for ``name``.  If the option is unknown a ``ValueError`` is raised at
  ## registration time, catching typos early.
  ##
  ## .. code-block:: nim
  ##   # Register slash with typed params first:
  ##   handler.addSlash("search", "Search items") do (i: Interaction, query: string, category: string):
  ##     await handler.reply(i, "Searching...")
  ##
  ##   # Now add autocomplete for 'category':
  ##   handler.addAutocompleteForOption("search", "category") do:
  ##     await handler.suggest(i, @["books", "movies", "music"])
  if not handler.hasSlashOption(name, optionName):
    raise newException(ValueError,
      "unknown slash option for autocomplete link: " & name & "." & optionName)

  handler.addAutocomplete(name, callback, guildId = guildId, optionName = optionName)

template addAutocomplete*(handler: InteractionHandler, name: string,
                          body: untyped{nkStmtList}) =
  ## Registers a **fallback** autocomplete handler using a do-block.
  ##
  ## Use `focusedOptionName` and `focusedOptionValue` inside the block
  ## to inspect what the user is typing, then call `suggest` to reply.
  ##
  ## .. code-block:: nim
  ##   handler.addAutocomplete("search") do:
  ##     let partial = i.focusedOptionValue
  ##     await handler.suggest(i, @["apple", "banana", "cherry"])
  handler.addAutocomplete(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

template addAutocomplete*(handler: InteractionHandler, name, optionName: string,
                          body: untyped{nkStmtList}) =
  ## Registers an **option-scoped** autocomplete handler using a do-block.
  ##
  ## This handler is selected only when the focused option matches
  ## `optionName`.  Falls back to the generic autocomplete handler if
  ## no option-specific match is found.
  handler.addAutocomplete(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    optionName = optionName
  )

template addAutocompleteForOption*(handler: InteractionHandler, name, optionName: string,
                                   body: untyped{nkStmtList}) =
  ## Registers an option-scoped autocomplete handler with slash-option validation.
  handler.addAutocompleteForOption(name,
    optionName,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body
  )

template addAutocomplete*(handler: InteractionHandler, name, guildId: string,
                          body: untyped{nkStmtList}) =
  ## Guild-scoped fallback autocomplete handler variant.
  handler.addAutocomplete(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    guildId = guildId
  )

template addAutocomplete*(handler: InteractionHandler, name, optionName, guildId: string,
                          body: untyped{nkStmtList}) =
  ## Guild-scoped option-specific autocomplete handler variant.
  handler.addAutocomplete(name,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    guildId = guildId,
    optionName = optionName
  )

template addAutocompleteForOption*(handler: InteractionHandler, name, optionName, guildId: string,
                                   body: untyped{nkStmtList}) =
  ## Guild-scoped option-specific autocomplete handler with validation.
  handler.addAutocompleteForOption(name,
    optionName,
    proc (s {.inject.}: Shard, i {.inject.}: Interaction) {.async, closure.} =
      body,
    guildId = guildId
  )
