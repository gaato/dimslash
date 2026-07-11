## The declarative command DSL — dimslash's primary API surface.
##
## .. code-block:: nim
##   handler.slash("roll", "Roll some dice"):
##     ## number of sides
##     sides {.min: 1, max: 1000.}: int = 6
##     ## how many dice
##     count: Option[int]
##     execute:
##       await ctx.reply($rollDice(sides, count.get(1)))
##
##   handler.slash("admin", "Admin tools"):
##     permissions = {permManageGuild}
##     group "user", "User management":
##       sub "ban", "Ban a user":
##         ## who to ban
##         target: User
##         execute:
##           await ctx.reply(target.username & " banned", ephemeral = true)
##
##   handler.button("page:{n:int}"):
##     await ctx.update("page " & $n)
##
## Inside a `slash` block:
##
## - `name: Type` declares an option; `Option[T]` makes it optional, a
##   default (`= 6`) makes it optional on Discord but non-Option in Nim.
##   The description comes from a `## doc` comment **on the preceding
##   line** (same-line doc comments don't survive parsing) or a
##   `{.desc: "…".}` pragma.
## - Per-option pragmas: `desc`, `name` (wire-name override), `min`/`max`
##   (int/float), `minLen`/`maxLen` (string), `choices` (string/int/float),
##   `channels` (Channel), `nameLoc`/`descLoc` (localization tables).
## - `key = value` lines configure the command: `guild`, `permissions`,
##   `nsfw`, `contexts`, `integrations`, `nameLocalizations`,
##   `descriptionLocalizations`, `cooldown` (seconds, or
##   `(seconds, cbUser|cbGuild|cbChannel|cbGlobal)`).
## - `check <cond>, "message"` or a `check:` block guards execution; a
##   failed check raises `UserError` (via `fail`), which the default
##   error hook sends to the user as an ephemeral reply. Checks and
##   cooldowns on a command/group also apply to every subcommand below
##   (a nested `cooldown` overrides the inherited one). `check` is a
##   reserved word inside these blocks — an option spelled "check" needs
##   a different Nim name plus a `{.name: "check".}` pragma.
## - `execute:` is the handler body; `ctx: SlashContext` and one variable
##   per declared option are in scope.
## - `group "name", "desc":` / `sub "name", "desc":` nest subcommands
##   (max depth: group → sub).
## - `autocomplete <option>:` attaches an autocomplete handler for one
##   option (compile-time checked); `autocomplete:` is the fallback for
##   the whole (sub)command. `ctx: AutocompleteContext` is in scope.
##
## Everything the macros can check is checked at compile time: Discord
## name rules, duplicate/misordered options, group depth, choices vs
## autocomplete conflicts, and unknown pragma keys.

import std/[macros, options, strutils, tables]
import dimscord

import ./types, ./registry, ./extract, ./context, ./dispatch

export types, registry, extract, context, dispatch

type
  OptClass = enum
    ocString, ocInt, ocFloat, ocBool, ocUser, ocMember, ocRole, ocChannel,
    ocMentionable, ocAttachment

  OptIR = ref object
    node: NimNode              # declaration site, for error positions
    nimName: NimNode           # ident bound in the execute body
    wireName: string
    class: OptClass
    optional: bool             # Option[T]
    default: NimNode           # nil if absent
    description: string
    minV, maxV: NimNode
    minLen, maxLen: NimNode
    choices: NimNode           # nnkTableConstr or nil
    channels: NimNode          # set literal or nil
    nameLoc, descLoc: NimNode  # table constructors or nil
    autocomplete: bool

  NodeIR = ref object
    node: NimNode
    name, description: string
    isGroup: bool
    options: seq[OptIR]
    executeBody: NimNode
    autocompleters: seq[tuple[optionName: string, body: NimNode,
                              site: NimNode]]
    children: seq[NodeIR]
    checks: seq[NimNode]       # run before execute; inherited by children
    cooldown: NimNode          # seconds or (seconds, bucket); nil if absent

  MetaIR = ref object
    guild, permissions, nsfw, contexts, integrations: NimNode
    nameLoc, descLoc: NimNode

const
  scalarClasses = {ocString, ocInt, ocFloat}
  numberClasses = {ocInt, ocFloat}

proc validateApiName(name: string, site: NimNode, what: string) =
  if name.len < 1 or name.len > 32:
    error(what & " name must be 1..32 characters: \"" & name & "\"", site)
  for c in name:
    if c in {'A'..'Z'}:
      error(what & " names must be lowercase (Discord requirement): \"" &
        name & "\"", site)
    if c in {' ', '/', '\\'}:
      error(what & " names must not contain '" & c & "': \"" & name & "\"",
        site)

proc validateDescription(desc: string, site: NimNode, what: string) =
  if desc.len < 1 or desc.len > 100:
    error(what & " description must be 1..100 characters", site)

proc classOf(t: NimNode): OptClass =
  if t.kind == nnkIdent:
    case $t
    of "string": return ocString
    of "int": return ocInt
    of "float": return ocFloat
    of "bool": return ocBool
    of "User": return ocUser
    of "Member": return ocMember
    of "Role": return ocRole
    of "Channel", "ResolvedChannel": return ocChannel
    of "Mentionable": return ocMentionable
    of "Attachment": return ocAttachment
    else: discard
  error("unsupported option type: " & t.repr &
    " (supported: string, int, float, bool, User, Member, Role, Channel, " &
    "Mentionable, Attachment, and Option[T] of those)", t)

proc acotOf(class: OptClass): NimNode =
  case class
  of ocString: bindSym"acotStr"
  of ocInt: bindSym"acotInt"
  of ocFloat: bindSym"acotNumber"
  of ocBool: bindSym"acotBool"
  of ocUser, ocMember: bindSym"acotUser"
  of ocRole: bindSym"acotRole"
  of ocChannel: bindSym"acotChannel"
  of ocMentionable: bindSym"acotMentionable"
  of ocAttachment: bindSym"acotAttachment"

proc extractTypeOf(class: OptClass): NimNode =
  # open idents on purpose: a bindSym'd type symbol fails to match the
  # generic typedesc parameters of `opt`/`req`
  case class
  of ocString: ident"string"
  of ocInt: ident"int"
  of ocFloat: ident"float"
  of ocBool: ident"bool"
  of ocUser: ident"User"
  of ocMember: ident"Member"
  of ocRole: ident"Role"
  of ocChannel: ident"ResolvedChannel"
  of ocMentionable: ident"Mentionable"
  of ocAttachment: ident"Attachment"

proc parseOptionPragmas(o: OptIR, pragma: NimNode) =
  for entry in pragma:
    if entry.kind != nnkExprColonExpr or entry[0].kind != nnkIdent:
      error("option pragmas take the form key: value", entry)
    let key = $entry[0]
    let value = entry[1]
    case key
    of "desc":
      value.expectKind nnkStrLit
      o.description = value.strVal
    of "name":
      value.expectKind nnkStrLit
      o.wireName = value.strVal
    of "min":
      if o.class notin numberClasses:
        error("min is only valid for int/float options", entry)
      o.minV = value
    of "max":
      if o.class notin numberClasses:
        error("max is only valid for int/float options", entry)
      o.maxV = value
    of "minLen":
      if o.class != ocString:
        error("minLen is only valid for string options", entry)
      o.minLen = value
    of "maxLen":
      if o.class != ocString:
        error("maxLen is only valid for string options", entry)
      o.maxLen = value
    of "choices":
      if o.class notin scalarClasses:
        error("choices are only valid for string/int/float options", entry)
      value.expectKind nnkTableConstr
      if value.len == 0 or value.len > 25:
        error("choices must have 1..25 entries", entry)
      o.choices = value
    of "channels":
      if o.class != ocChannel:
        error("channels is only valid for Channel options", entry)
      o.channels = value
    of "nameLoc":
      value.expectKind nnkTableConstr
      o.nameLoc = value
    of "descLoc":
      value.expectKind nnkTableConstr
      o.descLoc = value
    else:
      error("unknown option pragma: " & key & " (valid: desc, name, min, " &
        "max, minLen, maxLen, choices, channels, nameLoc, descLoc)", entry)

proc parseOptionDecl(stmt: NimNode, pendingDoc: string): OptIR =
  ## `name: Type`, `name: Type = default`, with an optional pragma list:
  ## Call(Ident|PragmaExpr, StmtList(TypeExpr | Asgn(TypeExpr, default)))
  result = OptIR(node: stmt, description: pendingDoc)
  var head = stmt[0]
  var pragma: NimNode = nil
  if head.kind == nnkPragmaExpr:
    pragma = head[1]
    head = head[0]
  head.expectKind nnkIdent
  result.nimName = head
  result.wireName = $head

  var typeExpr = stmt[1][0]
  if typeExpr.kind == nnkAsgn:
    result.default = typeExpr[1]
    typeExpr = typeExpr[0]
  if typeExpr.kind == nnkBracketExpr and typeExpr.len == 2 and
      typeExpr[0].kind == nnkIdent and $typeExpr[0] == "Option":
    if result.default != nil:
      error("an Option[T] option cannot also have a default; " &
        "use a plain type with a default instead", stmt)
    result.optional = true
    typeExpr = typeExpr[1]
  result.class = classOf(typeExpr)

  if pragma != nil:
    result.parseOptionPragmas(pragma)
  validateApiName(result.wireName, stmt, "option")
  if result.description.len == 0:
    warning("option \"" & result.wireName & "\" has no description " &
      "(add a ## doc comment on the line above or a desc pragma); " &
      "using the option name", stmt)
    result.description = result.wireName
  validateDescription(result.description, stmt, "option")

proc parseNodeBody(body: NimNode, ir: NodeIR, meta: MetaIR, isRoot: bool,
                   inGroup: bool)

proc parseGroupOrSub(stmt: NimNode, ir: NodeIR, isGroup: bool,
                     inGroup: bool) =
  let what = if isGroup: "group" else: "sub"
  if stmt.len != 4:
    error(what & " takes a name, a description, and a block: " &
      what & " \"name\", \"description\": ...", stmt)
  stmt[1].expectKind nnkStrLit
  stmt[2].expectKind nnkStrLit
  let child = NodeIR(node: stmt, name: stmt[1].strVal,
                     description: stmt[2].strVal, isGroup: isGroup)
  validateApiName(child.name, stmt, what)
  validateDescription(child.description, stmt, what)
  if isGroup and inGroup:
    error("groups cannot be nested inside groups (Discord allows " &
      "command → group → subcommand at most)", stmt)
  for existing in ir.children:
    if existing.name == child.name:
      error("duplicate " & what & " name: " & child.name, stmt)
  parseNodeBody(stmt[3], child, nil, isRoot = false, inGroup = isGroup)
  if not isGroup and child.executeBody == nil:
    error("sub \"" & child.name & "\" is missing an execute block", stmt)
  ir.children.add child

proc parseCheckCommand(stmt: NimNode): NimNode =
  ## `check <cond>[, "message"]` → `if not (<cond>): fail "message"`.
  if stmt.len notin {2, 3}:
    error("check takes a condition and an optional message: " &
      "check ctx.inGuild, \"guild only\"", stmt)
  let cond = stmt[1]
  let msg = if stmt.len == 3: stmt[2]
            else: newLit "You cannot use this command right now."
  nnkIfStmt.newTree(nnkElifBranch.newTree(
    nnkPrefix.newTree(ident"not", nnkPar.newTree(cond)),
    newCall(bindSym"fail", msg)))

proc parseSetting(stmt: NimNode, meta: MetaIR) =
  stmt[0].expectKind nnkIdent
  let value = stmt[1]
  case $stmt[0]
  of "guild": meta.guild = value
  of "permissions": meta.permissions = value
  of "nsfw": meta.nsfw = value
  of "contexts": meta.contexts = value
  of "integrations": meta.integrations = value
  of "nameLocalizations":
    value.expectKind nnkTableConstr
    meta.nameLoc = value
  of "descriptionLocalizations":
    value.expectKind nnkTableConstr
    meta.descLoc = value
  else:
    error("unknown command setting: " & $stmt[0] & " (valid: guild, " &
      "permissions, nsfw, contexts, integrations, nameLocalizations, " &
      "descriptionLocalizations, cooldown)", stmt)

proc parseNodeBody(body: NimNode, ir: NodeIR, meta: MetaIR, isRoot: bool,
                   inGroup: bool) =
  body.expectKind nnkStmtList
  var pendingDoc = ""
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      pendingDoc = stmt.strVal
      continue
    of nnkCall:
      if stmt[0].kind == nnkIdent and $stmt[0] == "execute":
        if inGroup:
          error("groups cannot have an execute block; put it in a sub",
            stmt)
        if ir.executeBody != nil:
          error("duplicate execute block", stmt)
        stmt[1].expectKind nnkStmtList
        ir.executeBody = stmt[1]
      elif stmt[0].kind == nnkIdent and $stmt[0] == "autocomplete":
        # `autocomplete:` — whole-command fallback
        stmt[1].expectKind nnkStmtList
        ir.autocompleters.add (optionName: "", body: stmt[1], site: stmt)
      elif stmt[0].kind == nnkIdent and $stmt[0] == "check" and
          stmt.len == 2 and stmt[1].kind == nnkStmtList:
        # `check:` block — runs before execute, inherited by subcommands.
        # ("check" is reserved; an option named check needs {.name.}.)
        ir.checks.add stmt[1]
      else:
        if inGroup:
          error("groups can only contain sub blocks", stmt)
        let opt = parseOptionDecl(stmt, pendingDoc)
        for existing in ir.options:
          if existing.wireName == opt.wireName:
            error("duplicate option name: " & opt.wireName, stmt)
        ir.options.add opt
    of nnkCommand:
      stmt[0].expectKind nnkIdent
      case $stmt[0]
      of "group":
        if not isRoot:
          error("group is only allowed at the top level of a slash block",
            stmt)
        parseGroupOrSub(stmt, ir, isGroup = true, inGroup = inGroup)
      of "sub":
        parseGroupOrSub(stmt, ir, isGroup = false, inGroup = inGroup)
      of "autocomplete":
        # `autocomplete <option>:` — option-scoped handler
        if stmt.len != 3 or stmt[1].kind != nnkIdent:
          error("autocomplete takes an option name: autocomplete query: ...",
            stmt)
        stmt[2].expectKind nnkStmtList
        ir.autocompleters.add (optionName: $stmt[1], body: stmt[2],
                               site: stmt)
      of "check":
        ir.checks.add parseCheckCommand(stmt)
      else:
        error("unexpected statement in " &
          (if isRoot: "slash" else: "sub") & " block: " & stmt.repr, stmt)
    of nnkAsgn:
      if stmt[0].kind == nnkIdent and $stmt[0] == "cooldown":
        # allowed at any level: groups pass it down, subs override
        if ir.cooldown != nil:
          error("duplicate cooldown setting", stmt)
        ir.cooldown = stmt[1]
      elif not isRoot:
        error("command settings (key = value) are only allowed at the " &
          "top level of a slash block (cooldown being the exception)", stmt)
      else:
        parseSetting(stmt, meta)
    else:
      error("unexpected statement in slash block: " & stmt.repr, stmt)
    pendingDoc = ""

proc validateNode(ir: NodeIR) =
  if ir.children.len > 0:
    if ir.options.len > 0 or ir.executeBody != nil:
      error("a command with subcommands cannot have its own options or " &
        "execute block", ir.node)
    if ir.autocompleters.len > 0:
      error("autocomplete blocks belong inside the sub they refer to",
        ir.autocompleters[0].site)
    if ir.children.len > 25:
      error("at most 25 subcommands/groups are allowed", ir.node)
    for child in ir.children:
      validateNode(child)
    return
  if ir.executeBody == nil:
    error("missing execute block", ir.node)
  if ir.options.len > 25:
    error("at most 25 options are allowed", ir.node)
  var seenOptional = false
  for opt in ir.options:
    let optionalOnWire = opt.optional or opt.default != nil
    if optionalOnWire:
      seenOptional = true
    elif seenOptional:
      error("required option \"" & opt.wireName & "\" must come before " &
        "all optional ones (Discord requirement)", opt.node)
  for (optionName, _, site) in ir.autocompleters:
    if optionName.len == 0:
      continue
    var found = false
    for opt in ir.options:
      if opt.wireName == optionName:
        if opt.class notin scalarClasses:
          error("autocomplete only works on string/int/float options", site)
        if opt.choices != nil:
          error("option \"" & optionName & "\" has choices; choices and " &
            "autocomplete are mutually exclusive", site)
        opt.autocomplete = true
        found = true
    if not found:
      error("autocomplete refers to unknown option \"" & optionName & "\"",
        site)

# --- Code generation ---------------------------------------------------------

proc genChoices(o: OptIR): NimNode =
  ## `{"label": value, ...}` → `@[choice("label", string(value)), ...]`
  ## (the conversion pins the value type to the option type).
  let conv = extractTypeOf(o.class)
  var bracket = newNimNode(nnkBracket)
  for entry in o.choices:
    entry.expectKind nnkExprColonExpr
    bracket.add newCall(bindSym"choice", entry[0],
                        newCall(conv, entry[1]))
  newCall(bindSym"@", bracket)

proc genOptionSpec(o: OptIR): tuple[stmts, specVar: NimNode] =
  let spec = genSym(nskVar, "spec")
  let (wire, desc) = (newLit o.wireName, newLit o.description)
  let kindE = acotOf(o.class)
  let required = newLit(not o.optional and o.default == nil)
  let ac = newLit o.autocomplete
  var stmts = newStmtList()
  stmts.add quote do:
    var `spec` = OptionSpec(name: `wire`, description: `desc`,
                            kind: `kindE`, required: `required`,
                            autocomplete: `ac`)
  if o.minV != nil:
    let v = o.minV
    stmts.add quote do:
      `spec`.minValue = some(float(`v`))
  if o.maxV != nil:
    let v = o.maxV
    stmts.add quote do:
      `spec`.maxValue = some(float(`v`))
  if o.minLen != nil:
    let v = o.minLen
    stmts.add quote do:
      `spec`.minLen = some(int(`v`))
  if o.maxLen != nil:
    let v = o.maxLen
    stmts.add quote do:
      `spec`.maxLen = some(int(`v`))
  if o.choices != nil:
    let choicesE = genChoices(o)
    stmts.add quote do:
      `spec`.choices = `choicesE`
  if o.channels != nil:
    let ch = o.channels
    stmts.add quote do:
      for channelType in `ch`:
        `spec`.channelTypes.add channelType
  if o.nameLoc != nil:
    let loc = o.nameLoc
    stmts.add quote do:
      `spec`.nameLoc = toTable(`loc`)
  if o.descLoc != nil:
    let loc = o.descLoc
    stmts.add quote do:
      `spec`.descLoc = toTable(`loc`)
  result = (stmts, spec)

proc genCooldown(path: string, spec: NimNode, ctxId: NimNode): NimNode =
  ## `cooldown = 5` / `cooldown = (5, cbGuild)` → a `checkCooldown` call.
  var (secondsE, bucketE) = (spec, bindSym"cbUser")
  if spec.kind == nnkTupleConstr:
    if spec.len != 2:
      error("cooldown takes seconds or (seconds, bucket)", spec)
    secondsE = spec[0]
    bucketE = spec[1]
  newCall(bindSym"checkCooldown", ctxId, newLit path,
          newCall(ident"float", secondsE), bucketE)

proc genRun(ir: NodeIR, checks: seq[NimNode], cooldown: NimNode,
            path: string): NimNode =
  ## The leaf's run closure: one `let` per option, then checks and the
  ## cooldown gate (in that order — a failed check must not eat a
  ## cooldown charge), then the user body.
  let ctxId = ident"ctx"
  let (optSym, reqSym) = (bindSym"opt", bindSym"req")
  var body = newStmtList()
  for o in ir.options:
    let (nimName, wire, typeE) = (o.nimName, newLit o.wireName,
                                  extractTypeOf(o.class))
    if o.default != nil:
      let default = o.default
      body.add quote do:
        let `nimName` = `optSym`(`ctxId`, `wire`, `typeE`).get(`default`)
    elif o.optional:
      body.add quote do:
        let `nimName` = `optSym`(`ctxId`, `wire`, `typeE`)
    else:
      body.add quote do:
        let `nimName` = `reqSym`(`ctxId`, `wire`, `typeE`)
  for chk in checks:
    body.add chk
  if cooldown != nil:
    body.add genCooldown(path, cooldown, ctxId)
  body.add ir.executeBody
  result = quote do:
    proc (`ctxId`: SlashContext): Future[void] {.async.} =
      `body`

proc genAutocompleter(body: NimNode): NimNode =
  let ctxId = ident"ctx"
  result = quote do:
    proc (`ctxId`: AutocompleteContext): Future[void] {.async.} =
      `body`

proc genNode(ir: NodeIR, inheritedChecks: seq[NimNode] = @[],
             inheritedCooldown: NimNode = nil,
             pathPrefix = ""): tuple[stmts, nodeVar: NimNode] =
  let node = genSym(nskVar, "node")
  let (name, desc) = (newLit ir.name, newLit ir.description)
  let path = if pathPrefix.len == 0: ir.name
             else: pathPrefix & "/" & ir.name
  # checks accumulate down the tree; the nearest cooldown wins
  let checks = inheritedChecks & ir.checks
  let cooldown = if ir.cooldown != nil: ir.cooldown else: inheritedCooldown
  var stmts = newStmtList()
  if ir.children.len > 0:
    stmts.add quote do:
      var `node` = SlashNode(kind: snGroup, name: `name`,
                             description: `desc`)
    for child in ir.children:
      let (childStmts, childVar) = genNode(child, checks, cooldown, path)
      stmts.add childStmts
      let childName = newLit child.name
      stmts.add quote do:
        `node`.children[`childName`] = `childVar`
  else:
    let runE = genRun(ir, checks, cooldown, path)
    stmts.add quote do:
      var `node` = SlashNode(kind: snLeaf, name: `name`,
                             description: `desc`, run: `runE`)
    for o in ir.options:
      let (specStmts, specVar) = genOptionSpec(o)
      stmts.add specStmts
      stmts.add quote do:
        `node`.options.add `specVar`
    for (optionName, acBody, _) in ir.autocompleters:
      let keyE = newLit optionName
      let acE = genAutocompleter(acBody)
      stmts.add quote do:
        `node`.autocompleters[`keyE`] = `acE`
  result = (stmts, node)

proc genMeta(meta: MetaIR): tuple[stmts, metaVar: NimNode] =
  let m = genSym(nskVar, "meta")
  var stmts = newStmtList()
  stmts.add quote do:
    var `m` = CommandMeta()
  if meta.guild != nil:
    let v = meta.guild
    stmts.add quote do:
      `m`.guildId = `v`
  if meta.permissions != nil:
    let v = meta.permissions
    stmts.add quote do:
      `m`.permissions = some(`v`)
  if meta.nsfw != nil:
    let v = meta.nsfw
    stmts.add quote do:
      `m`.nsfw = `v`
  if meta.contexts != nil:
    let v = meta.contexts
    stmts.add quote do:
      `m`.contexts = some(`v`)
  if meta.integrations != nil:
    let v = meta.integrations
    stmts.add quote do:
      `m`.integrations = some(`v`)
  if meta.nameLoc != nil:
    let v = meta.nameLoc
    stmts.add quote do:
      `m`.nameLoc = toTable(`v`)
  if meta.descLoc != nil:
    let v = meta.descLoc
    stmts.add quote do:
      `m`.descLoc = toTable(`v`)
  result = (stmts, m)

proc normalizeBody(body: NimNode): NimNode =
  ## Accept both `handler.slash(...): ...` and `slash(handler, ...) do: ...`.
  if body.kind == nnkDo:
    body.body
  else:
    body

macro slash*(handler: untyped; name, description: static string;
             body: untyped): untyped =
  ## Declares and registers a slash command. See the module docs for the
  ## full block grammar.
  let body = normalizeBody(body)
  let root = NodeIR(node: body, name: name, description: description)
  var meta = MetaIR()
  validateApiName(name, body, "slash command")
  validateDescription(description, body, "slash command")
  parseNodeBody(body, root, meta, isRoot = true, inGroup = false)
  validateNode(root)

  let (nodeStmts, nodeVar) = genNode(root)
  let (metaStmts, metaVar) = genMeta(meta)
  result = quote do:
    block:
      `metaStmts`
      `nodeStmts`
      addSlashCommand(`handler`,
        SlashCommand(meta: `metaVar`, root: `nodeVar`))

const settingKeys = ["guild", "permissions", "nsfw", "contexts",
                     "integrations", "nameLocalizations",
                     "descriptionLocalizations"]

proc splitSettingsAndBody(body: NimNode, meta: MetaIR,
                          cooldownPath: string):
    tuple[prologue, run: NimNode] =
  ## Context-menu commands: leading `key = value` settings, `check`
  ## blocks/conditions, and a `cooldown = …` are consumed; everything
  ## else (including ordinary assignments) is the handler body.
  ## The returned prologue (checks, then the cooldown gate) is inserted
  ## ahead of the body inside the generated handler.
  result = (newStmtList(), newStmtList())
  let ctxId = ident"ctx"
  var checks = newStmtList()
  var cooldown: NimNode = nil
  var inSettings = true
  for stmt in body:
    if inSettings:
      if stmt.kind == nnkAsgn and stmt[0].kind == nnkIdent:
        if $stmt[0] == "cooldown":
          if cooldown != nil:
            error("duplicate cooldown setting", stmt)
          cooldown = stmt[1]
          continue
        elif $stmt[0] in settingKeys:
          parseSetting(stmt, meta)
          continue
      elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
          $stmt[0] == "check" and stmt.len == 2 and
          stmt[1].kind == nnkStmtList:
        checks.add stmt[1]
        continue
      elif stmt.kind == nnkCommand and stmt[0].kind == nnkIdent and
          $stmt[0] == "check":
        checks.add parseCheckCommand(stmt)
        continue
    inSettings = false
    result.run.add stmt
  result.prologue.add checks
  if cooldown != nil:
    result.prologue.add genCooldown(cooldownPath, cooldown, ctxId)

macro user*(handler: untyped; name: static string; body: untyped): untyped =
  ## Declares a user context-menu command. The block is the handler body
  ## (`ctx: UserContext` is in scope), optionally preceded by
  ## `key = value` settings, `check` lines, and a `cooldown`.
  if name.len < 1 or name.len > 32:
    error("user command name must be 1..32 characters", body)
  var meta = MetaIR()
  let (prologue, runBody) = splitSettingsAndBody(normalizeBody(body), meta,
                                                 "user:" & name)
  let (metaStmts, metaVar) = genMeta(meta)
  let ctxId = ident"ctx"
  let nameE = newLit name
  result = quote do:
    block:
      `metaStmts`
      addUserCommand(`handler`, UserCommand(name: `nameE`, meta: `metaVar`,
        run: proc (`ctxId`: UserContext): Future[void] {.async.} =
          `prologue`
          `runBody`))

macro message*(handler: untyped; name: static string;
               body: untyped): untyped =
  ## Declares a message context-menu command. The block is the handler
  ## body (`ctx: MessageContext` is in scope), optionally preceded by
  ## `key = value` settings, `check` lines, and a `cooldown`.
  if name.len < 1 or name.len > 32:
    error("message command name must be 1..32 characters", body)
  var meta = MetaIR()
  let (prologue, runBody) = splitSettingsAndBody(normalizeBody(body), meta,
                                                 "message:" & name)
  let (metaStmts, metaVar) = genMeta(meta)
  let ctxId = ident"ctx"
  let nameE = newLit name
  result = quote do:
    block:
      `metaStmts`
      addMessageCommand(`handler`, MessageCommand(name: `nameE`,
        meta: `metaVar`,
        run: proc (`ctxId`: MessageContext): Future[void] {.async.} =
          `prologue`
          `runBody`))

proc genCaptureLets(pattern: string, site: NimNode,
                    ctxId: NimNode): NimNode =
  ## Compile-time pattern validation + one typed `let` per capture.
  result = newStmtList()
  var parsed: CustomIdPattern
  try:
    parsed = parseCustomIdPattern(pattern)
  except DimslashError as e:
    error(e.msg, site)
  for segment in parsed.segments:
    if segment.kind != psCapture:
      continue
    let nameId = ident(segment.name)
    let nameLit = newLit segment.name
    let parseIntSym = bindSym"parseInt"
    if segment.capture == capInt:
      result.add quote do:
        let `nameId` = `parseIntSym`(`ctxId`.captures[`nameLit`])
    else:
      result.add quote do:
        let `nameId` = `ctxId`.captures[`nameLit`]

proc splitGuards(body: NimNode, cooldownPath: string,
                 ctxId: NimNode): tuple[prologue, run: NimNode] =
  ## Component/modal handlers: leading `check` lines and a `cooldown = …`
  ## setting become a prologue that runs first (checks before the
  ## cooldown gate). Pattern captures are already in scope for both.
  result = (newStmtList(), newStmtList())
  var cooldown: NimNode = nil
  var inGuards = true
  for stmt in body:
    if inGuards:
      if stmt.kind == nnkAsgn and stmt[0].kind == nnkIdent and
          $stmt[0] == "cooldown":
        if cooldown != nil:
          error("duplicate cooldown setting", stmt)
        cooldown = stmt[1]
        continue
      elif stmt.kind == nnkCall and stmt[0].kind == nnkIdent and
          $stmt[0] == "check" and stmt.len == 2 and
          stmt[1].kind == nnkStmtList:
        result.prologue.add stmt[1]
        continue
      elif stmt.kind == nnkCommand and stmt[0].kind == nnkIdent and
          $stmt[0] == "check":
        result.prologue.add parseCheckCommand(stmt)
        continue
    inGuards = false
    result.run.add stmt
  if cooldown != nil:
    result.prologue.add genCooldown(cooldownPath, cooldown, ctxId)

macro button*(handler: untyped; customId: static string;
              body: untyped): untyped =
  ## Registers a button handler. `customId` may contain `{name}` /
  ## `{name:int}` captures, which become typed variables in the body
  ## (`ctx: ComponentContext` is in scope). Leading `check` lines and a
  ## `cooldown = …` guard the handler like they do for commands.
  let ctxId = ident"ctx"
  let body = normalizeBody(body)
  let lets = genCaptureLets(customId, body, ctxId)
  let (prologue, runBody) = splitGuards(body, "button:" & customId, ctxId)
  let idE = newLit customId
  result = quote do:
    addButtonHandler(`handler`, `idE`,
      proc (`ctxId`: ComponentContext): Future[void] {.async.} =
        `lets`
        `prologue`
        `runBody`)

macro select*(handler: untyped; customId: static string;
              body: untyped): untyped =
  ## Registers a select-menu handler (all five select kinds).
  ## Captures, `check` lines, and `cooldown` work like `button`;
  ## `ctx: ComponentContext` is in scope.
  let ctxId = ident"ctx"
  let body = normalizeBody(body)
  let lets = genCaptureLets(customId, body, ctxId)
  let (prologue, runBody) = splitGuards(body, "select:" & customId, ctxId)
  let idE = newLit customId
  result = quote do:
    addSelectHandler(`handler`, `idE`,
      proc (`ctxId`: ComponentContext): Future[void] {.async.} =
        `lets`
        `prologue`
        `runBody`)

macro modal*(handler: untyped; customId: static string;
             body: untyped): untyped =
  ## Registers a modal-submit handler. Captures, `check` lines, and
  ## `cooldown` work like `button`; `ctx: ModalContext` is in scope.
  let ctxId = ident"ctx"
  let body = normalizeBody(body)
  let lets = genCaptureLets(customId, body, ctxId)
  let (prologue, runBody) = splitGuards(body, "modal:" & customId, ctxId)
  let idE = newLit customId
  result = quote do:
    addModalHandler(`handler`, `idE`,
      proc (`ctxId`: ModalContext): Future[void] {.async.} =
        `lets`
        `prologue`
        `runBody`)

# --- modalForm ----------------------------------------------------------------

type
  FieldClass = enum
    fcString, fcInt, fcFloat

  FieldIR = ref object
    node: NimNode
    nimName: NimNode
    customId: string
    class: FieldClass
    optional: bool
    label: string
    placeholder, value: NimNode  # exprs or nil
    minLen, maxLen: NimNode
    paragraph: bool

proc parseFieldPragmas(f: FieldIR, pragma: NimNode) =
  for entry in pragma:
    if entry.kind == nnkIdent:
      if $entry == "paragraph":
        f.paragraph = true
        continue
      error("unknown field pragma: " & $entry & " (flags: paragraph)", entry)
    if entry.kind != nnkExprColonExpr or entry[0].kind != nnkIdent:
      error("field pragmas take the form key: value", entry)
    let value = entry[1]
    case $entry[0]
    of "label":
      value.expectKind nnkStrLit
      f.label = value.strVal
    of "name":
      value.expectKind nnkStrLit
      f.customId = value.strVal
    of "placeholder": f.placeholder = value
    of "value": f.value = value
    of "minLen": f.minLen = value
    of "maxLen": f.maxLen = value
    else:
      error("unknown field pragma: " & $entry[0] & " (valid: label, name, " &
        "placeholder, value, minLen, maxLen, paragraph)", entry)

proc parseFieldDecl(stmt: NimNode, pendingDoc: string): FieldIR =
  ## Same declaration shape as slash options: `name: Type` with an
  ## optional pragma list; the label comes from a preceding `## doc`
  ## comment or the `label` pragma.
  result = FieldIR(node: stmt, label: pendingDoc)
  var head = stmt[0]
  var pragma: NimNode = nil
  if head.kind == nnkPragmaExpr:
    pragma = head[1]
    head = head[0]
  head.expectKind nnkIdent
  result.nimName = head
  result.customId = $head

  var typeExpr = stmt[1][0]
  if typeExpr.kind == nnkAsgn:
    error("modal fields cannot have defaults; use Option[T] for optional " &
      "fields or the {.value: \"…\".} pragma for prefilled text", stmt)
  if typeExpr.kind == nnkBracketExpr and typeExpr.len == 2 and
      typeExpr[0].kind == nnkIdent and $typeExpr[0] == "Option":
    result.optional = true
    typeExpr = typeExpr[1]
  if typeExpr.kind == nnkIdent:
    case $typeExpr
    of "string": result.class = fcString
    of "int": result.class = fcInt
    of "float": result.class = fcFloat
    else:
      error("modal fields must be string, int, or float (text inputs are " &
        "text; numbers are parsed on submit): " & typeExpr.repr, stmt)
  else:
    error("unsupported modal field type: " & typeExpr.repr, stmt)

  if pragma != nil:
    result.parseFieldPragmas(pragma)
  if result.label.len == 0:
    warning("modal field \"" & result.customId & "\" has no label (add a " &
      "## doc comment on the line above or a label pragma); using the " &
      "field name", stmt)
    result.label = result.customId
  if result.label.len > 45:
    error("modal field labels are limited to 45 characters (Discord)", stmt)

proc parseFormBody(body: NimNode):
    tuple[fields: seq[FieldIR], checks: seq[NimNode], submit: NimNode] =
  var pendingDoc = ""
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      pendingDoc = stmt.strVal
      continue
    of nnkCall:
      if stmt[0].kind == nnkIdent and $stmt[0] == "submit":
        if result.submit != nil:
          error("duplicate submit block", stmt)
        stmt[1].expectKind nnkStmtList
        result.submit = stmt[1]
      elif stmt[0].kind == nnkIdent and $stmt[0] == "check" and
          stmt.len == 2 and stmt[1].kind == nnkStmtList:
        # runs after the fields are parsed, so field values are in scope
        result.checks.add stmt[1]
      else:
        let field = parseFieldDecl(stmt, pendingDoc)
        for existing in result.fields:
          if existing.customId == field.customId:
            error("duplicate field name: " & field.customId, stmt)
        result.fields.add field
    of nnkCommand:
      if stmt[0].kind == nnkIdent and $stmt[0] == "check":
        result.checks.add parseCheckCommand(stmt)
      else:
        error("unexpected statement in modalForm block: " & stmt.repr, stmt)
    else:
      error("unexpected statement in modalForm block: " & stmt.repr, stmt)
    pendingDoc = ""
  if result.submit == nil:
    error("modalForm is missing a submit block", body)
  if result.fields.len < 1 or result.fields.len > 5:
    error("a modal needs 1..5 text inputs (Discord limit)", body)

proc genFieldLet(f: FieldIR, ctxId: NimNode): NimNode =
  let (nimName, cid, lbl) = (f.nimName, newLit f.customId, newLit f.label)
  case f.class
  of fcString:
    if f.optional:
      let sym = bindSym"optField"
      quote do:
        let `nimName` = `sym`(`ctxId`, `cid`)
    else:
      let sym = bindSym"field"
      quote do:
        let `nimName` = `sym`(`ctxId`, `cid`).get("")
  of fcInt:
    let sym = if f.optional: bindSym"optFieldAsInt" else: bindSym"fieldAsInt"
    quote do:
      let `nimName` = `sym`(`ctxId`, `cid`, `lbl`)
  of fcFloat:
    let sym = if f.optional: bindSym"optFieldAsFloat"
              else: bindSym"fieldAsFloat"
    quote do:
      let `nimName` = `sym`(`ctxId`, `cid`, `lbl`)

macro modalForm*(handler: untyped; pattern, title: static string;
                 body: untyped): untyped =
  ## Declares a modal with typed text inputs and its submit handler in
  ## one block, registers the handler under `pattern`, and returns a
  ## `ModalForm` — open it with `ctx.showModal(form, captureValues...)`.
  ##
  ## .. code-block:: nim
  ##   let feedback = handler.modalForm("feedback:{topic}", "Feedback"):
  ##     ## Subject
  ##     subject {.maxLen: 100.}: string
  ##     ## Details
  ##     detail {.paragraph, placeholder: "Tell us more".}: Option[string]
  ##     ## Rating (1-5)
  ##     rating: int
  ##     submit:
  ##       await ctx.reply(topic & ": " & subject & " → " & $rating)
  ##
  ##   # elsewhere:
  ##   await ctx.showModal(feedback, "bug")
  ##
  ## Field types are `string`/`int`/`float` (plus `Option[T]`); numbers
  ## are parsed on submit and a bad value raises `UserError`, which the
  ## default error hook turns into a polite ephemeral reply. An empty
  ## optional input becomes `none`. In `submit`, `ctx: ModalContext`,
  ## one typed variable per field, and the pattern captures are in scope.
  if title.len < 1 or title.len > 45:
    error("modal title must be 1..45 characters", body)
  let body = normalizeBody(body)
  let (fields, checks, submitBody) = parseFormBody(body)
  let ctxId = ident"ctx"
  let captureLets = genCaptureLets(pattern, body, ctxId)

  # a field and a pattern capture with the same name would collide in
  # the submit scope; catch it here with a better message
  var parsed: CustomIdPattern
  try:
    parsed = parseCustomIdPattern(pattern)
  except DimslashError as e:
    error(e.msg, body)
  for segment in parsed.segments:
    if segment.kind != psCapture:
      continue
    for f in fields:
      if $f.nimName == segment.name:
        error("field \"" & $f.nimName & "\" collides with pattern " &
          "capture {" & segment.name & "}", f.node)

  let formSym = genSym(nskVar, "form")
  var specAdds = newStmtList()
  var fieldLets = newStmtList()
  for f in fields:
    let (cid, lbl) = (newLit f.customId, newLit f.label)
    let styleE = if f.paragraph: bindSym"tisParagraph" else: bindSym"tisShort"
    let requiredE = newLit(not f.optional)
    let placeholderE = if f.placeholder != nil: f.placeholder else: newLit ""
    let valueE = if f.value != nil: f.value else: newLit ""
    let minE = if f.minLen != nil: newCall(ident"int", f.minLen)
               else: newLit 0
    let maxE = if f.maxLen != nil: newCall(ident"int", f.maxLen)
               else: newLit 0
    specAdds.add quote do:
      `formSym`.fields.add TextFieldSpec(customId: `cid`, label: `lbl`,
        style: `styleE`, required: `requiredE`, placeholder: `placeholderE`,
        value: `valueE`, minLen: `minE`, maxLen: `maxE`)
    fieldLets.add genFieldLet(f, ctxId)

  var checkStmts = newStmtList()
  for chk in checks:
    checkStmts.add chk

  let (patternE, titleE) = (newLit pattern, newLit title)
  result = quote do:
    block:
      var `formSym` = ModalForm(pattern: `patternE`, title: `titleE`)
      `specAdds`
      addModalHandler(`handler`, `patternE`,
        proc (`ctxId`: ModalContext): Future[void] {.async.} =
          `captureLets`
          `fieldLets`
          `checkStmts`
          `submitBody`)
      `formSym`
