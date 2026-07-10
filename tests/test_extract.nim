import std/[unittest, options, tables]
import dimscord

import ../src/dimslash/[types, extract]
import ./helpers

suite "leaf options":
  test "flat command options pass through":
    let data = mkSlashData("sum", toOpts(intOpt("a", 1), intOpt("b", 2)))
    let (path, opts) = leafOptions(data)
    check path.len == 0
    check opts.len == 2
    check opts["a"].ival == 1

  test "subcommand is unwrapped":
    let data = mkSlashData("admin",
      toOpts(subOpt("ban", toOpts(strOpt("reason", "spam")))))
    let (path, opts) = leafOptions(data)
    check path == @["ban"]
    check opts["reason"].str == "spam"

  test "group + subcommand is unwrapped":
    let data = mkSlashData("admin",
      toOpts(subOpt("user", toOpts(subOpt("ban", toOpts(strOpt("reason", "spam")))), group = true)))
    let (path, opts) = leafOptions(data)
    check path == @["user", "ban"]
    check opts["reason"].str == "spam"

  test "leaf with no options yields empty table":
    let data = mkSlashData("admin", toOpts(subOpt("audit",
      initTable[string, ApplicationCommandInteractionDataOption]())))
    let (path, opts) = leafOptions(data)
    check path == @["audit"]
    check opts.len == 0

suite "typed option getters":
  proc mkCtx(opts: Table[string, ApplicationCommandInteractionDataOption],
             resolved = emptyResolved()): SlashContext =
    SlashContext(interaction: mkSlashInteraction("cmd", opts, resolved),
                 options: opts)

  test "scalar types":
    var opts = toOpts(
      strOpt("s", "hello"),
      intOpt("n", 42),
      ApplicationCommandInteractionDataOption(name: "f", kind: acotNumber, fval: 2.5),
      ApplicationCommandInteractionDataOption(name: "b", kind: acotBool, bval: true))
    let ctx = mkCtx(opts)
    check ctx.opt("s", string).get == "hello"
    check ctx.opt("n", int).get == 42
    check ctx.opt("f", float).get == 2.5
    check ctx.opt("b", bool).get == true
    check ctx.opt("missing", string).isNone
    check ctx.opt("n", string).isNone  # wrong type

  test "req raises on missing option":
    let ctx = mkCtx(initTable[string, ApplicationCommandInteractionDataOption]())
    expect DimslashError:
      discard ctx.req("nope", int)

  test "resolved user, member backfill, role":
    var resolved = emptyResolved()
    resolved.users["u1"] = User(id: "u1", username: "alice")
    resolved.members["u1"] = Member(nick: some "Ali")
    resolved.roles["r1"] = Role(id: "r1", name: "mods")
    let opts = toOpts(
      ApplicationCommandInteractionDataOption(name: "who", kind: acotUser, user_id: "u1"),
      ApplicationCommandInteractionDataOption(name: "role", kind: acotRole, role_id: "r1"))
    let ctx = mkCtx(opts, resolved)
    check ctx.opt("who", User).get.username == "alice"
    let m = ctx.opt("who", Member).get
    check m.nick.get == "Ali"
    check m.user.username == "alice"  # backfilled
    check ctx.opt("role", Role).get.name == "mods"

  test "resolved channel and attachment":
    var resolved = emptyResolved()
    resolved.channels["c1"] = ResolvedChannel(id: "c1", name: "general",
      kind: ctGuildText)
    resolved.attachments["a1"] = Attachment(id: "a1", filename: "cat.png")
    let opts = toOpts(
      ApplicationCommandInteractionDataOption(name: "ch", kind: acotChannel, channel_id: "c1"),
      ApplicationCommandInteractionDataOption(name: "file", kind: acotAttachment, aval: "a1"))
    let ctx = mkCtx(opts, resolved)
    check ctx.opt("ch", ResolvedChannel).get.name == "general"
    check ctx.opt("file", Attachment).get.filename == "cat.png"

  test "mentionable resolves user or role":
    var resolved = emptyResolved()
    resolved.users["u1"] = User(id: "u1", username: "alice")
    resolved.roles["r1"] = Role(id: "r1", name: "mods")
    let opts = toOpts(
      ApplicationCommandInteractionDataOption(name: "mu", kind: acotMentionable, mention_id: "u1"),
      ApplicationCommandInteractionDataOption(name: "mr", kind: acotMentionable, mention_id: "r1"))
    let ctx = mkCtx(opts, resolved)
    check ctx.opt("mu", Mentionable).get.kind == mkUser
    check ctx.opt("mu", Mentionable).get.user.username == "alice"
    check ctx.opt("mr", Mentionable).get.kind == mkRole
    check ctx.opt("mr", Mentionable).get.role.name == "mods"

suite "autocomplete extraction":
  test "focused option and string value":
    let opts = toOpts(strOpt("query", "hel", focused = true), intOpt("limit", 5))
    let focused = focusedOption(opts)
    check focused.get.name == "query"
    check focused.get.stringValue.get == "hel"
    check intOpt("limit", 5).stringValue.get == "5"

suite "context-menu targets":
  test "user command target with member backfill":
    var resolved = emptyResolved()
    resolved.users["u9"] = User(id: "u9", username: "bob")
    resolved.members["u9"] = Member(nick: some "Bobby")
    let data = ApplicationCommandInteractionData(
      resolved: resolved,
      interaction_type: idtApplicationCommand,
      id: "cmd-id", name: "Profile", kind: atUser, target_id: "u9")
    let i = baseInteraction(data)
    check i.targetUser.get.username == "bob"
    check i.targetMember.get.user.username == "bob"
    check i.targetMessage.isNone

  test "message command target":
    var resolved = emptyResolved()
    resolved.messages["m1"] = Message(id: "m1", content: "quoted text")
    let data = ApplicationCommandInteractionData(
      resolved: resolved,
      interaction_type: idtApplicationCommand,
      id: "cmd-id", name: "Quote", kind: atMessage, target_id: "m1")
    let i = baseInteraction(data)
    check i.targetMessage.get.content == "quoted text"
    check i.targetUser.isNone

suite "modal fields":
  test "collects text inputs through action rows and labels":
    let input = MessageComponent(kind: mctTextInput,
      custom_id: some "feedback", value: some "great")
    let nested = MessageComponent(kind: mctTextInput,
      custom_id: some "name", value: some "alice")
    let label = MessageComponent(kind: mctLabel, component: nested)
    let row = MessageComponent(kind: mctActionRow, components: @[input])
    let fields = modalFields(@[row, label])
    check fields["feedback"] == "great"
    check fields["name"] == "alice"
    check fields.len == 2

suite "custom_id patterns":
  test "exact pattern has no captures":
    let p = parseCustomIdPattern("confirm")
    check not p.hasCaptures
    check matchCustomId(p, "confirm").isSome
    check matchCustomId(p, "confirm2").isNone

  test "single capture":
    let p = parseCustomIdPattern("page:{n:int}")
    check p.hasCaptures
    check p.literalPrefixLen == 5
    let m = matchCustomId(p, "page:12")
    check m.get["n"] == "12"
    check matchCustomId(p, "page:abc").isNone   # int capture must parse
    check matchCustomId(p, "page:").isNone      # captures are non-empty
    check matchCustomId(p, "other:12").isNone

  test "negative int capture":
    let p = parseCustomIdPattern("vote:{delta:int}")
    check matchCustomId(p, "vote:-1").get["delta"] == "-1"

  test "multiple captures with separators":
    let p = parseCustomIdPattern("todo:{action}:{id:int}")
    let m = matchCustomId(p, "todo:done:31")
    check m.get["action"] == "done"
    check m.get["id"] == "31"
    check matchCustomId(p, "todo:done").isNone

  test "string capture in the middle is non-greedy":
    let p = parseCustomIdPattern("a:{x}:b")
    check matchCustomId(p, "a:hello:b").get["x"] == "hello"
    check matchCustomId(p, "a::b").isNone

  test "malformed patterns raise":
    expect DimslashError: discard parseCustomIdPattern("")
    expect DimslashError: discard parseCustomIdPattern("oops:{n")
    expect DimslashError: discard parseCustomIdPattern("oops:n}")
    expect DimslashError: discard parseCustomIdPattern("x:{a}{b}")
    expect DimslashError: discard parseCustomIdPattern("x:{1bad}")
    expect DimslashError: discard parseCustomIdPattern("x:{n:float}")

  test "patterns parse at compile time":
    const p = parseCustomIdPattern("page:{n:int}")
    check p.segments.len == 2
