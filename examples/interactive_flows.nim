## The feature tour: awaitable buttons, confirm/paginate flows,
## checks & cooldowns, a typed modal form, and the embed/rows builders.

import std/[asyncdispatch, os, strutils]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
let handler = newInteractionHandler(discord)

# --- confirm: ask before doing something scary --------------------------------

handler.slash("wipe", "Pretend to delete everything"):
  check ctx.inGuild, "This only works in a server."
  execute:
    # after confirm, reply automatically becomes a followup
    if await ctx.confirm("Really delete **everything**?",
                         yesLabel = "Do it", noLabel = "Never mind"):
      await ctx.reply("Poof. (Not really.)", ephemeral = true)
    else:
      await ctx.reply("Wise choice.", ephemeral = true)

# --- paginate: a whole pager in one call ---------------------------------------

handler.slash("guide", "Browse the guide"):
  cooldown = 10
  execute:
    var pages: seq[Embed]
    for part in 1 .. 5:
      let page = embed:
        title "Guide — part " & $part
        description "Imagine something useful on page " & $part & "."
        color 0x5865F2
        footer "dimslash paginate"
      pages.add page
    await ctx.paginate(pages)

# --- waitForButton: an inline quiz without registered handlers -----------------

handler.slash("quiz", "Answer a quick question"):
  execute:
    let two = ctx.scopedId("quiz:2")
    let four = ctx.scopedId("quiz:4")
    let buttons = rows:
      row:
        button "2", two
        button "4", four
    await ctx.reply("What is 2 + 2?", components = buttons)
    let press = await ctx.waitForButton([two, four], timeout = 30)
    if press.isNone:
      await ctx.reply("Too slow!", ephemeral = true)
    elif press.get.customId == four:
      await press.get.update("Correct! 🎉", components = @[])
    else:
      await press.get.update("Not quite.", components = @[])

# --- modalForm: typed fields, validation, and submit in one block --------------

let feedback = handler.modalForm("feedback:{topic}", "Send feedback"):
  ## Subject
  subject {.maxLen: 100.}: string
  ## Rating (1-5)
  rating {.placeholder: "5".}: int
  ## Anything else?
  detail {.paragraph.}: Option[string]
  check rating in 1 .. 5, "The rating has to be between 1 and 5."
  submit:
    await ctx.reply("Thanks for the " & topic & " feedback! " &
      subject & " → " & repeat("⭐", rating) & " " & detail.get(""),
      ephemeral = true)

handler.slash("feedback", "Tell us what you think"):
  ## what the feedback is about
  topic {.choices: {"the bot": "bot", "the docs": "docs"}.}: string
  execute:
    await ctx.showModal(feedback, topic)

# --- builders: embeds and component rows, declaratively ------------------------

handler.slash("vote", "Start a vote"):
  ## the motion
  motion: string
  execute:
    let card = embed:
      title "Vote: " & motion
      description "You have 60 seconds."
      color 0xFEE75C
      footer "one vote per minute"
    let buttons = rows:
      row:
        button "Aye", "vote:aye", style = bsSuccess
        button "Nay", "vote:nay", style = bsDanger
    await ctx.reply(embeds = @[card], components = buttons)

handler.button("vote:{side}"):
  cooldown = (60, cbUser)
  await ctx.reply(ctx.user.username & " votes " & side, ephemeral = true)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds},
                             content_intent = false)
