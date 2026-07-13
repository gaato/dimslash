import std/[asyncdispatch, enumutils, json, options, sequtils, strutils, tables,
            unittest]

import dimslash

type
  Flavor = enum
    vanilla
    chocolate = "Dark chocolate"
    strawberry
  Servings = range[1 .. 12]
  CustomerId = distinct string
  Priority = distinct int

proc slashInteraction(name: string; options: JsonNode = newJArray()): JsonNode =
  %*{
    "id": "interaction-1",
    "application_id": "application-1",
    "token": "token-1",
    "type": 2,
    "channel_id": "channel-1",
    "user": {"id": "user-1", "username": "alice"},
    "data": {"type": 1, "name": name, "options": options}
  }

proc componentInteraction(customId: string; messageFlags = 0): JsonNode =
  %*{
    "id": "interaction-2",
    "application_id": "application-1",
    "token": "token-2",
    "type": 3,
    "channel_id": "channel-1",
    "user": {"id": "user-1", "username": "alice"},
    "message": {
      "id": "message-1",
      "content": "old",
      "flags": messageFlags,
      "author": {"id": "user-2", "username": "bot"}
    },
    "data": {"component_type": 2, "custom_id": customId}
  }

proc autocompleteInteraction(name, focused: string): JsonNode =
  result = slashInteraction(name, %*[
    {"name": "query", "type": 3, "value": focused, "focused": true}
  ])
  result["type"] = %4

proc modalInteraction(customId: string): JsonNode =
  %*{
    "id": "interaction-3",
    "application_id": "application-1",
    "token": "token-3",
    "type": 5,
    "user": {"id": "user-1", "username": "alice"},
    "data": {
      "custom_id": customId,
      "components": [{
        "type": 1,
        "components": [{
          "type": 4, "custom_id": "reason", "value": "because"
        }]
      }]
    }
  }

proc userCommandInteraction(name: string): JsonNode =
  result = slashInteraction(name)
  result["data"] = %*{
    "type": 2, "name": name, "target_id": "target-user",
    "resolved": {
      "users": {"target-user": {
        "id": "target-user", "username": "target"}},
      "members": {"target-user": {"nick": "target-nick"}}
    }
  }

proc messageCommandInteraction(name: string): JsonNode =
  result = slashInteraction(name)
  result["data"] = %*{
    "type": 3, "name": name, "target_id": "target-message",
    "resolved": {
      "messages": {"target-message": {
        "id": "target-message", "content": "quoted",
        "author": {"id": "author", "username": "author"}
      }}
    }
  }

suite "new public API":
  test "typed command options are extracted from the handler signature":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("greet", "Greets a user",
        proc(ctx: SlashCommandContext;
             name {.description: "Who to greet".}: string;
             count {.min: 1, max: 5.}: int = 1) {.async.} =
          discard await ctx.respond(name.repeat(count)))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    let handled = waitFor binding.dispatch(slashInteraction("greet", %*[
      {"name": "name", "type": 3, "value": "Nim"}
    ]))

    check handled
    check transport.calls.len == 2
    check transport.calls[0].name == "initial"
    check transport.calls[0].data["data"]["content"].getStr == "Nim"
    check transport.calls[1].name == "get"

  test "response operations are explicit after defer":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("work", "Does work",
        proc(ctx: SlashCommandContext) {.async.} =
          await ctx.deferReply(ephemeral = true)
          let edited = await ctx.editOriginal("done")
          check $edited.id == "@original"
          let later = await ctx.followup("more")
          check $later.id == "message-1")
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(slashInteraction("work"))
    check transport.calls.mapIt(it.name) == @[
      "initial", "edit", "followup"]

  test "component captures are typed and update returns a message":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.button("page:{number:int}",
        proc(ctx: ComponentContext) {.async.} =
          let message = await ctx.update("page " & $ctx.captureInt("number"))
          check $message.id == "@original")
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(componentInteraction("page:12"))
    check transport.calls[0].data["data"]["content"].getStr == "page 12"

  test "missing initial response uses the state-safe error action":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("silent", "Returns without responding",
        proc(ctx: SlashCommandContext) {.async.} =
          discard)
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(slashInteraction("silent"))
    check transport.calls[0].name == "initial"
    check transport.calls[0].data["data"]["flags"].getInt == 64

  test "an ambiguous initial response disables further mutations":
    var observed = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("uncertain", "Tests an uncertain response",
        proc(ctx: SlashCommandContext) {.async.} =
          try:
            discard await ctx.respond("hello")
          except ResponseOutcomeUnknownError:
            check ctx.responseState == OutcomeUnknown
            observed = true)
    )
    let transport = newTestTransport()
    transport.failInitialAmbiguously = true
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(slashInteraction("uncertain"))
    check observed

  test "route factory runs exactly once":
    var evaluations = 0
    discard newDiscordApp(proc(routes: var Routes) =
      inc evaluations
      routes.slash("ping", "Replies with pong",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("pong"))
    )
    check evaluations == 1

  test "autocomplete and modal submission use specialized contexts":
    var submitted = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("search", "Searches",
        proc(ctx: SlashCommandContext;
             query {.description: "Query".}: string) {.async.} =
          discard await ctx.respond(query))
      routes.autocomplete("search", "query",
        proc(ctx: AutocompleteContext) {.async.} =
          check ctx.focusedName == "query"
          check ctx.focusedValue == "ni"
          await ctx.complete([choice("Nim", "nim")]))
      routes.modal("report:{number:int}",
        proc(ctx: ModalContext) {.async.} =
          submitted = ctx.fields["reason"] & ":" &
                      $ctx.captureInt("number")
          discard await ctx.respond("received"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check app.commands[0]["options"][0]["autocomplete"].getBool

    check waitFor binding.dispatch(
      autocompleteInteraction("search", "ni"))
    check transport.calls[0].data["data"]["choices"][0]["value"].getStr ==
      "nim"
    check waitFor binding.dispatch(modalInteraction("report:7"))
    check submitted == "because:7"

  test "Components V2 cannot be converted back to classic content":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("v2", "Uses Components V2",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond(componentsV2(@[
            textDisplay("hello")]).messageBody)
          expect InvalidResponseStateError:
            discard await ctx.editOriginal("classic"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(slashInteraction("v2"))

  test "component updates preserve a Components V2 source":
    var rejectedClassic = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.button("continue",
        proc(ctx: ComponentContext) {.async.} =
          try:
            discard await ctx.update("classic")
          except InvalidResponseStateError:
            rejectedClassic = true
          discard await ctx.update(componentsV2(@[
            textDisplay("continued")]).messageBody))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(componentInteraction("continue", 32768))
    check rejectedClassic
    check transport.calls[0].data["data"]["flags"].getInt == 32768

  test "message edits explicitly clear fields while converting to V2":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("convert", "Converts to Components V2",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("legacy")
          discard await ctx.editOriginal(componentsV2(@[
            textDisplay("modern")]).messageBody))
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      slashInteraction("convert"))
    let edit = transport.calls[^1].data
    check edit["content"].kind == JNull
    check edit["embeds"].len == 0
    check edit["attachments"].len == 0
    check edit["poll"].kind == JNull
    check edit["flags"].getInt == 32768

  test "stop quiesces and drains active handlers":
    let gate = newFuture[void]("test gate")
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("wait", "Waits for a gate",
        proc(ctx: SlashCommandContext) {.async.} =
          await gate
          discard await ctx.respond("done"))
    )
    let binding = app.bindForTesting(newTestTransport())
    let dispatch = binding.dispatch(slashInteraction("wait"))
    let stopped = binding.stop()

    check not dispatch.finished
    check not stopped.finished
    check not waitFor binding.dispatch(slashInteraction("wait"))
    gate.complete()
    check waitFor dispatch
    waitFor stopped
    check stopped.finished

  test "stop accepts Dimscord's normal disconnect exception":
    let app = newDiscordApp(proc(routes: var Routes) = discard routes)
    let transport = newTestTransport()
    transport.failStopWithDisconnect = true
    let binding = app.bindForTesting(transport)

    waitFor binding.stop()

  test "an error after responding becomes an explicit followup":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("late-error", "Fails after responding",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("first")
          raise userRejection("second"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)

    check waitFor binding.dispatch(slashInteraction("late-error"))
    check transport.calls.mapIt(it.name) == @["initial", "get", "followup"]
    check transport.calls[^1].data["content"].getStr == "second"

  test "Defects bypass the catchable interaction error policy":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("defect", "Raises a defect",
        proc(ctx: SlashCommandContext) {.async.} =
          raise newException(AssertionDefect, "programmer bug"))
    )
    expect AssertionDefect:
      discard waitFor app.bindForTesting(newTestTransport()).dispatch(
        slashInteraction("defect"))

  test "enum range and distinct options derive schema and values":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("order", "Creates an order",
        proc(ctx: SlashCommandContext;
             flavor {.description: "Flavor".}: Flavor;
             servings {.description: "Servings".}: Servings;
             customer {.description: "Customer".}: CustomerId;
             priority {.description: "Priority".}: Priority) {.async.} =
          received = flavor.symbolName & ":" & $servings & ":" &
                     string(customer) & ":" & $int(priority)
          discard await ctx.respond("ok"))
    )
    let schema = app.commands[0]["options"]
    check schema[0]["choices"][1]["name"].getStr == "Dark chocolate"
    check schema[0]["choices"][1]["value"].getStr == "chocolate"
    check schema[1]["min_value"].getInt == 1
    check schema[1]["max_value"].getInt == 12
    let binding = app.bindForTesting(newTestTransport())
    check waitFor binding.dispatch(slashInteraction("order", %*[
      {"name": "flavor", "type": 3, "value": "chocolate"},
      {"name": "servings", "type": 4, "value": 4},
      {"name": "customer", "type": 3, "value": "customer-42"},
      {"name": "priority", "type": 4, "value": 7}
    ]))
    check received == "chocolate:4:customer-42:7"

  test "resolved options decode into DimSlash-owned models":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("resolve", "Resolves entities",
        proc(ctx: SlashCommandContext;
             who {.description: "User".}: User;
             member {.description: "Member".}: Member;
             role {.description: "Role".}: Role;
             channel {.description: "Channel".}: ResolvedChannel;
             mention {.description: "Mentionable".}: Mentionable;
             file {.description: "Attachment".}: Attachment) {.async.} =
          received = who.username & ":" & member.nickname.get("") & ":" &
                     role.name & ":" & channel.name.get("") & ":" &
                     mention.mentionedRole.name & ":" & file.filename
          discard await ctx.respond("ok"))
    )
    let schema = app.commands[0]["options"]
    check schema.mapIt(it["type"].getInt) == @[6, 6, 8, 7, 9, 11]
    var raw = slashInteraction("resolve", %*[
      {"name": "who", "type": 6, "value": "user-1"},
      {"name": "member", "type": 6, "value": "user-1"},
      {"name": "role", "type": 8, "value": "role-1"},
      {"name": "channel", "type": 7, "value": "channel-1"},
      {"name": "mention", "type": 9, "value": "role-1"},
      {"name": "file", "type": 11, "value": "attachment-1"}
    ])
    raw["data"]["resolved"] = %*{
      "users": {
        "user-1": {"id": "user-1", "username": "alice"}
      },
      "members": {"user-1": {"nick": "ally"}},
      "roles": {"role-1": {"id": "role-1", "name": "admin"}},
      "channels": {
        "channel-1": {"id": "channel-1", "name": "general"}
      },
      "attachments": {
        "attachment-1": {
          "id": "attachment-1", "filename": "report.txt",
          "url": "https://cdn.example/report.txt"
        }
      }
    }
    let binding = app.bindForTesting(newTestTransport())
    check waitFor binding.dispatch(raw)
    check received == "alice:ally:admin:general:admin:report.txt"

  test "choices channel constraints and localizations reach the schema":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("schema", "Tests option metadata",
        proc(ctx: SlashCommandContext;
             category {.description: "Category",
                        choices: {"Books": "books", "Movies": "movies"},
                        nameLoc: {"ja": "カテゴリ"}.}: string;
             destination {.description: "Destination", name: "channel",
                           channels: {GuildText, GuildVoice},
                           descLoc: {"ja": "送信先"}.}:
               Option[ResolvedChannel]) {.async.} =
          discard await ctx.respond(category))
    )
    let options = app.commands[0]["options"]
    check options[0]["choices"].len == 2
    check options[0]["name_localizations"]["ja"].getStr == "カテゴリ"
    check options[1]["name"].getStr == "channel"
    check options[1]["channel_types"].mapIt(it.getInt) == @[0, 2]
    check options[1]["description_localizations"]["ja"].getStr == "送信先"

  test "subcommands and groups share one command schema and route by path":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.subcommand("admin", "Admin tools", "audit", "Audit log",
        proc(ctx: SlashCommandContext) {.async.} =
          received = ctx.commandPath.join("/")
          discard await ctx.respond("audit"))
      routes.groupSubcommand(
        "admin", "Admin tools", "user", "User management",
        "ban", "Ban a user",
        proc(ctx: SlashCommandContext;
             reason {.description: "Reason".}: string = "none") {.async.} =
          received = ctx.commandPath.join("/") & ":" & reason
          discard await ctx.respond("banned"))
    )
    let schema = app.commands[0]
    check schema["name"].getStr == "admin"
    check schema["options"].len == 2
    check schema["options"][0]["name"].getStr == "audit"
    check schema["options"][1]["name"].getStr == "user"
    check schema["options"][1]["options"][0]["name"].getStr == "ban"
    let binding = app.bindForTesting(newTestTransport())
    check waitFor binding.dispatch(slashInteraction("admin", %*[
      {"type": 1, "name": "audit"}
    ]))
    check received == "audit"
    check waitFor binding.dispatch(slashInteraction("admin", %*[
      {"type": 2, "name": "user", "options": [{
        "type": 1, "name": "ban", "options": [{
          "name": "reason", "type": 3, "value": "spam"
        }]
      }]}
    ]))
    check received == "user/ban:spam"

  test "command metadata is configured without coupling routes to scopes":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("admin", "Admin tools",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("ok"))
      routes.configureSlash("admin",
        defaultMemberPermissions = some(32'u64), nsfw = true,
        contexts = some({GuildContext}),
        integrations = some({GuildInstall}),
        nameLocalizations = {"ja": "かんり"}.toTable,
        descriptionLocalizations = {"ja": "管理ツール"}.toTable)
    )
    let schema = app.commands[0]
    check schema["default_member_permissions"].getStr == "32"
    check schema["nsfw"].getBool
    check schema["contexts"].mapIt(it.getInt) == @[0]
    check schema["integration_types"].mapIt(it.getInt) == @[0]
    check schema["name_localizations"]["ja"].getStr == "かんり"
    check schema["description_localizations"]["ja"].getStr == "管理ツール"

  test "classic and V2 action rows support string and entity selects":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("menus", "Shows select menus",
        proc(ctx: SlashCommandContext) {.async.} =
          var message = classicMessage("choose")
          message.rows = @[
            actionRow(selectMenu("language", [
              selectOption("Nim", "nim", description = "Nim language"),
              selectOption("Rust", "rust")
            ], placeholder = "Language")),
            actionRow(channelSelect("channel", {GuildText, GuildVoice}))
          ]
          discard await ctx.respond(message.messageBody))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    check waitFor binding.dispatch(slashInteraction("menus"))
    let components = transport.calls[0].data["data"]["components"]
    check components[0]["components"][0]["type"].getInt == 3
    check components[0]["components"][0]["options"].len == 2
    check components[1]["components"][0]["type"].getInt == 8
    check components[1]["components"][0]["channel_types"].mapIt(
      it.getInt) == @[0, 2]

  test "rich Components V2 serialize their complete nested shape":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("release", "Shows a release card",
        proc(ctx: SlashCommandContext) {.async.} =
          var body = componentsV2(@[
            textDisplay("# Release"),
            section(["Version 2 is ready", "Choose an action"],
              thumbnailAccessory("https://example.com/icon.png",
                                 "Application icon")),
            mediaGallery([
              mediaItem("https://example.com/one.png", "First"),
              mediaItem("attachment://two.png", spoiler = true)
            ]),
            separator(spacing = 2),
            container([
              textDisplay("Inside"),
              v2ActionRow(
                button("Install", "release:install", Success),
                linkButton("Docs", "https://example.com/docs"))
            ], accentColor = some(0x5865F2), spoiler = true)
          ])
          discard await ctx.respond(body.messageBody))
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      slashInteraction("release"))
    let payload = transport.calls[0].data["data"]
    check payload["flags"].getInt == 32768
    check payload["components"].mapIt(it["type"].getInt) ==
      @[10, 9, 12, 14, 17]
    check payload["components"][1]["accessory"]["type"].getInt == 11
    check payload["components"][2]["items"][1]["spoiler"].getBool
    check payload["components"][4]["accent_color"].getInt == 0x5865F2
    check payload["components"][4]["components"][1]["components"].len == 2

  test "select interactions expose resolved entities in selected order":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.select("assignees",
        proc(ctx: ComponentContext) {.async.} =
          let users = ctx.selectedUsers
          let members = ctx.selectedMembers
          received = users.mapIt(it.username).join(",") & ":" &
                     members.mapIt(it.nickname.get("")).join(",")
          discard await ctx.update("selected"))
    )
    var raw = componentInteraction("assignees")
    raw["data"] = %*{
      "component_type": 5,
      "custom_id": "assignees",
      "values": ["user-2", "user-1"],
      "resolved": {
        "users": {
          "user-1": {"id": "user-1", "username": "alice"},
          "user-2": {"id": "user-2", "username": "bob"}
        },
        "members": {
          "user-1": {"nick": "ally"},
          "user-2": {"nick": "bobby"}
        }
      }
    }
    check waitFor app.bindForTesting(newTestTransport()).dispatch(raw)
    check received == "bob,alice:bobby,ally"

  test "typed modal fields use current Label payloads and decode values":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("report", "Opens a report form",
        proc(ctx: SlashCommandContext) {.async.} =
          await ctx.showModal(modalDialog("report:9", "Report",
            textInput("reason", "Reason", ParagraphText,
              description = "Explain what happened", minLength = some(1)),
            textInput("score", "Score", required = false))))
      routes.modal("report:{number:int}",
        proc(ctx: ModalContext;
             reason {.description: "Reason".}: string;
             score {.description: "Score".}: Option[int]) {.async.} =
          received = reason & ":" & $score.get(0) & ":" &
                     $ctx.captureInt("number")
          discard await ctx.respond("received"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    check waitFor binding.dispatch(slashInteraction("report"))
    let modal = transport.calls[0].data["data"]
    check modal["components"][0]["type"].getInt == 18
    check modal["components"][0]["label"].getStr == "Reason"
    check modal["components"][0]["description"].getStr ==
      "Explain what happened"
    check modal["components"][0]["component"]["type"].getInt == 4
    var submission = modalInteraction("report:9")
    submission["data"]["components"] = %*[
      {"type": 18, "component": {
        "type": 4, "custom_id": "reason", "value": "spam"}},
      {"type": 18, "component": {
        "type": 4, "custom_id": "score", "value": "7"}}
    ]
    check waitFor binding.dispatch(submission)
    check received == "spam:7:9"

  test "modal update capability follows its command or component source":
    var commandRejected = false
    var componentUpdated = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.modal("command-modal",
        proc(ctx: ModalContext) {.async.} =
          check ctx.source.get.kind == CommandModalSource
          try:
            discard await ctx.update("invalid")
          except InvalidResponseStateError:
            commandRejected = true
            discard await ctx.respond("separate response"))
      routes.modal("component-modal",
        proc(ctx: ModalContext) {.async.} =
          check ctx.source.get.kind == ComponentModalSource
          check ctx.source.get.message.get.content == "source"
          discard await ctx.update("updated")
          componentUpdated = true)
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    check waitFor binding.dispatch(modalInteraction("command-modal"))
    var componentSubmit = modalInteraction("component-modal")
    componentSubmit["message"] = %*{
      "id": "source-message", "content": "source",
      "author": {"id": "bot", "username": "bot"}
    }
    check waitFor binding.dispatch(componentSubmit)
    check commandRejected
    check componentUpdated
    check transport.calls[^2].name == "initial"
    check transport.calls[^2].data["kind"].getInt == 1
    check transport.calls[^1].name == "get"

  test "message uploads preserve attachment metadata and bytes":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("upload", "Uploads a report",
        proc(ctx: SlashCommandContext) {.async.} =
          var body = classicMessage("report")
          body.files = @[
            uploadedFile("report.txt", "contents", "Daily report")
          ]
          discard await ctx.respond(body.messageBody))
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      slashInteraction("upload"))
    let call = transport.calls[0]
    check call.data["data"]["attachments"][0]["id"].getStr == "0"
    check call.data["data"]["attachments"][0]["filename"].getStr ==
      "report.txt"
    check call.data["data"]["attachments"][0]["description"].getStr ==
      "Daily report"
    check call.files.len == 1
    check call.files[0].content == "contents"

  test "owned embeds retain the classic Discord embed surface":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("embed", "Shows an embed",
        proc(ctx: SlashCommandContext) {.async.} =
          var card = embed("Release", "Version 2", some(0x5865F2))
          card.url = some("https://example.com/release")
          card.timestamp = some("2026-07-13T00:00:00Z")
          card.author = some(embedAuthor("DimSlash",
            "https://example.com", "https://example.com/icon.png"))
          card.footer = some(embedFooter("Footer",
            "https://example.com/footer.png"))
          card.image = some(embedMedia("attachment://release.png"))
          card.thumbnail = some(embedMedia("https://example.com/thumb.png"))
          card.add embedField("Status", "Ready", inline = true)
          var body = classicMessage()
          body.embeds = @[card]
          discard await ctx.respond(body.messageBody))
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      slashInteraction("embed"))
    let card = transport.calls[0].data["data"]["embeds"][0]
    check card["title"].getStr == "Release"
    check card["author"]["name"].getStr == "DimSlash"
    check card["footer"]["icon_url"].getStr.endsWith("footer.png")
    check card["image"]["url"].getStr == "attachment://release.png"
    check card["fields"][0]["inline"].getBool

  test "launchActivity acknowledges once and returns its owned instance":
    var instanceId = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("play", "Launches the Activity",
        proc(ctx: SlashCommandContext) {.async.} =
          let instance = await ctx.launchActivity()
          instanceId = instance.id)
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      slashInteraction("play"))
    check instanceId == "activity-1"
    check transport.calls.mapIt(it.name) == @["launchActivity"]

  test "checks run before deterministic binding-owned cooldowns":
    var now = 1_000'i64
    var ran = 0
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("careful", "Checks then throttles",
        proc(ctx: SlashCommandContext;
             amount {.description: "Amount".}: int) {.async.} =
          inc ran
          discard await ctx.respond("accepted " & $amount))
      routes.checkSlash("careful",
        proc(ctx: SlashCommandContext): Future[CheckDecision] {.async.} =
          if ctx.interaction.guildId.isNone:
            return deny("guild only")
          if requiredOption[int](ctx, "amount") > 100:
            return deny("too large")
          return allow())
      routes.cooldownSlash("careful",
        cooldownRule(500, UserCooldown))
    )
    let binding = app.bindForTesting(newTestTransport(), proc(): int64 = now)
    var request = slashInteraction("careful", %*[
      {"name": "amount", "type": 4, "value": 20}
    ])
    check waitFor binding.dispatch(request)
    check ran == 0
    request["guild_id"] = %"guild-1"
    check waitFor binding.dispatch(request)
    check ran == 1
    check waitFor binding.dispatch(request)
    check ran == 1
    now += 500
    check waitFor binding.dispatch(request)
    check ran == 2

  test "component cooldown keys use the route pattern not its captures":
    var ran = 0
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.button("vote:{number:int}",
        proc(ctx: ComponentContext) {.async.} =
          inc ran
          discard await ctx.respond("vote " &
            $ctx.captureInt("number")))
      routes.checkButton("vote:{number:int}",
        proc(ctx: ComponentContext): Future[CheckDecision] {.async.} =
          if ctx.captureInt("number") > 3: return deny("no such option")
          return allow())
      routes.cooldownButton("vote:{number:int}",
        cooldownRule(60_000))
    )
    let binding = app.bindForTesting(newTestTransport(), proc(): int64 = 0)
    check waitFor binding.dispatch(componentInteraction("vote:9"))
    check ran == 0
    check waitFor binding.dispatch(componentInteraction("vote:1"))
    check ran == 1
    check waitFor binding.dispatch(componentInteraction("vote:2"))
    check ran == 1

  test "short-lived component waiters win before persistent routes":
    var answer = 0
    var persistentRan = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("quiz", "Waits for an answer",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("choose")
          let press = await ctx.waitForButton("quiz:{answer:int}",
                                              timeoutMs = 1_000)
          if press.isSome:
            answer = press.get.captureInt("answer")
            discard await press.get.update("answer " & $answer))
      routes.button("quiz:{answer:int}",
        proc(ctx: ComponentContext) {.async.} =
          persistentRan = true
          discard await ctx.respond("persistent"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    let command = binding.dispatch(slashInteraction("quiz"))
    waitFor sleepAsync(1)
    check not command.finished
    check waitFor binding.dispatch(componentInteraction("quiz:3"))
    check waitFor command
    check answer == 3
    check not persistentRan
    check transport.calls[^2].name == "initial"
    check transport.calls[^2].data["kind"].getInt == 1

  test "waiters filter the invoking user and stop wakes pending flows":
    var settled = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("wait", "Waits for its invoker",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("waiting")
          let press = await ctx.waitForButton("only-me", timeoutMs = 60_000)
          settled = press.isNone)
    )
    let binding = app.bindForTesting(newTestTransport())
    let command = binding.dispatch(slashInteraction("wait"))
    waitFor sleepAsync(1)
    var other = componentInteraction("only-me")
    other["user"] = %*{"id": "user-2", "username": "bob"}
    check not waitFor binding.dispatch(other)
    check not command.finished
    let stopping = binding.stop()
    check waitFor command
    waitFor stopping
    check settled

  test "confirm owns its short-lived buttons and disables them":
    var confirmed = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("confirm", "Asks for confirmation",
        proc(ctx: SlashCommandContext) {.async.} =
          confirmed = await ctx.confirm("Proceed?", timeoutMs = 1_000))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    let command = binding.dispatch(slashInteraction("confirm"))
    waitFor sleepAsync(1)
    let yesId = transport.calls[0].data["data"]["components"][0][
      "components"][0]["custom_id"].getStr
    var press = componentInteraction(yesId)
    press["message"]["id"] = %"@original"
    check waitFor binding.dispatch(press)
    check waitFor command
    check confirmed
    let disabled = transport.calls[^2].data["data"]["components"][0][
      "components"]
    check disabled[0]["disabled"].getBool
    check disabled[1]["disabled"].getBool

  test "paginate updates pages and stop closes its collector":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("pages", "Shows pages",
        proc(ctx: SlashCommandContext) {.async.} =
          await ctx.paginate([
            embed("One", "first"), embed("Two", "second")
          ], timeoutMs = 60_000))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport)
    let command = binding.dispatch(slashInteraction("pages"))
    waitFor sleepAsync(1)
    let nextId = transport.calls[0].data["data"]["components"][0][
      "components"][2]["custom_id"].getStr
    var press = componentInteraction(nextId)
    press["message"]["id"] = %"@original"
    check waitFor binding.dispatch(press)
    waitFor sleepAsync(1)
    check transport.calls[^2].data["data"]["embeds"][0]["title"].getStr ==
      "Two"
    let stopped = binding.stop()
    check waitFor command
    waitFor stopped

  test "modal waiters route one submission before persistent handlers":
    var submitted = ""
    var persistentRan = false
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("form", "Waits for a form",
        proc(ctx: SlashCommandContext) {.async.} =
          await ctx.showModal(modalDialog("flow:4", "Flow",
            textInput("reason", "Reason")))
          let submission = await ctx.waitForModal("flow:{number:int}",
                                                  timeoutMs = 1_000)
          if submission.isSome:
            submitted = submission.get.fields["reason"] & ":" &
                        $submission.get.captureInt("number")
            discard await submission.get.respond("done"))
      routes.modal("flow:{number:int}",
        proc(ctx: ModalContext) {.async.} =
          persistentRan = true
          discard await ctx.respond("persistent"))
    )
    let binding = app.bindForTesting(newTestTransport())
    let command = binding.dispatch(slashInteraction("form"))
    waitFor sleepAsync(1)
    check waitFor binding.dispatch(modalInteraction("flow:4"))
    check waitFor command
    check submitted == "because:4"
    check not persistentRan

  test "disableAll deep-copies interactive V2 descendants":
    let original = @[
      container([
        v2ActionRow(button("Run", "run")),
        section(["Choose"], buttonAccessory(button("Open", "open")))
      ])
    ]
    let disabled = disableAll(original)
    check not original[0].containerComponents[0].interactiveComponents[0].
      button.disabled
    check disabled[0].containerComponents[0].interactiveComponents[0].
      button.disabled
    check disabled[0].containerComponents[1].sectionAccessory.
      accessoryButton.disabled

  test "context accessors preserve guild member locale and permissions":
    var received = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("context", "Reads context",
        proc(ctx: SlashCommandContext) {.async.} =
          received = ctx.user.username & ":" &
            ctx.member.get.nickname.get("") & ":" &
            $ctx.guildId.get & ":" & ctx.locale.get("") & ":" &
            ctx.guildLocale.get("") & ":" &
            $ctx.appPermissions.toUint64 & ":" &
            $ctx.member.get.permissions.get.toUint64
          discard await ctx.respond("ok"))
    )
    var raw = slashInteraction("context")
    raw.delete("user")
    raw["guild_id"] = %"guild-1"
    raw["locale"] = %"ja"
    raw["guild_locale"] = %"en-US"
    raw["app_permissions"] = %"32"
    raw["member"] = %*{
      "user": {"id": "user-1", "username": "alice"},
      "nick": "ally", "permissions": "64"
    }
    check waitFor app.bindForTesting(newTestTransport()).dispatch(raw)
    check received == "alice:ally:guild-1:ja:en-US:32:64"

  test "custom id dispatch prefers exact then longer literal routes":
    var selected = ""
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.button("item:{value}",
        proc(ctx: ComponentContext) {.async.} =
          selected = "generic"
          discard await ctx.respond("generic"))
      routes.button("item:special:{value}",
        proc(ctx: ComponentContext) {.async.} =
          selected = "specific"
          discard await ctx.respond("specific"))
      routes.button("item:special:42",
        proc(ctx: ComponentContext) {.async.} =
          selected = "exact"
          discard await ctx.respond("exact"))
    )
    let binding = app.bindForTesting(newTestTransport())
    check waitFor binding.dispatch(componentInteraction("item:special:7"))
    check selected == "specific"
    check waitFor binding.dispatch(componentInteraction("item:special:42"))
    check selected == "exact"

  test "autocomplete rejects oversized result sets through its safe fallback":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("search", "Searches",
        proc(ctx: SlashCommandContext;
             query {.description: "Query".}: string) {.async.} =
          discard await ctx.respond(query))
      routes.autocomplete("search", "query",
        proc(ctx: AutocompleteContext) {.async.} =
          var choices: seq[Choice]
          for index in 0 .. 25: choices.add choice($index, $index)
          await ctx.complete(choices))
    )
    let transport = newTestTransport()
    check waitFor app.bindForTesting(transport).dispatch(
      autocompleteInteraction("search", "n"))
    check transport.calls.len == 1
    check transport.calls[0].data["data"]["choices"].len == 0

  test "command sync bulk-overwrites every managed scope authoritatively":
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.slash("ping", "Replies with pong",
        proc(ctx: SlashCommandContext) {.async.} =
          discard await ctx.respond("pong"))
    )
    let transport = newTestTransport()
    let binding = app.bindForTesting(transport,
      managedScopes = @[globalScope(), guildScope(GuildId("guild-1"))])
    let first = waitFor binding.syncCommands()
    check first.len == 2
    check first.mapIt(it.commandCount) == @[1, 1]
    check transport.calls.mapIt(it.name) == @[
      "resolveApplicationId", "putCommands", "putCommands"]
    check transport.calls[1].data["scope"].getStr == "global"
    check transport.calls[2].data["guild_id"].getStr == "guild-1"
    discard waitFor binding.syncCommands()
    check transport.calls.countIt(it.name == "resolveApplicationId") == 1

    let emptyApp = newDiscordApp(proc(routes: var Routes) = discard)
    let clearing = newTestTransport()
    let emptyBinding = emptyApp.bindForTesting(clearing,
      managedScopes = @[guildScope(GuildId("guild-2"))])
    discard waitFor emptyBinding.syncCommands()
    check clearing.calls[^1].data["commands"].len == 0

  test "context menu routes expose owned targets and share policies":
    var received: seq[string]
    let app = newDiscordApp(proc(routes: var Routes) =
      routes.userCommand("Inspect",
        proc(ctx: UserCommandContext) {.async.} =
          received.add ctx.target.username & ":" &
            ctx.targetMember.get.nickname.get("")
          discard await ctx.respond("inspected"))
      routes.checkUserCommand("Inspect",
        proc(ctx: UserCommandContext): Future[CheckDecision] {.async.} =
          return allow())
      routes.cooldownUserCommand("Inspect", cooldownRule(1_000))
      routes.messageCommand("Quote",
        proc(ctx: MessageCommandContext) {.async.} =
          received.add ctx.target.content
          discard await ctx.respond("quoted"))
    )
    let binding = app.bindForTesting(newTestTransport(), proc(): int64 = 0)
    check waitFor binding.dispatch(userCommandInteraction("Inspect"))
    check waitFor binding.dispatch(userCommandInteraction("Inspect"))
    check waitFor binding.dispatch(messageCommandInteraction("Quote"))
    check received == @["target:target-nick", "quoted"]

  test "route registration validates context names and raw cooldown rules":
    let unicodeName = repeat("調", 32)
    discard newDiscordApp(proc(routes: var Routes) =
      routes.userCommand(unicodeName,
        proc(ctx: UserCommandContext) {.async.} =
          discard await ctx.respond("ok"))
    )

    expect RouteDefinitionError:
      discard newDiscordApp(proc(routes: var Routes) =
        routes.userCommand("   ",
          proc(ctx: UserCommandContext) {.async.} =
            discard await ctx.respond("no"))
      )
    expect RouteDefinitionError:
      discard newDiscordApp(proc(routes: var Routes) =
        routes.messageCommand(repeat("x", 33),
          proc(ctx: MessageCommandContext) {.async.} =
            discard await ctx.respond("no"))
      )
    expect RouteDefinitionError:
      discard newDiscordApp(proc(routes: var Routes) =
        routes.slash("limited", "Limited command",
          proc(ctx: SlashCommandContext) {.async.} =
            discard await ctx.respond("ok"))
        routes.cooldownSlash("limited",
          CooldownRule(durationMs: 0, scope: UserCooldown))
      )
