## Component & modal payload extraction helpers.
##
## These procs extract data from message-component and modal-submit
## interactions.  They complement the slash argument helpers in
## `slashargs` by covering buttons, select menus, and modals.
##
## Quick reference
## ---------------
## =================  ==============================================
## Proc               Returns
## =================  ==============================================
## ``customId``       ``Option[string]`` — the ``custom_id`` field
## ``selectValues``   ``seq[string]`` — selected values from a select menu
## ``modalValues``    ``Table[string, string]`` — all text-input fields
## ``modalValue``     ``Option[string]`` — one text-input field by id
## =================  ==============================================
##
## Example: modal handler
## ----------------------
## .. code-block:: nim
##   handler.addModal("feedback_form") do:
##     let vals = i.modalValues
##     let name = i.modalValue("name_field").get("anonymous")
##     await handler.reply(i, "Thanks, " & name & "!")
##
## Example: select handler
## -----------------------
## .. code-block:: nim
##   handler.addSelect("role_picker") do:
##     let picked = i.selectValues
##     await handler.reply(i, "You chose: " & picked.join(", "))

import std/[options, tables]
import dimscord

proc customId*(i: Interaction): Option[string] =
  ## Returns the ``custom_id`` attached to a message-component or
  ## modal-submit interaction.
  ##
  ## For application-command or ping interactions the result is ``none``.
  ## The returned value is the same string you specified when sending
  ## the button, select menu, or modal.
  if i.data.isSome and i.data.get.interaction_type in {idtMessageComponent, idtModalSubmit}:
    return some(i.data.get.custom_id)
  none(string)

proc selectValues*(i: Interaction): seq[string] =
  ## Returns the values the user picked in a select-menu component.
  ##
  ## Supports all select variants: ``mctSelectMenu`` (string select),
  ## ``mctUserSelect``, ``mctRoleSelect``, ``mctMentionableSelect``,
  ## and ``mctChannelSelect``.  Returns an empty seq for non-select
  ## interactions.
  if i.data.isSome and i.data.get.interaction_type == idtMessageComponent:
    let data = i.data.get
    if data.component_type in {mctSelectMenu, mctUserSelect, mctRoleSelect, mctMentionableSelect, mctChannelSelect}:
      return data.values
  @[]

proc collectModalValues(components: seq[MessageComponent], outTable: var Table[string, string]) =
  ## Recursively walks the component tree and collects every
  ## ``mctTextInput`` that has both a ``custom_id`` and a ``value``.
  ## Modal action-rows nest text inputs inside containers, so we
  ## recurse into ``components`` and ``component`` fields.
  for component in components:
    if component.isNil:
      continue

    if component.kind == mctTextInput:
      if component.custom_id.isSome and component.value.isSome:
        outTable[component.custom_id.get] = component.value.get

    if component.components.len > 0:
      collectModalValues(component.components, outTable)

    if component.kind == mctLabel and not component.component.isNil:
      collectModalValues(@[component.component], outTable)

proc modalValues*(i: Interaction): Table[string, string] =
  ## Extracts **all** text-input values from a modal-submit interaction
  ## as a ``Table[string, string]`` keyed by each field's ``custom_id``.
  ##
  ## Returns an empty table for non-modal interactions.
  ##
  ## .. code-block:: nim
  ##   handler.addModal("survey") do:
  ##     let fields = i.modalValues
  ##     for id, value in fields:
  ##       echo id, " = ", value
  result = initTable[string, string]()
  if i.data.isSome and i.data.get.interaction_type == idtModalSubmit:
    collectModalValues(i.data.get.components, result)

proc modalValue*(i: Interaction, fieldCustomId: string): Option[string] =
  ## Returns a **single** modal text-input value by its ``custom_id``.
  ##
  ## This is a convenience wrapper around ``modalValues`` for when you
  ## only need one field.  Returns ``none`` when the field is missing
  ## or the interaction is not a modal submit.
  ##
  ## .. code-block:: nim
  ##   let email = i.modalValue("email_field").get("not provided")
  let values = i.modalValues()
  if values.hasKey(fieldCustomId):
    return some(values[fieldCustomId])
  none(string)
