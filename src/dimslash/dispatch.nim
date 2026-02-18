## Interaction dispatch — routes incoming Discord interactions to the
## correct registered handler.
##
## The single entry point is `handleInteraction`.  Call it from
## your `interactionCreate` event handler:
##
## .. code-block:: nim
##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
##     discard await handler.handleInteraction(s, i)
##
## Dispatch flow
## =============
##
## 1. Inspect `Interaction.kind` to determine the category.
## 2. **Application command** (`itApplicationCommand`) — extract the command
##    name and further refine by `atSlash` / `atUser` / `atMessage`.
## 3. **Message component** (`itMessageComponent`) — extract `custom_id`,
##    try button first, then select.
## 4. **Autocomplete** (`itAutoComplete`) — extract command name and
##    focused option, look up via `findAutocomplete`.
## 5. **Modal submit** (`itModalSubmit`) — extract `custom_id`.
## 6. **Ping** (`itPing`) — ignored (returns `false`).
##
## Error handling
## ==============
##
## `handleInteraction` propagates all errors as-is:
##
## - `HandlerError(hekInvalidInteraction)` when the payload is missing
##   required fields (command name or custom-id).
## - `HandlerError(hekNotFound)` when no handler is registered.
## - Any exception raised by your command callback itself.
##
## A typical pattern wraps the call in a try/except:
##
## .. code-block:: nim
##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
##     try:
##       discard await handler.handleInteraction(s, i)
##     except HandlerError as e:
##       echo "dispatch error: ", e.kind, " — ", e.msg

import std/[asyncdispatch, options]

import dimscord

import ./types
import ./registry
import ./slashargs

proc getCommandName(i: Interaction): Option[string] =
  ## Extracts the command name from an application-command interaction.
  ##
  ## Only returns a value when `i.data` is present **and**
  ## `interaction_type == idtApplicationCommand`.  For all other
  ## payloads (components, modals, pings …) the result is `none`.
  if i.data.isSome and i.data.get.interaction_type == idtApplicationCommand:
    return some(i.data.get.name)
  none(string)

proc getCustomId(i: Interaction): Option[string] =
  ## Extracts the ``custom_id`` string from a message-component or
  ## modal-submit interaction.
  ##
  ## The custom-id is the identifier you attached to the button,
  ## select menu, or modal when you sent it.  Returns `none` for
  ## application-command and ping interactions.
  if i.data.isSome and i.data.get.interaction_type in {idtMessageComponent, idtModalSubmit}:
    return some(i.data.get.custom_id)
  none(string)

proc handleInteraction*(handler: InteractionHandler, s: Shard, i: Interaction): Future[bool] {.async.} =
  ## Routes the incoming Discord interaction `i` to the matching registered
  ## handler and returns `true` on success.
  ##
  ## Returns `false` for interaction types that are silently ignored
  ## (`itPing`).
  ##
  ## Resolution per interaction kind
  ## -------------------------------
  ##
  ## - **itApplicationCommand** — extract command name, map ``atSlash`` /
  ##   ``atUser`` / ``atMessage`` to the corresponding ``CommandKind``,
  ##   then ``find(kind, name)``.
  ## - **itMessageComponent** — extract ``custom_id``, try
  ##   ``find(ckButton, id)`` first; on ``hekNotFound`` fall back to
  ##   ``find(ckSelect, id)``.
  ## - **itAutoComplete** — extract command name + focused option, call
  ##   ``findAutocomplete(name, option)``.
  ## - **itModalSubmit** — extract ``custom_id``, call
  ##   ``find(ckModal, id)``.
  ## - **itPing** — silently ignored (returns ``false``).
  ##
  ## **Component fallback behaviour**: When a `itMessageComponent`
  ## interaction arrives the dispatcher first tries `ckButton`.  If no
  ## button handler is registered it falls back to `ckSelect`.  This lets
  ## you use a single custom-id for a button *or* a select menu without
  ## worrying about component type.
  ##
  ## Raises
  ## ------
  ## - `HandlerError(hekInvalidInteraction)` — the payload is missing
  ##   required fields (command name or custom-id).
  ## - `HandlerError(hekNotFound)` — no handler is registered for the
  ##   command / custom-id.
  ##
  ## Example
  ## -------
  ## .. code-block:: nim
  ##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  ##     try:
  ##       discard await handler.handleInteraction(s, i)
  ##     except HandlerError as e:
  ##       echo "handler error: ", e.msg
  case i.kind
  of itApplicationCommand:
    let commandName = i.getCommandName()
    if commandName.isNone:
      raise newInvalidInteractionError("application command interaction has no command name")

    let commandKind =
      if i.data.isSome and i.data.get.interaction_type == idtApplicationCommand:
        case i.data.get.kind
        of atSlash: ckSlash
        of atUser: ckUser
        of atMessage: ckMessage
        of atNothing, atPrimaryEntryPoint: ckSlash
      else:
        ckSlash

    let command = handler.registry.find(commandKind, commandName.get)
    await command.callback(s, i)
    return true

  of itMessageComponent:
    let customId = i.getCustomId()
    if customId.isNone:
      raise newInvalidInteractionError("message component interaction has no custom id")

    var command: RegisteredCommand
    try:
      command = handler.registry.find(ckButton, customId.get)
    except HandlerError as err:
      if err.kind == hekNotFound:
        command = handler.registry.find(ckSelect, customId.get)
      else:
        raise

    await command.callback(s, i)
    return true

  of itAutoComplete:
    let commandName = i.getCommandName()
    if commandName.isNone:
      raise newInvalidInteractionError("autocomplete interaction has no command name")

    let focused = i.focusedOptionName().get("")
    let command = handler.registry.findAutocomplete(commandName.get, focused)
    await command.callback(s, i)
    return true

  of itModalSubmit:
    let customId = i.getCustomId()
    if customId.isNone:
      raise newInvalidInteractionError("modal submit interaction has no custom id")
    let command = handler.registry.find(ckModal, customId.get)
    await command.callback(s, i)
    return true

  of itPing:
    return false
