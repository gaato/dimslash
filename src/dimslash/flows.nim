## Ready-made interaction flows built on the waiters in `wait`:
## a yes/no confirmation and an embed paginator.
##
## .. code-block:: nim
##   handler.slash("wipe", "Delete everything"):
##     execute:
##       if await ctx.confirm("Really delete everything?"):
##         await ctx.followup("Gone.", ephemeral = true)
##
## Both flows stay resident (async, not blocking the dispatcher) until
## they finish or time out, and disable their buttons when done.
## Interaction tokens expire after 15 minutes — keep timeouts below that.

import std/[asyncdispatch, options]
import dimscord

import ./types, ./extract, ./context, ./wait

const interactiveKinds = {mctButton, mctTextInput} + SelectKinds

proc disableAll*(components: seq[MessageComponent]): seq[MessageComponent] =
  ## A deep copy of `components` with every button, select, and text
  ## input disabled. Containers (action rows, sections, labels) are
  ## descended into; the originals are left untouched.
  for component in components:
    if component.isNil:
      result.add component
      continue
    var copy = new MessageComponent
    copy[] = component[]
    if copy.kind in interactiveKinds:
      copy.disabled = some true
    if copy.components.len > 0:
      copy.components = disableAll(copy.components)
    if copy.kind == mctLabel and not copy.component.isNil:
      copy.component = disableAll(@[copy.component])[0]
    if copy.kind == mctSection and not copy.accessory.isNil:
      copy.accessory = disableAll(@[copy.accessory])[0]
    result.add copy

proc sendFlowMessage(ctx: InteractionContext; content: string;
                     embeds: seq[Embed]; components: seq[MessageComponent];
                     ephemeral: bool): Future[string] {.async.} =
  ## Sends via the reply state machine and returns the id `edit` needs to
  ## reach the message later ("@original" or a followup id).
  if ctx.state == rsResponded:
    let msg = await ctx.followup(content, embeds = embeds,
                                 components = components,
                                 ephemeral = ephemeral)
    return msg.id
  await ctx.reply(content, embeds = embeds, components = components,
                  ephemeral = ephemeral)
  return "@original"

proc confirm*(ctx: InteractionContext; prompt: string;
              yesLabel = "Yes"; noLabel = "No";
              timeout = 60.0; ephemeral = true): Future[bool] {.async.} =
  ## Asks the invoking user a yes/no question and waits for the answer.
  ## Sends `prompt` with two buttons (as the initial response, or as a
  ## followup when one was already sent), returns `true` only for "yes",
  ## and `false` for "no" or timeout. The buttons are disabled once the
  ## flow settles either way.
  let yesId = ctx.scopedId("confirm:yes")
  let noId = ctx.scopedId("confirm:no")
  let buttons = @[newActionRow(
    newButton(yesLabel, yesId, bsSuccess),
    newButton(noLabel, noId, bsDanger))]
  let msgId = await ctx.sendFlowMessage(prompt, @[], buttons, ephemeral)
  let press = await ctx.waitForButton([yesId, noId], timeout)
  if press.isNone:
    discard await ctx.edit(prompt, components = disableAll(buttons),
                           messageId = msgId)
    return false
  await press.get.update(prompt, components = disableAll(buttons))
  return press.get.customId == yesId

proc pagerControls(ctx: InteractionContext; prevId, nextId: string;
                   page, total: int; disabled = false): seq[MessageComponent] =
  @[newActionRow(
    newButton("◀", prevId, bsSecondary,
              disabled = disabled or page == 0),
    newButton($(page + 1) & " / " & $total, ctx.scopedId("page:label"),
              bsSecondary, disabled = true),
    newButton("▶", nextId, bsSecondary,
              disabled = disabled or page == total - 1))]

proc paginate*(ctx: InteractionContext; pages: seq[Embed];
               timeout = 120.0; ephemeral = false) {.async.} =
  ## Sends `pages[0]` with ◀/▶ buttons and serves page flips to the
  ## invoking user. Stays resident until `timeout` seconds pass without
  ## a press (each press resets the clock), then disables the buttons.
  ## A single page is sent without controls.
  if pages.len == 0:
    raise newException(DimslashError, "paginate needs at least one page")
  if pages.len == 1:
    await ctx.reply(embeds = @[pages[0]], ephemeral = ephemeral)
    return
  let prevId = ctx.scopedId("page:prev")
  let nextId = ctx.scopedId("page:next")
  var page = 0
  let msgId = await ctx.sendFlowMessage("", @[pages[0]],
    ctx.pagerControls(prevId, nextId, 0, pages.len), ephemeral)
  while true:
    let press = await ctx.waitForButton([prevId, nextId], timeout)
    if press.isNone:
      discard await ctx.edit(embeds = @[pages[page]],
        components = ctx.pagerControls(prevId, nextId, page, pages.len,
                                       disabled = true),
        messageId = msgId)
      return
    if press.get.customId == prevId and page > 0:
      dec page
    elif press.get.customId == nextId and page < pages.len - 1:
      inc page
    await press.get.update(embeds = @[pages[page]],
      components = ctx.pagerControls(prevId, nextId, page, pages.len))
