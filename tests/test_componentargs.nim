import std/[unittest, options, tables]
import json
import dimscord
import ../src/dimslash

proc emptyResolved(): ResolvedData =
  ResolvedData(
    users: initTable[string, User](),
    attachments: initTable[string, Attachment](),
    members: initTable[string, Member](),
    roles: initTable[string, Role](),
    channels: initTable[string, ResolvedChannel](),
    messages: initTable[string, Message]()
  )

proc baseInteraction(kind: InteractionType, data: ApplicationCommandInteractionData): Interaction =
  Interaction(
    id: "i",
    application_id: "app",
    guild_id: none(string),
    channel_id: none(string),
    locale: none(string),
    guild_locale: none(string),
    kind: kind,
    message: none(Message),
    member: none(Member),
    user: none(User),
    app_permissions: {},
    token: "tok",
    data: some(data),
    version: 1,
    entitlements: @[],
    authorizing_integration_owners: initTable[string, JsonNode](),
    context: none(InteractionContextType),
    attachment_size_limit: 0
  )

suite "componentargs":
  test "select values are extracted":
    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtMessageComponent,
      component_type: mctSelectMenu,
      values: @["a", "b"],
      custom_id: "pick",
      components: @[]
    )
    let i = baseInteraction(itMessageComponent, data)
    check selectValues(i) == @["a", "b"]
    check customId(i).get("") == "pick"

  test "modal values are extracted":
    let textInput = MessageComponent(
      kind: mctTextInput,
      custom_id: some("feedback"),
      value: some("great")
    )
    let row = MessageComponent(kind: mctActionRow, components: @[textInput])

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtModalSubmit,
      component_type: mctNone,
      custom_id: "feedback:modal",
      components: @[row]
    )
    let i = baseInteraction(itModalSubmit, data)

    let values = modalValues(i)
    check values.hasKey("feedback")
    check values["feedback"] == "great"
    check modalValue(i, "feedback").get("") == "great"
