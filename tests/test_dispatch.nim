import std/[asyncdispatch, tables, unittest]
import dimscord

import ../src/dimslash/[types, registry, dispatch]
import ./helpers

proc leaf(name: string, run: SlashRun,
          autocompleters: openArray[(string, AutocompleteRun)] = []):
    SlashNode =
  result = SlashNode(kind: snLeaf, name: name, description: name, run: run)
  for (optName, ac) in autocompleters:
    result.autocompleters[optName] = ac

proc group(name: string, children: varargs[SlashNode]): SlashNode =
  result = SlashNode(kind: snGroup, name: name, description: name)
  for child in children:
    result.children[child.name] = child

proc slashCmd(root: SlashNode): SlashCommand =
  SlashCommand(root: root)

suite "slash dispatch":
  test "flat command runs with its options":
    let handler = newTestHandler(newRecorder())
    var gotContent = ""
    handler.addSlashCommand slashCmd(leaf("echo",
      proc (ctx: SlashContext) {.async.} =
        gotContent = ctx.options["text"].str))
    let handled = waitFor handler.handleInteraction(nil,
      mkSlashInteraction("echo", toOpts(strOpt("text", "hi"))))
    check handled
    check gotContent == "hi"

  test "group and subcommand route to the right leaf":
    let handler = newTestHandler(newRecorder())
    var ran: seq[string]
    handler.addSlashCommand slashCmd(
      group("admin",
        group("user",
          leaf("ban", proc (ctx: SlashContext) {.async.} =
            ran.add "ban:" & ctx.options["reason"].str
            check ctx.path == @["user", "ban"]),
          leaf("kick", proc (ctx: SlashContext) {.async.} =
            ran.add "kick")),
        leaf("audit", proc (ctx: SlashContext) {.async.} =
          ran.add "audit")))
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("admin",
      toOpts(subOpt("user",
        toOpts(subOpt("ban", toOpts(strOpt("reason", "spam")))),
        group = true))))
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("admin",
      toOpts(subOpt("audit",
        initTable[string, ApplicationCommandInteractionDataOption]()))))
    check ran == @["ban:spam", "audit"]

  test "unknown command returns false and fires onUnknown":
    let handler = newTestHandler(newRecorder())
    var sawUnknown = false
    handler.onUnknown = proc (ctx: InteractionContext) {.async.} =
      sawUnknown = true
    let handled = waitFor handler.handleInteraction(nil,
      mkSlashInteraction("nope",
        initTable[string, ApplicationCommandInteractionDataOption]()))
    check not handled
    check sawUnknown

  test "handler exception goes to onError":
    let handler = newTestHandler(newRecorder())
    var caught = ""
    handler.onError = proc (ctx: InteractionContext,
                            e: ref Exception) {.async.} =
      caught = e.msg
    handler.addSlashCommand slashCmd(leaf("boom",
      proc (ctx: SlashContext) {.async.} =
        raise newException(ValueError, "kaboom")))
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("boom",
      initTable[string, ApplicationCommandInteractionDataOption]()))
    check caught == "kaboom"

  test "nil onError re-raises":
    let handler = newTestHandler(newRecorder())
    handler.onError = nil
    handler.addSlashCommand slashCmd(leaf("boom",
      proc (ctx: SlashContext) {.async.} =
        raise newException(ValueError, "kaboom")))
    expect ValueError:
      discard waitFor handler.handleInteraction(nil,
        mkSlashInteraction("boom",
          initTable[string, ApplicationCommandInteractionDataOption]()))

suite "context-menu dispatch":
  test "user and message commands":
    let handler = newTestHandler(newRecorder())
    var ran: seq[string]
    handler.addUserCommand UserCommand(name: "Profile",
      run: proc (ctx: UserContext) {.async.} = ran.add "user")
    handler.addMessageCommand MessageCommand(name: "Quote",
      run: proc (ctx: MessageContext) {.async.} = ran.add "message")
    check waitFor handler.handleInteraction(nil,
      mkUserCommandInteraction("Profile", "u1", emptyResolved()))
    check waitFor handler.handleInteraction(nil,
      mkMessageCommandInteraction("Quote", "m1", emptyResolved()))
    check ran == @["user", "message"]

suite "component dispatch":
  test "button and select with the same custom_id are distinct":
    let handler = newTestHandler(newRecorder())
    var ran: seq[string]
    handler.addButtonHandler("pick",
      proc (ctx: ComponentContext) {.async.} = ran.add "button")
    handler.addSelectHandler("pick",
      proc (ctx: ComponentContext) {.async.} = ran.add "select")
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("pick", mctButton))
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("pick", mctSelectMenu, @["a"]))
    check ran == @["button", "select"]

  test "pattern captures reach the context":
    let handler = newTestHandler(newRecorder())
    var got: Table[string, string]
    handler.addButtonHandler("page:{n:int}",
      proc (ctx: ComponentContext) {.async.} = got = ctx.captures)
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("page:7"))
    check got["n"] == "7"

  test "exact match beats pattern; longer prefix beats shorter":
    let handler = newTestHandler(newRecorder())
    var ran: seq[string]
    handler.addButtonHandler("todo:{rest}",
      proc (ctx: ComponentContext) {.async.} = ran.add "short")
    handler.addButtonHandler("todo:done:{id}",
      proc (ctx: ComponentContext) {.async.} = ran.add "long")
    handler.addButtonHandler("todo:done:special",
      proc (ctx: ComponentContext) {.async.} = ran.add "exact")
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("todo:done:special"))
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("todo:done:31"))
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("todo:open:31"))
    check ran == @["exact", "long", "short"]

  test "non-matching int pattern falls through to unknown":
    let handler = newTestHandler(newRecorder())
    handler.addButtonHandler("page:{n:int}",
      proc (ctx: ComponentContext) {.async.} = discard)
    check not waitFor handler.handleInteraction(nil,
      mkComponentInteraction("page:abc"))

suite "modal dispatch":
  test "modal routes by custom_id with captures":
    let handler = newTestHandler(newRecorder())
    var topic = ""
    handler.addModalHandler("feedback:{topic}",
      proc (ctx: ModalContext) {.async.} = topic = ctx.captures["topic"])
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("feedback:bugs"))
    check topic == "bugs"

suite "autocomplete dispatch":
  test "option-specific handler wins over fallback":
    let handler = newTestHandler(newRecorder())
    var ran: seq[string]
    handler.addSlashCommand slashCmd(leaf("search",
      proc (ctx: SlashContext) {.async.} = discard,
      {"query": AutocompleteRun(proc (ctx: AutocompleteContext) {.async.} =
         ran.add "query:" & ctx.focusedName),
       "": AutocompleteRun(proc (ctx: AutocompleteContext) {.async.} =
         ran.add "fallback:" & ctx.focusedName)}))
    check waitFor handler.handleInteraction(nil,
      mkAutocompleteInteraction("search",
        toOpts(strOpt("query", "he", focused = true))))
    check waitFor handler.handleInteraction(nil,
      mkAutocompleteInteraction("search",
        toOpts(strOpt("other", "xx", focused = true))))
    check ran == @["query:query", "fallback:other"]

  test "autocomplete under a subcommand resolves the leaf":
    let handler = newTestHandler(newRecorder())
    var ran = false
    handler.addSlashCommand slashCmd(
      group("admin",
        leaf("ban", proc (ctx: SlashContext) {.async.} = discard,
          {"target": AutocompleteRun(
            proc (ctx: AutocompleteContext) {.async.} =
              ran = true
              check ctx.path == @["ban"])})))
    check waitFor handler.handleInteraction(nil,
      mkAutocompleteInteraction("admin",
        toOpts(subOpt("ban", toOpts(strOpt("target", "al", focused = true))))))
    check ran

  test "no autocompleter falls through to unknown":
    let handler = newTestHandler(newRecorder())
    handler.addSlashCommand slashCmd(leaf("plain",
      proc (ctx: SlashContext) {.async.} = discard))
    check not waitFor handler.handleInteraction(nil,
      mkAutocompleteInteraction("plain",
        toOpts(strOpt("x", "y", focused = true))))

suite "ping":
  test "ping returns false":
    let i = Interaction(id: "p", kind: itPing, token: "t")
    let handler = newTestHandler(newRecorder())
    check not waitFor handler.handleInteraction(nil, i)
