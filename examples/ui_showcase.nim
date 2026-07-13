## Buttons, select menus, embeds, message updates, and modals in one bot.

import std/[asyncdispatch, os, strformat, strutils]
import dimscord
import dimslash

let token = getEnv("DISCORD_TOKEN")
let discord = newDiscordClient(token)
let handler = newInteractionHandler(discord)

# A pager built from registered pattern buttons: stateless, so it keeps
# working across bot restarts. For a session-scoped pager in one call,
# see `ctx.paginate` in examples/interactive_flows.nim.
const pages = [
  "Page one: welcome!",
  "Page two: the middle.",
  "Page three: the end."
]

proc pager(page: int): seq[MessageComponent] =
  @[newActionRow(
    newButton("◀", fmt"pager:{page - 1}", disabled = page <= 0),
    newButton("▶", fmt"pager:{page + 1}", disabled = page >= pages.high))]

handler.slash("pages", "A paginated message"):
  execute:
    await ctx.reply(pages[0], components = pager(0))

handler.button("pager:{page:int}"):
  await ctx.update(pages[page], components = pager(page))

handler.slash("poll", "Start a quick poll"):
  ## the question
  question: string
  execute:
    await ctx.reply("**" & question & "**",
      components = @[newActionRow(
        newButton("Yes", "poll:yes", bsSuccess),
        newButton("No", "poll:no", bsDanger))])

handler.button("poll:{answer}"):
  await ctx.reply(ctx.user.username & " voted " & answer, ephemeral = true)

handler.slash("pick", "Pick your favorites"):
  execute:
    await ctx.reply("Choose up to two:",
      components = @[newActionRow(
        newSelectMenu("fruit_picker", @[
          newMenuOption("Apple", "apple"),
          newMenuOption("Banana", "banana"),
          newMenuOption("Cherry", "cherry")
        ], placeholder = "Fruits...", minValues = 1, maxValues = 2))])

handler.select("fruit_picker"):
  await ctx.update("You picked: " & ctx.values.join(", "),
                   components = @[])

handler.slash("embed", "Reply with an embed"):
  ## the title
  title: string
  execute:
    await ctx.reply(embeds = @[Embed(
      title: some title,
      description: some "Made with dimslash",
      color: some 0x5865F2)])

handler.slash("layout", "Show a Components V2 layout"):
  execute:
    let release = layout:
      text "# Version 2.0"
      section:
        text "The new build is ready."
        thumbnail "https://nim-lang.org/assets/img/logo.svg",
          desc = "Nim logo"
      separator spacing = 2
      container accent = 0x5865F2:
        text "Choose an action"
        row:
          button "Install", "release:install", style = bsSuccess
          linkButton "Nim", "https://nim-lang.org/"
    await ctx.reply(release)

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds},
                             content_intent = false)
