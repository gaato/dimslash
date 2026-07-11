## Awaitable interactions: suspend a handler until a matching button press,
## select choice, or modal submit arrives — or a timeout passes.
##
## .. code-block:: nim
##   handler.slash("quiz", "Answer a question"):
##     execute:
##       await ctx.reply("Pick one!", components = someButtons)
##       let press = await ctx.waitForButton("quiz:{answer}", timeout = 30)
##       if press.isSome:
##         await press.get.update("You picked " & press.get.captures["answer"])
##       else:
##         await ctx.followup("Time's up!", ephemeral = true)
##
## Waiters are checked *before* the registry, are one-shot (removed as soon
## as they fire), and match the same typed custom_id patterns as the
## `button`/`select`/`modal` blocks. Every `waitFor*` returns
## `Option[...Context]` — `none` on timeout — and responding to the returned
## context (`update`, `reply`, …) is the caller's job.
##
## The `ctx` variants only accept the user who invoked `ctx` by default;
## pass `user = ""` to accept anyone. Interaction tokens live 15 minutes,
## so keep timeouts comfortably below that.

import std/[asyncdispatch, options, tables]
import dimscord

import ./types, ./extract

proc invokerId*(i: Interaction): string =
  ## The id of the user who triggered the interaction ("" if absent).
  if i.member.isSome and i.member.get.user.id.len > 0:
    i.member.get.user.id
  elif i.user.isSome:
    i.user.get.id
  else:
    ""

proc scopedId*(ctx: InteractionContext, tag: string): string =
  ## A custom_id unique to this interaction — build throwaway components
  ## for `waitFor*` flows without colliding with registered handlers or
  ## other invocations of the same command.
  "ds:" & tag & ":" & ctx.interaction.id

# --- Matching (called by dispatch before the registry) -----------------------

proc matchAny(patterns: seq[CustomIdPattern],
              id: string): Option[Table[string, string]] =
  for pattern in patterns:
    let m = matchCustomId(pattern, id)
    if m.isSome:
      return m

proc tryCompleteComponentWaiter*(handler: InteractionHandler, s: Shard,
                                 i: Interaction): bool =
  ## Completes the first pending component waiter matching this
  ## interaction, if any. Used by `dispatch.handleInteraction`.
  let data = i.data.get
  for idx, waiter in handler.componentWaiters:
    if data.component_type notin waiter.kinds:
      continue
    if waiter.userId.len > 0 and i.invokerId != waiter.userId:
      continue
    if waiter.messageId.len > 0 and
        (i.message.isNone or i.message.get.id != waiter.messageId):
      continue
    let m = matchAny(waiter.patterns, data.custom_id)
    if m.isNone:
      continue
    let ctx = ComponentContext(handler: handler, shard: s, interaction: i,
                               captures: m.get)
    handler.componentWaiters.delete(idx)
    waiter.future.complete(ctx)
    return true

proc tryCompleteModalWaiter*(handler: InteractionHandler, s: Shard,
                             i: Interaction): bool =
  ## Modal-submit counterpart of `tryCompleteComponentWaiter`.
  let data = i.data.get
  for idx, waiter in handler.modalWaiters:
    if waiter.userId.len > 0 and i.invokerId != waiter.userId:
      continue
    let m = matchAny(waiter.patterns, data.custom_id)
    if m.isNone:
      continue
    let ctx = ModalContext(handler: handler, shard: s, interaction: i,
                           captures: m.get)
    handler.modalWaiters.delete(idx)
    waiter.future.complete(ctx)
    return true

# --- Waiting ------------------------------------------------------------------

proc parseAll(patterns: openArray[string]): seq[CustomIdPattern] =
  if patterns.len == 0:
    raise newException(DimslashError, "waitFor needs at least one pattern")
  for pattern in patterns:
    result.add parseCustomIdPattern(pattern)

proc awaitComponent(handler: InteractionHandler, waiter: ComponentWaiter,
                    timeoutMs: int): Future[Option[ComponentContext]] {.async.} =
  if await withTimeout(waiter.future, timeoutMs):
    return some waiter.future.read
  if waiter.future.finished:
    # the event squeaked in between the timeout firing and us resuming
    return some waiter.future.read
  let idx = handler.componentWaiters.find(waiter)
  if idx >= 0:
    handler.componentWaiters.delete(idx)
  return none ComponentContext

proc awaitModal(handler: InteractionHandler, waiter: ModalWaiter,
                timeoutMs: int): Future[Option[ModalContext]] {.async.} =
  if await withTimeout(waiter.future, timeoutMs):
    return some waiter.future.read
  if waiter.future.finished:
    return some waiter.future.read
  let idx = handler.modalWaiters.find(waiter)
  if idx >= 0:
    handler.modalWaiters.delete(idx)
  return none ModalContext

proc waitForComponent*(handler: InteractionHandler,
    kinds: set[MessageComponentType], patterns: openArray[string];
    timeout = 60.0; user = ""; message = ""): Future[Option[ComponentContext]] =
  ## Waits for the next component interaction whose custom_id matches one
  ## of `patterns` (captures land in `ctx.captures`), optionally filtered
  ## by component kind, pressing user, and host message. `none` on timeout.
  let waiter = ComponentWaiter(kinds: kinds, patterns: parseAll(patterns),
                               userId: user, messageId: message,
                               future: newFuture[ComponentContext]("dimslash.waitForComponent"))
  handler.componentWaiters.add waiter
  handler.awaitComponent(waiter, int(timeout * 1000))

proc waitForButton*(handler: InteractionHandler, patterns: openArray[string];
    timeout = 60.0; user = ""; message = ""): Future[Option[ComponentContext]] =
  ## `waitForComponent` restricted to buttons.
  waitForComponent(handler, {mctButton}, patterns, timeout, user, message)

proc waitForButton*(handler: InteractionHandler, pattern: string;
    timeout = 60.0; user = ""; message = ""): Future[Option[ComponentContext]] =
  waitForComponent(handler, {mctButton}, [pattern], timeout, user, message)

proc waitForSelect*(handler: InteractionHandler, patterns: openArray[string];
    timeout = 60.0; user = ""; message = ""): Future[Option[ComponentContext]] =
  ## `waitForComponent` restricted to the select-menu kinds.
  waitForComponent(handler, SelectKinds, patterns, timeout, user, message)

proc waitForSelect*(handler: InteractionHandler, pattern: string;
    timeout = 60.0; user = ""; message = ""): Future[Option[ComponentContext]] =
  waitForComponent(handler, SelectKinds, [pattern], timeout, user, message)

proc waitForModal*(handler: InteractionHandler, patterns: openArray[string];
    timeout = 300.0; user = ""): Future[Option[ModalContext]] =
  ## Waits for the next matching modal submit. `none` on timeout (modals
  ## default to a longer window: the user is typing).
  let waiter = ModalWaiter(patterns: parseAll(patterns), userId: user,
                           future: newFuture[ModalContext]("dimslash.waitForModal"))
  handler.modalWaiters.add waiter
  handler.awaitModal(waiter, int(timeout * 1000))

proc waitForModal*(handler: InteractionHandler, pattern: string;
    timeout = 300.0; user = ""): Future[Option[ModalContext]] =
  waitForModal(handler, [pattern], timeout, user)

# --- ctx variants: filter to the invoking user by default ---------------------

proc waitForComponent*(ctx: InteractionContext,
    kinds: set[MessageComponentType], patterns: openArray[string];
    timeout = 60.0; user = invokerId(ctx.interaction);
    message = ""): Future[Option[ComponentContext]] =
  waitForComponent(ctx.handler, kinds, patterns, timeout, user, message)

proc waitForButton*(ctx: InteractionContext, patterns: openArray[string];
    timeout = 60.0; user = invokerId(ctx.interaction);
    message = ""): Future[Option[ComponentContext]] =
  waitForComponent(ctx.handler, {mctButton}, patterns, timeout, user, message)

proc waitForButton*(ctx: InteractionContext, pattern: string;
    timeout = 60.0; user = invokerId(ctx.interaction);
    message = ""): Future[Option[ComponentContext]] =
  waitForComponent(ctx.handler, {mctButton}, [pattern], timeout, user, message)

proc waitForSelect*(ctx: InteractionContext, patterns: openArray[string];
    timeout = 60.0; user = invokerId(ctx.interaction);
    message = ""): Future[Option[ComponentContext]] =
  waitForComponent(ctx.handler, SelectKinds, patterns, timeout, user, message)

proc waitForSelect*(ctx: InteractionContext, pattern: string;
    timeout = 60.0; user = invokerId(ctx.interaction);
    message = ""): Future[Option[ComponentContext]] =
  waitForComponent(ctx.handler, SelectKinds, [pattern], timeout, user, message)

proc waitForModal*(ctx: InteractionContext, patterns: openArray[string];
    timeout = 300.0;
    user = invokerId(ctx.interaction)): Future[Option[ModalContext]] =
  waitForModal(ctx.handler, patterns, timeout, user)

proc waitForModal*(ctx: InteractionContext, pattern: string;
    timeout = 300.0;
    user = invokerId(ctx.interaction)): Future[Option[ModalContext]] =
  waitForModal(ctx.handler, [pattern], timeout, user)
