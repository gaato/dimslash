## Typed extraction of slash-command options from an `Interaction`.
##
## Discord delivers slash-command arguments as a flat (or nested, for
## sub-commands) table of `ApplicationCommandInteractionDataOption`.
## This module provides two families of helpers:
##
## - **`getSlashArg`** – returns `Option[T]`, `none` when the option is
##   absent or has the wrong type.
## - **`requireSlashArg`** – returns `T` directly, raises
##   `HandlerError(hekInvalidInteraction)` when the option is missing.
##
## Supported Nim types
## ===================
##
## ===========  ============  =============================================
## Nim type     ACOT kind     Notes
## ===========  ============  =============================================
## `string`     `acotStr`     Raw string value
## `int`        `acotInt`     64-bit integer, cast to `int`
## `bool`       `acotBool`    Boolean toggle
## `float`      `acotNumber`  Double-precision number
## `User`       `acotUser`    Resolved via `data.resolved.users`
## `Role`       `acotRole`    Resolved via `data.resolved.roles`
## ===========  ============  =============================================
##
## Wrap any of the above in `Option[T]` to make it optional (uses
## `getSlashArg` instead of `requireSlashArg`).
##
## `getSlashArg` vs `requireSlashArg`
## ===================================
##
## .. code-block:: nim
##   # Optional — caller handles missing value:
##   let name = getSlashArg(i, "name", string)  # Option[string]
##
##   # Required — raises on missing value:
##   let name = requireSlashArg(i, "name", string)  # string
##
## In practice you rarely call these directly — the `addSlash` macro in
## `dsl` generates the extraction code automatically from the `do` block
## parameters.
##
## Autocomplete helpers
## ====================
##
## When handling `itAutoComplete` interactions, use `focusedOption`,
## `focusedOptionName`, and `focusedOptionValue` to inspect the
## option the user is currently typing in.
##
## .. code-block:: nim
##   handler.addAutocomplete("search") do:
##     let partial = focusedOptionValue(i).get("")
##     # ... filter your data source by `partial` ...
##     await handler.suggest(i, filteredResults)

import std/[options, tables, strutils]
import dimscord

import ./types

proc normalizeOptionName*(name: string): string =
  ## Normalises a Nim-style parameter name into the lowercase, no-underscore
  ## key that Discord uses for slash option lookup.
  ##
  ## The conversion is intentionally lossy — `camelCase`, `snake_case` and
  ## `PascalCase` all collapse to the same key.
  runnableExamples "-d:ssl":
    doAssert normalizeOptionName("camelCase") == "camelcase"
    doAssert normalizeOptionName("snake_case") == "snakecase"
    doAssert normalizeOptionName("PascalCase") == "pascalcase"
    doAssert normalizeOptionName("ALL_CAPS") == "allcaps"
    doAssert normalizeOptionName("simple") == "simple"
  #==#
  result = name.toLowerAscii().replace("_", "")

proc getTailOptions(data: ApplicationCommandInteractionData): Table[string, ApplicationCommandInteractionDataOption] =
  ## Walks through nested sub-command groups to return the leaf options
  ## table that actually contains the user-supplied values.
  result = data.options
  while true:
    var nextChild: Option[ApplicationCommandInteractionDataOption]
    for _, child in result:
      if child.kind in {acotSubCommandGroup, acotSubCommand}:
        nextChild = some(child)
        break

    if nextChild.isSome and len(result) == 1:
      result = nextChild.get.options
    else:
      break

proc slashOptions*(i: Interaction): Table[string, ApplicationCommandInteractionDataOption] =
  ## Returns the leaf-level options table for the current slash interaction.
  ##
  ## If `i` is not a slash command (e.g. a user command or a component
  ## interaction) an empty table is returned so callers can safely iterate
  ## without extra guards.
  ##
  ## For commands with sub-commands / sub-command-groups the table is
  ## automatically "unwrapped" to the deepest level.  For example, given
  ## ``/parent child --name "foo"``, this proc returns the table containing
  ## the ``name`` option, not the ``child`` sub-command node itself.
  if i.data.isNone or i.data.get.interaction_type != idtApplicationCommand:
    return initTable[string, ApplicationCommandInteractionDataOption]()

  if i.data.get.kind != atSlash:
    return initTable[string, ApplicationCommandInteractionDataOption]()

  result = getTailOptions(i.data.get)

proc focusedOption*(i: Interaction): Option[ApplicationCommandInteractionDataOption] =
  ## Returns the option node that is currently focused during an autocomplete
  ## interaction.
  ##
  ## Discord marks exactly one option with ``focused = true`` when an
  ## autocomplete interaction is dispatched.  This proc scans the leaf
  ## options and returns that node (or `none` if nothing is focused).
  ##
  ## .. code-block:: nim
  ##   let opt = i.focusedOption()
  ##   if opt.isSome:
  ##     echo "focused kind: ", opt.get.kind
  ##     echo "focused name: ", opt.get.name
  let opts = i.slashOptions()
  for _, opt in opts:
    if opt.focused.isSome and opt.focused.get:
      return some(opt)
  none(ApplicationCommandInteractionDataOption)

proc focusedOptionName*(i: Interaction): Option[string] =
  ## Returns the **name** of the focused option during autocomplete.
  ##
  ## This is useful for dispatching to different autocomplete logic
  ## depending on which option the user is typing in:
  ##
  ## .. code-block:: nim
  ##   handler.addAutocomplete("search") do:
  ##     case focusedOptionName(i).get("")
  ##     of "query": await handler.suggest(i, queryResults)
  ##     of "lang":  await handler.suggest(i, langResults)
  ##     else: discard
  let focused = i.focusedOption()
  if focused.isSome:
    return some(focused.get.name)
  none(string)

proc focusedOptionValue*(i: Interaction): Option[string] =
  ## Returns the current partial value the user has typed so far.
  ##
  ## The value is always returned as a string regardless of the underlying
  ## option type (`string`, `int`, `float`, `bool`).  Returns `none` when
  ## no option is focused or the type cannot be stringified.
  ##
  ## Typical usage — filter suggestions client-side:
  ##
  ## .. code-block:: nim
  ##   handler.addAutocomplete("search") do:
  ##     let partial = focusedOptionValue(i).get("")
  ##     let matches = allItems.filterIt(partial in it)
  ##     await handler.suggest(i, matches[0 ..< min(25, matches.len)])
  let focused = i.focusedOption()
  if focused.isNone:
    return none(string)

  let opt = focused.get
  case opt.kind
  of acotStr:
    some(opt.str)
  of acotInt:
    some($opt.ival)
  of acotNumber:
    some($opt.fval)
  of acotBool:
    some($opt.bval)
  else:
    none(string)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[string]): Option[string] =
  ## Extracts a **string** slash option by name.
  ## Returns `none(string)` when the option is absent or has a different type.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(string)
  let opt = opts[key]
  if opt.kind == acotStr:
    return some(opt.str)
  none(string)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[int]): Option[int] =
  ## Extracts an **int** slash option by name.
  ## Returns `none(int)` when the option is absent or has a different type.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(int)
  let opt = opts[key]
  if opt.kind == acotInt:
    return some(int(opt.ival))
  none(int)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[bool]): Option[bool] =
  ## Extracts a **bool** slash option by name.
  ## Returns `none(bool)` when the option is absent or has a different type.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(bool)
  let opt = opts[key]
  if opt.kind == acotBool:
    return some(opt.bval)
  none(bool)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[float]): Option[float] =
  ## Extracts a **float** (number) slash option by name.
  ## Returns `none(float)` when the option is absent or has a different type.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(float)
  let opt = opts[key]
  if opt.kind == acotNumber:
    return some(float(opt.fval))
  none(float)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[User]): Option[User] =
  ## Extracts a **User** slash option by name.
  ##
  ## The resolved `User` object is looked up from
  ## `Interaction.data.resolved.users`.  Returns `none(User)` when the
  ## option is absent or the user was not resolved.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(User)
  let opt = opts[key]
  if opt.kind != acotUser:
    return none(User)

  let resolved = i.data.get.resolved.users
  if resolved.hasKey(opt.user_id):
    return some(resolved[opt.user_id])
  none(User)

proc getSlashArg*(i: Interaction, name: string, _: typedesc[Role]): Option[Role] =
  ## Extracts a **Role** slash option by name.
  ##
  ## The resolved `Role` object is looked up from
  ## `Interaction.data.resolved.roles`.  Returns `none(Role)` when the
  ## option is absent or the role was not resolved.
  let key = normalizeOptionName(name)
  let opts = i.slashOptions()
  if not opts.hasKey(key):
    return none(Role)
  let opt = opts[key]
  if opt.kind != acotRole:
    return none(Role)

  let resolved = i.data.get.resolved.roles
  if resolved.hasKey(opt.role_id):
    return some(resolved[opt.role_id])
  none(Role)

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[string]): string =
  ## Same as `getSlashArg` for `string`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, string)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[int]): int =
  ## Same as `getSlashArg` for `int`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, int)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[bool]): bool =
  ## Same as `getSlashArg` for `bool`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, bool)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[float]): float =
  ## Same as `getSlashArg` for `float`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, float)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[User]): User =
  ## Same as `getSlashArg` for `User`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, User)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get

proc requireSlashArg*(i: Interaction, name: string, _: typedesc[Role]): Role =
  ## Same as `getSlashArg` for `Role`, but raises
  ## `HandlerError(hekInvalidInteraction)` when the option is missing.
  let value = i.getSlashArg(name, Role)
  if value.isNone:
    raise newInvalidInteractionError("missing or invalid slash option: " & name)
  value.get
