import asyncdispatch
import os
import options
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
var handler = newInteractionHandler(discord)

proc actorName(i: Interaction): string =
  if i.member.isSome:
    return i.member.get.user.username
  if i.user.isSome:
    return i.user.get.username
  "unknown"

proc interactionScope(i: Interaction): string =
  let guildId = i.guild_id.get("dm")
  let channelId = i.channel_id.get("unknown")
  "guild=" & guildId & " channel=" & channelId

handler.addSlash("ping", "Replies with pong") do (s: Shard, i: Interaction):
  await handler.reply(i, "pong by=" & actorName(i) & " " & interactionScope(i) & " shard=" & $s.id)

handler.addButton("confirm:delete", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "button clicked by=" & actorName(i) & " shard=" & $s.id)
)

handler.addSelect("pick:role", proc (s: Shard, i: Interaction) {.async.} =
  let picked = selectValues(i)
  await handler.reply(i, "picked=" & $picked & " " & interactionScope(i))
)

handler.addModal("feedback:modal", proc (s: Shard, i: Interaction) {.async.} =
  let feedback = modalValue(i, "feedback")
  await handler.reply(i, "feedback=" & feedback.get("") & " actor=" & actorName(i))
)

handler.addAutocomplete("ping", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-one", input & "-two", input & "-three"])
)

handler.addSlash("search", "Search repositories") do (s: Shard, i: Interaction, query: Option[string], lang: Option[string]):
  let q = query.get("nim")
  let l = lang.get("nim")
  await handler.reply(i, "search q=" & q & " lang=" & l & " actor=" & actorName(i) & " shard=" & $s.id)

handler.addAutocompleteForOption("search", "query", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-bot", input & "-api", input & "-web"])
)

handler.addAutocompleteForOption("search", "lang", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "nim", input & "go", input & "rust"])
)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  try:
    discard await handler.handleInteraction(s, i)
  except HandlerError as e:
    echo "scaffold status: ", e.msg

waitFor discord.startSession(gateway_intents = {giGuilds}, content_intent = false)
