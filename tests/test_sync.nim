import std/[asyncdispatch, json, options, tables, unittest]
import dimscord

import ../src/dimslash/[types, dsl, sync]
import ./helpers

proc kitchenHandler(rec: Recorder): InteractionHandler =
  result = newTestHandler(rec)
  result.slash("kitchen", "One of everything"):
    permissions = {permManageGuild}
    nsfw = true
    contexts = {ictGuild, ictBotDm}
    integrations = {aitGuildInstall, aitUserInstall}
    nameLocalizations = {"ja": "キッチン"}
    ## the query
    query {.minLen: 2, maxLen: 50.}: string
    ## how many
    amount {.min: 1, max: 10.}: int = 1
    ## a ratio
    ratio {.min: 0.5, max: 2.5.}: Option[float]
    ## pick one
    category {.choices: {"Books": "books", "Movies": "movies"},
               descLoc: {"ja": "カテゴリ"}.}: Option[string]
    ## where
    place {.channels: {ctGuildText}.}: Option[Channel]
    autocomplete query:
      await ctx.suggest(@[ctx.focusedValue])
    execute:
      discard (query, amount, ratio, category, place)

suite "toCommandJson":
  test "full option fidelity (the fields dimscord drops)":
    let handler = kitchenHandler(newRecorder())
    let payload = toCommandJson(handler.registry.slash["kitchen"])
    check payload["type"].getInt == 1
    check payload["name"].getStr == "kitchen"
    check payload["nsfw"].getBool
    check payload["default_member_permissions"].getStr ==
      $cast[int]({permManageGuild})
    check payload["contexts"] == %[0, 1]
    check payload["integration_types"] == %[0, 1]
    check payload["name_localizations"]["ja"].getStr == "キッチン"

    let opts = payload["options"]
    check opts[0]["name"].getStr == "query"
    check opts[0]["required"].getBool
    check opts[0]["autocomplete"].getBool
    check opts[0]["min_length"].getInt == 2
    check opts[0]["max_length"].getInt == 50
    check opts[1]["min_value"].getInt == 1     # int option → integer JSON
    check opts[1]["max_value"].getInt == 10
    check not opts[1]["required"].getBool      # default ⇒ optional on wire
    check opts[2]["min_value"].getFloat == 0.5
    check opts[3]["choices"][0] == %*{"name": "Books", "value": "books"}
    check opts[3]["description_localizations"]["ja"].getStr == "カテゴリ"
    check opts[4]["channel_types"] == %[0]

  test "group/sub nesting becomes nested options":
    let handler = newTestHandler(newRecorder())
    handler.slash("admin", "Admin tools"):
      group "user", "User management":
        sub "ban", "Ban a user":
          ## why
          reason: Option[string]
          execute: discard reason
      sub "audit", "Audit log":
        execute: discard ctx
    let payload = toCommandJson(handler.registry.slash["admin"])
    let group = payload["options"][0]
    check group["type"].getInt == 2
    check group["name"].getStr == "user"
    check group["options"][0]["type"].getInt == 1
    check group["options"][0]["name"].getStr == "ban"
    check group["options"][0]["options"][0]["name"].getStr == "reason"
    check payload["options"][1]["type"].getInt == 1
    check payload["options"][1]["name"].getStr == "audit"

  test "context-menu commands":
    let handler = newTestHandler(newRecorder())
    handler.user("Inspect"):
      discard ctx
    let payload = toCommandJson(handler.registry.user["Inspect"])
    check payload["type"].getInt == 2
    check payload["name"].getStr == "Inspect"
    check not payload.hasKey("description")

suite "canonicalize":
  test "local payload equals its Discord echo":
    let handler = kitchenHandler(newRecorder())
    let local = newJArray()
    local.add toCommandJson(handler.registry.slash["kitchen"])
    # simulate what Discord sends back: server fields added, defaults
    # materialized differently, floats where we wrote ints
    let echoed = copy(local)
    echoed[0]["id"] = %"111"
    echoed[0]["application_id"] = %"222"
    echoed[0]["version"] = %"333"
    echoed[0]["default_permission"] = %true
    echoed[0]["options"][1]["min_value"] = %1.0
    echoed[0]["options"][2]["required"] = %false
    check canonicalize(local) == canonicalize(echoed)

  test "a real difference is detected":
    let handler = kitchenHandler(newRecorder())
    let local = newJArray()
    local.add toCommandJson(handler.registry.slash["kitchen"])
    let changed = copy(local)
    changed[0]["options"][0]["description"] = %"something else"
    check canonicalize(local) != canonicalize(changed)

  test "command order does not matter":
    let a = %*[{"name": "a", "type": 1, "description": "x"},
               {"name": "b", "type": 1, "description": "y"}]
    let b = %*[{"name": "b", "type": 1, "description": "y"},
               {"name": "a", "type": 1, "description": "x"}]
    check canonicalize(a) == canonicalize(b)

  test "unknown server fields are ignored":
    let a = %*[{"name": "a", "type": 1, "description": "x",
                "some_future_field": {"deep": true}}]
    let b = %*[{"name": "a", "type": 1, "description": "x"}]
    check canonicalize(a) == canonicalize(b)

suite "sameCommands":
  test "app-default integration_types/contexts on the echo are ignored":
    # a user-installable app echoes integration_types [0, 1] and effective
    # contexts even when the command never set them (found in real E2E)
    let handler = newTestHandler(newRecorder())
    handler.slash("plain", "No install settings"):
      execute: discard ctx
    let local = newJArray()
    local.add toCommandJson(handler.registry.slash["plain"])
    let echoed = copy(local)
    echoed[0]["integration_types"] = %[0, 1]
    echoed[0]["contexts"] = %[0, 1, 2]
    check sameCommands(echoed, local)

  test "explicitly set integrations still compare":
    let handler = kitchenHandler(newRecorder())   # sets [0, 1]
    let local = newJArray()
    local.add toCommandJson(handler.registry.slash["kitchen"])
    let echoed = copy(local)
    echoed[0]["integration_types"] = %[0]
    check not sameCommands(echoed, local)
    echoed[0]["integration_types"] = %[1, 0]      # order-insensitive
    check sameCommands(echoed, local)

suite "syncCommands":
  test "no PUT when Discord already matches":
    let rec = newRecorder()
    let handler = kitchenHandler(rec)
    rec.cannedCommands = newJArray()
    rec.cannedCommands.add toCommandJson(handler.registry.slash["kitchen"])
    let results = waitFor handler.syncCommands()
    check results.len == 1
    check not results[0].updated
    check rec.names == @["getApplicationId", "getCommands"]

  test "PUT when something changed":
    let rec = newRecorder()
    let handler = kitchenHandler(rec)
    rec.cannedCommands = %*[]
    let results = waitFor handler.syncCommands()
    check results[0].updated
    check "putCommands" in rec.names

  test "force always PUTs and skips the GET":
    let rec = newRecorder()
    let handler = kitchenHandler(rec)
    let results = waitFor handler.syncCommands(force = true)
    check results[0].updated
    check rec.names == @["getApplicationId", "putCommands"]

  test "commands are grouped per scope":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    handler.slash("global-cmd", "everywhere"):
      execute: discard ctx
    handler.slash("guild-cmd", "one guild"):
      guild = "g1"
      execute: discard ctx
    rec.cannedCommands = %*[]
    discard waitFor handler.syncCommands()
    var putScopes: seq[string]
    for (name, args) in rec.calls:
      if name == "putCommands":
        putScopes.add args["guildId"].getStr
    check putScopes == @["", "g1"]

  test "defaultGuildId applies to unscoped commands":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    handler.defaultGuildId = "home"
    handler.slash("cmd", "somewhere"):
      execute: discard ctx
    rec.cannedCommands = %*[]
    discard waitFor handler.syncCommands()
    check rec.calls[^1].args["guildId"].getStr == "home"

  test "explicit applicationId skips the lookup":
    let rec = newRecorder()
    let handler = kitchenHandler(rec)
    handler.applicationId = "preset"
    discard waitFor handler.syncCommands(force = true)
    check rec.names == @["putCommands"]
    check rec.calls[0].args["appId"].getStr == "preset"
