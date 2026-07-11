import std/[asyncdispatch, json, options, strutils, tables, unittest]
import dimscord

import ../src/dimslash
import ./helpers

proc invokedBy(i: Interaction, userId: string,
               guildId = ""): Interaction =
  result = i
  result.user = some User(id: userId)
  if guildId.len > 0:
    result.guild_id = some guildId

proc newCheckedHandler(rec: Recorder): InteractionHandler =
  result = newTestHandler(rec)
  result.onError = defaultOnError

suite "UserError / fail":
  test "fail in execute becomes an ephemeral reply, verbatim":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    handler.slash("boom", "Always refuses"):
      execute:
        fail "not today"
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("boom",
      initTable[string, ApplicationCommandInteractionDataOption]()))
    check rec.names == @["createResponse"]
    check rec.calls[0].args["data"]["content"].getStr == "not today"
    check rec.calls[0].args["data"]["flags"].getInt == cast[int]({mfEphemeral})

  test "UserError after a response becomes an ephemeral followup":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    handler.slash("late", "Fails after replying"):
      execute:
        await ctx.reply("partial")
        fail "and then it broke"
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("late",
      initTable[string, ApplicationCommandInteractionDataOption]()))
    check rec.names == @["createResponse", "createFollowup"]
    check rec.calls[1].args["content"].getStr == "and then it broke"
    check rec.calls[1].args["flags"].getInt == cast[int]({mfEphemeral})

suite "check":
  test "short form guards execution with the given message":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("guarded", "Guild only"):
      check ctx.inGuild, "guild only"
      execute:
        inc ran
        await ctx.reply("ok")
    check waitFor handler.handleInteraction(nil,
      mkSlashInteraction("guarded",
        initTable[string, ApplicationCommandInteractionDataOption]()))
    check ran == 0
    check rec.calls[0].args["data"]["content"].getStr == "guild only"
    var inGuild = mkSlashInteraction("guarded",
      initTable[string, ApplicationCommandInteractionDataOption]())
    inGuild.guild_id = some "g1"
    check waitFor handler.handleInteraction(nil, inGuild)
    check ran == 1

  test "short form without a message uses the default":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    handler.slash("nope", "Never passes"):
      check false
      execute:
        await ctx.reply("unreachable")
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("nope",
      initTable[string, ApplicationCommandInteractionDataOption]()))
    check rec.calls[0].args["data"]["content"].getStr ==
      "You cannot use this command right now."

  test "check block sees declared options":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("bet", "Place a bet"):
      ## how much
      amount: int
      check:
        if amount > 100:
          fail "too rich for this table"
      execute:
        inc ran
        await ctx.reply("bet placed")
    check waitFor handler.handleInteraction(nil,
      mkSlashInteraction("bet", toOpts(intOpt("amount", 500))))
    check ran == 0
    check rec.calls[0].args["data"]["content"].getStr ==
      "too rich for this table"
    check waitFor handler.handleInteraction(nil,
      mkSlashInteraction("bet", toOpts(intOpt("amount", 50))))
    check ran == 1

  test "top-level checks are inherited by group subcommands":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("admin", "Admin tools"):
      check ctx.inGuild, "guild only"
      group "user", "User management":
        sub "kick", "Kick someone":
          execute:
            inc ran
            await ctx.reply("kicked")
    check waitFor handler.handleInteraction(nil,
      mkSlashInteraction("admin", toOpts(subOpt("user",
        toOpts(subOpt("kick",
          initTable[string, ApplicationCommandInteractionDataOption]())),
        group = true))))
    check ran == 0
    check rec.calls[0].args["data"]["content"].getStr == "guild only"

suite "cooldown":
  test "second use within the window is refused per user":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("daily", "Claim your daily"):
      cooldown = 60
      execute:
        inc ran
        await ctx.reply("claimed")
    template daily(userId: string): Interaction =
      mkSlashInteraction("daily",
        initTable[string, ApplicationCommandInteractionDataOption]())
        .invokedBy(userId)
    check waitFor handler.handleInteraction(nil, daily("alice"))
    check ran == 1
    check waitFor handler.handleInteraction(nil, daily("alice"))
    check ran == 1
    check rec.calls[1].args["data"]["content"].getStr.contains("cooldown")
    # a different user has their own bucket
    check waitFor handler.handleInteraction(nil, daily("bob"))
    check ran == 2

  test "guild bucket is shared across users":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("raid", "Start a raid"):
      cooldown = (60, cbGuild)
      execute:
        inc ran
        await ctx.reply("raid!")
    template raid(userId: string): Interaction =
      mkSlashInteraction("raid",
        initTable[string, ApplicationCommandInteractionDataOption]())
        .invokedBy(userId, guildId = "g1")
    check waitFor handler.handleInteraction(nil, raid("alice"))
    check waitFor handler.handleInteraction(nil, raid("bob"))
    check ran == 1

  test "cooldown expires":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("quick", "Fast cooldown"):
      cooldown = 0.05
      execute:
        inc ran
        await ctx.reply("ok")
    template quick(): Interaction =
      mkSlashInteraction("quick",
        initTable[string, ApplicationCommandInteractionDataOption]())
        .invokedBy("alice")
    check waitFor handler.handleInteraction(nil, quick())
    waitFor sleepAsync(80)
    check waitFor handler.handleInteraction(nil, quick())
    check ran == 2

  test "a failed check does not consume the cooldown":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.slash("careful", "Guarded and throttled"):
      cooldown = 60
      check ctx.inGuild, "guild only"
      execute:
        inc ran
        await ctx.reply("ok")
    template careful(guildId: string): Interaction =
      mkSlashInteraction("careful",
        initTable[string, ApplicationCommandInteractionDataOption]())
        .invokedBy("alice", guildId)
    check waitFor handler.handleInteraction(nil, careful(""))
    check ran == 0
    check waitFor handler.handleInteraction(nil, careful("g1"))
    check ran == 1

suite "checks and cooldowns on context-menu commands":
  test "user command honors check and cooldown":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.user("Inspect"):
      check ctx.inGuild, "guild only"
      cooldown = 60
      inc ran
      await ctx.reply("inspected")
    var dm = mkUserCommandInteraction("Inspect", "t1", emptyResolved())
    dm.user = some User(id: "alice")
    check waitFor handler.handleInteraction(nil, dm)
    check ran == 0
    check rec.calls[0].args["data"]["content"].getStr == "guild only"
    var inGuild = dm
    inGuild.guild_id = some "g1"
    check waitFor handler.handleInteraction(nil, inGuild)
    check ran == 1
    check waitFor handler.handleInteraction(nil, inGuild)
    check ran == 1

suite "checks and cooldowns on component handlers":
  test "button honors check and cooldown, captures in scope":
    let rec = newRecorder()
    let handler = newCheckedHandler(rec)
    var ran = 0
    handler.button("vote:{n:int}"):
      check n <= 3, "no such option"
      cooldown = 60
      inc ran
      await ctx.reply("ok")
    proc press(id: string): Interaction =
      result = mkComponentInteraction(id)
      result.user = some User(id: "alice")
    check waitFor handler.handleInteraction(nil, press("vote:9"))
    check ran == 0
    check rec.calls[0].args["data"]["content"].getStr == "no such option"
    check waitFor handler.handleInteraction(nil, press("vote:1"))
    check ran == 1
    check waitFor handler.handleInteraction(nil, press("vote:2"))
    check ran == 1  # same user, cooldown shared across the pattern

suite "checkCooldown programmatic use":
  test "raises UserError with remaining time":
    let handler = newTestHandler(newRecorder())
    var i = mkSlashInteraction("x",
      initTable[string, ApplicationCommandInteractionDataOption]())
    i.user = some User(id: "u1")
    let ctx = InteractionContext(handler: handler, interaction: i)
    ctx.checkCooldown("x", 60.0, cbUser)
    expect UserError:
      ctx.checkCooldown("x", 60.0, cbUser)
