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

proc mkSlashInteraction(opts: Table[string, ApplicationCommandInteractionDataOption]): Interaction =
  let data = ApplicationCommandInteractionData(
    resolved: emptyResolved(),
    interaction_type: idtApplicationCommand,
    id: "cmd",
    name: "sum",
    guild_id: none(string),
    kind: atSlash,
    options: opts
  )

  Interaction(
    id: "i",
    application_id: "app",
    guild_id: none(string),
    channel_id: none(string),
    locale: none(string),
    guild_locale: none(string),
    kind: itApplicationCommand,
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

suite "slash args":
  test "normalize option names":
    check normalizeOptionName("camelCase") == "camelcase"
    check normalizeOptionName("snake_case") == "snakecase"

  test "extract required int option":
    var opts = initTable[string, ApplicationCommandInteractionDataOption]()
    opts["a"] = ApplicationCommandInteractionDataOption(name: "a", kind: acotInt, ival: 7)
    let i = mkSlashInteraction(opts)

    check requireSlashArg(i, "a", int) == 7

  test "extract optional int option":
    var opts = initTable[string, ApplicationCommandInteractionDataOption]()
    let i = mkSlashInteraction(opts)

    let x = getSlashArg(i, "x", int)
    check x.isNone

  test "focused autocomplete option is extracted":
    var opts = initTable[string, ApplicationCommandInteractionDataOption]()
    opts["query"] = ApplicationCommandInteractionDataOption(
      name: "query",
      kind: acotStr,
      str: "hel",
      focused: some(true)
    )
    let i = mkSlashInteraction(opts)

    check focusedOptionName(i).get("") == "query"
    check focusedOptionValue(i).get("") == "hel"
