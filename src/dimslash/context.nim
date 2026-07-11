## Context objects' behavior: typed accessors on the interaction and
## response helpers that track state so you can't double-respond.
##
## Response flow
## =============
##
## - `reply` sends the initial response; called again (or after `followup`)
##   it automatically becomes a followup, and after `deferReply` it edits
##   the deferred placeholder.
## - `update`/`deferUpdate` (components and modals) edit the message the
##   component sits on instead of sending a new one.
## - `suggest` is the only response an autocomplete handler can send.
##
## All REST traffic goes through `handler.rest`, so everything here is
## testable against a recording backend.

import std/[asyncdispatch, json, monotimes, options, strutils, tables, times]
import dimscord

import ./types, ./extract

# --- Accessors ---------------------------------------------------------------

proc user*(ctx: InteractionContext): User =
  ## The invoking user (in guilds, taken from the member object).
  let i = ctx.interaction
  if i.member.isSome:
    i.member.get.user
  elif i.user.isSome:
    i.user.get
  else:
    User()

proc member*(ctx: InteractionContext): Option[Member] =
  ctx.interaction.member

proc guildId*(ctx: InteractionContext): Option[string] =
  ctx.interaction.guild_id

proc channelId*(ctx: InteractionContext): string =
  ctx.interaction.channel_id.get("")

proc locale*(ctx: InteractionContext): Option[string] =
  ctx.interaction.locale

proc appPermissions*(ctx: InteractionContext): set[PermissionFlags] =
  ctx.interaction.app_permissions

proc inGuild*(ctx: InteractionContext): bool =
  ctx.interaction.guild_id.isSome

proc target*(ctx: UserContext): User =
  ## The user this context-menu command was invoked on.
  let u = ctx.interaction.targetUser
  if u.isNone:
    raise newException(DimslashError, "interaction has no resolved target user")
  u.get

proc targetMember*(ctx: UserContext): Option[Member] =
  ## Guild member data for the target user, when invoked in a guild.
  ctx.interaction.targetMember

proc target*(ctx: MessageContext): Message =
  ## The message this context-menu command was invoked on.
  let m = ctx.interaction.targetMessage
  if m.isNone:
    raise newException(DimslashError, "interaction has no resolved target message")
  m.get

proc customId*(ctx: ComponentContext | ModalContext): string =
  ctx.interaction.data.get.custom_id

proc values*(ctx: ComponentContext): seq[string] =
  ## Raw values picked in a select menu (empty for buttons).
  let data = ctx.interaction.data.get
  if data.component_type in SelectKinds:
    data.values
  else:
    @[]

proc selectedUsers*(ctx: ComponentContext): seq[User] =
  for id in ctx.values:
    let resolved = ctx.interaction.data.get.resolved
    if resolved.users.hasKey(id):
      result.add resolved.users[id]

proc selectedMembers*(ctx: ComponentContext): seq[Member] =
  let resolved = ctx.interaction.data.get.resolved
  for id in ctx.values:
    if resolved.members.hasKey(id):
      var m = resolved.members[id]
      if resolved.users.hasKey(id):
        m.user = resolved.users[id]
      result.add m

proc selectedRoles*(ctx: ComponentContext): seq[Role] =
  let resolved = ctx.interaction.data.get.resolved
  for id in ctx.values:
    if resolved.roles.hasKey(id):
      result.add resolved.roles[id]

proc selectedChannels*(ctx: ComponentContext): seq[ResolvedChannel] =
  let resolved = ctx.interaction.data.get.resolved
  for id in ctx.values:
    if resolved.channels.hasKey(id):
      result.add resolved.channels[id]

proc message*(ctx: ComponentContext): Option[Message] =
  ## The message the clicked component is attached to.
  ctx.interaction.message

proc fields*(ctx: ModalContext): Table[string, string] =
  ## All text-input values of the submitted modal, keyed by custom_id.
  modalFields(ctx.interaction.data.get.components)

proc field*(ctx: ModalContext, customId: string): Option[string] =
  ## One text-input value of the submitted modal.
  let all = ctx.fields
  if all.hasKey(customId):
    return some all[customId]

proc optField*(ctx: ModalContext, customId: string): Option[string] =
  ## Like `field`, but an empty (untouched optional) input becomes `none`.
  let raw = ctx.field(customId)
  if raw.isSome and raw.get.len > 0:
    return raw

proc fieldAsInt*(ctx: ModalContext, customId, label: string): int =
  ## `field` parsed as an integer. Discord can't validate text inputs, so
  ## a non-number raises `UserError` — a polite ephemeral message via the
  ## default error hook. The `modalForm` macro generates these calls for
  ## `int` fields.
  let raw = ctx.field(customId).get("").strip()
  try:
    parseInt(raw)
  except ValueError:
    raise newException(UserError, "\"" & label & "\" must be a whole number.")

proc optFieldAsInt*(ctx: ModalContext, customId, label: string): Option[int] =
  if ctx.field(customId).get("").strip().len == 0:
    return none int
  some ctx.fieldAsInt(customId, label)

proc fieldAsFloat*(ctx: ModalContext, customId, label: string): float =
  ## `field` parsed as a number; raises `UserError` when it doesn't parse.
  let raw = ctx.field(customId).get("").strip()
  try:
    parseFloat(raw)
  except ValueError:
    raise newException(UserError, "\"" & label & "\" must be a number.")

proc optFieldAsFloat*(ctx: ModalContext,
                      customId, label: string): Option[float] =
  if ctx.field(customId).get("").strip().len == 0:
    return none float
  some ctx.fieldAsFloat(customId, label)

proc focusedValue*(ctx: AutocompleteContext): string =
  ## The partial text the user has typed so far, as a string.
  if ctx.options.hasKey(ctx.focusedName):
    ctx.options[ctx.focusedName].stringValue.get("")
  else:
    ""

# --- Response helpers --------------------------------------------------------

const mentionDefault = AllowedMentions(parse: @["users", "roles", "everyone"])
  ## dimscord always serializes allowed_mentions, and an empty object means
  ## "suppress everything" — so the unset default must spell out Discord's
  ## normal parse behavior instead.

proc callbackData(content: string; embeds: seq[Embed];
                  components: seq[MessageComponent];
                  attachments: seq[Attachment];
                  allowedMentions: Option[AllowedMentions];
                  ephemeral, tts: bool): InteractionCallbackDataMessage =
  var flags: set[MessageFlags]
  if ephemeral:
    flags.incl mfEphemeral
  InteractionCallbackDataMessage(
    content: content,
    embeds: embeds,
    components: components,
    attachments: attachments,
    flags: flags,
    tts: if tts: some(true) else: none(bool),
    allowed_mentions: allowedMentions.get(mentionDefault))

proc messagePayload(content: string; embeds: seq[Embed];
                    components: seq[MessageComponent];
                    attachments: seq[Attachment];
                    files: seq[DiscordFile];
                    allowedMentions: Option[AllowedMentions];
                    ephemeral, tts: bool): MessagePayload =
  var flags: set[MessageFlags]
  if ephemeral:
    flags.incl mfEphemeral
  MessagePayload(
    content: some content,
    embeds: embeds,
    components: components,
    attachments: attachments,
    files: files,
    allowedMentions: allowedMentions,
    flags: flags,
    tts: tts)

proc followup*(ctx: InteractionContext; content = "";
               embeds: seq[Embed] = @[];
               components: seq[MessageComponent] = @[];
               attachments: seq[Attachment] = @[];
               files: seq[DiscordFile] = @[];
               allowedMentions = none AllowedMentions;
               ephemeral = false; tts = false): Future[Message] {.async.} =
  ## Sends a followup message (requires an initial response or deferral).
  result = await ctx.handler.rest.createFollowup(
    ctx.interaction.application_id, ctx.interaction.token,
    messagePayload(content, embeds, components, attachments, files,
                   allowedMentions, ephemeral, tts))
  ctx.state = rsResponded

proc edit*(ctx: InteractionContext; content = "";
           embeds: seq[Embed] = @[];
           components: seq[MessageComponent] = @[];
           attachments: seq[Attachment] = @[];
           files: seq[DiscordFile] = @[];
           allowedMentions = none AllowedMentions;
           messageId = "@original"): Future[Message] {.async.} =
  ## Edits the original response (or a followup by id). The message becomes
  ## exactly what you pass: omitted content/embeds/components are cleared.
  result = await ctx.handler.rest.editResponse(
    ctx.interaction.application_id, ctx.interaction.token, messageId,
    messagePayload(content, embeds, components, attachments, files,
                   allowedMentions, ephemeral = false, tts = false))

proc reply*(ctx: InteractionContext; content = "";
            embeds: seq[Embed] = @[];
            components: seq[MessageComponent] = @[];
            attachments: seq[Attachment] = @[];
            files: seq[DiscordFile] = @[];
            allowedMentions = none AllowedMentions;
            ephemeral = false; tts = false) {.async.} =
  ## Replies to the interaction. State-aware: the first call sends the
  ## initial response, after `deferReply` it fills in the placeholder,
  ## and any later call becomes a followup.
  ##
  ## `files` are only supported after a deferral or initial response
  ## (Discord limitation of the initial-response callback in dimscord).
  case ctx.state
  of rsNone:
    await ctx.handler.rest.createResponse(
      ctx.interaction.id, ctx.interaction.token,
      irtChannelMessageWithSource,
      callbackData(content, embeds, components, attachments,
                   allowedMentions, ephemeral, tts))
    ctx.state = rsResponded
  of rsDeferred:
    discard await ctx.edit(content, embeds, components, attachments, files,
                           allowedMentions)
    ctx.state = rsResponded
  of rsResponded:
    discard await ctx.followup(content, embeds, components, attachments,
                               files, allowedMentions, ephemeral, tts)

proc deferReply*(ctx: InteractionContext; ephemeral = false) {.async.} =
  ## Acknowledges the interaction with a loading placeholder; follow with
  ## `reply` (which edits the placeholder) or `followup`.
  if ctx.state != rsNone:
    raise newException(DimslashError, "interaction was already responded to")
  var flags: set[MessageFlags]
  if ephemeral:
    flags.incl mfEphemeral
  await ctx.handler.rest.createResponse(
    ctx.interaction.id, ctx.interaction.token,
    irtDeferredChannelMessageWithSource,
    InteractionCallbackDataMessage(flags: flags,
                                   allowed_mentions: mentionDefault))
  ctx.state = rsDeferred

proc original*(ctx: InteractionContext): Future[Message] =
  ## Fetches the original interaction response.
  ctx.handler.rest.getResponse(
    ctx.interaction.application_id, ctx.interaction.token, "@original")

proc delete*(ctx: InteractionContext; messageId = "@original"): Future[void] =
  ## Deletes the original response (or a followup by id).
  ctx.handler.rest.deleteResponse(
    ctx.interaction.application_id, ctx.interaction.token, messageId)

proc newTextInput*(customId, label: string; style = tisShort;
                   required = true; placeholder = ""; value = "";
                   minLen = 0; maxLen = 0): MessageComponent =
  ## A modal text input, already wrapped in the action row Discord
  ## requires (dimscord has builders for buttons/selects but not these).
  ## Pass the results straight to `showModal`.
  var input = MessageComponent(
    kind: mctTextInput,
    custom_id: some customId,
    label: some label,
    input_style: some style,
    required: some required)
  if placeholder.len > 0:
    input.placeholder = some placeholder
  if value.len > 0:
    input.value = some value
  if minLen > 0:
    input.min_length = some minLen
  if maxLen > 0:
    input.max_length = some maxLen
  MessageComponent(kind: mctActionRow, components: @[input])

proc showModal*(ctx: InteractionContext; customId, title: string;
                components: seq[MessageComponent]) {.async.} =
  ## Opens a modal as the initial response. Not allowed for modal-submit
  ## or autocomplete interactions (Discord rejects those).
  if ctx.state != rsNone:
    raise newException(DimslashError, "interaction was already responded to")
  await ctx.handler.rest.createModal(
    ctx.interaction.id, ctx.interaction.token,
    InteractionCallbackDataModal(custom_id: customId, title: title,
                                 components: components))
  ctx.state = rsResponded

proc formComponents(form: ModalForm): seq[MessageComponent] =
  for f in form.fields:
    result.add newTextInput(f.customId, f.label, f.style, f.required,
                            f.placeholder, f.value, f.minLen, f.maxLen)

proc showModal*(ctx: InteractionContext; form: ModalForm;
                captures: varargs[string, `$`]): Future[void] =
  ## Opens a modal declared with the `modalForm` macro. `captures` fill
  ## the form pattern's `{...}` captures in declaration order (they may
  ## be any `$`-able values); a count or type mismatch raises
  ## `DimslashError`.
  let customId = fillPattern(parseCustomIdPattern(form.pattern), captures)
  ctx.showModal(customId, form.title, form.formComponents)

proc update*(ctx: ComponentContext | ModalContext; content = "";
             embeds: seq[Embed] = @[];
             components: seq[MessageComponent] = @[];
             attachments: seq[Attachment] = @[];
             allowedMentions = none AllowedMentions) {.async.} =
  ## Edits the message the component/modal came from instead of sending a
  ## new one. After `deferUpdate` this edits the original message via REST.
  case ctx.state
  of rsNone:
    await ctx.handler.rest.createResponse(
      ctx.interaction.id, ctx.interaction.token,
      irtUpdateMessage,
      callbackData(content, embeds, components, attachments,
                   allowedMentions, ephemeral = false, tts = false))
    ctx.state = rsResponded
  of rsDeferred:
    discard await ctx.edit(content, embeds, components, attachments,
                           allowedMentions = allowedMentions)
    ctx.state = rsResponded
  of rsResponded:
    raise newException(DimslashError, "interaction was already responded to")

proc deferUpdate*(ctx: ComponentContext | ModalContext) {.async.} =
  ## Acknowledges a component interaction without any visible change;
  ## follow with `update` or `edit`.
  if ctx.state != rsNone:
    raise newException(DimslashError, "interaction was already responded to")
  await ctx.handler.rest.createResponse(
    ctx.interaction.id, ctx.interaction.token,
    irtDeferredUpdateMessage,
    InteractionCallbackDataMessage(allowed_mentions: mentionDefault))
  ctx.state = rsDeferred

# --- Autocomplete responses --------------------------------------------------

proc suggestRaw(ctx: AutocompleteContext, choices: JsonNode) {.async.} =
  if ctx.state != rsNone:
    raise newException(DimslashError, "autocomplete was already responded to")
  var trimmed = choices
  if choices.len > 25:
    trimmed = newJArray()
    for i in 0 ..< 25:
      trimmed.add choices[i]
  await ctx.handler.rest.createAutocomplete(
    ctx.interaction.id, ctx.interaction.token, trimmed)
  ctx.state = rsResponded

proc suggest*(ctx: AutocompleteContext,
              choices: seq[ApplicationCommandOptionChoice]): Future[void] =
  ## Sends autocomplete suggestions. Only the first 25 are sent
  ## (Discord's hard limit).
  var arr = newJArray()
  for c in choices:
    var node = %*{"name": c.name}
    if c.value[0].isSome:
      node["value"] = %c.value[0].get
    elif c.value[1].isSome:
      node["value"] = %c.value[1].get
    arr.add node
  ctx.suggestRaw(arr)

proc suggest*(ctx: AutocompleteContext, choices: seq[string]): Future[void] =
  ## String suggestions where the label is also the value.
  var arr = newJArray()
  for c in choices:
    arr.add %*{"name": c, "value": c}
  ctx.suggestRaw(arr)

proc suggest*(ctx: AutocompleteContext,
              choices: openArray[(string, string)]): Future[void] =
  ## (label, value) string suggestions.
  var arr = newJArray()
  for (name, value) in choices:
    arr.add %*{"name": name, "value": value}
  ctx.suggestRaw(arr)

proc suggest*(ctx: AutocompleteContext,
              choices: openArray[(string, int)]): Future[void] =
  ## (label, value) integer suggestions.
  var arr = newJArray()
  for (name, value) in choices:
    arr.add %*{"name": name, "value": value}
  ctx.suggestRaw(arr)

proc suggest*(ctx: AutocompleteContext,
              choices: openArray[(string, float)]): Future[void] =
  ## (label, value) number suggestions (raw JSON: dimscord's choice type
  ## cannot represent float values).
  var arr = newJArray()
  for (name, value) in choices:
    arr.add %*{"name": name, "value": value}
  ctx.suggestRaw(arr)

# --- Cooldowns ----------------------------------------------------------------

proc checkCooldown*(ctx: InteractionContext; path: string;
                    seconds: float; bucket: CooldownBucket) =
  ## Enforces one use per `seconds` per bucket, raising `UserError` with
  ## the remaining time when the command is still cooling down. The
  ## `slash`/`user`/`message` macros inject this for `cooldown = …`
  ## settings; call it yourself for programmatic handlers.
  let bucketKey =
    case bucket
    of cbUser: "u:" & ctx.user.id
    of cbGuild: "g:" & ctx.guildId.get("@dm")
    of cbChannel: "c:" & ctx.channelId
    of cbGlobal: "*"
  let key = path & "\31" & bucketKey
  let now = getMonoTime()
  let readyAt = ctx.handler.cooldowns.getOrDefault(key)
  if readyAt > now:
    let remaining = (readyAt - now).inMilliseconds.float / 1000.0
    raise newException(UserError,
      "This command is on cooldown — try again in " &
      remaining.formatFloat(ffDecimal, 1) & "s.")
  ctx.handler.cooldowns[key] =
    now + initDuration(milliseconds = int(seconds * 1000))

# --- Default error hook ------------------------------------------------------

proc defaultOnError*(ctx: InteractionContext, e: ref Exception) {.async.} =
  ## Installed by `newInteractionHandler`: logs to stderr and, if nothing
  ## was sent yet, replies with a generic ephemeral error message.
  ## `UserError` is special-cased: its message goes to the user as an
  ## ephemeral reply (or followup) and nothing is logged.
  ## Set `handler.onError = nil` to let exceptions propagate instead.
  if e of UserError:
    if not (ctx of AutocompleteContext):
      try:
        await ctx.reply(e.msg, ephemeral = true)
      except CatchableError:
        discard
    return
  stderr.writeLine "[dimslash] unhandled exception in handler: " & e.msg
  let trace = e.getStackTrace()
  if trace.len > 0:
    stderr.writeLine trace
  if ctx.state == rsNone and not (ctx of AutocompleteContext):
    try:
      await ctx.reply("Something went wrong while handling this interaction.",
                      ephemeral = true)
    except CatchableError:
      discard
