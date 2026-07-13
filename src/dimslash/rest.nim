## The dimscord-backed `RestBackend` and the handler constructor.
##
## Command GET/PUT go through raw `api.request` with dimslash-built JSON:
## dimscord 1.8.0's own command serializer drops `min_value`/`max_value`/
## `min_length`/`max_length`/`channel_types`, and its autocomplete choice
## type cannot carry float values.

import std/[asyncdispatch, httpclient, json, mimetypes, options, os]
import dimscord
import dimscord/restapi/requester

import ./types, ./context

type
  MessagePayloadTarget* = enum
    ## The Discord endpoint a normalized `MessagePayload` is being encoded for.
    ## The target matters because Components V2 followups have stricter upload
    ## rules than initial responses and message edits.
    mptInitialResponse, mptFollowup, mptEdit

proc messageDataJson*(payload: MessagePayload;
                      target: MessagePayloadTarget): JsonNode =
  ## Encodes dimslash's normalized message payload without inheriting
  ## dimscord's legacy serializer defaults. In particular, Components V2
  ## create requests omit `content` and `embeds` entirely.
  let componentsV2 = mfIsComponentsV2 in payload.flags
  if componentsV2:
    if payload.content.isSome or payload.embeds.len > 0:
      raise newException(DimslashError,
        "Components V2 cannot contain legacy content or embeds")
    if payload.tts:
      raise newException(DimslashError,
        "Components V2 messages cannot be sent as TTS")
    if payload.components.len == 0:
      raise newException(DimslashError,
        "Components V2 requires at least one component")
    if target == mptFollowup and
        (payload.files.len > 0 or payload.attachments.len > 0):
      raise newException(DimslashError,
        "Discord does not accept file uploads in Components V2 followups")

  if target == mptInitialResponse and payload.files.len > 0:
    raise newException(DimslashError,
      "initial interaction responses require Attachment uploads; defer or " &
      "use edit for DiscordFile uploads")

  result = newJObject()

  if target == mptEdit:
    # Edits are replacements. Null/empty legacy fields are also required when
    # converting an existing message to Components V2.
    result["content"] =
      if payload.content.isSome: %payload.content.get else: newJNull()
    result["embeds"] = %payload.embeds
    result["components"] = %payload.components
    result["attachments"] = %payload.attachments
    if componentsV2:
      result["poll"] = newJNull()
  else:
    if payload.content.isSome:
      result["content"] = %payload.content.get
    if payload.embeds.len > 0:
      result["embeds"] = %payload.embeds
    if payload.components.len > 0:
      result["components"] = %payload.components
    if payload.attachments.len > 0:
      result["attachments"] = %payload.attachments

  if payload.allowedMentions.isSome:
    result["allowed_mentions"] = %payload.allowedMentions.get
  if payload.flags != {}:
    result["flags"] = %cast[int](payload.flags)
  if payload.tts:
    result["tts"] = %true

proc uploadFilename(path: string): string =
  result = extractFilename(path)
  if result.len == 0:
    result = path

proc uploadContentType(filename: string; mimeDb: MimeDB): string =
  let ext = splitFile(filename).ext
  if ext.len > 1:
    result = mimeDb.getMimetype(ext[1 .. ^1])
  else:
    result = "application/octet-stream"

proc addUploads*(payload: MessagePayload; data: var JsonNode;
                 mpd: var MultipartData;
                 target: MessagePayloadTarget) =
  ## Adds Discord-compatible multipart file parts and minimal attachment
  ## metadata. This deliberately does not use dimscord's Attachment helper:
  ## that helper serializes the whole inbound Attachment model (including
  ## file bytes and read-only URLs) into `payload_json`.
  if payload.files.len > 0 and payload.attachments.len > 0:
    raise newException(DimslashError,
      "pass uploads as either DiscordFile or Attachment, not both")
  if payload.files.len == 0 and payload.attachments.len == 0:
    return

  mpd = newMultipartData()
  var messageData =
    if target == mptInitialResponse: data["data"]
    else: data
  messageData["attachments"] = newJArray()
  let mimeDb = newMimetypes()

  if payload.files.len > 0:
    for i, file in payload.files:
      if file.isNil or file.name.len == 0:
        raise newException(DimslashError,
          "DiscordFile uploads require a name")
      let filename = uploadFilename(file.name)
      messageData["attachments"].add %*{
        "id": $i,
        "filename": filename
      }
      let body = if file.body.len > 0: file.body else: readFile(file.name)
      mpd.add("files[" & $i & "]", body, filename,
              uploadContentType(filename, mimeDb), useStream = false)
  else:
    for i, attachment in payload.attachments:
      if attachment.isNil or attachment.filename.len == 0:
        raise newException(DimslashError,
          "Attachment uploads require a filename")
      let filename = uploadFilename(attachment.filename)
      var metadata = %*{
        "id": $i,
        "filename": filename
      }
      if attachment.description.isSome:
        metadata["description"] = %attachment.description.get
      messageData["attachments"].add metadata
      let body =
        if attachment.file.len > 0: attachment.file
        else: readFile(attachment.filename)
      mpd.add("files[" & $i & "]", body, filename,
              uploadContentType(filename, mimeDb), useStream = false)

  mpd.add("payload_json", $data, contentType = "application/json")

proc newDimscordBackend*(discord: DiscordClient): RestBackend =
  let api = discord.api
  RestBackend(
    createResponse: proc (interactionId, token: string;
        kind: InteractionResponseType;
        payload: MessagePayload): Future[void] {.async.} =
      var body = %*{
        "type": int kind,
        "data": messageDataJson(payload, mptInitialResponse)
      }
      var mpd: MultipartData
      payload.addUploads(body, mpd, mptInitialResponse)
      discard await api.request(
        "POST", endpointInteractionsCallback(interactionId, token),
        $body, mp = mpd),

    createAutocomplete: proc (interactionId, token: string;
        choices: JsonNode): Future[void] {.async.} =
      discard await api.request(
        "POST",
        endpointInteractionsCallback(interactionId, token),
        $(%*{"type": int irtAutoCompleteResult,
             "data": {"choices": choices}})),

    createModal: proc (interactionId, token: string;
        data: InteractionCallbackDataModal): Future[void] =
      api.interactionResponseModal(interactionId, token, data),

    createFollowup: proc (applicationId, token: string;
        payload: MessagePayload): Future[Message] {.async.} =
      var data = messageDataJson(payload, mptFollowup)
      var mpd: MultipartData
      payload.addUploads(data, mpd, mptFollowup)
      var endpoint = endpointWebhookToken(applicationId, token) & "?wait=true"
      if payload.components.len > 0:
        endpoint &= "&with_components=true"
      result = (await api.request("POST", endpoint, $data, mp = mpd)).newMessage,

    editResponse: proc (applicationId, token, messageId: string;
        payload: MessagePayload): Future[Message] {.async.} =
      var data = messageDataJson(payload, mptEdit)
      var mpd: MultipartData
      payload.addUploads(data, mpd, mptEdit)
      var endpoint = endpointWebhookMessage(applicationId, token, messageId)
      if payload.components.len > 0:
        endpoint &= "?with_components=true"
      result = (await api.request("PATCH", endpoint, $data, mp = mpd)).newMessage,

    getResponse: proc (applicationId, token,
        messageId: string): Future[Message] =
      api.getInteractionResponse(applicationId, token, messageId),

    deleteResponse: proc (applicationId, token,
        messageId: string): Future[void] =
      api.deleteInteractionResponse(applicationId, token, messageId),

    getApplicationId: proc (): Future[string] {.async.} =
      result = (await api.getCurrentApplication()).id,

    getCommands: proc (applicationId, guildId: string): Future[JsonNode] =
      api.request("GET",
        if guildId.len > 0: endpointGuildCommands(applicationId, guildId)
        else: endpointGlobalCommands(applicationId)),

    putCommands: proc (applicationId, guildId: string;
        payload: JsonNode): Future[JsonNode] =
      api.request("PUT",
        (if guildId.len > 0: endpointGuildCommands(applicationId, guildId)
         else: endpointGlobalCommands(applicationId)),
        $payload))

proc newInteractionHandler*(discord: DiscordClient;
                            defaultGuildId = ""): InteractionHandler =
  ## Creates a handler wired to `discord`. Commands without an explicit
  ## `guild =` register to `defaultGuildId` when set, otherwise globally.
  InteractionHandler(
    discord: discord,
    rest: newDimscordBackend(discord),
    registry: newRegistry(),
    defaultGuildId: defaultGuildId,
    onError: defaultOnError)
