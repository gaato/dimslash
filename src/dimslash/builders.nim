## Declarative builders for embeds and component rows.
##
## .. code-block:: nim
##   let e = embed:
##     title "Vote"
##     description "Pick a side"
##     color 0x5865F2
##     field "Ayes", "12", inline = true
##     field "Noes", "3", inline = true
##     footer "closes in 5 minutes"
##
##   let comps = rows:
##     row:
##       button "Yes", "vote:yes", style = bsSuccess
##       button "No", "vote:no", style = bsDanger
##       linkButton "Docs", "https://example.com"
##     row:
##       select "vote:menu", placeholder = "Or pick here":
##         option "Aye", "yes", desc = "For the motion"
##         option "Nay", "no"
##
##   await ctx.reply(embeds = @[e], components = comps)
##
## `row:` builds a single action row (`MessageComponent`); `rows:` builds
## a list of them, ready for any `components =` parameter. Named
## arguments are passed through to the underlying dimscord builders, so
## everything they accept (`style`, `emoji`, `disabled`, `placeholder`,
## `minValues`, `maxValues`, …) works here. Entity selects are
## `userSelect`, `roleSelect`, `mentionableSelect`, and `channelSelect`
## (the latter takes `channels = {ctGuildText, …}` to filter kinds).

import std/[macros, options, strutils]
import dimscord

type
  MessageLayout* = object
    ## A Components V2 message body. Construct one with `layout`; its
    ## separate type makes it impossible to accidentally combine V2
    ## components with the legacy `content` or `embeds` response fields.
    items: seq[MessageComponent]

proc components*(layout: MessageLayout): seq[MessageComponent] {.inline.} =
  ## The dimscord components produced by `layout`.
  layout.items

# --- Embed runtime helpers (called by the generated code) ---------------------

proc embedTitle(e: var Embed, text: string) = e.title = some text
proc embedDescription(e: var Embed, text: string) = e.description = some text
proc embedColor(e: var Embed, color: int) = e.color = some color
proc embedUrl(e: var Embed, url: string) = e.url = some url
proc embedTimestamp(e: var Embed, ts: string) = e.timestamp = some ts
proc embedImage(e: var Embed, url: string) =
  e.image = some EmbedImage(url: url)
proc embedThumbnail(e: var Embed, url: string) =
  e.thumbnail = some EmbedThumbnail(url: url)

proc embedAuthor(e: var Embed, name: string, url = "", icon = "") =
  var author = EmbedAuthor(name: name)
  if url.len > 0:
    author.url = some url
  if icon.len > 0:
    author.icon_url = some icon
  e.author = some author

proc embedFooter(e: var Embed, text: string, icon = "") =
  var footer = EmbedFooter(text: text)
  if icon.len > 0:
    footer.icon_url = some icon
  e.footer = some footer

proc embedField(e: var Embed, name, value: string, inline = false) =
  var fields = e.fields.get(@[])
  fields.add EmbedField(name: name, value: value,
                        inline: if inline: some true else: none bool)
  e.fields = some fields

# --- Component runtime helpers -------------------------------------------------

proc linkButtonComp(label, url: string, disabled = false): MessageComponent =
  newButton(label, url, bsLink, disabled = disabled)

template entityHelper(helperName, kindLit) =
  proc helperName(customId: string; placeholder = ""; minValues = 1;
                  maxValues = 1; disabled = false): MessageComponent =
    result = MessageComponent(kind: kindLit, custom_id: some customId,
                              min_values: some minValues,
                              max_values: some maxValues,
                              disabled: some disabled)
    if placeholder.len > 0:
      result.placeholder = some placeholder

entityHelper(userSelectComp, mctUserSelect)
entityHelper(roleSelectComp, mctRoleSelect)
entityHelper(mentionableSelectComp, mctMentionableSelect)

proc channelSelectComp(customId: string; placeholder = "";
                       channels: set[ChannelType] = {}; minValues = 1;
                       maxValues = 1; disabled = false): MessageComponent =
  result = MessageComponent(kind: mctChannelSelect, custom_id: some customId,
                            min_values: some minValues,
                            max_values: some maxValues,
                            disabled: some disabled)
  if placeholder.len > 0:
    result.placeholder = some placeholder
  for kind in channels:
    result.channel_types.add kind

# --- Components V2 runtime helpers -------------------------------------------

proc textDisplayComp(content: string): MessageComponent =
  MessageComponent(kind: mctTextDisplay, content: content)

proc thumbnailComp(url: string; description = "";
                   spoiler = false): MessageComponent =
  result = MessageComponent(kind: mctThumbnail,
                            media: UnfurledMediaItem(url: url))
  if description.len > 0:
    result.description = some description
  if spoiler:
    result.spoiler = some true

proc mediaGalleryItem(url: string; description = "";
                      spoiler = false): MediaGallery =
  result = MediaGallery(media: UnfurledMediaItem(url: url))
  if description.len > 0:
    result.description = some description
  if spoiler:
    result.spoiler = some true

proc sectionComp(texts: seq[string]; accessory: MessageComponent):
    MessageComponent =
  if texts.len notin 1 .. 3:
    raise newException(ValueError,
      "a section needs between 1 and 3 text components")
  if accessory.isNil or accessory.kind notin {mctButton, mctThumbnail}:
    raise newException(ValueError,
      "a section accessory must be a button, linkButton, or thumbnail")
  var displays: seq[TextDisplay]
  for text in texts:
    displays.add TextDisplay(kind: mctTextDisplay, content: text)
  MessageComponent(kind: mctSection, sect_components: displays,
                   accessory: accessory)

proc galleryComp(items: seq[MediaGallery]): MessageComponent =
  if items.len notin 1 .. 10:
    raise newException(ValueError,
      "a gallery needs between 1 and 10 media items")
  MessageComponent(kind: mctMediaGallery, items: items)

proc fileComp(url: string; spoiler = false): MessageComponent =
  if not url.startsWith("attachment://") or
      url.len == "attachment://".len:
    raise newException(ValueError,
      "a file component URL must use attachment://<filename>")
  result = MessageComponent(kind: mctFile,
                            file: UnfurledMediaItem(url: url),
                            name: "", size: 0)
  if spoiler:
    result.spoiler = some true

proc separatorComp(divider = true; spacing = 1): MessageComponent =
  if spacing notin 1 .. 2:
    raise newException(ValueError, "separator spacing must be 1 or 2")
  MessageComponent(kind: mctSeparator, divider: some divider,
                   spacing: some spacing)

proc containerComp(components: seq[MessageComponent];
                   accent = none int;
                   spoiler = false): MessageComponent =
  if components.len == 0:
    raise newException(ValueError, "a container cannot be empty")
  result = MessageComponent(kind: mctContainer, components: components)
  if accent.isSome:
    let color = accent.get
    if color notin 0 .. 0xFFFFFF:
      raise newException(ValueError,
        "container accent must be between 0x000000 and 0xFFFFFF")
    result.accent_color = some color
  if spoiler:
    result.spoiler = some true

proc componentCount(component: MessageComponent): int =
  if component.isNil:
    return 0
  result = 1
  case component.kind
  of mctActionRow, mctContainer:
    for child in component.components:
      result += componentCount(child)
  of mctSection:
    result += component.sect_components.len
    result += componentCount(component.accessory)
  else:
    discard

proc newMessageLayout(components: seq[MessageComponent]): MessageLayout =
  if components.len == 0:
    raise newException(ValueError, "a message layout cannot be empty")
  var total = 0
  for component in components:
    total += componentCount(component)
  if total > 40:
    raise newException(ValueError,
      "a Components V2 message can contain at most 40 total components")
  MessageLayout(items: components)

# --- Macros --------------------------------------------------------------------

proc keywordOf(stmt: NimNode, where: string): string =
  if stmt.kind notin {nnkCommand, nnkCall} or stmt[0].kind != nnkIdent:
    error("expected a builder keyword in " & where & " block, got: " &
      stmt.repr, stmt)
  $stmt[0]

proc passArgs(call: NimNode, stmt: NimNode) =
  ## Appends `stmt`'s arguments (positional and `name = value`) to `call`.
  for i in 1 ..< stmt.len:
    call.add stmt[i]

macro embed*(body: untyped): Embed =
  ## Builds an `Embed` from a keyword block. Keywords: `title`,
  ## `description`, `color`, `url`, `timestamp`, `image`, `thumbnail`,
  ## `author name[, url = …, icon = …]`, `footer text[, icon = …]`, and
  ## `field name, value[, inline = …]` (repeatable).
  let e = genSym(nskVar, "embed")
  var stmts = newStmtList()
  for stmt in body:
    let helper =
      case keywordOf(stmt, "embed")
      of "title": bindSym"embedTitle"
      of "description": bindSym"embedDescription"
      of "color": bindSym"embedColor"
      of "url": bindSym"embedUrl"
      of "timestamp": bindSym"embedTimestamp"
      of "image": bindSym"embedImage"
      of "thumbnail": bindSym"embedThumbnail"
      of "author": bindSym"embedAuthor"
      of "footer": bindSym"embedFooter"
      of "field": bindSym"embedField"
      else:
        error("unknown embed keyword: " & $stmt[0] & " (valid: title, " &
          "description, color, url, timestamp, image, thumbnail, author, " &
          "footer, field)", stmt)
        nil
    var call = newCall(helper, e)
    call.passArgs(stmt)
    stmts.add call
  result = quote do:
    block:
      var `e` = Embed()
      `stmts`
      `e`

proc buildSelect(stmt: NimNode): NimNode =
  ## `select "id", placeholder = "…": option "label", "value", …` →
  ## a `newSelectMenu` call with the options collected from the block.
  var optsBody: NimNode = nil
  var args: seq[NimNode]
  for i in 1 ..< stmt.len:
    if stmt[i].kind == nnkStmtList:
      optsBody = stmt[i]
    else:
      args.add stmt[i]
  if args.len == 0:
    error("select needs a custom_id: select \"menu\", ...: option ...", stmt)
  let opts = genSym(nskVar, "opts")
  var optStmts = newStmtList()
  if optsBody != nil:
    for o in optsBody:
      if o.keywordOf("select") != "option":
        error("select blocks contain option lines: " &
          "option \"label\", \"value\"[, desc = …, default = …]", o)
      var ocall = newCall(bindSym"newMenuOption")
      for j in 1 ..< o.len:
        var arg = o[j]
        # newMenuOption spells it `description`; accept the short form too
        if arg.kind == nnkExprEqExpr and arg[0].kind == nnkIdent and
            $arg[0] == "desc":
          arg = nnkExprEqExpr.newTree(ident"description", arg[1])
        ocall.add arg
      optStmts.add newCall(ident"add", opts, ocall)
  var scall = newCall(bindSym"newSelectMenu", args[0], opts)
  for i in 1 ..< args.len:
    scall.add args[i]
  result = quote do:
    block:
      var `opts`: seq[SelectMenuOption]
      `optStmts`
      `scall`

const selectKeywords = ["select", "userSelect", "roleSelect",
                        "mentionableSelect", "channelSelect"]

proc buildRow(body: NimNode): NimNode =
  let items = genSym(nskVar, "row")
  var stmts = newStmtList()
  if body.len == 0:
    error("a row cannot be empty", body)
  for stmt in body:
    # Discord: a select menu fills its whole action row
    if keywordOf(stmt, "row") in selectKeywords and body.len > 1:
      error("a select menu must be the only component in its row " &
        "(Discord requirement) — put it in its own row block", stmt)
  if body.len > 5:
    error("an action row can contain at most 5 buttons", body)
  for stmt in body:
    let compE =
      case keywordOf(stmt, "row")
      of "button":
        var call = newCall(bindSym"newButton")
        call.passArgs(stmt)
        call
      of "linkButton":
        var call = newCall(bindSym"linkButtonComp")
        call.passArgs(stmt)
        call
      of "select":
        buildSelect(stmt)
      of "userSelect":
        var call = newCall(bindSym"userSelectComp")
        call.passArgs(stmt)
        call
      of "roleSelect":
        var call = newCall(bindSym"roleSelectComp")
        call.passArgs(stmt)
        call
      of "mentionableSelect":
        var call = newCall(bindSym"mentionableSelectComp")
        call.passArgs(stmt)
        call
      of "channelSelect":
        var call = newCall(bindSym"channelSelectComp")
        call.passArgs(stmt)
        call
      else:
        error("unknown component keyword: " & $stmt[0] & " (valid: " &
          "button, linkButton, select, userSelect, roleSelect, " &
          "mentionableSelect, channelSelect)", stmt)
        nil
    stmts.add newCall(ident"add", items, compE)
  result = quote do:
    block:
      var `items`: seq[MessageComponent]
      `stmts`
      newActionRow(`items`)

macro row*(body: untyped): MessageComponent =
  ## Builds one action row. Component keywords: `button`, `linkButton`,
  ## `select` (with nested `option` lines), `userSelect`, `roleSelect`,
  ## `mentionableSelect`, `channelSelect`.
  buildRow(body)

macro rows*(body: untyped): seq[MessageComponent] =
  ## Builds a list of action rows from nested `row:` blocks — the shape
  ## every `components =` parameter expects.
  let items = genSym(nskVar, "rows")
  var stmts = newStmtList()
  for stmt in body:
    if stmt.keywordOf("rows") != "row" or stmt[^1].kind != nnkStmtList:
      error("rows blocks contain row: blocks", stmt)
    stmts.add newCall(ident"add", items, buildRow(stmt[^1]))
  result = quote do:
    block:
      var `items`: seq[MessageComponent]
      `stmts`
      `items`

# --- Components V2 layout macro ----------------------------------------------

type BuiltLayoutComponent = object
  expression: NimNode
  count: int

proc layoutKeyword(stmt: NimNode; where: string): string =
  if stmt.kind == nnkIdent:
    return $stmt
  if stmt.kind in {nnkCommand, nnkCall} and stmt.len > 0 and
      stmt[0].kind == nnkIdent:
    return $stmt[0]
  error("expected a layout keyword in " & where & " block, got: " &
    stmt.repr, stmt)

proc layoutArgs(stmt: NimNode): seq[NimNode] =
  if stmt.kind in {nnkCommand, nnkCall}:
    for i in 1 ..< stmt.len:
      if stmt[i].kind != nnkStmtList:
        result.add stmt[i]

proc layoutBody(stmt: NimNode; keyword: string): NimNode =
  if stmt.kind notin {nnkCommand, nnkCall} or stmt.len < 2 or
      stmt[^1].kind != nnkStmtList:
    error(keyword & " needs an indented block", stmt)
  stmt[^1]

proc noLayoutBody(stmt: NimNode; keyword: string) =
  if stmt.kind in {nnkCommand, nnkCall} and stmt.len > 1 and
      stmt[^1].kind == nnkStmtList:
    error(keyword & " does not take an indented block", stmt)

proc requireArgCount(stmt: NimNode; keyword: string; minimum, maximum: int) =
  let count = stmt.layoutArgs.len
  if count < minimum or count > maximum:
    let expected = if minimum == maximum: $minimum else: $minimum & ".." & $maximum
    error(keyword & " expects " & expected & " argument(s)", stmt)

proc callWithArgs(helper: NimNode; args: seq[NimNode]): NimNode =
  result = newCall(helper)
  for arg in args:
    result.add arg

proc seqExpression(elementType: NimNode;
                   expressions: seq[NimNode]): NimNode =
  let items = genSym(nskVar, "items")
  var statements = newStmtList()
  for expression in expressions:
    statements.add newCall(bindSym"add", items, expression)
  result = quote do:
    block:
      var `items`: seq[`elementType`]
      `statements`
      `items`

proc integerLiteral(node: NimNode; value: var int): bool =
  if node.kind in {nnkIntLit .. nnkUInt64Lit}:
    value = int(node.intVal)
    return true
  if node.kind == nnkPrefix and node.len == 2 and node[0].eqIdent("-"):
    var positive: int
    if integerLiteral(node[1], positive):
      value = -positive
      return true

proc checkIntegerArgument(args: seq[NimNode]; name: string;
                          minimum, maximum: int; message: string) =
  for arg in args:
    if arg.kind == nnkExprEqExpr and arg[0].eqIdent(name):
      var value: int
      if integerLiteral(arg[1], value) and value notin minimum .. maximum:
        error(message, arg[1])

proc normalizeDescriptionArgs(args: seq[NimNode]): seq[NimNode] =
  for arg in args:
    if arg.kind == nnkExprEqExpr and arg[0].eqIdent("desc"):
      result.add nnkExprEqExpr.newTree(ident"description", arg[1])
    else:
      result.add arg

proc normalizeContainerArgs(args: seq[NimNode]): seq[NimNode] =
  for arg in args:
    if arg.kind == nnkExprEqExpr and (arg[0].eqIdent("accent") or
        arg[0].eqIdent("accentColor") or arg[0].eqIdent("accent_color")):
      result.add nnkExprEqExpr.newTree(ident"accent",
        newCall(bindSym"some", arg[1]))
    else:
      result.add arg

proc buildLayoutComponent(stmt: NimNode; inContainer: bool):
    BuiltLayoutComponent =
  let keyword = stmt.layoutKeyword(if inContainer: "container" else: "layout")
  case keyword
  of "text":
    stmt.noLayoutBody(keyword)
    stmt.requireArgCount(keyword, 1, 1)
    result.expression = callWithArgs(bindSym"textDisplayComp", stmt.layoutArgs)
    result.count = 1

  of "section":
    let body = stmt.layoutBody(keyword)
    var texts: seq[NimNode]
    var accessory: NimNode
    for child in body:
      let childKeyword = child.layoutKeyword("section")
      case childKeyword
      of "text":
        child.noLayoutBody(childKeyword)
        child.requireArgCount(childKeyword, 1, 1)
        texts.add child.layoutArgs[0]
      of "button":
        child.noLayoutBody(childKeyword)
        if not accessory.isNil:
          error("a section must have exactly one accessory", child)
        accessory = callWithArgs(bindSym"newButton", child.layoutArgs)
      of "linkButton":
        child.noLayoutBody(childKeyword)
        if not accessory.isNil:
          error("a section must have exactly one accessory", child)
        accessory = callWithArgs(bindSym"linkButtonComp", child.layoutArgs)
      of "thumbnail":
        child.noLayoutBody(childKeyword)
        child.requireArgCount(childKeyword, 1, 3)
        if not accessory.isNil:
          error("a section must have exactly one accessory", child)
        accessory = callWithArgs(bindSym"thumbnailComp",
          normalizeDescriptionArgs(child.layoutArgs))
      else:
        error("section blocks contain 1-3 text lines and exactly one " &
          "button, linkButton, or thumbnail accessory", child)
    if texts.len notin 1 .. 3:
      error("a section needs between 1 and 3 text lines", stmt)
    if accessory.isNil:
      error("a section needs exactly one button, linkButton, or thumbnail " &
        "accessory", stmt)
    let textSeq = seqExpression(bindSym"string", texts)
    result.expression = newCall(bindSym"sectionComp", textSeq, accessory)
    result.count = texts.len + 2

  of "gallery":
    let body = stmt.layoutBody(keyword)
    var media: seq[NimNode]
    for child in body:
      if child.layoutKeyword("gallery") != "media":
        error("gallery blocks contain media lines", child)
      child.noLayoutBody("media")
      child.requireArgCount("media", 1, 3)
      media.add callWithArgs(bindSym"mediaGalleryItem",
        normalizeDescriptionArgs(child.layoutArgs))
    if media.len notin 1 .. 10:
      error("a gallery needs between 1 and 10 media items", stmt)
    result.expression = newCall(bindSym"galleryComp",
      seqExpression(bindSym"MediaGallery", media))
    result.count = 1

  of "file":
    stmt.noLayoutBody(keyword)
    stmt.requireArgCount(keyword, 1, 2)
    let args = stmt.layoutArgs
    var urlArgument: NimNode
    for arg in args:
      if arg.kind == nnkExprEqExpr and arg[0].eqIdent("url"):
        urlArgument = arg[1]
      elif arg.kind != nnkExprEqExpr and urlArgument.isNil:
        urlArgument = arg
    if not urlArgument.isNil and
        urlArgument.kind in {nnkStrLit .. nnkTripleStrLit} and
        (not urlArgument.strVal.startsWith("attachment://") or
         urlArgument.strVal.len == "attachment://".len):
      error("a file component URL must use attachment://<filename>",
        urlArgument)
    result.expression = callWithArgs(bindSym"fileComp", args)
    result.count = 1

  of "separator":
    stmt.noLayoutBody(keyword)
    let args = stmt.layoutArgs
    if args.len > 2:
      error("separator accepts divider and spacing arguments", stmt)
    args.checkIntegerArgument("spacing", 1, 2,
      "separator spacing must be 1 or 2")
    var positional = 0
    for arg in args:
      if arg.kind != nnkExprEqExpr:
        inc positional
        if positional == 2:
          var value: int
          if integerLiteral(arg, value) and value notin 1 .. 2:
            error("separator spacing must be 1 or 2", arg)
    result.expression = callWithArgs(bindSym"separatorComp", args)
    result.count = 1

  of "row":
    let body = stmt.layoutBody(keyword)
    result.expression = buildRow(body)
    result.count = body.len + 1

  of "container":
    if inContainer:
      error("containers cannot be nested inside containers", stmt)
    let body = stmt.layoutBody(keyword)
    if body.len == 0:
      error("a container cannot be empty", stmt)
    var children: seq[NimNode]
    var total = 1
    for child in body:
      let built = buildLayoutComponent(child, inContainer = true)
      children.add built.expression
      total += built.count
    let rawArgs = stmt.layoutArgs
    rawArgs.checkIntegerArgument("accent", 0, 0xFFFFFF,
      "container accent must be between 0x000000 and 0xFFFFFF")
    rawArgs.checkIntegerArgument("accentColor", 0, 0xFFFFFF,
      "container accent must be between 0x000000 and 0xFFFFFF")
    rawArgs.checkIntegerArgument("accent_color", 0, 0xFFFFFF,
      "container accent must be between 0x000000 and 0xFFFFFF")
    var args = normalizeContainerArgs(rawArgs)
    result.expression = newCall(bindSym"containerComp",
      seqExpression(bindSym"MessageComponent", children))
    for arg in args:
      result.expression.add arg
    result.count = total

  else:
    let valid = if inContainer:
      "text, section, gallery, file, separator, row"
    else:
      "text, section, gallery, file, separator, container, row"
    error("unknown " & (if inContainer: "container" else: "layout") &
      " keyword: " & keyword & " (valid: " & valid & ")", stmt)

macro layout*(body: untyped): MessageLayout =
  ## Builds a Components V2 message. Top-level keywords are `text`,
  ## `section`, `gallery`, `file`, `separator`, `container`, and `row`.
  ## Invalid nesting and all statically knowable Discord shape limits are
  ## rejected while compiling the bot.
  var expressions: seq[NimNode]
  var total = 0
  for stmt in body:
    let built = buildLayoutComponent(stmt, inContainer = false)
    expressions.add built.expression
    total += built.count
  if expressions.len == 0:
    error("a message layout cannot be empty", body)
  if total > 40:
    error("a Components V2 message can contain at most 40 total components " &
      "(this layout contains " & $total & ")", body)
  newCall(bindSym"newMessageLayout",
          seqExpression(bindSym"MessageComponent", expressions))
