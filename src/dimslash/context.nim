## Convenience helpers for responding to Discord interactions.
##
## These procs wrap the low-level dimscord REST calls so you don't have to
## remember which `interactionResponseMessage` kind or endpoint to use.
##
## Response flow cheat-sheet
## =========================
##
## =======================  ================================================
## Scenario                 What to call
## =======================  ================================================
## Quick reply (< 3 s)      ``reply(handler, i, content)``
## Deferred reply (> 3 s)   ``deferResponse(handler, i)`` then ``followup``
## Follow-up messages       ``followup(handler, i, content)`` (repeatable)
## Autocomplete results     ``suggest(handler, i, choices)``
## =======================  ================================================
##
## .. Note:: Discord requires a response within 3 seconds.  If your
##    handler does heavy work, call `deferResponse` immediately, then
##    send the real content with `followup`.
##
## Full example
## ============
##
## .. code-block:: nim
##   handler.addSlash("slow", "Deferred example") do (i: Interaction):
##     await handler.deferResponse(i)         # shows "thinking…"
##     # ... expensive work (e.g. database query) ...
##     discard await handler.followup(i, "Done!")
##     discard await handler.followup(i, "Here is another message")

import std/[asyncdispatch, options]

import dimscord
import ./types

proc reply*(handler: InteractionHandler, i: Interaction, content: string): Future[void] {.async.} =
  ## Sends an immediate visible reply to the interaction.
  ##
  ## This corresponds to `irtChannelMessageWithSource`.
  ## You **must** call this within 3 seconds of receiving the interaction,
  ## otherwise Discord will show "The application did not respond".
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("greet", "Says hi") do (i: Interaction):
  ##     await handler.reply(i, "Hi there!")
  await handler.discord.api.interactionResponseMessage(
    i.id,
    i.token,
    kind = irtChannelMessageWithSource,
    response = InteractionCallbackDataMessage(content: content)
  )

proc deferResponse*(handler: InteractionHandler, i: Interaction): Future[void] {.async.} =
  ## Acknowledges the interaction and shows a "thinking…" indicator.
  ##
  ## Use this when your handler needs more than 3 seconds to produce a
  ## response.  Follow up later with `followup`.
  ##
  ## .. code-block:: nim
  ##   handler.addSlash("slow", "Takes a while") do (i: Interaction):
  ##     await handler.deferResponse(i)
  ##     # ... long-running work ...
  ##     discard await handler.followup(i, "All done!")
  await handler.discord.api.interactionResponseMessage(
    i.id,
    i.token,
    kind = irtDeferredChannelMessageWithSource,
    response = nil
  )

proc followup*(handler: InteractionHandler, i: Interaction, content: string): Future[Message] {.async.} =
  ## Sends a follow-up message after the initial response or deferral.
  ##
  ## Returns the `Message` object created by Discord.
  ## You can call this multiple times to send several follow-up messages.
  ##
  ## .. code-block:: nim
  ##   await handler.deferResponse(i)
  ##   discard await handler.followup(i, "Step 1 complete")
  ##   discard await handler.followup(i, "Step 2 complete")
  result = await handler.discord.api.createFollowupMessage(
    i.application_id,
    i.token,
    content = content
  )

proc suggest*(handler: InteractionHandler, i: Interaction,
              choices: seq[ApplicationCommandOptionChoice]): Future[void] {.async.} =
  ## Responds to an autocomplete interaction with the given choices.
  ##
  ## Discord allows up to **25 choices** per autocomplete response.
  ## Each `ApplicationCommandOptionChoice` specifies a `name` (shown to
  ## the user) and a `value` (sent back when selected).
  ##
  ## .. code-block:: nim
  ##   handler.addAutocomplete("search") do:
  ##     var choices: seq[ApplicationCommandOptionChoice]
  ##     choices.add ApplicationCommandOptionChoice(
  ##       name: "Nim", value: (some("nim"), none(int)))
  ##     choices.add ApplicationCommandOptionChoice(
  ##       name: "Go",  value: (some("go"),  none(int)))
  ##     await handler.suggest(i, choices)
  await handler.discord.api.interactionResponseAutocomplete(
    i.id,
    i.token,
    InteractionCallbackDataAutocomplete(choices: choices)
  )

proc suggest*(handler: InteractionHandler, i: Interaction,
              choices: seq[string]): Future[void] {.async.} =
  ## Convenience overload: maps each string to a choice where
  ## `name == value`.
  ##
  ## This is the simplest way to provide autocomplete suggestions:
  ##
  ## .. code-block:: nim
  ##   handler.addAutocomplete("search") do:
  ##     let partial = focusedOptionValue(i).get("")
  ##     await handler.suggest(i, @[partial & "-one", partial & "-two"])
  var mapped: seq[ApplicationCommandOptionChoice] = @[]
  for choice in choices:
    mapped.add ApplicationCommandOptionChoice(
      name: choice,
      value: (some(choice), none(int))
    )
  await handler.suggest(i, mapped)
