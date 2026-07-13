## Thin bot lifecycle convenience on top of dimscord.
##
## The high-level path removes the event-wiring boilerplate:
##
## .. code-block:: nim
##   let bot = newBot("TOKEN")
##   bot.slash("ping", "Replies with pong"):
##     execute:
##       await ctx.reply("pong")
##   waitFor bot.start()
##
## `install` is the escape hatch for advanced dimscord `startSession`
## settings. It chains callbacks already present on the client: dimslash
## handles registered interactions first, then forwards unknown ones to the
## previous `interaction_create` callback. On READY, command sync completes
## before the previous callback runs.

import std/asyncdispatch
import dimscord

import ./types, ./rest, ./dispatch, ./sync

type Bot* = InteractionHandler
  ## An ergonomic name for `InteractionHandler`; it is an alias, not a
  ## second wrapper object, so every existing dimslash API remains usable.

proc newBot*(token: string; defaultGuildId = ""; restVersion = 10): Bot =
  ## Creates the dimscord client and dimslash handler together.
  newInteractionHandler(
    newDiscordClient(token, restVersion = restVersion), defaultGuildId)

proc syncForReady(bot: Bot; force: bool): Future[void] {.async.} =
  discard await bot.syncCommands(force = force)

proc install*(bot: Bot; autoSync = true; forceSync = false) =
  ## Installs READY and INTERACTION_CREATE routing on the underlying client.
  ## Calling this more than once is a no-op; the first options win.
  ##
  ## `autoSync` performs one diff-aware sync for the whole process, shared by
  ## concurrent shard READY events and reconnects. If it fails, a later READY
  ## retries. Call this explicitly before dimscord's `startSession` when you
  ## need gateway/cache/sharding options not exposed by `start`.
  if bot.isNil:
    raise newException(DimslashError, "cannot install a nil bot")
  if bot.discord.isNil:
    raise newException(DimslashError,
      "bot has no DiscordClient; use newBot or newInteractionHandler(client)")
  if bot.lifecycleInstalled:
    return
  bot.lifecycleInstalled = true

  let previousReady = bot.discord.events.on_ready
  let previousInteraction = bot.discord.events.interaction_create

  bot.discord.events.on_ready = proc (shard: Shard,
                                      ready: Ready) {.async.} =
    var syncError: ref Exception
    if autoSync:
      if bot.readySync.isNil:
        bot.readySync = bot.syncForReady(forceSync)
      let pending = bot.readySync
      yield pending
      if pending.failed:
        if bot.readySync == pending:
          bot.readySync = nil
        syncError = pending.readError
    if not previousReady.isNil:
      await previousReady(shard, ready)
    if not syncError.isNil:
      raise syncError

  bot.discord.events.interaction_create = proc (shard: Shard,
                                                interaction: Interaction) {.async.} =
    let dispatched = bot.handleInteraction(shard, interaction)
    yield dispatched
    if dispatched.failed:
      discard dispatched.read
    elif not dispatched.read and not previousInteraction.isNil:
      await previousInteraction(shard, interaction)

proc start*(bot: Bot; gatewayIntents: set[GatewayIntent] = {giGuilds};
            contentIntent = false; autoSync = true;
            forceSync = false): Future[void] {.async.} =
  ## Installs dimslash and starts the dimscord gateway session.
  ## Slash-only bots default to `giGuilds` without the privileged message
  ## content intent. For advanced dimscord session options, call `install`
  ## and then `bot.discord.startSession(...)` directly.
  bot.install(autoSync, forceSync)
  await bot.discord.startSession(gateway_intents = gatewayIntents,
                                 content_intent = contentIntent)
