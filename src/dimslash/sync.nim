## Command synchronization with diffing.
##
## `syncCommands` groups registered commands by scope (global + each
## guild), fetches what Discord currently has, and only PUTs a scope when
## the payload actually differs — so restarting a bot no longer rewrites
## every command on every boot.
##
## dimslash builds the JSON itself (`toCommandJson`): dimscord 1.8.0's
## serializer silently drops `min_value`/`max_value`/`min_length`/
## `max_length`/`channel_types`.
##
## Comparison happens on a canonical form (`canonicalize`) that keeps a
## whitelist of writable fields, materializes Discord's defaults, and
## sorts commands — so server-added echo fields can never cause a
## spurious PUT.
##
## Caveat: only scopes that currently contain at least one registered
## command are synced. If you remove the *last* command of a guild (or
## global), clear that scope manually or with an empty bulk overwrite.

import std/[asyncdispatch, algorithm, json, options, tables]
import dimscord

import ./types

type
  SyncResult* = object
    scope*: string       ## "" = global, otherwise a guild id
    commandCount*: int
    updated*: bool       ## false = Discord already matched

# --- Payload generation ------------------------------------------------------

proc toJson(value: ChoiceValue): JsonNode =
  case value.kind
  of cvString: %value.strVal
  of cvInt: %value.intVal
  of cvFloat: %value.floatVal

proc toOptionJson*(spec: OptionSpec): JsonNode =
  result = %*{
    "type": int spec.kind,
    "name": spec.name,
    "description": spec.description,
    "required": spec.required
  }
  if spec.autocomplete:
    result["autocomplete"] = %true
  if spec.choices.len > 0:
    var choices = newJArray()
    for c in spec.choices:
      choices.add %*{"name": c.name, "value": c.value.toJson}
    result["choices"] = choices
  if spec.minValue.isSome:
    result["min_value"] =
      if spec.kind == acotInt: %int(spec.minValue.get)
      else: %spec.minValue.get
  if spec.maxValue.isSome:
    result["max_value"] =
      if spec.kind == acotInt: %int(spec.maxValue.get)
      else: %spec.maxValue.get
  if spec.minLen.isSome:
    result["min_length"] = %spec.minLen.get
  if spec.maxLen.isSome:
    result["max_length"] = %spec.maxLen.get
  if spec.channelTypes.len > 0:
    var kinds = newJArray()
    for kind in spec.channelTypes:
      kinds.add %int(kind)
    result["channel_types"] = kinds
  if spec.nameLoc.len > 0:
    result["name_localizations"] = %spec.nameLoc
  if spec.descLoc.len > 0:
    result["description_localizations"] = %spec.descLoc

proc toNodeJson(node: SlashNode): JsonNode =
  ## A group/sub node as a nested option (group = type 2, sub = type 1).
  case node.kind
  of snLeaf:
    result = %*{
      "type": int acotSubCommand,
      "name": node.name,
      "description": node.description
    }
    if node.options.len > 0:
      var options = newJArray()
      for spec in node.options:
        options.add toOptionJson(spec)
      result["options"] = options
  of snGroup:
    result = %*{
      "type": int acotSubCommandGroup,
      "name": node.name,
      "description": node.description
    }
    var children = newJArray()
    for _, child in node.children:
      children.add toNodeJson(child)
    result["options"] = children
  if node.nameLoc.len > 0:
    result["name_localizations"] = %node.nameLoc
  if node.descLoc.len > 0:
    result["description_localizations"] = %node.descLoc

proc applyMeta(target: JsonNode, meta: CommandMeta) =
  if meta.permissions.isSome:
    target["default_member_permissions"] = %($cast[int](meta.permissions.get))
  if meta.nsfw:
    target["nsfw"] = %true
  if meta.contexts.isSome:
    var contexts = newJArray()
    for context in InteractionContextType:
      if context in meta.contexts.get:
        contexts.add %int(context)
    target["contexts"] = contexts
  if meta.integrations.isSome:
    var integrations = newJArray()
    for integration in ApplicationIntegrationType:
      if integration in meta.integrations.get:
        integrations.add %int(integration)
    target["integration_types"] = integrations
  if meta.nameLoc.len > 0:
    target["name_localizations"] = %meta.nameLoc
  if meta.descLoc.len > 0:
    target["description_localizations"] = %meta.descLoc

proc toCommandJson*(cmd: SlashCommand): JsonNode =
  result = %*{
    "type": int atSlash,
    "name": cmd.root.name,
    "description": cmd.root.description
  }
  case cmd.root.kind
  of snLeaf:
    if cmd.root.options.len > 0:
      var options = newJArray()
      for spec in cmd.root.options:
        options.add toOptionJson(spec)
      result["options"] = options
  of snGroup:
    var options = newJArray()
    for _, child in cmd.root.children:
      options.add toNodeJson(child)
    result["options"] = options
  result.applyMeta(cmd.meta)

proc toCommandJson*(cmd: UserCommand): JsonNode =
  result = %*{"type": int atUser, "name": cmd.name}
  result.applyMeta(cmd.meta)

proc toCommandJson*(cmd: MessageCommand): JsonNode =
  result = %*{"type": int atMessage, "name": cmd.name}
  result.applyMeta(cmd.meta)

# --- Canonical form for comparison -------------------------------------------

proc canonicalizeOption(option: JsonNode): JsonNode =
  result = %*{
    "type": option{"type"}.getInt(1),
    "name": option{"name"}.getStr,
    "description": option{"description"}.getStr,
    "required": option{"required"}.getBool(false),
    "autocomplete": option{"autocomplete"}.getBool(false)
  }
  # numbers normalize to float: we may write 1 where Discord echoes 1.0
  for key in ["min_value", "max_value"]:
    let v = option{key}
    if v != nil and v.kind in {JInt, JFloat}:
      result[key] = %v.getFloat
  for key in ["min_length", "max_length"]:
    let v = option{key}
    if v != nil and v.kind == JInt:
      result[key] = v
  var choices = newJArray()
  for c in option{"choices"}.getElems:
    var value = c{"value"}
    if value != nil and value.kind in {JInt, JFloat}:
      value = %value.getFloat
    choices.add %*{"name": c{"name"}.getStr, "value": value}
  result["choices"] = choices
  var channelTypes: seq[int]
  for kind in option{"channel_types"}.getElems:
    channelTypes.add kind.getInt
  channelTypes.sort
  result["channel_types"] = %channelTypes
  for key in ["name_localizations", "description_localizations"]:
    let loc = option{key}
    if loc != nil and loc.kind == JObject and loc.len > 0:
      result[key] = loc
  var nested = newJArray()
  for child in option{"options"}.getElems:
    nested.add canonicalizeOption(child)
  result["options"] = nested

proc canonicalizeCommand(cmd: JsonNode): JsonNode =
  result = %*{
    "type": cmd{"type"}.getInt(1),
    "name": cmd{"name"}.getStr,
    "description": cmd{"description"}.getStr,
    "nsfw": cmd{"nsfw"}.getBool(false)
  }
  let perms = cmd{"default_member_permissions"}
  if perms != nil and perms.kind == JString:
    result["default_member_permissions"] = perms
  let contexts = cmd{"contexts"}
  if contexts != nil and contexts.kind == JArray:
    var values: seq[int]
    for c in contexts:
      values.add c.getInt
    values.sort
    result["contexts"] = %values
  # Discord defaults integration_types to [0] when unset
  var integrations: seq[int] = @[0]
  let rawIntegrations = cmd{"integration_types"}
  if rawIntegrations != nil and rawIntegrations.kind == JArray:
    integrations = @[]
    for i in rawIntegrations:
      integrations.add i.getInt
    integrations.sort
  result["integration_types"] = %integrations
  for key in ["name_localizations", "description_localizations"]:
    let loc = cmd{key}
    if loc != nil and loc.kind == JObject and loc.len > 0:
      result[key] = loc
  var options = newJArray()
  for option in cmd{"options"}.getElems:
    options.add canonicalizeOption(option)
  result["options"] = options

proc canonicalize*(commands: JsonNode): JsonNode =
  ## Reduces a command-array payload (ours or Discord's) to the comparable
  ## subset: writable fields only, defaults materialized, commands sorted
  ## by (type, name).
  var canonical: seq[JsonNode]
  for cmd in commands.getElems:
    canonical.add canonicalizeCommand(cmd)
  canonical.sort proc (a, b: JsonNode): int =
    result = cmp(a["type"].getInt, b["type"].getInt)
    if result == 0:
      result = cmp(a["name"].getStr, b["name"].getStr)
  result = newJArray()
  for cmd in canonical:
    result.add cmd

# --- Sync ---------------------------------------------------------------------

proc resolveApplicationId*(handler: InteractionHandler): Future[string]
    {.async.} =
  ## Explicitly set `handler.applicationId` beats asking Discord; the
  ## result is cached either way.
  if handler.applicationId.len == 0:
    handler.applicationId = await handler.rest.getApplicationId()
  result = handler.applicationId

proc payloadsByScope(handler: InteractionHandler): OrderedTable[string, JsonNode] =
  proc scopeOf(meta: CommandMeta): string =
    if meta.guildId.len > 0: meta.guildId else: handler.defaultGuildId
  template put(meta: CommandMeta, payload: JsonNode) =
    let scope = scopeOf(meta)
    if not result.hasKey(scope):
      result[scope] = newJArray()
    result[scope].add payload
  for _, cmd in handler.registry.slash:
    put cmd.meta, toCommandJson(cmd)
  for _, cmd in handler.registry.user:
    put cmd.meta, toCommandJson(cmd)
  for _, cmd in handler.registry.message:
    put cmd.meta, toCommandJson(cmd)

proc syncCommands*(handler: InteractionHandler,
                   force = false): Future[seq[SyncResult]] {.async.} =
  ## Pushes registered commands to Discord, per scope, skipping scopes
  ## whose commands already match. `force = true` always overwrites.
  ## Call once after startup (e.g. in the `onReady` event).
  let appId = await handler.resolveApplicationId()
  for scope, payload in handler.payloadsByScope:
    var needsUpdate = force
    if not needsUpdate:
      let current = await handler.rest.getCommands(appId, scope)
      needsUpdate = canonicalize(current) != canonicalize(payload)
    if needsUpdate:
      discard await handler.rest.putCommands(appId, scope, payload)
    result.add SyncResult(scope: scope, commandCount: payload.len,
                          updated: needsUpdate)
