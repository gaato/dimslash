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

import std/[macros, options]
import dimscord

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
  for stmt in body:
    # Discord: a select menu fills its whole action row
    if keywordOf(stmt, "row") in selectKeywords and body.len > 1:
      error("a select menu must be the only component in its row " &
        "(Discord requirement) — put it in its own row block", stmt)
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
