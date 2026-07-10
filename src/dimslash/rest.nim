## The dimscord-backed `RestBackend` and the handler constructor.
##
## Command GET/PUT go through raw `api.request` with dimslash-built JSON:
## dimscord 1.8.0's own command serializer drops `min_value`/`max_value`/
## `min_length`/`max_length`/`channel_types`, and its autocomplete choice
## type cannot carry float values.

import std/[asyncdispatch, json, options]
import dimscord
import dimscord/restapi/requester

import ./types, ./context

proc newDimscordBackend*(discord: DiscordClient): RestBackend =
  let api = discord.api
  RestBackend(
    createResponse: proc (interactionId, token: string;
        kind: InteractionResponseType;
        data: InteractionCallbackDataMessage): Future[void] =
      api.interactionResponseMessage(interactionId, token, kind, data),

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
        payload: MessagePayload): Future[Message] =
      api.createFollowupMessage(applicationId, token,
        content = payload.content.get(""),
        tts = payload.tts,
        files = payload.files,
        attachments = payload.attachments,
        embeds = payload.embeds,
        allowed_mentions = payload.allowedMentions,
        components = payload.components,
        flags = payload.flags),

    editResponse: proc (applicationId, token, messageId: string;
        payload: MessagePayload): Future[Message] =
      api.editInteractionResponse(applicationId, token, messageId,
        content = some payload.content.get(""),
        embeds = payload.embeds,
        flags = payload.flags,
        allowed_mentions = payload.allowedMentions,
        attachments = payload.attachments,
        files = payload.files,
        components = payload.components),

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
