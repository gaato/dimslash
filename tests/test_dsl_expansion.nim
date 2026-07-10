import std/[asyncdispatch, json, options, tables, unittest]
import dimscord

import ../src/dimslash/[types, dsl]
import ./helpers

suite "slash block expansion":
  test "options, pragmas, defaults and metadata land in the registry":
    let handler = newTestHandler(newRecorder())
    handler.slash("roll", "Roll some dice"):
      ## number of sides
      sides {.min: 1, max: 1000.}: int = 6
      ## how many dice
      count: Option[int]
      execute:
        discard ctx
        discard sides
        discard count

    let cmd = handler.registry.slash["roll"]
    check cmd.root.kind == snLeaf
    check cmd.root.description == "Roll some dice"
    let sides = cmd.root.options[0]
    check sides.name == "sides"
    check sides.description == "number of sides"
    check sides.kind == acotInt
    check not sides.required        # default value makes it optional
    check sides.minValue.get == 1.0
    check sides.maxValue.get == 1000.0
    let count = cmd.root.options[1]
    check count.name == "count"
    check not count.required
    check count.minValue.isNone

  test "choices, autocomplete flag, and all option types":
    let handler = newTestHandler(newRecorder())
    handler.slash("kitchen", "One of everything"):
      ## query
      query: string
      ## a category
      category {.choices: {"Books": "books", "Movies": "movies"}.}: Option[string]
      ## a number
      level {.choices: {"Low": 1, "High": 10}.}: Option[int]
      ## a ratio
      ratio: Option[float]
      ## yes or no
      flag: Option[bool]
      ## a user
      who: Option[User]
      ## a member
      whom: Option[Member]
      ## a role
      role: Option[Role]
      ## a channel
      channel {.channels: {ctGuildText, ctGuildVoice}.}: Option[Channel]
      ## user or role
      pingable: Option[Mentionable]
      ## a file
      file: Option[Attachment]
      autocomplete query:
        await ctx.suggest(@[ctx.focusedValue])
      execute:
        discard (query, category, level, ratio, flag)
        discard (who, whom, role, channel, pingable, file)

    let opts = handler.registry.slash["kitchen"].root.options
    check opts[0].autocomplete
    check opts[1].choices.len == 2
    check opts[1].choices[0].name == "Books"
    check opts[1].choices[0].value.strVal == "books"
    check opts[2].choices[0].value.intVal == 1
    check opts[3].kind == acotNumber
    check opts[4].kind == acotBool
    check opts[5].kind == acotUser
    check opts[6].kind == acotUser      # Member rides on acotUser
    check opts[7].kind == acotRole
    check opts[8].kind == acotChannel
    check opts[8].channelTypes == @[ctGuildText, ctGuildVoice]
    check opts[9].kind == acotMentionable
    check opts[10].kind == acotAttachment
    check handler.registry.slash["kitchen"].root.autocompleters.hasKey("query")

  test "command settings populate the meta":
    let handler = newTestHandler(newRecorder())
    handler.slash("admin", "Admin tools"):
      guild = "123"
      permissions = {permManageGuild}
      nsfw = true
      contexts = {ictGuild}
      integrations = {aitGuildInstall}
      nameLocalizations = {"ja": "かんり"}
      execute:
        discard ctx

    let meta = handler.registry.slash["admin"].meta
    check meta.guildId == "123"
    check meta.permissions.get == {permManageGuild}
    check meta.nsfw
    check meta.contexts.get == {ictGuild}
    check meta.integrations.get == {aitGuildInstall}
    check meta.nameLoc["ja"] == "かんり"

  test "wire-name override and localization pragmas":
    let handler = newTestHandler(newRecorder())
    handler.slash("greet", "Say hi"):
      ## who to greet
      target {.name: "user", nameLoc: {"ja": "ユーザー"}.}: User
      execute:
        discard target
    let opt = handler.registry.slash["greet"].root.options[0]
    check opt.name == "user"
    check opt.nameLoc["ja"] == "ユーザー"

  test "group and sub build the tree":
    let handler = newTestHandler(newRecorder())
    handler.slash("admin", "Admin tools"):
      group "user", "User management":
        sub "ban", "Ban a user":
          ## target
          target: User
          execute:
            discard target
      sub "audit", "Audit log":
        execute:
          discard ctx
    let root = handler.registry.slash["admin"].root
    check root.kind == snGroup
    check root.children["user"].kind == snGroup
    check root.children["user"].children["ban"].options.len == 1
    check root.children["audit"].kind == snLeaf

suite "end-to-end: DSL to dispatch":
  test "typed extraction inside execute":
    let handler = newTestHandler(newRecorder())
    var got = ""
    handler.slash("greet", "Greets someone"):
      ## who
      who: User
      ## how many times
      times: int = 1
      ## shout?
      loud: Option[bool]
      execute:
        got = who.username & ":" & $times & ":" & $loud.isSome

    var resolved = emptyResolved()
    resolved.users["u1"] = User(id: "u1", username: "alice")
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("greet",
      toOpts(ApplicationCommandInteractionDataOption(name: "who",
        kind: acotUser, user_id: "u1")), resolved))
    check got == "alice:1:false"

  test "subcommand execute runs with its own options":
    let handler = newTestHandler(newRecorder())
    var banned = ""
    handler.slash("admin", "Admin tools"):
      group "user", "User management":
        sub "ban", "Ban a user":
          ## reason
          reason: string = "no reason"
          execute:
            banned = reason
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("admin",
      toOpts(subOpt("user",
        toOpts(subOpt("ban", toOpts(strOpt("reason", "spam")))),
        group = true))))
    check banned == "spam"

  test "autocomplete block responds through the context":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    handler.slash("search", "Search"):
      ## query
      query: string
      autocomplete query:
        await ctx.suggest(@[ctx.focusedValue & "!"])
      execute:
        discard query
    check waitFor handler.handleInteraction(nil,
      mkAutocompleteInteraction("search",
        toOpts(strOpt("query", "he", focused = true))))
    check rec.calls[0].args["choices"][0]["name"].getStr == "he!"

  test "user and message command blocks":
    let handler = newTestHandler(newRecorder())
    var seen = ""
    handler.user("Inspect"):
      contexts = {ictGuild}
      seen = "user:" & ctx.target.username
    handler.message("Quote It"):
      seen = "msg:" & ctx.target.content

    check handler.registry.user["Inspect"].meta.contexts.get == {ictGuild}
    var resolved = emptyResolved()
    resolved.users["u1"] = User(id: "u1", username: "bob")
    check waitFor handler.handleInteraction(nil,
      mkUserCommandInteraction("Inspect", "u1", resolved))
    check seen == "user:bob"

    var mresolved = emptyResolved()
    mresolved.messages["m1"] = Message(id: "m1", content: "hi there")
    check waitFor handler.handleInteraction(nil,
      mkMessageCommandInteraction("Quote It", "m1", mresolved))
    check seen == "msg:hi there"

  test "button pattern captures become typed variables":
    let handler = newTestHandler(newRecorder())
    var page = 0
    var action = ""
    handler.button("page:{n:int}"):
      page = n + 1
    handler.modal("form:{kind}"):
      action = kind & ":" & ctx.field("f").get("-")
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("page:41"))
    check page == 42
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("form:bug"))
    check action == "bug:-"

  test "select block sees the values":
    let handler = newTestHandler(newRecorder())
    var picked: seq[string]
    handler.select("pick"):
      picked = ctx.values
    check waitFor handler.handleInteraction(nil,
      mkComponentInteraction("pick", mctSelectMenu, @["a", "b"]))
    check picked == @["a", "b"]

suite "compile-time rejection":
  let handler {.used.} = newTestHandler(newRecorder())

  test "uppercase and overlong names are rejected":
    check not compiles(
      slash(handler, "Bad", "desc") do:
        execute: discard)
    check not compiles(
      slash(handler, "waaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaay-too-long", "d") do:
        execute: discard)

  test "missing execute is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## an option
        x: int)

  test "required option after optional is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## optional first
        a: Option[int]
        ## required second
        b: int
        execute: discard (a, b))

  test "duplicate option is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## one
        x: int
        ## two
        x: string
        execute: discard x)

  test "autocomplete on unknown or choice-bearing option is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## opt
        x: int
        autocomplete y:
          discard
        execute: discard x)
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## opt
        x {.choices: {"a": 1}.}: int
        autocomplete x:
          discard
        execute: discard x)

  test "nested groups and options next to subs are rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        group "a", "d":
          group "b", "d":
            sub "c", "d":
              execute: discard)
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## stray option
        x: int
        sub "s", "d":
          execute: discard)

  test "wrong pragma for type is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## bad
        x {.minLen: 3.}: int
        execute: discard x)
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## bad
        x {.unknownKey: 3.}: int
        execute: discard x)

  test "Option with default is rejected":
    check not compiles(
      slash(handler, "cmd", "desc") do:
        ## bad
        x: Option[int] = 3
        execute: discard x)

  test "malformed custom_id pattern is rejected":
    check not compiles(
      button(handler, "oops:{n") do:
        discard)
    check not compiles(
      button(handler, "x:{a}{b}") do:
        discard)

  test "the do-block forms of valid commands compile":
    check compiles(
      slash(handler, "ok", "desc") do:
        execute: discard)
    check compiles(
      button(handler, "ok:{n:int}") do:
        discard n)
