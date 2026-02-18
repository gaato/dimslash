import std/[unittest, options, tables, asyncdispatch]
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

suite "scaffold dispatch":
  test "button registration via do syntax":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    handler.addButton("confirm:delete") do:
      let marker = 1
      discard marker

    let cmd = handler.registry.find(ckButton, "confirm:delete")
    check cmd.name == "confirm:delete"

  test "button component dispatches callback":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    var called = false
    handler.addButton("confirm:delete", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      called = true
    )

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtMessageComponent,
      component_type: mctButton,
      custom_id: "confirm:delete",
      components: @[]
    )
    let i = baseInteraction(itMessageComponent, data)

    discard waitFor handler.handleInteraction(nil, i)
    check called

  test "select component dispatches callback":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    var called = false
    handler.addSelect("pick:role", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      called = true
    )

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtMessageComponent,
      component_type: mctSelectMenu,
      values: @["123"],
      custom_id: "pick:role",
      components: @[]
    )
    let i = baseInteraction(itMessageComponent, data)

    discard waitFor handler.handleInteraction(nil, i)
    check called

  test "modal submit dispatches callback":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    var called = false
    handler.addModal("feedback:modal", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      called = true
    )

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtModalSubmit,
      component_type: mctNone,
      custom_id: "feedback:modal",
      components: @[]
    )
    let i = baseInteraction(itModalSubmit, data)

    discard waitFor handler.handleInteraction(nil, i)
    check called

  test "autocomplete dispatches callback":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    var called = false
    handler.addAutocomplete("sum", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      called = true
    )

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtApplicationCommand,
      id: "cmd",
      name: "sum",
      guild_id: none(string),
      kind: atSlash,
      options: initTable[string, ApplicationCommandInteractionDataOption]()
    )
    let i = baseInteraction(itAutoComplete, data)

    discard waitFor handler.handleInteraction(nil, i)
    check called

  test "autocomplete dispatches option-specific handler":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    var calledQuery = false
    var calledFallback = false

    handler.addAutocomplete("sum", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      calledFallback = true
    )

    handler.addAutocomplete("sum", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      calledQuery = true
    , optionName = "query")

    var opts = initTable[string, ApplicationCommandInteractionDataOption]()
    opts["query"] = ApplicationCommandInteractionDataOption(
      name: "query",
      kind: acotStr,
      str: "ab",
      focused: some(true)
    )

    let data = ApplicationCommandInteractionData(
      resolved: emptyResolved(),
      interaction_type: idtApplicationCommand,
      id: "cmd",
      name: "sum",
      guild_id: none(string),
      kind: atSlash,
      options: opts
    )
    let i = baseInteraction(itAutoComplete, data)

    discard waitFor handler.handleInteraction(nil, i)
    check calledQuery
    check not calledFallback

  test "autocomplete option link requires known slash option":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )

    handler.addSlash("sum", "Adds") do (i: Interaction, query: string):
      discard

    handler.addAutocompleteForOption("sum", "query", proc (s: Shard, i: Interaction): Future[void] {.async.} =
      discard
    )

    expect ValueError:
      handler.addAutocompleteForOption("sum", "unknown", proc (s: Shard, i: Interaction): Future[void] {.async.} =
        discard
      )
