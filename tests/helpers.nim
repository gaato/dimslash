## Shared builders for hand-crafting Interaction payloads in tests, plus a
## recording RestBackend so response/sync behavior can be asserted without
## a Discord connection.

import std/[asyncdispatch, json, options, tables]
import dimscord

import ../src/dimslash/types

type
  Recorder* = ref object
    calls*: seq[tuple[name: string, args: JsonNode]]
    cannedCommands*: JsonNode   ## returned by getCommands
    appId*: string

proc newRecorder*(): Recorder =
  Recorder(cannedCommands: newJArray(), appId: "app-id")

proc names*(rec: Recorder): seq[string] =
  for (name, _) in rec.calls:
    result.add name

proc newRecordingBackend*(rec: Recorder): RestBackend =
  result = RestBackend()
  result.createResponse = proc (interactionId, token: string;
      kind: InteractionResponseType;
      data: InteractionCallbackDataMessage): Future[void] {.async.} =
    rec.calls.add ("createResponse", %*{
      "id": interactionId, "token": token, "kind": int kind,
      "data": %data})
  result.createAutocomplete = proc (interactionId, token: string;
      choices: JsonNode): Future[void] {.async.} =
    rec.calls.add ("createAutocomplete", %*{
      "id": interactionId, "token": token, "choices": choices})
  result.createModal = proc (interactionId, token: string;
      data: InteractionCallbackDataModal): Future[void] {.async.} =
    rec.calls.add ("createModal", %*{
      "id": interactionId, "token": token,
      "custom_id": data.custom_id, "title": data.title})
  result.createFollowup = proc (applicationId, token: string;
      payload: MessagePayload): Future[Message] {.async.} =
    rec.calls.add ("createFollowup", %*{
      "appId": applicationId, "token": token,
      "content": payload.content.get(""),
      "flags": cast[int](payload.flags),
      "embeds": payload.embeds.len})
    result = Message(id: "followup-msg")
  result.editResponse = proc (applicationId, token, messageId: string;
      payload: MessagePayload): Future[Message] {.async.} =
    rec.calls.add ("editResponse", %*{
      "appId": applicationId, "token": token, "messageId": messageId,
      "content": payload.content.get(""),
      "embeds": payload.embeds.len})
    result = Message(id: "edited-msg")
  result.getResponse = proc (applicationId, token,
      messageId: string): Future[Message] {.async.} =
    rec.calls.add ("getResponse", %*{"messageId": messageId})
    result = Message(id: "original-msg")
  result.deleteResponse = proc (applicationId, token,
      messageId: string): Future[void] {.async.} =
    rec.calls.add ("deleteResponse", %*{"messageId": messageId})
  result.getApplicationId = proc (): Future[string] {.async.} =
    rec.calls.add ("getApplicationId", newJObject())
    result = rec.appId
  result.getCommands = proc (applicationId,
      guildId: string): Future[JsonNode] {.async.} =
    rec.calls.add ("getCommands", %*{"appId": applicationId,
                                     "guildId": guildId})
    result = rec.cannedCommands
  result.putCommands = proc (applicationId, guildId: string;
      payload: JsonNode): Future[JsonNode] {.async.} =
    rec.calls.add ("putCommands", %*{"appId": applicationId,
                                     "guildId": guildId,
                                     "payload": payload})
    result = payload

proc newTestHandler*(rec: Recorder): InteractionHandler =
  InteractionHandler(rest: newRecordingBackend(rec), registry: newRegistry())

proc emptyResolved*(): ResolvedData =
  ResolvedData()

proc baseInteraction*(data: ApplicationCommandInteractionData): Interaction =
  Interaction(
    id: "interaction-id",
    application_id: "app-id",
    kind: itApplicationCommand,
    token: "interaction-token",
    data: some data,
    version: 1,
    authorizing_integration_owners: initTable[string, JsonNode]()
  )

proc mkSlashData*(name: string,
                  opts: Table[string, ApplicationCommandInteractionDataOption],
                  resolved = emptyResolved()): ApplicationCommandInteractionData =
  ApplicationCommandInteractionData(
    resolved: resolved,
    interaction_type: idtApplicationCommand,
    id: "cmd-id",
    name: name,
    kind: atSlash,
    options: opts
  )

proc mkSlashInteraction*(name: string,
    opts: Table[string, ApplicationCommandInteractionDataOption],
    resolved = emptyResolved()): Interaction =
  result = baseInteraction(mkSlashData(name, opts, resolved))

proc strOpt*(name, value: string,
             focused = false): ApplicationCommandInteractionDataOption =
  ApplicationCommandInteractionDataOption(name: name, kind: acotStr,
    str: value, focused: if focused: some true else: none bool)

proc intOpt*(name: string,
             value: BiggestInt): ApplicationCommandInteractionDataOption =
  ApplicationCommandInteractionDataOption(name: name, kind: acotInt,
    ival: value)

proc subOpt*(name: string,
    children: Table[string, ApplicationCommandInteractionDataOption],
    group = false): ApplicationCommandInteractionDataOption =
  if group:
    ApplicationCommandInteractionDataOption(name: name,
      kind: acotSubCommandGroup, options: children)
  else:
    ApplicationCommandInteractionDataOption(name: name,
      kind: acotSubCommand, options: children)

proc toOpts*(opts: varargs[ApplicationCommandInteractionDataOption]):
    Table[string, ApplicationCommandInteractionDataOption] =
  for opt in opts:
    result[opt.name] = opt

proc mkComponentInteraction*(customId: string,
                             componentType: static MessageComponentType = mctButton,
                             values: seq[string] = @[],
                             resolved = emptyResolved()): Interaction =
  when componentType in {mctSelectMenu, mctUserSelect, mctRoleSelect,
                         mctMentionableSelect, mctChannelSelect}:
    let data = ApplicationCommandInteractionData(
      resolved: resolved,
      interaction_type: idtMessageComponent,
      component_type: componentType,
      values: values,
      custom_id: customId)
  else:
    let data = ApplicationCommandInteractionData(
      resolved: resolved,
      interaction_type: idtMessageComponent,
      component_type: componentType,
      custom_id: customId)
  result = baseInteraction(data)
  result.kind = itMessageComponent

proc mkModalInteraction*(customId: string,
    components: seq[MessageComponent] = @[]): Interaction =
  let data = ApplicationCommandInteractionData(
    resolved: emptyResolved(),
    interaction_type: idtModalSubmit,
    component_type: mctNone,
    custom_id: customId,
    components: components)
  result = baseInteraction(data)
  result.kind = itModalSubmit

proc mkAutocompleteInteraction*(name: string,
    opts: Table[string, ApplicationCommandInteractionDataOption]): Interaction =
  result = mkSlashInteraction(name, opts)
  result.kind = itAutoComplete

proc mkUserCommandInteraction*(name, targetId: string,
                               resolved: ResolvedData): Interaction =
  let data = ApplicationCommandInteractionData(
    resolved: resolved,
    interaction_type: idtApplicationCommand,
    id: "cmd-id", name: name, kind: atUser, target_id: targetId)
  result = baseInteraction(data)

proc mkMessageCommandInteraction*(name, targetId: string,
                                  resolved: ResolvedData): Interaction =
  let data = ApplicationCommandInteractionData(
    resolved: resolved,
    interaction_type: idtApplicationCommand,
    id: "cmd-id", name: name, kind: atMessage, target_id: targetId)
  result = baseInteraction(data)
