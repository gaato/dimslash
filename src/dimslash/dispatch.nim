## Routes incoming interactions to registered handlers.
##
## Call `handleInteraction` from your `interactionCreate` event:
##
## .. code-block:: nim
##   proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
##     discard await handler.handleInteraction(s, i)
##
## Routing is data-driven: components are told apart by
## `data.component_type` (buttons vs the five select kinds), slash
## subcommands descend the interaction payload and the registered command
## tree in lockstep, and autocomplete resolves the same way before picking
## the focused option's handler.
##
## Exceptions raised by user handlers go to `handler.onError`; interactions
## with no registered handler go to `handler.onUnknown` (if set) and make
## `handleInteraction` return `false`.

import std/[asyncdispatch, options, tables]
import dimscord

import ./types, ./extract, ./registry, ./wait

proc invoke[T](handler: InteractionHandler, ctx: T,
               run: proc (ctx: T): Future[void]): Future[void] {.async.} =
  # `yield` waits without propagating: catching with try/except around an
  # await poisons later awaits in the same async proc (the iterator
  # re-raises the in-flight exception when it resumes)
  let fut = run(ctx)
  yield fut
  if fut.failed:
    if handler.onError.isNil:
      raise fut.error
    await handler.onError(ctx, fut.error)

proc unknown(handler: InteractionHandler, s: Shard,
             i: Interaction): Future[bool] {.async.} =
  if not handler.onUnknown.isNil:
    await handler.onUnknown(
      InteractionContext(handler: handler, shard: s, interaction: i))
  return false

proc handleInteraction*(handler: InteractionHandler, s: Shard,
                        i: Interaction): Future[bool] {.async.} =
  ## Returns `true` when a registered handler ran, `false` for pings and
  ## unhandled interactions.
  if i.data.isNone:
    return false
  let data = i.data.get

  case i.kind
  of itApplicationCommand:
    if data.interaction_type != idtApplicationCommand:
      return await handler.unknown(s, i)
    case data.kind
    of atSlash:
      if not handler.registry.slash.hasKey(data.name):
        return await handler.unknown(s, i)
      let cmd = handler.registry.slash[data.name]
      let (path, options) = leafOptions(data)
      let leaf = resolveLeaf(cmd, path)
      if leaf.isNone or leaf.get.run.isNil:
        return await handler.unknown(s, i)
      let ctx = SlashContext(handler: handler, shard: s, interaction: i,
                             path: path, options: options)
      await handler.invoke(ctx, leaf.get.run)
      return true
    of atUser:
      if not handler.registry.user.hasKey(data.name):
        return await handler.unknown(s, i)
      let ctx = UserContext(handler: handler, shard: s, interaction: i)
      await handler.invoke(ctx, handler.registry.user[data.name].run)
      return true
    of atMessage:
      if not handler.registry.message.hasKey(data.name):
        return await handler.unknown(s, i)
      let ctx = MessageContext(handler: handler, shard: s, interaction: i)
      await handler.invoke(ctx, handler.registry.message[data.name].run)
      return true
    else:
      return await handler.unknown(s, i)

  of itMessageComponent:
    if data.interaction_type != idtMessageComponent:
      return await handler.unknown(s, i)
    if data.component_type != mctButton and
        data.component_type notin SelectKinds:
      return await handler.unknown(s, i)
    if handler.tryCompleteComponentWaiter(s, i):
      return true
    let found =
      if data.component_type == mctButton:
        handler.registry.buttons.lookup(data.custom_id)
      else:
        handler.registry.selects.lookup(data.custom_id)
    if found.isNone:
      return await handler.unknown(s, i)
    let ctx = ComponentContext(handler: handler, shard: s, interaction: i,
                               captures: found.get.captures)
    await handler.invoke(ctx, found.get.handler)
    return true

  of itModalSubmit:
    if data.interaction_type != idtModalSubmit:
      return await handler.unknown(s, i)
    if handler.tryCompleteModalWaiter(s, i):
      return true
    let found = handler.registry.modals.lookup(data.custom_id)
    if found.isNone:
      return await handler.unknown(s, i)
    let ctx = ModalContext(handler: handler, shard: s, interaction: i,
                           captures: found.get.captures)
    await handler.invoke(ctx, found.get.handler)
    return true

  of itAutoComplete:
    if data.interaction_type != idtApplicationCommand or
        not handler.registry.slash.hasKey(data.name):
      return await handler.unknown(s, i)
    let cmd = handler.registry.slash[data.name]
    let (path, options) = leafOptions(data)
    let leaf = resolveLeaf(cmd, path)
    if leaf.isNone:
      return await handler.unknown(s, i)
    let focused = focusedOption(options)
    let focusedName = if focused.isSome: focused.get.name else: ""
    var run: AutocompleteRun
    if leaf.get.autocompleters.hasKey(focusedName):
      run = leaf.get.autocompleters[focusedName]
    elif leaf.get.autocompleters.hasKey(""):
      run = leaf.get.autocompleters[""]
    else:
      return await handler.unknown(s, i)
    let ctx = AutocompleteContext(handler: handler, shard: s, interaction: i,
                                  path: path, options: options,
                                  focusedName: focusedName)
    await handler.invoke(ctx, run)
    return true

  else:
    return false
