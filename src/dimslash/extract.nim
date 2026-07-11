## Payload extraction: typed slash options, resolved entities, context-menu
## targets, modal fields, and custom_id pattern parsing/matching.
##
## The `opt`/`req` getters are what the `slash` macro's generated code calls;
## they are exported for programmatic handlers too.

import std/[options, strutils, tables]
import dimscord

import ./types

type
  LeafOptions* = Table[string, ApplicationCommandInteractionDataOption]

const SelectKinds* = {mctSelectMenu, mctUserSelect, mctRoleSelect,
                      mctMentionableSelect, mctChannelSelect}

proc leafOptions*(data: ApplicationCommandInteractionData):
    tuple[path: seq[string], options: LeafOptions] =
  ## Descends `acotSubCommandGroup`/`acotSubCommand` nesting and returns the
  ## group/subcommand names walked plus the leaf table holding actual values.
  result.options = data.options
  while result.options.len == 1:
    var next: Option[ApplicationCommandInteractionDataOption]
    for _, child in result.options:
      if child.kind in {acotSubCommand, acotSubCommandGroup}:
        next = some child
    if next.isNone:
      break
    result.path.add next.get.name
    result.options = next.get.options

proc resolved(ctx: InteractionContext): ResolvedData =
  ctx.interaction.data.get.resolved

# --- Scalar options ---------------------------------------------------------

proc opt*(ctx: SlashContext, name: string, T: typedesc[string]): Option[string] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotStr:
    return some ctx.options[name].str

proc opt*(ctx: SlashContext, name: string, T: typedesc[int]): Option[int] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotInt:
    return some int(ctx.options[name].ival)

proc opt*(ctx: SlashContext, name: string, T: typedesc[bool]): Option[bool] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotBool:
    return some ctx.options[name].bval

proc opt*(ctx: SlashContext, name: string, T: typedesc[float]): Option[float] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotNumber:
    return some float(ctx.options[name].fval)

# --- Resolved options -------------------------------------------------------

proc opt*(ctx: SlashContext, name: string, T: typedesc[User]): Option[User] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotUser:
    let id = ctx.options[name].user_id
    if ctx.resolved.users.hasKey(id):
      return some ctx.resolved.users[id]

proc opt*(ctx: SlashContext, name: string, T: typedesc[Member]): Option[Member] =
  ## Guild-only: resolves the member and backfills `member.user` from the
  ## resolved users table (Discord omits it inside `resolved.members`).
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotUser:
    let id = ctx.options[name].user_id
    if ctx.resolved.members.hasKey(id):
      var m = ctx.resolved.members[id]
      if ctx.resolved.users.hasKey(id):
        m.user = ctx.resolved.users[id]
      return some m

proc opt*(ctx: SlashContext, name: string, T: typedesc[Role]): Option[Role] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotRole:
    let id = ctx.options[name].role_id
    if ctx.resolved.roles.hasKey(id):
      return some ctx.resolved.roles[id]

proc opt*(ctx: SlashContext, name: string,
          T: typedesc[ResolvedChannel]): Option[ResolvedChannel] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotChannel:
    let id = ctx.options[name].channel_id
    if ctx.resolved.channels.hasKey(id):
      return some ctx.resolved.channels[id]

proc opt*(ctx: SlashContext, name: string,
          T: typedesc[Attachment]): Option[Attachment] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotAttachment:
    let id = ctx.options[name].aval
    if ctx.resolved.attachments.hasKey(id):
      return some ctx.resolved.attachments[id]

proc opt*(ctx: SlashContext, name: string,
          T: typedesc[Mentionable]): Option[Mentionable] =
  if ctx.options.hasKey(name) and ctx.options[name].kind == acotMentionable:
    let id = ctx.options[name].mention_id
    if ctx.resolved.users.hasKey(id):
      return some Mentionable(kind: mkUser, user: ctx.resolved.users[id])
    if ctx.resolved.roles.hasKey(id):
      return some Mentionable(kind: mkRole, role: ctx.resolved.roles[id])

proc req*[T](ctx: SlashContext, name: string, t: typedesc[T]): T =
  ## Required-option variant: raises `DimslashError` when the option is
  ## missing or unresolvable. Discord enforces required options client-side,
  ## so this only fires on malformed payloads.
  let value = opt(ctx, name, T)
  if value.isNone:
    raise newException(DimslashError,
      "missing or invalid slash option: " & name)
  value.get

# --- Autocomplete -----------------------------------------------------------

proc focusedOption*(options: LeafOptions):
    Option[ApplicationCommandInteractionDataOption] =
  for _, opt in options:
    if opt.focused.get(false):
      return some opt

proc stringValue*(opt: ApplicationCommandInteractionDataOption): Option[string] =
  ## The option's value as text, regardless of underlying type.
  case opt.kind
  of acotStr: some opt.str
  of acotInt: some $opt.ival
  of acotNumber: some $opt.fval
  of acotBool: some $opt.bval
  else: none string

# --- Context-menu targets ---------------------------------------------------

proc targetUser*(i: Interaction): Option[User] =
  if i.data.isSome and i.data.get.interaction_type == idtApplicationCommand and
      i.data.get.kind == atUser:
    let data = i.data.get
    if data.resolved.users.hasKey(data.target_id):
      return some data.resolved.users[data.target_id]

proc targetMember*(i: Interaction): Option[Member] =
  if i.data.isSome and i.data.get.interaction_type == idtApplicationCommand and
      i.data.get.kind == atUser:
    let data = i.data.get
    if data.resolved.members.hasKey(data.target_id):
      var m = data.resolved.members[data.target_id]
      if data.resolved.users.hasKey(data.target_id):
        m.user = data.resolved.users[data.target_id]
      return some m

proc targetMessage*(i: Interaction): Option[Message] =
  if i.data.isSome and i.data.get.interaction_type == idtApplicationCommand and
      i.data.get.kind == atMessage:
    let data = i.data.get
    if data.resolved.messages.hasKey(data.target_id):
      return some data.resolved.messages[data.target_id]

# --- Modal fields -----------------------------------------------------------

proc collectModalFields(components: seq[MessageComponent],
                        fields: var Table[string, string]) =
  ## Recursively collects every `mctTextInput` with a custom_id and value.
  ## Modals nest inputs in action rows and (components v2) label containers.
  for component in components:
    if component.isNil:
      continue
    if component.kind == mctTextInput and
        component.custom_id.isSome and component.value.isSome:
      fields[component.custom_id.get] = component.value.get
    if component.components.len > 0:
      collectModalFields(component.components, fields)
    if component.kind == mctLabel and not component.component.isNil:
      collectModalFields(@[component.component], fields)

proc modalFields*(components: seq[MessageComponent]): Table[string, string] =
  collectModalFields(components, result)

# --- custom_id patterns -----------------------------------------------------

proc isValidCaptureName(name: string): bool =
  if name.len == 0 or name[0] notin IdentStartChars:
    return false
  for c in name:
    if c notin IdentChars:
      return false
  true

proc parseCustomIdPattern*(raw: string): CustomIdPattern =
  ## Parses `"page:{n:int}"`-style patterns. Captures are `{name}` (string)
  ## or `{name:int}`; two captures must be separated by literal text.
  ## Raises `DimslashError` on malformed patterns (the DSL macros run this
  ## at compile time, turning these into compile errors).
  if raw.len == 0:
    raise newException(DimslashError, "custom_id pattern must not be empty")
  result.raw = raw
  var lit = ""
  var i = 0
  while i < raw.len:
    case raw[i]
    of '{':
      let close = raw.find('}', i)
      if close < 0:
        raise newException(DimslashError,
          "unclosed '{' in custom_id pattern: " & raw)
      let inner = raw[i + 1 ..< close]
      var name = inner
      var capture = capString
      let colon = inner.find(':')
      if colon >= 0:
        name = inner[0 ..< colon]
        case inner[colon + 1 .. ^1]
        of "int": capture = capInt
        of "string", "str": capture = capString
        else:
          raise newException(DimslashError,
            "unknown capture type in custom_id pattern: " & inner)
      if not isValidCaptureName(name):
        raise newException(DimslashError,
          "invalid capture name in custom_id pattern: " & inner)
      if lit.len > 0:
        result.segments.add PatternSegment(kind: psLiteral, lit: lit)
        lit = ""
      elif result.segments.len > 0:
        raise newException(DimslashError,
          "adjacent captures need literal text between them: " & raw)
      result.segments.add PatternSegment(kind: psCapture, name: name,
                                         capture: capture)
      i = close + 1
    of '}':
      raise newException(DimslashError,
        "unbalanced '}' in custom_id pattern: " & raw)
    else:
      lit.add raw[i]
      inc i
  if lit.len > 0:
    result.segments.add PatternSegment(kind: psLiteral, lit: lit)

proc hasCaptures*(pattern: CustomIdPattern): bool =
  for seg in pattern.segments:
    if seg.kind == psCapture:
      return true

proc literalPrefixLen*(pattern: CustomIdPattern): int =
  if pattern.segments.len > 0 and pattern.segments[0].kind == psLiteral:
    pattern.segments[0].lit.len
  else:
    0

proc isInteger(s: string): bool =
  if s.len == 0:
    return false
  let start = if s[0] == '-': 1 else: 0
  if start == s.len:
    return false
  for i in start ..< s.len:
    if s[i] notin Digits:
      return false
  true

proc fillPattern*(pattern: CustomIdPattern,
                  args: openArray[string]): string =
  ## Materializes a pattern into a concrete custom_id by substituting the
  ## captures with `args` in order. Raises `DimslashError` on an argument
  ## count mismatch or a non-integer value for an `int` capture.
  var i = 0
  for seg in pattern.segments:
    case seg.kind
    of psLiteral:
      result.add seg.lit
    of psCapture:
      if i >= args.len:
        raise newException(DimslashError,
          "missing value for capture {" & seg.name & "} in pattern: " &
          pattern.raw)
      if seg.capture == capInt and not args[i].isInteger:
        raise newException(DimslashError,
          "capture {" & seg.name & ":int} needs an integer, got: " & args[i])
      result.add args[i]
      inc i
  if i < args.len:
    raise newException(DimslashError,
      "too many capture values for pattern: " & pattern.raw)

proc matchCustomId*(pattern: CustomIdPattern,
                    id: string): Option[Table[string, string]] =
  ## Matches an incoming custom_id against a pattern. Captures are
  ## non-greedy (end at the first occurrence of the following literal)
  ## and must be non-empty; `int` captures must parse as an integer.
  var captures = initTable[string, string]()
  var pos = 0
  for idx, seg in pattern.segments:
    case seg.kind
    of psLiteral:
      if not id.continuesWith(seg.lit, pos):
        return none Table[string, string]
      pos += seg.lit.len
    of psCapture:
      var endPos = id.len
      if idx + 1 < pattern.segments.len:
        # parseCustomIdPattern guarantees the next segment is a literal
        let next = id.find(pattern.segments[idx + 1].lit, pos)
        if next < 0:
          return none Table[string, string]
        endPos = next
      let text = id[pos ..< endPos]
      if text.len == 0:
        return none Table[string, string]
      if seg.capture == capInt and not text.isInteger:
        return none Table[string, string]
      captures[seg.name] = text
      pos = endPos
  if pos != id.len:
    return none Table[string, string]
  some captures
