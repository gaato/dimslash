## Core data model for dimslash.
##
## Everything here is plain data: command descriptors built by the DSL
## macros in `dsl`, the registry that stores them, the context objects
## passed to handlers, and the `RestBackend` seam that all REST traffic
## goes through (so tests can swap in a recording backend).

import std/[asyncdispatch, json, monotimes, options, tables]
import dimscord

type
  DimslashError* = object of CatchableError
    ## Raised on misuse of dimslash itself: duplicate registrations,
    ## responding twice to the same interaction, malformed custom_id
    ## patterns, and the like. Discord/network errors are dimscord's.

  UserError* = object of CatchableError
    ## An error whose message is meant for the invoking user. The default
    ## `onError` hook replies with `msg` as an ephemeral message instead
    ## of logging; raise it (or call `fail`) for expected refusals like
    ## failed checks, cooldowns, or invalid input.

  CooldownBucket* = enum
    ## What a `cooldown = …` command setting is keyed on.
    cbUser, cbGuild, cbChannel, cbGlobal

  MentionableKind* = enum
    mkUser, mkRole
  Mentionable* = object
    ## Value of an `acotMentionable` slash option: either a user or a role.
    case kind*: MentionableKind
    of mkUser: user*: User
    of mkRole: role*: Role

  ChoiceValueKind* = enum
    cvString, cvInt, cvFloat
  ChoiceValue* = object
    case kind*: ChoiceValueKind
    of cvString: strVal*: string
    of cvInt: intVal*: BiggestInt
    of cvFloat: floatVal*: float
  ChoiceSpec* = object
    ## One entry of an option's `choices` list.
    name*: string
    value*: ChoiceValue

  OptionSpec* = object
    ## Compile-time description of one slash-command option, produced by
    ## the `slash` macro and serialized by `sync.toCommandJson`.
    name*, description*: string
    kind*: ApplicationCommandOptionType
    required*: bool
    choices*: seq[ChoiceSpec]
    minValue*, maxValue*: Option[float]   ## emitted as integers for acotInt
    minLen*, maxLen*: Option[int]
    channelTypes*: seq[ChannelType]
    autocomplete*: bool
    nameLoc*, descLoc*: Table[string, string]

  CommandMeta* = object
    ## Command-level registration settings shared by slash/user/message
    ## commands.
    guildId*: string                      ## "" = global (or handler default)
    permissions*: Option[set[PermissionFlags]]
    nsfw*: bool
    contexts*: Option[set[InteractionContextType]]
    integrations*: Option[set[ApplicationIntegrationType]]
    nameLoc*, descLoc*: Table[string, string]

  ResponseState* = enum
    rsNone       ## nothing sent yet
    rsDeferred   ## deferReply/deferUpdate sent; next reply edits/follows up
    rsResponded  ## initial response sent; further replies become followups

  InteractionContext* = ref object of RootObj
    ## Base context passed to every handler. Concrete subtypes add
    ## interaction-kind-specific accessors (see `context`).
    handler*: InteractionHandler
    shard*: Shard                         ## may be nil in tests
    interaction*: Interaction
    state*: ResponseState

  SlashContext* = ref object of InteractionContext
    path*: seq[string]                    ## group/subcommand names, if any
    options*: Table[string, ApplicationCommandInteractionDataOption]

  UserContext* = ref object of InteractionContext
  MessageContext* = ref object of InteractionContext

  ComponentContext* = ref object of InteractionContext
    captures*: Table[string, string]      ## custom_id pattern captures

  ModalContext* = ref object of InteractionContext
    captures*: Table[string, string]

  AutocompleteContext* = ref object of InteractionContext
    path*: seq[string]
    options*: Table[string, ApplicationCommandInteractionDataOption]
    focusedName*: string

  SlashRun* = proc (ctx: SlashContext): Future[void]
  UserRun* = proc (ctx: UserContext): Future[void]
  MessageRun* = proc (ctx: MessageContext): Future[void]
  ComponentRun* = proc (ctx: ComponentContext): Future[void]
  ModalRun* = proc (ctx: ModalContext): Future[void]
  AutocompleteRun* = proc (ctx: AutocompleteContext): Future[void]

  PatternSegmentKind* = enum
    psLiteral, psCapture
  CaptureKind* = enum
    capString, capInt
  PatternSegment* = object
    case kind*: PatternSegmentKind
    of psLiteral:
      lit*: string
    of psCapture:
      name*: string
      capture*: CaptureKind

  CustomIdPattern* = object
    ## Parsed form of a custom_id pattern like `"page:{n:int}"`.
    ## A pattern without captures matches its literal text exactly.
    raw*: string
    segments*: seq[PatternSegment]

  SlashNodeKind* = enum
    snLeaf, snGroup
  SlashNode* = ref object
    ## A slash command is a tree: the root is either a leaf (plain
    ## command with options) or a group of subcommands/groups.
    name*, description*: string
    nameLoc*, descLoc*: Table[string, string]
    case kind*: SlashNodeKind
    of snLeaf:
      options*: seq[OptionSpec]
      run*: SlashRun
      autocompleters*: OrderedTable[string, AutocompleteRun]
        ## keyed by option name; "" is the whole-command fallback
    of snGroup:
      children*: OrderedTable[string, SlashNode]

  SlashCommand* = ref object
    meta*: CommandMeta
    root*: SlashNode                      ## root.name is the command name

  UserCommand* = ref object
    name*: string
    meta*: CommandMeta
    run*: UserRun

  MessageCommand* = ref object
    name*: string
    meta*: CommandMeta
    run*: MessageRun

  ComponentEntry*[H] = object
    pattern*: CustomIdPattern
    handler*: H
  ComponentTable*[H] = object
    exact*: Table[string, H]
    patterns*: seq[ComponentEntry[H]]     ## longest literal prefix first

  Registry* = ref object
    slash*: OrderedTable[string, SlashCommand]
    user*: OrderedTable[string, UserCommand]
    message*: OrderedTable[string, MessageCommand]
    buttons*: ComponentTable[ComponentRun]
    selects*: ComponentTable[ComponentRun]
    modals*: ComponentTable[ModalRun]

  TextFieldSpec* = object
    ## One text input of a `modalForm`, used to build the modal when it
    ## is shown. `minLen`/`maxLen` of 0 mean "unset".
    customId*, label*: string
    style*: TextInputStyle
    required*: bool
    placeholder*, value*: string
    minLen*, maxLen*: int

  ModalForm* = ref object
    ## A modal declared with the `modalForm` macro: the submit handler is
    ## registered under `pattern`, and `context.showModal` builds the
    ## dialog from `fields` (filling the pattern's captures).
    pattern*: string
    title*: string
    fields*: seq[TextFieldSpec]

  ComponentWaiter* = ref object
    ## A one-shot pending `wait.waitForComponent` call. Dispatch checks
    ## waiters before the registry and removes one as soon as it fires.
    kinds*: set[MessageComponentType]
    patterns*: seq[CustomIdPattern]
    userId*: string                       ## "" = any user
    messageId*: string                    ## "" = any message
    future*: Future[ComponentContext]

  ModalWaiter* = ref object
    ## A one-shot pending `wait.waitForModal` call.
    patterns*: seq[CustomIdPattern]
    userId*: string                       ## "" = any user
    future*: Future[ModalContext]

  MessagePayload* = object
    ## Normalized message content for followups and edits.
    content*: Option[string]
    embeds*: seq[Embed]
    components*: seq[MessageComponent]
    attachments*: seq[Attachment]
    files*: seq[DiscordFile]
    allowedMentions*: Option[AllowedMentions]
    flags*: set[MessageFlags]
    tts*: bool

  RestBackend* = ref object
    ## Every REST call dimslash makes goes through one of these closures.
    ## `rest.newDimscordBackend` wires them to dimscord; tests use a
    ## recording backend instead.
    createResponse*: proc (interactionId, token: string;
        kind: InteractionResponseType;
        data: InteractionCallbackDataMessage): Future[void]
    createAutocomplete*: proc (interactionId, token: string;
        choices: JsonNode): Future[void]
    createModal*: proc (interactionId, token: string;
        data: InteractionCallbackDataModal): Future[void]
    createFollowup*: proc (applicationId, token: string;
        payload: MessagePayload): Future[Message]
    editResponse*: proc (applicationId, token, messageId: string;
        payload: MessagePayload): Future[Message]
    getResponse*: proc (applicationId, token, messageId: string): Future[Message]
    deleteResponse*: proc (applicationId, token, messageId: string): Future[void]
    getApplicationId*: proc (): Future[string]
    getCommands*: proc (applicationId, guildId: string): Future[JsonNode]
    putCommands*: proc (applicationId, guildId: string;
        payload: JsonNode): Future[JsonNode]

  ErrorHook* = proc (ctx: InteractionContext, e: ref Exception): Future[void]
  UnknownHook* = proc (ctx: InteractionContext): Future[void]

  InteractionHandler* = ref object
    discord*: DiscordClient               ## may be nil in tests
    rest*: RestBackend
    registry*: Registry
    defaultGuildId*: string               ## guild for commands without `guild =`
    applicationId*: string                ## resolved lazily; settable up front
    onError*: ErrorHook
      ## called when a handler raises; default logs and sends an
      ## ephemeral error reply if nothing was sent yet. nil = re-raise.
    onUnknown*: UnknownHook
      ## called for interactions with no registered handler. nil = ignore.
    componentWaiters*: seq[ComponentWaiter]  ## pending `waitFor*` calls
    modalWaiters*: seq[ModalWaiter]
    cooldowns*: Table[string, MonoTime]
      ## ready-again times for `cooldown = …` commands, keyed by
      ## command path + bucket

template fail*(msg: string) =
  ## Aborts the current handler with a message shown to the invoking user
  ## (ephemeral, via the default `onError` hook). Sugar for raising
  ## `UserError`.
  raise newException(UserError, msg)

proc choice*(name: string, value: string): ChoiceSpec =
  ChoiceSpec(name: name, value: ChoiceValue(kind: cvString, strVal: value))

proc choice*(name: string, value: int): ChoiceSpec =
  ChoiceSpec(name: name, value: ChoiceValue(kind: cvInt, intVal: value))

proc choice*(name: string, value: float): ChoiceSpec =
  ChoiceSpec(name: name, value: ChoiceValue(kind: cvFloat, floatVal: value))

proc newRegistry*(): Registry =
  Registry()
