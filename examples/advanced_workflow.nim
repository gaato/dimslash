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

# 1) Typed slash command with optional options
handler.addSlash("ticket", "Create or update a support ticket") do (
  s: Shard,
  i: Interaction,
  title: string,
  priority: Option[string],
  assignee: Option[User]
):
  let p = priority.get("normal")
  let who = if assignee.isSome: assignee.get.username else: "unassigned"
  let actor = actorName(i)
  await handler.reply(
    i,
    "ticket created: title='" & title & "' priority=" & p &
    " assignee=" & who & " actor=" & actor & " " & interactionScope(i) &
    " shard=" & $s.id
  )

# 2) Option-linked autocomplete for each focused option
handler.addAutocompleteForOption("ticket", "title", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & " bug", input & " feature", input & " docs"])
)

handler.addAutocompleteForOption("ticket", "priority", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "low", input & "normal", input & "high"])
)

# 3) Component handlers
handler.addButton("ticket:close", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "ticket closed by=" & actorName(i) & " shard=" & $s.id)
)

handler.addSelect("ticket:category", proc (s: Shard, i: Interaction) {.async.} =
  let values = selectValues(i)
  await handler.reply(i, "category=" & $values & " " & interactionScope(i))
)

# 4) Modal submit handler
handler.addModal("ticket:feedback", proc (s: Shard, i: Interaction) {.async.} =
  let score = modalValue(i, "score").get("?")
  let comment = modalValue(i, "comment").get("(empty)")
  await handler.reply(i, "feedback score=" & score & " comment=" & comment & " actor=" & actorName(i))
)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  try:
    discard await handler.handleInteraction(s, i)
  except HandlerError as e:
    echo "handler error: ", e.msg

waitFor discord.startSession(gateway_intents = {giGuilds}, content_intent = false)
