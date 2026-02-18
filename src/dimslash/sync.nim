## Command synchronisation — bulk-overwrites registered commands to Discord.
##
## After all commands have been added with the DSL helpers, call
## `registerCommands` once (usually in the `onReady` event) to push
## the command payload to Discord so slash commands appear in the UI.
##
## .. code-block:: nim
##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
##     await handler.registerCommands()   # uses defaultGuildId
##
## Which commands are synced?
## ===========================
##
## Only **application commands** (slash, user, message) are pushed to the
## API.  Buttons, select menus, modals, and autocomplete handlers are
## purely local and are *not* part of the sync payload.
##
## ==================  =========  ===========================
## Command kind        Synced?    Notes
## ==================  =========  ===========================
## ``ckSlash``         Yes        Name + description + options
## ``ckUser``          Yes        Name only (context menu)
## ``ckMessage``       Yes        Name only (context menu)
## ``ckButton``        No         Local dispatch only
## ``ckSelect``        No         Local dispatch only
## ``ckModal``         No         Local dispatch only
## ``ckAutocomplete``  No         Local dispatch only
## ==================  =========  ===========================
##
## Propagation timing
## ==================
##
## - **Guild-scoped** commands update instantly (ideal for development).
## - **Global** commands may take **up to one hour** to propagate across
##   all Discord clients.
##
## Pass a `guildId` during development and switch to an empty string
## (global) for production.

import std/[asyncdispatch, tables]

import dimscord

import ./types
import ./registry

proc toApplicationCommand(command: RegisteredCommand): ApplicationCommand =
  ## Converts a `RegisteredCommand` into the dimscord `ApplicationCommand`
  ## payload expected by the bulk-overwrite REST endpoint.
  ##
  ## Mapping:
  ## - ``ckSlash`` → ``atSlash`` with ``name`` + ``description``.
  ## - ``ckUser``  → ``atUser``  with ``name`` only (no description).
  ## - ``ckMessage`` → ``atMessage`` with ``name`` only.
  ## - Other kinds raise via ``ensureImplemented``.
  case command.kind
  of ckSlash:
    ApplicationCommand(
      name: command.name,
      description: command.description,
      kind: atSlash
    )
  of ckUser:
    ApplicationCommand(
      name: command.name,
      kind: atUser
    )
  of ckMessage:
    ApplicationCommand(
      name: command.name,
      kind: atMessage
    )
  else:
    command.kind.ensureImplemented()
    ApplicationCommand(name: command.name)

proc collectCommandsFor(handler: InteractionHandler, guildId: string): seq[ApplicationCommand] =
  ## Gathers all slash, user, and message commands that should be
  ## synchronised for `guildId`.
  ##
  ## Inclusion rules per command:
  ## - Command has **no** ``guildId`` (empty string) → included in every
  ##   sync call (global command).
  ## - Command's ``guildId`` matches the target → included.
  ## - Otherwise → skipped.
  ##
  ## Button, select, modal, and autocomplete handlers are **not** included
  ## because Discord does not register them via the application-commands
  ## endpoint.
  for _, cmd in handler.registry.pairs(ckSlash):
    if cmd.guildId.len == 0 or cmd.guildId == guildId:
      result.add cmd.toApplicationCommand()

  for _, cmd in handler.registry.pairs(ckUser):
    if cmd.guildId.len == 0 or cmd.guildId == guildId:
      result.add cmd.toApplicationCommand()

  for _, cmd in handler.registry.pairs(ckMessage):
    if cmd.guildId.len == 0 or cmd.guildId == guildId:
      result.add cmd.toApplicationCommand()

proc registerCommands*(handler: InteractionHandler, guildId = ""): Future[void] {.async.} =
  ## Bulk-overwrites all registered commands for one guild (or globally).
  ##
  ## This calls the Discord ``PUT /applications/{id}/guilds/{gid}/commands``
  ## endpoint, which replaces **all** existing commands for that scope with
  ## the supplied list.  Any previously synced command that is not in the
  ## current registry will be **removed** from Discord.
  ##
  ## Must be called **after** the gateway has connected and the shard's
  ## ``user.id`` is available — typically inside ``onReady``.
  ##
  ## Parameters
  ## ----------
  ## - `guildId` – target guild.  When empty, falls back to
  ##   ``handler.defaultGuildId``.  If both are empty the commands are
  ##   registered **globally**.
  ##
  ## Raises
  ## ------
  ## - ``ValueError`` when the shard user ID is not yet available
  ##   (gateway not connected).
  ##
  ## Example
  ## -------
  ## .. code-block:: nim
  ##   proc onReady(s: Shard, r: Ready) {.event(discord).} =
  ##     # Guild-scoped (instant update, great for development):
  ##     await handler.registerCommands(guildId = "123456789")
  ##
  ##     # Global (may take up to 1 hour to propagate):
  ##     await handler.registerCommands()
  let targetGuildId = if guildId.len == 0: handler.defaultGuildId else: guildId
  let payload = handler.collectCommandsFor(targetGuildId)
  if handler.discord.isNil or len(handler.discord.shards) == 0 or not handler.discord.shards.hasKey(0):
    raise newException(ValueError, "cannot register commands before shard user is available")

  let applicationId = handler.discord.shards[0].user.id
  if applicationId.len == 0:
    raise newException(ValueError, "cannot register commands before shard user id is available")

  discard await handler.discord.api.bulkOverwriteApplicationCommands(
    applicationId,
    payload,
    guild_id = targetGuildId
  )
