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

handler.addSlash("ui-demo", "Show button/select/modal UI demo") do (i: Interaction):
  let controls = newActionRow(
    newButton("Open feedback modal", "ui:open_modal", style = bsPrimary),
    newButton("Acknowledge", "ui:ack", style = bsSecondary)
  )

  let menu = newActionRow(
    newSelectMenu("ui:color", @[
      newMenuOption("Red", "red"),
      newMenuOption("Green", "green"),
      newMenuOption("Blue", "blue")
    ], placeholder = "Choose a color")
  )

  await handler.discord.api.interactionResponseMessage(
    i.id,
    i.token,
    kind = irtChannelMessageWithSource,
    response = InteractionCallbackDataMessage(
      content: "UI demo: press a button or pick a color",
      components: @[controls, menu]
    )
  )

handler.addButton("ui:ack", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "acknowledged by " & actorName(i))
)

handler.addButton("ui:open_modal", proc (s: Shard, i: Interaction) {.async.} =
  let titleRow = newActionRow(
    MessageComponent(
      kind: mctTextInput,
      custom_id: some("title"),
      label: some("Title"),
      input_style: some(tisShort),
      placeholder: some("Short title"),
      required: some(true),
      min_length: some(1),
      max_length: some(80)
    )
  )

  let feedbackRow = newActionRow(
    MessageComponent(
      kind: mctTextInput,
      custom_id: some("feedback"),
      label: some("Feedback"),
      input_style: some(tisParagraph),
      placeholder: some("Tell us what you think"),
      required: some(true),
      min_length: some(1),
      max_length: some(400)
    )
  )

  await handler.discord.api.interactionResponseModal(
    i.id,
    i.token,
    response = InteractionCallbackDataModal(
      custom_id: "ui:feedback",
      title: "Feedback Form",
      components: @[titleRow, feedbackRow]
    )
  )
)

handler.addSelect("ui:color", proc (s: Shard, i: Interaction) {.async.} =
  let values = selectValues(i)
  let picked = if values.len > 0: values[0] else: "(none)"
  await handler.reply(i, "selected color: " & picked)
)

handler.addModal("ui:feedback", proc (s: Shard, i: Interaction) {.async.} =
  let title = modalValue(i, "title").get("(missing)")
  let feedback = modalValue(i, "feedback").get("(missing)")
  await handler.reply(i, "thanks " & actorName(i) & " / " & title & " / " & feedback)
)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  try:
    discard await handler.handleInteraction(s, i)
  except HandlerError as e:
    echo "ui demo handler error: ", e.msg

waitFor discord.startSession(gateway_intents = {giGuilds}, content_intent = false)
