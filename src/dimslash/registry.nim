## Command registration and lookup.
##
## The DSL macros in `dsl` expand to calls into this module; the procs are
## public so commands can also be registered programmatically.

import std/[algorithm, options, tables]

import ./types, ./extract

proc addSlashCommand*(handler: InteractionHandler, cmd: SlashCommand) =
  let name = cmd.root.name
  if handler.registry.slash.hasKey(name):
    raise newException(DimslashError, "duplicate slash command: " & name)
  handler.registry.slash[name] = cmd

proc addUserCommand*(handler: InteractionHandler, cmd: UserCommand) =
  if handler.registry.user.hasKey(cmd.name):
    raise newException(DimslashError, "duplicate user command: " & cmd.name)
  handler.registry.user[cmd.name] = cmd

proc addMessageCommand*(handler: InteractionHandler, cmd: MessageCommand) =
  if handler.registry.message.hasKey(cmd.name):
    raise newException(DimslashError, "duplicate message command: " & cmd.name)
  handler.registry.message[cmd.name] = cmd

proc add[H](table: var ComponentTable[H], customId: string, run: H,
            what: string) =
  let pattern = parseCustomIdPattern(customId)
  if not pattern.hasCaptures:
    if table.exact.hasKey(customId):
      raise newException(DimslashError, "duplicate " & what & ": " & customId)
    table.exact[customId] = run
  else:
    for entry in table.patterns:
      if entry.pattern.raw == customId:
        raise newException(DimslashError, "duplicate " & what & ": " & customId)
    table.patterns.add ComponentEntry[H](pattern: pattern, handler: run)
    # longest literal prefix wins; sort is stable so ties keep insert order
    table.patterns.sort(
      proc (a, b: ComponentEntry[H]): int =
        b.pattern.literalPrefixLen - a.pattern.literalPrefixLen)

proc addButtonHandler*(handler: InteractionHandler, customId: string,
                       run: ComponentRun) =
  handler.registry.buttons.add(customId, run, "button handler")

proc addSelectHandler*(handler: InteractionHandler, customId: string,
                       run: ComponentRun) =
  handler.registry.selects.add(customId, run, "select handler")

proc addModalHandler*(handler: InteractionHandler, customId: string,
                      run: ModalRun) =
  handler.registry.modals.add(customId, run, "modal handler")

proc lookup*[H](table: ComponentTable[H], customId: string):
    Option[tuple[handler: H, captures: Table[string, string]]] =
  ## Exact custom_id match first, then patterns in priority order.
  if table.exact.hasKey(customId):
    return some (table.exact[customId], initTable[string, string]())
  for entry in table.patterns:
    let m = matchCustomId(entry.pattern, customId)
    if m.isSome:
      return some (entry.handler, m.get)

proc resolveLeaf*(cmd: SlashCommand, path: seq[string]): Option[SlashNode] =
  ## Follows a group/subcommand path (as produced by `extract.leafOptions`)
  ## down the command tree to the leaf that should run.
  var node = cmd.root
  for name in path:
    if node.kind != snGroup or not node.children.hasKey(name):
      return none SlashNode
    node = node.children[name]
  if node.kind == snLeaf:
    return some node
