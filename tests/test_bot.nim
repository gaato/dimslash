import std/[asyncdispatch, json, sequtils, tables, unittest]
import dimscord

import ../src/dimslash
import ./helpers

suite "Bot lifecycle":
  test "newBot owns a dimscord client and keeps handler compatibility":
    let bot = newBot("test-token", defaultGuildId = "guild-1")
    check not bot.isNil
    check not bot.discord.isNil
    check bot.discord.token == "Bot test-token"
    check bot.defaultGuildId == "guild-1"
    check compiles(bot.start())

  test "install syncs once, chains ready, and is idempotent":
    let rec = newRecorder()
    let discord = newDiscordClient("test-token")
    let bot = newInteractionHandler(discord)
    bot.rest = newRecordingBackend(rec)
    var readyCalls = 0
    discord.events.on_ready = proc (s: Shard, r: Ready) {.async.} =
      inc readyCalls
    bot.slash("ping", "Replies with pong"):
      execute:
        await ctx.reply("pong")

    bot.install()
    bot.install()
    waitFor discord.events.on_ready(nil, Ready())
    waitFor discord.events.on_ready(nil, Ready())

    check readyCalls == 2
    check rec.names.count("getApplicationId") == 1
    check rec.names.count("getCommands") == 1
    check rec.names.count("putCommands") == 1

  test "failed sync still chains ready and retries on the next READY":
    let rec = newRecorder()
    let discord = newDiscordClient("test-token")
    let bot = newInteractionHandler(discord)
    bot.rest = newRecordingBackend(rec)
    let getCommands = bot.rest.getCommands
    var getAttempts = 0
    bot.rest.getCommands = proc (applicationId,
        guildId: string): Future[JsonNode] {.async.} =
      inc getAttempts
      if getAttempts == 1:
        raise newException(IOError, "temporary command sync failure")
      result = await getCommands(applicationId, guildId)
    var readyCalls = 0
    discord.events.on_ready = proc (s: Shard, r: Ready) {.async.} =
      inc readyCalls
    bot.slash("ping", "Replies with pong"):
      execute:
        await ctx.reply("pong")

    bot.install()
    expect IOError:
      waitFor discord.events.on_ready(nil, Ready())

    check readyCalls == 1
    check getAttempts == 1
    check bot.readySync.isNil

    waitFor discord.events.on_ready(nil, Ready())

    check readyCalls == 2
    check getAttempts == 2
    check not bot.readySync.isNil
    check bot.readySync.finished

  test "registered interactions are handled and unknown ones are forwarded":
    let rec = newRecorder()
    let discord = newDiscordClient("test-token")
    let bot = newInteractionHandler(discord)
    bot.rest = newRecordingBackend(rec)
    var ran = 0
    var forwarded = 0
    discord.events.interaction_create = proc (s: Shard,
        i: Interaction) {.async.} =
      inc forwarded
    bot.slash("ping", "Replies with pong"):
      execute:
        inc ran
        await ctx.reply("pong")
    bot.install(autoSync = false)

    waitFor discord.events.interaction_create(nil,
      mkSlashInteraction("ping",
        initTable[string, ApplicationCommandInteractionDataOption]()))
    waitFor discord.events.interaction_create(nil,
      mkSlashInteraction("missing",
        initTable[string, ApplicationCommandInteractionDataOption]()))

    check ran == 1
    check forwarded == 1
    check rec.names.count("createResponse") == 1
