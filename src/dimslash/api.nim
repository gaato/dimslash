## The public DimSlash API.
##
## `DiscordApp` contains an immutable route table. `AppBinding` owns one
## running transport and all request-scoped response state.

import std/[asyncdispatch, enumutils, hashes, httpclient, json, macros,
            mimetypes, monotimes, options, os, sequtils, sets, strutils,
            tables, typetraits, unicode]
import dimscord as discord
import dimscord/restapi/requester

type
  ApplicationId* = distinct string
  InteractionId* = distinct string
  MessageId* = distinct string
  UserId* = distinct string
  GuildId* = distinct string
  ChannelId* = distinct string
  RoleId* = distinct string
  AttachmentId* = distinct string
  Permissions* = distinct uint64

  DimSlashError* = object of CatchableError
  RouteDefinitionError* = object of DimSlashError
  InvalidInteractionError* = object of DimSlashError
  InvalidResponseStateError* = object of DimSlashError
  ResponseOutcomeUnknownError* = object of DimSlashError
  MissingInitialResponseError* = object of DimSlashError
  UserRejectionError* = object of CatchableError
    userMessageValue: string

  User* = object
    idValue: UserId
    usernameValue: string

  Member* = object
    userValue: User
    nicknameValue: Option[string]
    permissionsValue: Option[Permissions]

  Role* = object
    idValue: RoleId
    nameValue: string

  ResolvedChannel* = object
    idValue: ChannelId
    nameValue: Option[string]

  Attachment* = object
    idValue: AttachmentId
    filenameValue: string
    urlValue: string

  Message* = object
    idValue: MessageId
    contentValue: string
    authorValue: Option[User]

  ActivityInstance* = object
    idValue: string

  MentionableKind* = enum
    MentionableUser
    MentionableRole

  Mentionable* = object
    case kind*: MentionableKind
    of MentionableUser:
      mentionedUser*: User
    of MentionableRole:
      mentionedRole*: Role

  EmbedMedia* = object
    url*: string

  EmbedAuthor* = object
    name*: string
    url*: Option[string]
    iconUrl*: Option[string]

  EmbedFooter* = object
    text*: string
    iconUrl*: Option[string]

  EmbedField* = object
    name*: string
    value*: string
    inline*: bool

  Embed* = object
    title*: Option[string]
    description*: Option[string]
    url*: Option[string]
    timestamp*: Option[string]
    color*: Option[int]
    footer*: Option[EmbedFooter]
    image*: Option[EmbedMedia]
    thumbnail*: Option[EmbedMedia]
    author*: Option[EmbedAuthor]
    fields*: seq[EmbedField]

  AllowedMentions* = object
    parseEveryone*: bool
    parseUsers*: bool
    parseRoles*: bool
    repliedUser*: bool
    users*: seq[UserId]
    roles*: seq[RoleId]

  UploadedFile* = object
    filename*: string
    content*: string
    description*: Option[string]

  ButtonStyle* = enum
    Primary = 1
    Secondary = 2
    Success = 3
    Danger = 4
    Link = 5

  Button* = object
    label*: string
    style*: ButtonStyle
    customId*: Option[string]
    url*: Option[string]
    disabled*: bool

  SelectOption* = object
    label*: string
    value*: string
    description*: Option[string]
    default*: bool

  SelectMenuKind* = enum
    StringSelect = 3
    UserSelect = 5
    RoleSelect = 6
    MentionableSelect = 7
    ChannelSelect = 8

  SelectMenu* = object
    kind*: SelectMenuKind
    customId*: string
    placeholder*: Option[string]
    minValues*: int
    maxValues*: int
    disabled*: bool
    options*: seq[SelectOption]
    channelKinds*: seq[ChannelKind]

  ClassicComponentKind* = enum
    ClassicButton
    ClassicSelect

  ClassicComponent* = object
    case kind*: ClassicComponentKind
    of ClassicButton:
      button*: Button
    of ClassicSelect:
      selectMenu*: SelectMenu

  ClassicActionRow* = object
    components*: seq[ClassicComponent]

  ClassicMessage* = object
    content*: Option[string]
    embeds*: seq[Embed]
    rows*: seq[ClassicActionRow]
    allowedMentions*: AllowedMentions
    files*: seq[UploadedFile]
    ephemeral*: bool
    tts*: bool

  V2ComponentKind* = enum
    TextDisplay
    V2ActionRow
    Section
    MediaGallery
    FileDisplay
    Separator
    Container

  MediaItem* = object
    url*: string
    description*: Option[string]
    spoiler*: bool

  SectionAccessoryKind* = enum
    AccessoryButton
    AccessoryThumbnail

  SectionAccessory* = object
    case kind*: SectionAccessoryKind
    of AccessoryButton:
      accessoryButton*: Button
    of AccessoryThumbnail:
      thumbnail*: MediaItem

  V2Component* = ref object
    case kind*: V2ComponentKind
    of TextDisplay:
      text*: string
    of V2ActionRow:
      interactiveComponents*: seq[ClassicComponent]
    of Section:
      sectionTexts*: seq[string]
      sectionAccessory*: SectionAccessory
    of MediaGallery:
      mediaItems*: seq[MediaItem]
    of FileDisplay:
      fileItem*: MediaItem
    of Separator:
      divider*: bool
      spacing*: range[1 .. 2]
    of Container:
      containerComponents*: seq[V2Component]
      accentColor*: Option[int]
      containerSpoiler*: bool

  V2Message* = object
    components*: seq[V2Component]
    allowedMentions*: AllowedMentions
    files*: seq[UploadedFile]
    ephemeral*: bool

  MessageBodyKind* = enum
    ClassicBody
    ComponentsV2Body

  MessageBody* = object
    case kind*: MessageBodyKind
    of ClassicBody:
      classic*: ClassicMessage
    of ComponentsV2Body:
      v2*: V2Message

  InteractionKind* = enum
    SlashCommand
    UserCommand
    MessageCommand
    Autocomplete
    MessageComponent
    ModalSubmit

  Interaction* = object
    idValue: InteractionId
    applicationIdValue: ApplicationId
    tokenValue: string
    kindValue: InteractionKind
    guildIdValue: Option[GuildId]
    channelIdValue: Option[ChannelId]
    userValue: Option[User]
    memberValue: Option[Member]
    messageValue: Option[Message]
    localeValue: Option[string]
    guildLocaleValue: Option[string]
    appPermissionsValue: Permissions
    rawValue: JsonNode

  ResponseState* = enum
    Pending
    DeferredReply
    DeferredUpdate
    Responded
    OutcomeUnknown

  InitialResponseKind = enum
    InitialMessage
    InitialUpdate
    InitialDeferredMessage
    InitialDeferredUpdate
    InitialModal
    InitialAutocomplete

  ResponseRejectedError* = object of CatchableError
  ResponseAmbiguousError = object of CatchableError

  ResponseSink = ref object
    initial: proc(interactionId: InteractionId; token: string;
                  kind: InitialResponseKind; data: JsonNode;
                  files: seq[UploadedFile]): Future[void]
    createFollowup: proc(applicationId: ApplicationId; token: string;
                         data: JsonNode;
                         files: seq[UploadedFile]): Future[Message]
    editMessage: proc(applicationId: ApplicationId; token: string;
                      messageId: MessageId; data: JsonNode;
                      files: seq[UploadedFile]): Future[Message]
    getMessage: proc(applicationId: ApplicationId; token: string;
                     messageId: MessageId): Future[Message]
    deleteMessage: proc(applicationId: ApplicationId; token: string;
                        messageId: MessageId): Future[void]
    launchActivity: proc(interactionId: InteractionId;
                         token: string): Future[ActivityInstance]

  CommandSyncSink = ref object
    resolveApplicationId: proc(): Future[ApplicationId]
    putCommands: proc(applicationId: ApplicationId; scope: CommandScope;
                      commands: JsonNode): Future[void]

  ResponseController = ref object
    sink: ResponseSink
    interactionId: InteractionId
    applicationId: ApplicationId
    token: string
    state: ResponseState
    originalUsesV2: bool

  InteractionContext* = ref object of RootObj
    interactionValue: Interaction
    response: ResponseController
    bindingValue: AppBinding

  SlashCommandContext* = ref object of InteractionContext
    commandNameValue: string
    commandPathValue: seq[string]
    optionsValue: JsonNode
    resolvedValue: JsonNode

  UserCommandContext* = ref object of InteractionContext
    targetValue: User
    targetMemberValue: Option[Member]

  MessageCommandContext* = ref object of InteractionContext
    targetValue: Message

  ComponentContext* = ref object of InteractionContext
    customIdValue: string
    valuesValue: seq[string]
    resolvedValue: JsonNode
    capturesValue: Table[string, string]

  ModalSourceKind* = enum
    CommandModalSource
    ComponentModalSource

  ModalSource* = object
    kindValue: ModalSourceKind
    messageValue: Option[Message]

  ModalContext* = ref object of InteractionContext
    customIdValue: string
    capturesValue: Table[string, string]
    fieldsValue: Table[string, string]
    resolvedValue: JsonNode
    sourceValue: Option[ModalSource]

  TextInputStyle* = enum
    ShortText = 1
    ParagraphText = 2

  ModalInput* = object
    customId*: string
    label*: string
    description*: Option[string]
    style*: TextInputStyle
    required*: bool
    minLength*: Option[int]
    maxLength*: Option[int]
    value*: Option[string]
    placeholder*: Option[string]

  Modal* = object
    customId*: string
    title*: string
    inputs*: seq[ModalInput]

  Choice* = object
    name*: string
    value*: JsonNode

  AutocompleteContext* = ref object of InteractionContext
    commandNameValue: string
    focusedNameValue: string
    focusedValueValue: string
    optionsValue: JsonNode
    resolvedValue: JsonNode

  ErrorActionKind* = enum
    Reraise
    Ignore
    RespondEphemeral
    CompleteAutocomplete

  ErrorAction* = object
    case kind*: ErrorActionKind
    of RespondEphemeral:
      message*: string
    else:
      discard

  ErrorHandler* = proc(ctx: InteractionContext;
                       error: ref CatchableError): Future[ErrorAction]

  CheckDecisionKind* = enum
    CheckPassed
    CheckRejected

  CheckDecision* = object
    case kind*: CheckDecisionKind
    of CheckPassed:
      discard
    of CheckRejected:
      rejectionMessage*: string

  InteractionCheck = proc(ctx: InteractionContext): Future[CheckDecision]
  SlashCheck* = proc(ctx: SlashCommandContext): Future[CheckDecision]
  UserCommandCheck* = proc(ctx: UserCommandContext): Future[CheckDecision]
  MessageCommandCheck* = proc(
    ctx: MessageCommandContext): Future[CheckDecision]
  ComponentCheck* = proc(ctx: ComponentContext): Future[CheckDecision]
  ModalCheck* = proc(ctx: ModalContext): Future[CheckDecision]

  CooldownScope* = enum
    GlobalCooldown
    UserCooldown
    GuildCooldown

  CooldownRule* = object
    durationMs*: int64
    scope*: CooldownScope

  OptionKind* = enum
    StringOption = 3
    IntegerOption = 4
    BooleanOption = 5
    UserOption = 6
    ChannelOption = 7
    RoleOption = 8
    MentionableOption = 9
    NumberOption = 10
    AttachmentOption = 11

  ChannelKind* = enum
    GuildText = 0
    DirectMessage = 1
    GuildVoice = 2
    GroupDirectMessage = 3
    GuildCategory = 4
    GuildAnnouncement = 5
    AnnouncementThread = 10
    PublicThread = 11
    PrivateThread = 12
    GuildStageVoice = 13
    GuildDirectory = 14
    GuildForum = 15
    GuildMedia = 16

  InteractionContextKind* = enum
    GuildContext = 0
    BotDirectMessageContext = 1
    PrivateChannelContext = 2

  IntegrationKind* = enum
    GuildInstall = 0
    UserInstall = 1

  GatewayIntent* = enum
    Guilds = 0
    GuildMembers
    GuildModeration
    GuildEmojisAndStickers
    GuildIntegrations
    GuildWebhooks
    GuildInvites
    GuildVoiceStates
    GuildPresences
    GuildMessages
    GuildMessageReactions
    GuildMessageTyping
    DirectMessages
    DirectMessageReactions
    DirectMessageTyping
    MessageContent
    GuildScheduledEvents = 16
    AutoModerationConfiguration = 20
    AutoModerationExecution
    GuildMessagePolls = 24
    DirectMessagePolls

  CommandMetadata = object
    defaultMemberPermissions: Option[uint64]
    nsfw: bool
    contexts: Option[set[InteractionContextKind]]
    integrations: Option[set[IntegrationKind]]
    nameLocalizations: Table[string, string]
    descriptionLocalizations: Table[string, string]

  CommandOption* = object
    name*: string
    description*: string
    kind*: OptionKind
    required*: bool
    minValue*: Option[float]
    maxValue*: Option[float]
    minLength*: Option[int]
    maxLength*: Option[int]
    autocomplete*: bool
    choices*: seq[Choice]
    channelKinds*: seq[ChannelKind]
    nameLocalizations*: Table[string, string]
    descriptionLocalizations*: Table[string, string]

  SlashHandler = proc(ctx: SlashCommandContext): Future[void]
  UserCommandHandler = proc(ctx: UserCommandContext): Future[void]
  MessageCommandHandler = proc(ctx: MessageCommandContext): Future[void]
  ComponentHandler = proc(ctx: ComponentContext): Future[void]
  ModalHandler = proc(ctx: ModalContext): Future[void]
  AutocompleteHandler = proc(ctx: AutocompleteContext): Future[void]

  SlashRoute = object
    name: string
    description: string
    path: seq[string]
    pathDescriptions: seq[string]
    options: seq[CommandOption]
    handler: SlashHandler
    autocompleteHandlers: Table[string, AutocompleteHandler]
    metadata: CommandMetadata
    checks: seq[InteractionCheck]
    cooldown: Option[CooldownRule]

  NamedRoute[T] = object
    name: string
    handler: T
    metadata: CommandMetadata
    checks: seq[InteractionCheck]
    cooldown: Option[CooldownRule]

  PatternKind = enum
    LiteralSegment
    StringCapture
    IntegerCapture

  PatternSegment = object
    kind: PatternKind
    literal: string
    captureName: string

  Pattern = object
    raw: string
    segments: seq[PatternSegment]

  ComponentRoute = object
    pattern: Pattern
    isSelect: bool
    handler: ComponentHandler
    checks: seq[InteractionCheck]
    cooldown: Option[CooldownRule]

  ModalRoute = object
    pattern: Pattern
    handler: ModalHandler
    checks: seq[InteractionCheck]
    cooldown: Option[CooldownRule]

  ComponentInteractionKind* = enum
    ButtonInteraction
    SelectInteraction

  ComponentWaiter = ref object
    kinds: set[ComponentInteractionKind]
    patterns: seq[Pattern]
    userId: Option[UserId]
    messageId: Option[MessageId]
    future: Future[Option[ComponentContext]]

  ModalWaiter = ref object
    patterns: seq[Pattern]
    userId: Option[UserId]
    future: Future[Option[ModalContext]]

  Routes* = object
    slashRoutes: OrderedTable[string, SlashRoute]
    userRoutes: OrderedTable[string, NamedRoute[UserCommandHandler]]
    messageRoutes: OrderedTable[string, NamedRoute[MessageCommandHandler]]
    buttonRoutes: seq[ComponentRoute]
    modalRoutes: seq[ModalRoute]

  RouteFactory* = proc(routes: var Routes)

  DiscordApp* = object
    routesValue: Routes
    errorHandlerValue: ErrorHandler

  AppBinding* = ref object
    app: DiscordApp
    sink: ResponseSink
    commandSink: CommandSyncSink
    client: discord.DiscordClient
    previousDispatch: proc(shard: discord.Shard; event: string;
                           data: JsonNode): Future[void]
    previousReady: proc(shard: discord.Shard;
                        ready: discord.Ready): Future[void]
    managedScopes: seq[CommandScope]
    applicationId: ApplicationId
    installed: bool
    commandsSynced: bool
    accepting: bool
    activeRequests: int
    drained: Future[void]
    cooldowns: Table[string, int64]
    monotonicMilliseconds: proc(): int64
    componentWaiters: seq[ComponentWaiter]
    modalWaiters: seq[ModalWaiter]
    gatewayIntents: set[GatewayIntent]
    messageContentIntent: bool
    autoReconnect: bool

  CommandScopeKind* = enum
    GlobalCommands
    GuildCommands

  CommandScope* = object
    case kind*: CommandScopeKind
    of GlobalCommands:
      discard
    of GuildCommands:
      guildId*: GuildId

  SyncResult* = object
    scope*: CommandScope
    commandCount*: int

const OriginalMessageId = MessageId("@original")

template description*(value: static string) {.pragma.}
template desc*(value: static string) {.pragma.}
template min*(value: untyped) {.pragma.}
template max*(value: untyped) {.pragma.}
template minLength*(value: static int) {.pragma.}
template maxLength*(value: static int) {.pragma.}
template minLen*(value: static int) {.pragma.}
template maxLen*(value: static int) {.pragma.}
template name*(value: static string) {.pragma.}
template choices*(value: untyped) {.pragma.}
template channels*(value: untyped) {.pragma.}
template nameLoc*(value: untyped) {.pragma.}
template descLoc*(value: untyped) {.pragma.}

proc `$`*(value: ApplicationId | InteractionId | MessageId | UserId |
                 GuildId | ChannelId | RoleId | AttachmentId): string =
  string(value)

proc toUint64*(value: Permissions): uint64 = uint64(value)

proc containsAll*(value, required: Permissions): bool =
  (uint64(value) and uint64(required)) == uint64(required)

proc `==`*(left, right: ApplicationId): bool {.borrow.}
proc `==`*(left, right: InteractionId): bool {.borrow.}
proc `==`*(left, right: MessageId): bool {.borrow.}
proc `==`*(left, right: UserId): bool {.borrow.}
proc `==`*(left, right: GuildId): bool {.borrow.}
proc `==`*(left, right: ChannelId): bool {.borrow.}
proc `==`*(left, right: RoleId): bool {.borrow.}
proc `==`*(left, right: AttachmentId): bool {.borrow.}
proc hash*(value: ApplicationId): Hash {.borrow.}
proc hash*(value: InteractionId): Hash {.borrow.}
proc hash*(value: MessageId): Hash {.borrow.}
proc hash*(value: UserId): Hash {.borrow.}
proc hash*(value: GuildId): Hash {.borrow.}
proc hash*(value: ChannelId): Hash {.borrow.}
proc hash*(value: RoleId): Hash {.borrow.}
proc hash*(value: AttachmentId): Hash {.borrow.}

proc id*(value: User): UserId = value.idValue
proc username*(value: User): string = value.usernameValue
proc user*(value: Member): User = value.userValue
proc nickname*(value: Member): Option[string] = value.nicknameValue
proc permissions*(value: Member): Option[Permissions] = value.permissionsValue
proc id*(value: Role): RoleId = value.idValue
proc name*(value: Role): string = value.nameValue
proc id*(value: ResolvedChannel): ChannelId = value.idValue
proc name*(value: ResolvedChannel): Option[string] = value.nameValue
proc id*(value: Attachment): AttachmentId = value.idValue
proc filename*(value: Attachment): string = value.filenameValue
proc url*(value: Attachment): string = value.urlValue
proc id*(value: Message): MessageId = value.idValue
proc content*(value: Message): string = value.contentValue
proc author*(value: Message): Option[User] = value.authorValue
proc id*(value: ActivityInstance): string = value.idValue

proc id*(value: Interaction): InteractionId = value.idValue
proc applicationId*(value: Interaction): ApplicationId =
  value.applicationIdValue
proc kind*(value: Interaction): InteractionKind = value.kindValue
proc guildId*(value: Interaction): Option[GuildId] = value.guildIdValue
proc channelId*(value: Interaction): Option[ChannelId] = value.channelIdValue
proc user*(value: Interaction): Option[User] = value.userValue
proc member*(value: Interaction): Option[Member] = value.memberValue
proc message*(value: Interaction): Option[Message] = value.messageValue
proc locale*(value: Interaction): Option[string] = value.localeValue
proc guildLocale*(value: Interaction): Option[string] = value.guildLocaleValue
proc appPermissions*(value: Interaction): Permissions =
  value.appPermissionsValue
proc raw*(value: Interaction): JsonNode = value.rawValue.copy

proc interaction*(ctx: InteractionContext): Interaction =
  ctx.interactionValue
proc responseState*(ctx: InteractionContext): ResponseState =
  ctx.response.state
proc commandName*(ctx: SlashCommandContext): string = ctx.commandNameValue
proc commandPath*(ctx: SlashCommandContext): seq[string] =
  for segment in ctx.commandPathValue: result.add segment
proc target*(ctx: UserCommandContext): User = ctx.targetValue
proc targetMember*(ctx: UserCommandContext): Option[Member] =
  ctx.targetMemberValue
proc target*(ctx: MessageCommandContext): Message = ctx.targetValue
proc customId*(ctx: ComponentContext | ModalContext): string =
  ctx.customIdValue
proc values*(ctx: ComponentContext): seq[string] =
  for value in ctx.valuesValue: result.add value
proc fields*(ctx: ModalContext): Table[string, string] =
  for name, value in ctx.fieldsValue: result[name] = value
proc field*(ctx: ModalContext; name: string): Option[string] =
  if ctx.fieldsValue.hasKey(name): some(ctx.fieldsValue[name])
  else: none(string)
proc source*(ctx: ModalContext): Option[ModalSource] = ctx.sourceValue
proc kind*(source: ModalSource): ModalSourceKind = source.kindValue
proc message*(source: ModalSource): Option[Message] = source.messageValue
proc focusedName*(ctx: AutocompleteContext): string = ctx.focusedNameValue
proc focusedValue*(ctx: AutocompleteContext): string = ctx.focusedValueValue

proc user*(ctx: InteractionContext): User =
  if ctx.interactionValue.userValue.isNone:
    raise newException(InvalidInteractionError,
      "interaction has no invoking user")
  ctx.interactionValue.userValue.get

proc member*(ctx: InteractionContext): Option[Member] =
  ctx.interactionValue.memberValue

proc guildId*(ctx: InteractionContext): Option[GuildId] =
  ctx.interactionValue.guildIdValue

proc channelId*(ctx: InteractionContext): Option[ChannelId] =
  ctx.interactionValue.channelIdValue

proc locale*(ctx: InteractionContext): Option[string] =
  ctx.interactionValue.localeValue

proc guildLocale*(ctx: InteractionContext): Option[string] =
  ctx.interactionValue.guildLocaleValue

proc appPermissions*(ctx: InteractionContext): Permissions =
  ctx.interactionValue.appPermissionsValue

proc inGuild*(ctx: InteractionContext): bool =
  ctx.interactionValue.guildIdValue.isSome

proc embed*(title = ""; description = "";
            color = none(int)): Embed =
  if title.len > 0: result.title = some(title)
  if description.len > 0: result.description = some(description)
  if color.isSome:
    if color.get notin 0 .. 0xFFFFFF:
      raise newException(ValueError,
        "an embed color must be between 0x000000 and 0xFFFFFF")
    result.color = color

proc embedMedia*(url: string): EmbedMedia =
  if url.len == 0: raise newException(ValueError, "embed media needs a URL")
  EmbedMedia(url: url)

proc embedAuthor*(name: string; url = ""; iconUrl = ""): EmbedAuthor =
  if name.len == 0: raise newException(ValueError, "embed author needs a name")
  result.name = name
  if url.len > 0: result.url = some(url)
  if iconUrl.len > 0: result.iconUrl = some(iconUrl)

proc embedFooter*(text: string; iconUrl = ""): EmbedFooter =
  if text.len == 0: raise newException(ValueError, "embed footer needs text")
  result.text = text
  if iconUrl.len > 0: result.iconUrl = some(iconUrl)

proc embedField*(name, value: string; inline = false): EmbedField =
  if name.len == 0 or value.len == 0:
    raise newException(ValueError,
      "an embed field needs a non-empty name and value")
  EmbedField(name: name, value: value, inline: inline)

proc add*(value: var Embed; field: sink EmbedField) =
  if value.fields.len >= 25:
    raise newException(ValueError, "an embed allows at most 25 fields")
  value.fields.add field

proc classicMessage*(content = ""; ephemeral = false): ClassicMessage =
  result.allowedMentions = AllowedMentions(
    parseEveryone: true, parseUsers: true, parseRoles: true)
  result.ephemeral = ephemeral
  if content.len > 0:
    result.content = some(content)

proc validateButton(value: Button) =
  if value.label.len notin 1 .. 80:
    raise newException(ValueError,
      "a button label must contain 1..80 characters")
  if value.style == Link:
    if value.url.isNone or value.customId.isSome:
      raise newException(ValueError,
        "a link button requires a URL and no custom id")
  elif value.customId.isNone or value.url.isSome:
    raise newException(ValueError,
      "an interactive button requires a custom id and no URL")

proc validateSelect(value: SelectMenu) =
  if value.customId.len notin 1 .. 100:
    raise newException(ValueError,
      "a select custom id must contain 1..100 characters")
  if value.minValues < 0 or value.maxValues < value.minValues or
      value.maxValues > 25:
    raise newException(ValueError,
      "a select requires 0 <= minValues <= maxValues <= 25")
  if value.kind == StringSelect:
    if value.options.len notin 1 .. 25 or
        value.maxValues > value.options.len:
      raise newException(ValueError,
        "a string select requires 1..25 options and maxValues within them")
  elif value.options.len > 0:
    raise newException(ValueError,
      "an entity select cannot contain string options")
  if value.kind != ChannelSelect and value.channelKinds.len > 0:
    raise newException(ValueError,
      "channel kinds are valid only for channel selects")

proc validateRow(components: seq[ClassicComponent]) =
  if components.len notin 1 .. 5:
    raise newException(ValueError,
      "an action row requires 1..5 interactive components")
  var selects = 0
  for component in components:
    case component.kind
    of ClassicButton: validateButton(component.button)
    of ClassicSelect:
      inc selects
      validateSelect(component.selectMenu)
  if selects > 0 and (selects != 1 or components.len != 1):
    raise newException(ValueError,
      "a select menu must be the only component in its action row")

proc validateV2Node(component: V2Component; insideContainer: bool;
                    visiting: var HashSet[pointer];
                    customIds: var HashSet[string]; total: var int) =
  if component.isNil:
    raise newException(ValueError, "a Components V2 node cannot be nil")
  let identity = cast[pointer](component)
  if identity in visiting:
    raise newException(ValueError, "a Components V2 tree cannot contain a cycle")
  visiting.incl identity
  defer: visiting.excl identity
  inc total
  case component.kind
  of TextDisplay:
    if component.text.len notin 1 .. 4000:
      raise newException(ValueError,
        "a text display must contain 1..4000 characters")
  of V2ActionRow:
    validateRow(component.interactiveComponents)
    total += component.interactiveComponents.len
    for child in component.interactiveComponents:
      let customId = case child.kind
        of ClassicButton: child.button.customId.get("")
        of ClassicSelect: child.selectMenu.customId
      if customId.len > 0:
        if customId in customIds:
          raise newException(ValueError,
            "component custom ids must be unique: " & customId)
        customIds.incl customId
  of Section:
    if component.sectionTexts.len notin 1 .. 3:
      raise newException(ValueError,
        "a section requires 1..3 text displays")
    total += component.sectionTexts.len + 1
    for text in component.sectionTexts:
      if text.len notin 1 .. 4000:
        raise newException(ValueError,
          "a section text must contain 1..4000 characters")
    if component.sectionAccessory.kind == AccessoryButton:
      validateButton(component.sectionAccessory.accessoryButton)
      let customId = component.sectionAccessory.accessoryButton.customId.get("")
      if customId.len > 0:
        if customId in customIds:
          raise newException(ValueError,
            "component custom ids must be unique: " & customId)
        customIds.incl customId
    elif component.sectionAccessory.thumbnail.url.len == 0:
      raise newException(ValueError, "a thumbnail needs a URL")
  of MediaGallery:
    if component.mediaItems.len notin 1 .. 10:
      raise newException(ValueError,
        "a media gallery requires 1..10 items")
    for item in component.mediaItems:
      if item.url.len == 0:
        raise newException(ValueError, "a media item needs a URL")
  of FileDisplay:
    if not component.fileItem.url.startsWith("attachment://") or
        component.fileItem.url.len == "attachment://".len:
      raise newException(ValueError,
        "a file display URL must use attachment://<filename>")
  of Separator:
    discard
  of Container:
    if insideContainer:
      raise newException(ValueError,
        "a Components V2 container cannot contain another container")
    if component.containerComponents.len == 0:
      raise newException(ValueError,
        "a Components V2 container cannot be empty")
    for child in component.containerComponents:
      validateV2Node(child, true, visiting, customIds, total)

proc componentsV2*(components: seq[V2Component];
                   ephemeral = false): V2Message =
  if components.len == 0:
    raise newException(ValueError,
      "a Components V2 message requires at least one component")
  var count = 0
  var visiting = initHashSet[pointer]()
  var customIds = initHashSet[string]()
  for component in components:
    validateV2Node(component, false, visiting, customIds, count)
  if count > 40:
    raise newException(ValueError,
      "a Components V2 message allows at most 40 total components")
  V2Message(components: components, ephemeral: ephemeral,
            allowedMentions: AllowedMentions(
              parseEveryone: true, parseUsers: true, parseRoles: true))

proc messageBody*(value: ClassicMessage): MessageBody =
  if value.content.isSome and value.content.get.len > 2000:
    raise newException(ValueError,
      "classic message content allows at most 2000 characters")
  if value.embeds.len > 10:
    raise newException(ValueError, "a classic message allows at most 10 embeds")
  if value.rows.len > 5:
    raise newException(ValueError,
      "a classic message allows at most 5 action rows")
  if value.files.len > 10:
    raise newException(ValueError, "a message allows at most 10 uploaded files")
  var customIds = initHashSet[string]()
  for row in value.rows:
    validateRow(row.components)
    for component in row.components:
      let customId = case component.kind
        of ClassicButton: component.button.customId.get("")
        of ClassicSelect: component.selectMenu.customId
      if customId.len > 0:
        if customId in customIds:
          raise newException(ValueError,
            "component custom ids must be unique: " & customId)
        customIds.incl customId
  MessageBody(kind: ClassicBody, classic: value)

proc messageBody*(value: V2Message): MessageBody =
  if value.files.len > 10:
    raise newException(ValueError, "a message allows at most 10 uploaded files")
  discard componentsV2(value.components, value.ephemeral)
  MessageBody(kind: ComponentsV2Body, v2: value)

proc button*(label, customId: string; style = Primary;
             disabled = false): Button =
  if label.len notin 1 .. 80:
    raise newException(ValueError,
      "a button label must contain 1..80 characters")
  if customId.len notin 1 .. 100:
    raise newException(ValueError,
      "a button custom id must contain 1..100 characters")
  if style == Link:
    raise newException(ValueError, "use linkButton for link-style buttons")
  Button(label: label, customId: some(customId), style: style,
         disabled: disabled)

proc linkButton*(label, url: string; disabled = false): Button =
  if label.len notin 1 .. 80:
    raise newException(ValueError,
      "a button label must contain 1..80 characters")
  if url.len notin 1 .. 512:
    raise newException(ValueError,
      "a link button URL must contain 1..512 characters")
  Button(label: label, url: some(url), style: Link, disabled: disabled)

proc actionRow*(buttons: varargs[Button]): ClassicActionRow =
  if buttons.len notin 1 .. 5:
    raise newException(ValueError, "an action row requires 1..5 buttons")
  for value in buttons:
    result.components.add ClassicComponent(kind: ClassicButton,
                                            button: value)

proc selectOption*(label, value: string; description = "";
                   default = false): SelectOption =
  if label.len notin 1 .. 100 or value.len notin 1 .. 100:
    raise newException(ValueError,
      "a select option label and value must contain 1..100 characters")
  if description.len > 100:
    raise newException(ValueError,
      "a select option description allows at most 100 characters")
  result = SelectOption(label: label, value: value, default: default)
  if description.len > 0: result.description = some(description)

proc selectMenu*(customId: string; options: openArray[SelectOption];
                 placeholder = ""; minValues = 1; maxValues = 1;
                 disabled = false): SelectMenu =
  if options.len notin 1 .. 25:
    raise newException(ValueError,
      "a string select menu requires 1..25 options")
  if customId.len notin 1 .. 100:
    raise newException(ValueError,
      "a select custom id must contain 1..100 characters")
  if placeholder.len > 150:
    raise newException(ValueError,
      "a select placeholder allows at most 150 characters")
  if minValues < 0 or maxValues < minValues or maxValues > options.len:
    raise newException(ValueError,
      "a string select requires 0 <= minValues <= maxValues <= option count")
  let defaults = options.countIt(it.default)
  if defaults > 0 and defaults notin minValues .. maxValues:
    raise newException(ValueError,
      "the default option count must fit minValues..maxValues")
  result = SelectMenu(kind: StringSelect, customId: customId,
    minValues: minValues, maxValues: maxValues, disabled: disabled,
    options: @options)
  if placeholder.len > 0: result.placeholder = some(placeholder)

proc entitySelect(kind: SelectMenuKind; customId, placeholder: string;
                  minValues, maxValues: int; disabled: bool): SelectMenu =
  if kind == StringSelect:
    raise newException(ValueError, "use selectMenu for string selects")
  if customId.len notin 1 .. 100:
    raise newException(ValueError,
      "a select custom id must contain 1..100 characters")
  if placeholder.len > 150:
    raise newException(ValueError,
      "a select placeholder allows at most 150 characters")
  if minValues < 0 or maxValues < minValues or maxValues > 25:
    raise newException(ValueError,
      "an entity select requires 0 <= minValues <= maxValues <= 25")
  result = SelectMenu(kind: kind, customId: customId,
    minValues: minValues, maxValues: maxValues, disabled: disabled)
  if placeholder.len > 0: result.placeholder = some(placeholder)

proc userSelect*(customId: string; placeholder = ""; minValues = 1;
                 maxValues = 1; disabled = false): SelectMenu =
  entitySelect(UserSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc roleSelect*(customId: string; placeholder = ""; minValues = 1;
                 maxValues = 1; disabled = false): SelectMenu =
  entitySelect(RoleSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc mentionableSelect*(customId: string; placeholder = ""; minValues = 1;
                        maxValues = 1; disabled = false): SelectMenu =
  entitySelect(MentionableSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc channelSelect*(customId: string; channelKinds: set[ChannelKind] = {};
                    placeholder = ""; minValues = 1; maxValues = 1;
                    disabled = false): SelectMenu =
  result = entitySelect(ChannelSelect, customId, placeholder, minValues,
                        maxValues, disabled)
  for kind in channelKinds: result.channelKinds.add kind

proc actionRow*(menu: SelectMenu): ClassicActionRow =
  ClassicActionRow(components: @[
    ClassicComponent(kind: ClassicSelect, selectMenu: menu)
  ])

proc textDisplay*(content: string): V2Component =
  V2Component(kind: TextDisplay, text: content)

proc v2ActionRow*(buttons: varargs[Button]): V2Component =
  if buttons.len notin 1 .. 5:
    raise newException(ValueError, "an action row requires 1..5 buttons")
  result = V2Component(kind: V2ActionRow)
  for button in buttons:
    result.interactiveComponents.add ClassicComponent(
      kind: ClassicButton, button: button)

proc v2ActionRow*(menu: SelectMenu): V2Component =
  V2Component(kind: V2ActionRow, interactiveComponents: @[
    ClassicComponent(kind: ClassicSelect, selectMenu: menu)
  ])

proc mediaItem*(url: string; description = "";
                spoiler = false): MediaItem =
  result = MediaItem(url: url, spoiler: spoiler)
  if description.len > 0: result.description = some(description)

proc buttonAccessory*(button: Button): SectionAccessory =
  if button.style == Link or button.customId.isSome:
    return SectionAccessory(kind: AccessoryButton,
                            accessoryButton: button)
  raise newException(ValueError, "a section button needs a custom id or URL")

proc thumbnailAccessory*(url: string; description = "";
                         spoiler = false): SectionAccessory =
  SectionAccessory(kind: AccessoryThumbnail,
    thumbnail: mediaItem(url, description, spoiler))

proc section*(texts: openArray[string];
              accessory: SectionAccessory): V2Component =
  if texts.len notin 1 .. 3:
    raise newException(ValueError,
      "a Components V2 section requires 1..3 text displays")
  V2Component(kind: Section, sectionTexts: @texts,
              sectionAccessory: accessory)

proc mediaGallery*(items: openArray[MediaItem]): V2Component =
  if items.len notin 1 .. 10:
    raise newException(ValueError,
      "a Components V2 media gallery requires 1..10 items")
  V2Component(kind: MediaGallery, mediaItems: @items)

proc fileDisplay*(attachmentUrl: string; spoiler = false): V2Component =
  if not attachmentUrl.startsWith("attachment://") or
      attachmentUrl.len == "attachment://".len:
    raise newException(ValueError,
      "a file display URL must use attachment://<filename>")
  V2Component(kind: FileDisplay,
              fileItem: mediaItem(attachmentUrl, spoiler = spoiler))

proc separator*(divider = true; spacing: range[1 .. 2] = 1): V2Component =
  V2Component(kind: Separator, divider: divider, spacing: spacing)

proc container*(components: openArray[V2Component];
                accentColor = none(int); spoiler = false): V2Component =
  if components.len == 0:
    raise newException(ValueError,
      "a Components V2 container cannot be empty")
  if accentColor.isSome and accentColor.get notin 0 .. 0xFFFFFF:
    raise newException(ValueError,
      "a container accent color must be between 0x000000 and 0xFFFFFF")
  V2Component(kind: Container, containerComponents: @components,
              accentColor: accentColor, containerSpoiler: spoiler)

proc userRejection*(message: string): ref UserRejectionError =
  result = newException(UserRejectionError, message)
  result.userMessageValue = message

proc userMessage*(error: ref UserRejectionError): string =
  if error.userMessageValue.len > 0: error.userMessageValue
  else: error.msg.split("\nAsync traceback:")[0]

proc allow*(): CheckDecision = CheckDecision(kind: CheckPassed)

proc deny*(message: string): CheckDecision =
  if message.len == 0:
    raise newException(ValueError, "a rejected check needs a message")
  CheckDecision(kind: CheckRejected, rejectionMessage: message)

proc cooldownRule*(durationMs: int64;
                   scope = UserCooldown): CooldownRule =
  if durationMs <= 0:
    raise newException(ValueError,
      "a cooldown duration must be greater than zero")
  CooldownRule(durationMs: durationMs, scope: scope)

proc noMentions*(): AllowedMentions = AllowedMentions()

proc uploadedFile*(filename, content: string;
                   description = ""): UploadedFile =
  if filename.len == 0 or extractFilename(filename) != filename:
    raise newException(ValueError,
      "an uploaded file needs a plain non-empty filename")
  result = UploadedFile(filename: filename, content: content)
  if description.len > 0: result.description = some(description)

proc textInput*(customId, label: string; style = ShortText;
                description = ""; required = true;
                minLength = none(int); maxLength = none(int);
                value = none(string);
                placeholder = none(string)): ModalInput =
  result = ModalInput(customId: customId, label: label, style: style,
    required: required, minLength: minLength, maxLength: maxLength,
    value: value, placeholder: placeholder)
  if description.len > 0: result.description = some(description)

proc modalDialog*(customId, title: string;
                  inputs: varargs[ModalInput]): Modal =
  if customId.len notin 1 .. 100:
    raise newException(ValueError, "a modal custom id must contain 1..100 characters")
  if title.len notin 1 .. 45:
    raise newException(ValueError, "a modal title must contain 1..45 characters")
  if inputs.len notin 1 .. 5:
    raise newException(ValueError, "a modal requires 1..5 inputs")
  result = Modal(customId: customId, title: title, inputs: @inputs)
  var ids = initTable[string, bool]()
  for input in result.inputs:
    if input.customId.len notin 1 .. 100:
      raise newException(ValueError,
        "a modal input custom id must contain 1..100 characters")
    if input.label.len notin 1 .. 45:
      raise newException(ValueError,
        "a modal input label must contain 1..45 characters")
    if ids.hasKey(input.customId):
      raise newException(ValueError,
        "modal input custom ids must be unique: " & input.customId)
    ids[input.customId] = true
    if input.minLength.isSome and input.minLength.get notin 0 .. 4000:
      raise newException(ValueError, "modal minLength must be in 0..4000")
    if input.maxLength.isSome and input.maxLength.get notin 1 .. 4000:
      raise newException(ValueError, "modal maxLength must be in 1..4000")
    if input.minLength.isSome and input.maxLength.isSome and
        input.minLength.get > input.maxLength.get:
      raise newException(ValueError,
        "modal minLength must not exceed maxLength")

proc choice*(name, value: string): Choice =
  Choice(name: name, value: %value)

proc choice*(name: string; value: int): Choice =
  Choice(name: name, value: %value)

proc choice*(name: string; value: float): Choice =
  Choice(name: name, value: %value)

proc toJson(value: AllowedMentions): JsonNode =
  var parse = newJArray()
  if value.parseEveryone: parse.add %"everyone"
  if value.parseUsers: parse.add %"users"
  if value.parseRoles: parse.add %"roles"
  result = %*{"parse": parse, "replied_user": value.repliedUser}
  result["users"] = %value.users.mapIt($it)
  result["roles"] = %value.roles.mapIt($it)

proc toJson(value: Button): JsonNode =
  result = %*{"type": 2, "style": int(value.style), "label": value.label,
              "disabled": value.disabled}
  if value.customId.isSome: result["custom_id"] = %value.customId.get
  if value.url.isSome: result["url"] = %value.url.get

proc toJson(value: SelectOption): JsonNode =
  result = %*{
    "label": value.label,
    "value": value.value,
    "default": value.default
  }
  if value.description.isSome:
    result["description"] = %value.description.get

proc toJson(value: SelectMenu): JsonNode =
  result = %*{
    "type": int(value.kind),
    "custom_id": value.customId,
    "min_values": value.minValues,
    "max_values": value.maxValues,
    "disabled": value.disabled
  }
  if value.placeholder.isSome:
    result["placeholder"] = %value.placeholder.get
  if value.options.len > 0:
    result["options"] = newJArray()
    for option in value.options: result["options"].add option.toJson
  if value.channelKinds.len > 0:
    result["channel_types"] = newJArray()
    for kind in value.channelKinds:
      result["channel_types"].add %int(kind)

proc toJson(value: ClassicComponent): JsonNode =
  case value.kind
  of ClassicButton: value.button.toJson
  of ClassicSelect: value.selectMenu.toJson

proc toJson(value: MediaItem): JsonNode =
  result = %*{"media": {"url": value.url}}
  if value.description.isSome:
    result["description"] = %value.description.get
  if value.spoiler: result["spoiler"] = %true

proc toJson(value: SectionAccessory): JsonNode =
  case value.kind
  of AccessoryButton:
    result = value.accessoryButton.toJson
  of AccessoryThumbnail:
    result = value.thumbnail.toJson
    result["type"] = %11

proc toJson(value: V2Component): JsonNode =
  case value.kind
  of TextDisplay:
    result = %*{"type": 10, "content": value.text}
  of V2ActionRow:
    var interactive = newJArray()
    for item in value.interactiveComponents:
      interactive.add item.toJson
    result = %*{"type": 1, "components": interactive}
  of Section:
    var texts = newJArray()
    for text in value.sectionTexts:
      texts.add %*{"type": 10, "content": text}
    result = %*{
      "type": 9,
      "components": texts,
      "accessory": value.sectionAccessory.toJson
    }
  of MediaGallery:
    var items = newJArray()
    for item in value.mediaItems: items.add item.toJson
    result = %*{"type": 12, "items": items}
  of FileDisplay:
    result = %*{
      "type": 13,
      "file": {"url": value.fileItem.url}
    }
    if value.fileItem.spoiler: result["spoiler"] = %true
  of Separator:
    result = %*{
      "type": 14,
      "divider": value.divider,
      "spacing": int(value.spacing)
    }
  of Container:
    var children = newJArray()
    for child in value.containerComponents: children.add child.toJson
    result = %*{"type": 17, "components": children}
    if value.accentColor.isSome:
      result["accent_color"] = %value.accentColor.get
    if value.containerSpoiler: result["spoiler"] = %true

proc toJson(value: Embed): JsonNode =
  result = newJObject()
  if value.title.isSome: result["title"] = %value.title.get
  if value.description.isSome:
    result["description"] = %value.description.get
  if value.url.isSome: result["url"] = %value.url.get
  if value.timestamp.isSome: result["timestamp"] = %value.timestamp.get
  if value.color.isSome: result["color"] = %value.color.get
  if value.footer.isSome:
    let footer = value.footer.get
    result["footer"] = %*{"text": footer.text}
    if footer.iconUrl.isSome:
      result["footer"]["icon_url"] = %footer.iconUrl.get
  if value.image.isSome:
    result["image"] = %*{"url": value.image.get.url}
  if value.thumbnail.isSome:
    result["thumbnail"] = %*{"url": value.thumbnail.get.url}
  if value.author.isSome:
    let author = value.author.get
    result["author"] = %*{"name": author.name}
    if author.url.isSome: result["author"]["url"] = %author.url.get
    if author.iconUrl.isSome:
      result["author"]["icon_url"] = %author.iconUrl.get
  if value.fields.len > 0:
    result["fields"] = newJArray()
    for field in value.fields:
      result["fields"].add %*{
        "name": field.name,
        "value": field.value,
        "inline": field.inline
      }

proc toJson(value: ClassicMessage): JsonNode =
  result = newJObject()
  if value.content.isSome: result["content"] = %value.content.get
  result["embeds"] = newJArray()
  for embed in value.embeds: result["embeds"].add embed.toJson
  var components = newJArray()
  for row in value.rows:
    var items = newJArray()
    for component in row.components:
      items.add component.toJson
    components.add %*{"type": 1, "components": items}
  result["components"] = components
  result["allowed_mentions"] = value.allowedMentions.toJson
  result["tts"] = %value.tts
  if value.ephemeral: result["flags"] = %64
  if value.files.len > 0:
    result["attachments"] = newJArray()
    for index, file in value.files:
      var attachment = %*{"id": $index, "filename": file.filename}
      if file.description.isSome:
        attachment["description"] = %file.description.get
      result["attachments"].add attachment

proc toJson(value: V2Message): JsonNode =
  result = newJObject()
  var components = newJArray()
  for component in value.components:
    components.add component.toJson
  result["components"] = components
  result["allowed_mentions"] = value.allowedMentions.toJson
  result["flags"] = %(32768 or (if value.ephemeral: 64 else: 0))
  if value.files.len > 0:
    result["attachments"] = newJArray()
    for index, file in value.files:
      var attachment = %*{"id": $index, "filename": file.filename}
      if file.description.isSome:
        attachment["description"] = %file.description.get
      result["attachments"].add attachment

proc toJson(value: MessageBody): JsonNode =
  case value.kind
  of ClassicBody: value.classic.toJson
  of ComponentsV2Body: value.v2.toJson

proc toEditJson(value: MessageBody): JsonNode =
  result = value.toJson
  case value.kind
  of ClassicBody:
    if value.classic.content.isNone: result["content"] = newJNull()
  of ComponentsV2Body:
    result["content"] = newJNull()
    result["embeds"] = newJArray()
    result["poll"] = newJNull()
  if not result.hasKey("attachments"):
    result["attachments"] = newJArray()

proc files(value: MessageBody): seq[UploadedFile] =
  case value.kind
  of ClassicBody: value.classic.files
  of ComponentsV2Body: value.v2.files

proc requireState(controller: ResponseController;
                  expected: set[ResponseState]; operation: string) =
  if controller.state == OutcomeUnknown:
    raise newException(ResponseOutcomeUnknownError,
      operation & " is disabled because the preceding response outcome " &
      "is unknown")
  if controller.state notin expected:
    raise newException(InvalidResponseStateError,
      operation & " is invalid while the response is " &
      $controller.state)

proc sendInitial(controller: ResponseController; kind: InitialResponseKind;
                 data: JsonNode; next: ResponseState;
                 files: seq[UploadedFile] = @[]): Future[void] {.async.} =
  try:
    await controller.sink.initial(controller.interactionId, controller.token,
                                  kind, data, files)
    controller.state = next
  except ResponseRejectedError:
    raise
  except CatchableError as error:
    controller.state = OutcomeUnknown
    raise newException(ResponseOutcomeUnknownError,
      "Discord may have accepted the response: " & error.msg)

proc respond*(ctx: InteractionContext;
              body: MessageBody): Future[Message] {.async.} =
  ctx.response.requireState({Pending}, "respond")
  await ctx.response.sendInitial(InitialMessage, body.toJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc respond*(ctx: InteractionContext; content: string;
              ephemeral = false): Future[Message] =
  ctx.respond(classicMessage(content, ephemeral).messageBody)

proc deferReply*(ctx: InteractionContext;
                 ephemeral = false): Future[void] {.async.} =
  ctx.response.requireState({Pending}, "deferReply")
  let flags = if ephemeral: 64 else: 0
  await ctx.response.sendInitial(InitialDeferredMessage, %*{"flags": flags},
                                 DeferredReply)

proc update*(ctx: ComponentContext;
             body: MessageBody): Future[Message] {.async.} =
  ctx.response.requireState({Pending}, "update")
  await ctx.response.sendInitial(InitialUpdate, body.toEditJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc update*(ctx: ComponentContext; content: string): Future[Message] =
  ctx.update(classicMessage(content).messageBody)

proc deferUpdate*(ctx: ComponentContext): Future[void] {.async.} =
  ctx.response.requireState({Pending}, "deferUpdate")
  await ctx.response.sendInitial(InitialDeferredUpdate, newJObject(),
                                 DeferredUpdate)

proc requireComponentSource(ctx: ModalContext; operation: string) =
  if ctx.sourceValue.isNone or
      ctx.sourceValue.get.kindValue != ComponentModalSource:
    raise newException(InvalidResponseStateError,
      operation & " requires a modal opened from a message component")

proc update*(ctx: ModalContext;
             body: MessageBody): Future[Message] {.async.} =
  ctx.requireComponentSource("update")
  ctx.response.requireState({Pending}, "update")
  await ctx.response.sendInitial(InitialUpdate, body.toEditJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc update*(ctx: ModalContext; content: string): Future[Message] =
  ctx.update(classicMessage(content).messageBody)

proc deferUpdate*(ctx: ModalContext): Future[void] {.async.} =
  ctx.requireComponentSource("deferUpdate")
  ctx.response.requireState({Pending}, "deferUpdate")
  await ctx.response.sendInitial(InitialDeferredUpdate, newJObject(),
                                 DeferredUpdate)

proc editOriginal*(ctx: InteractionContext;
                   body: MessageBody): Future[Message] {.async.} =
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "editOriginal")
  if ctx.response.originalUsesV2 and body.kind != ComponentsV2Body:
    raise newException(InvalidResponseStateError,
      "a Components V2 message cannot be converted back to classic content")
  let message = await ctx.response.sink.editMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId,
    body.toEditJson, body.files)
  ctx.response.state = Responded
  if body.kind == ComponentsV2Body:
    ctx.response.originalUsesV2 = true
  return message

proc toJson(value: Modal): JsonNode =
  result = %*{"custom_id": value.customId, "title": value.title}
  result["components"] = newJArray()
  for input in value.inputs:
    var data = %*{
      "type": 4,
      "custom_id": input.customId,
      "style": int(input.style),
      "required": input.required
    }
    if input.minLength.isSome: data["min_length"] = %input.minLength.get
    if input.maxLength.isSome: data["max_length"] = %input.maxLength.get
    if input.value.isSome: data["value"] = %input.value.get
    if input.placeholder.isSome:
      data["placeholder"] = %input.placeholder.get
    var label = %*{"type": 18, "label": input.label, "component": data}
    if input.description.isSome:
      label["description"] = %input.description.get
    result["components"].add label

proc showModal*(ctx: SlashCommandContext | ComponentContext;
                modal: Modal): Future[void] {.async.} =
  ctx.response.requireState({Pending}, "showModal")
  await ctx.response.sendInitial(InitialModal, modal.toJson, Responded)

proc launchActivity*(ctx: SlashCommandContext | UserCommandContext |
    MessageCommandContext | ComponentContext | ModalContext):
    Future[ActivityInstance] {.async.} =
  ctx.response.requireState({Pending}, "launchActivity")
  try:
    result = await ctx.response.sink.launchActivity(
      ctx.response.interactionId, ctx.response.token)
    ctx.response.state = Responded
  except ResponseRejectedError:
    raise
  except CatchableError as error:
    ctx.response.state = OutcomeUnknown
    raise newException(ResponseOutcomeUnknownError,
      "Discord may have launched the Activity: " & error.msg)

proc sendChoices(ctx: AutocompleteContext;
                 values: JsonNode): Future[void] {.async.} =
  ctx.response.requireState({Pending}, "complete")
  await ctx.response.sendInitial(InitialAutocomplete,
                                 %*{"choices": values}, Responded)

proc complete*(ctx: AutocompleteContext;
               choices: openArray[Choice]): Future[void] =
  if choices.len > 25:
    raise newException(ValueError,
      "autocomplete allows at most 25 choices")
  var values = newJArray()
  for choice in choices:
    if choice.name.len notin 1 .. 100:
      raise newException(ValueError,
        "an autocomplete choice name must contain 1..100 characters")
    values.add %*{"name": choice.name, "value": choice.value}
  ctx.sendChoices(values)

proc editOriginal*(ctx: InteractionContext;
                   content: string): Future[Message] =
  ctx.editOriginal(classicMessage(content).messageBody)

proc followup*(ctx: InteractionContext;
               body: MessageBody): Future[Message] {.async.} =
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "followup")
  return await ctx.response.sink.createFollowup(
    ctx.response.applicationId, ctx.response.token, body.toJson, body.files)

proc followup*(ctx: InteractionContext; content: string;
               ephemeral = false): Future[Message] =
  ctx.followup(classicMessage(content, ephemeral).messageBody)

proc editFollowup*(ctx: InteractionContext; messageId: MessageId;
                   body: MessageBody): Future[Message] {.async.} =
  if messageId == OriginalMessageId:
    return await ctx.editOriginal(body)
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "editFollowup")
  return await ctx.response.sink.editMessage(
    ctx.response.applicationId, ctx.response.token, messageId,
    body.toEditJson,
    body.files)

proc editFollowup*(ctx: InteractionContext; messageId: MessageId;
                   content: string): Future[Message] =
  ctx.editFollowup(messageId, classicMessage(content).messageBody)

proc original*(ctx: InteractionContext): Future[Message] =
  ctx.response.sink.getMessage(ctx.response.applicationId,
                               ctx.response.token, OriginalMessageId)

proc deleteOriginal*(ctx: InteractionContext): Future[void] {.async.} =
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "deleteOriginal")
  await ctx.response.sink.deleteMessage(ctx.response.applicationId,
                                        ctx.response.token,
                                        OriginalMessageId)

proc deleteFollowup*(ctx: InteractionContext;
                     messageId: MessageId): Future[void] {.async.} =
  if messageId == OriginalMessageId:
    await ctx.deleteOriginal()
    return
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "deleteFollowup")
  await ctx.response.sink.deleteMessage(ctx.response.applicationId,
                                        ctx.response.token, messageId)

proc decodeUser(node: JsonNode): User
proc decodeMember(node: JsonNode; user: User): Member
proc decodeRole(node: JsonNode): Role
proc decodeChannel(node: JsonNode): ResolvedChannel
proc decodeAttachment(node: JsonNode): Attachment

proc resolvedEntity(resolved: JsonNode; collection,
                    id: string): Option[JsonNode] =
  if resolved.isNil or resolved.kind != JObject or
      not resolved.hasKey(collection):
    return none(JsonNode)
  let entities = resolved[collection]
  if entities.kind != JObject or not entities.hasKey(id):
    return none(JsonNode)
  some(entities[id])

proc selectedUsers*(ctx: ComponentContext): seq[User] =
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("users", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected user is not resolved: " & id)
    result.add decodeUser(entity.get)

proc selectedMembers*(ctx: ComponentContext): seq[Member] =
  for id in ctx.valuesValue:
    let member = ctx.resolvedValue.resolvedEntity("members", id)
    let user = ctx.resolvedValue.resolvedEntity("users", id)
    if member.isNone or user.isNone:
      raise newException(InvalidInteractionError,
        "selected member is not resolved: " & id)
    result.add decodeMember(member.get, decodeUser(user.get))

proc selectedRoles*(ctx: ComponentContext): seq[Role] =
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("roles", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected role is not resolved: " & id)
    result.add decodeRole(entity.get)

proc selectedChannels*(ctx: ComponentContext): seq[ResolvedChannel] =
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("channels", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected channel is not resolved: " & id)
    result.add decodeChannel(entity.get)

proc selectedMentionables*(ctx: ComponentContext): seq[Mentionable] =
  for id in ctx.valuesValue:
    let user = ctx.resolvedValue.resolvedEntity("users", id)
    if user.isSome:
      result.add Mentionable(kind: MentionableUser,
                             mentionedUser: decodeUser(user.get))
      continue
    let role = ctx.resolvedValue.resolvedEntity("roles", id)
    if role.isSome:
      result.add Mentionable(kind: MentionableRole,
                             mentionedRole: decodeRole(role.get))
      continue
    raise newException(InvalidInteractionError,
      "selected mentionable is not resolved: " & id)

proc invalidOption(name: string) {.noinline, noreturn.} =
  raise newException(InvalidInteractionError,
    "slash option is missing or invalid: " & name)

proc optionJson(ctx: SlashCommandContext; name: string): Option[JsonNode] =
  if ctx.optionsValue.kind != JObject or not ctx.optionsValue.hasKey(name):
    return none(JsonNode)
  some(ctx.optionsValue[name])

proc resolvedEntity(ctx: SlashCommandContext; collection,
                    id: string): Option[JsonNode] =
  ctx.resolvedValue.resolvedEntity(collection, id)

proc requiredOption*[T](ctx: SlashCommandContext; name: string): T =
  let value = ctx.optionJson(name)
  if value.isNone:
    invalidOption(name)
  try:
    when T is string:
      return value.get.getStr
    elif T is int:
      return value.get.getInt
    elif T is bool:
      return value.get.getBool
    elif T is float:
      return value.get.getFloat
    elif T is User:
      let entity = ctx.resolvedEntity("users", value.get.getStr)
      if entity.isSome: return decodeUser(entity.get)
    elif T is Member:
      let id = value.get.getStr
      let member = ctx.resolvedEntity("members", id)
      let user = ctx.resolvedEntity("users", id)
      if member.isSome and user.isSome:
        return decodeMember(member.get, decodeUser(user.get))
    elif T is Role:
      let entity = ctx.resolvedEntity("roles", value.get.getStr)
      if entity.isSome: return decodeRole(entity.get)
    elif T is ResolvedChannel:
      let entity = ctx.resolvedEntity("channels", value.get.getStr)
      if entity.isSome: return decodeChannel(entity.get)
    elif T is Attachment:
      let entity = ctx.resolvedEntity("attachments", value.get.getStr)
      if entity.isSome: return decodeAttachment(entity.get)
    elif T is Mentionable:
      let id = value.get.getStr
      let user = ctx.resolvedEntity("users", id)
      if user.isSome:
        return Mentionable(kind: MentionableUser,
                           mentionedUser: decodeUser(user.get))
      let role = ctx.resolvedEntity("roles", id)
      if role.isSome:
        return Mentionable(kind: MentionableRole,
                           mentionedRole: decodeRole(role.get))
    elif T is enum:
      let raw = value.get.getStr
      for candidate in T:
        if candidate.symbolName == raw: return candidate
    elif T is range:
      let raw = value.get.getInt
      when low(T) is SomeInteger and high(T) is SomeInteger:
        if raw >= int(low(T)) and raw <= int(high(T)): return T(raw)
    elif T is distinct:
      when distinctBase(T) is string:
        return T(value.get.getStr)
      elif distinctBase(T) is int:
        return T(value.get.getInt)
      else:
        {.error: "distinct slash options must wrap string or int".}
    else:
      {.error: "unsupported slash option type".}
  except JsonKindError, ValueError, RangeDefect:
    discard
  invalidOption(name)

proc optionalOption*[T](ctx: SlashCommandContext; name: string): Option[T] =
  let value = ctx.optionJson(name)
  if value.isNone:
    return none(T)
  some(requiredOption[T](ctx, name))

proc capture*(ctx: ComponentContext | ModalContext; name: string): string =
  if not ctx.capturesValue.hasKey(name):
    raise newException(InvalidInteractionError, "capture is missing: " & name)
  ctx.capturesValue[name]

proc captureInt*(ctx: ComponentContext | ModalContext; name: string): int =
  try:
    parseInt(ctx.capture(name))
  except ValueError:
    raise newException(InvalidInteractionError,
      "capture is not an integer: " & name)

proc requiredModalField*[T](ctx: ModalContext; name: string;
                            label = ""): T =
  let value = ctx.field(name)
  if value.isNone:
    raise newException(InvalidInteractionError,
      "modal field is missing: " & name)
  when T is string:
    return value.get
  elif T is int:
    let displayName = if label.len > 0: label else: name
    try: return parseInt(value.get.strip)
    except ValueError:
      raise userRejection("\"" & displayName &
        "\" must be a whole number.")
  elif T is float:
    let displayName = if label.len > 0: label else: name
    try: return parseFloat(value.get.strip)
    except ValueError:
      raise userRejection("\"" & displayName & "\" must be a number.")
  else:
    {.error: "modal text fields support string, int, and float".}

proc optionalModalField*[T](ctx: ModalContext; name: string;
                            label = ""): Option[T] =
  let value = ctx.field(name)
  if value.isNone or value.get.strip.len == 0: return none(T)
  some(requiredModalField[T](ctx, name, label))

proc parsePattern(value: string): Pattern =
  result.raw = value
  var cursor = 0
  while cursor < value.len:
    let opening = value.find('{', cursor)
    if opening < 0:
      result.segments.add PatternSegment(
        kind: LiteralSegment, literal: value[cursor .. ^1])
      break
    if opening > cursor:
      result.segments.add PatternSegment(
        kind: LiteralSegment, literal: value[cursor ..< opening])
    let closing = value.find('}', opening + 1)
    if closing < 0:
      raise newException(RouteDefinitionError,
        "unclosed capture in custom id pattern: " & value)
    let parts = value[opening + 1 ..< closing].split(':')
    if parts.len notin 1 .. 2 or parts[0].len == 0:
      raise newException(RouteDefinitionError,
        "invalid capture in custom id pattern: " & value)
    let kind = if parts.len == 2 and parts[1] == "int": IntegerCapture
               elif parts.len == 1 or parts[1] == "string": StringCapture
               else:
                 raise newException(RouteDefinitionError,
                   "unknown capture type in custom id pattern: " & value)
    result.segments.add PatternSegment(kind: kind, captureName: parts[0])
    cursor = closing + 1

proc match(pattern: Pattern; value: string): Option[Table[string, string]] =
  var captures = initTable[string, string]()
  var cursor = 0
  for index, segment in pattern.segments:
    case segment.kind
    of LiteralSegment:
      if not value.continuesWith(segment.literal, cursor):
        return none(Table[string, string])
      cursor += segment.literal.len
    of StringCapture, IntegerCapture:
      var closing = value.len
      if index + 1 < pattern.segments.len and
          pattern.segments[index + 1].kind == LiteralSegment:
        closing = value.find(pattern.segments[index + 1].literal, cursor)
        if closing < 0: return none(Table[string, string])
      if closing == cursor: return none(Table[string, string])
      let captured = value[cursor ..< closing]
      if segment.kind == IntegerCapture:
        try: discard parseInt(captured)
        except ValueError: return none(Table[string, string])
      captures[segment.captureName] = captured
      cursor = closing
  if cursor != value.len: return none(Table[string, string])
  some(captures)

proc rank(pattern: Pattern): tuple[exact, literal: int] =
  result.exact = 1
  for segment in pattern.segments:
    case segment.kind
    of LiteralSegment: result.literal += segment.literal.len
    of StringCapture, IntegerCapture: result.exact = 0

proc invokerId*(interaction: Interaction): Option[UserId] =
  if interaction.userValue.isSome:
    some(interaction.userValue.get.id)
  else:
    none(UserId)

proc invokerId*(ctx: InteractionContext): Option[UserId] =
  ctx.interactionValue.invokerId

proc scopedId*(ctx: InteractionContext; tag: string): string =
  result = "ds:" & tag & ":" & $ctx.interactionValue.id
  if result.len > 100:
    raise newException(ValueError,
      "a scoped component id exceeds Discord's 100-character limit")

proc parsePatterns(patterns: openArray[string]): seq[Pattern] =
  if patterns.len == 0:
    raise newException(ValueError, "a waiter needs at least one pattern")
  for pattern in patterns: result.add parsePattern(pattern)

proc awaitComponent(binding: AppBinding; waiter: ComponentWaiter;
                    timeoutMs: int): Future[Option[ComponentContext]]
                    {.async.} =
  if timeoutMs <= 0:
    raise newException(ValueError, "a waiter timeout must be positive")
  if not binding.accepting: return none(ComponentContext)
  binding.componentWaiters.add waiter
  if await withTimeout(waiter.future, timeoutMs):
    return waiter.future.read
  if waiter.future.finished: return waiter.future.read
  let index = binding.componentWaiters.find(waiter)
  if index >= 0: binding.componentWaiters.delete(index)
  if not waiter.future.finished:
    waiter.future.complete(none(ComponentContext))
  return none(ComponentContext)

proc waitForComponent*(binding: AppBinding;
    kinds: set[ComponentInteractionKind]; patterns: openArray[string];
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  if binding.isNil:
    raise newException(ValueError, "a component waiter requires a binding")
  let waiter = ComponentWaiter(kinds: kinds,
    patterns: parsePatterns(patterns), userId: userId, messageId: messageId,
    future: newFuture[Option[ComponentContext]]("dimslash.waitForComponent"))
  binding.awaitComponent(waiter, timeoutMs)

proc waitForButton*(binding: AppBinding; patterns: openArray[string];
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  binding.waitForComponent({ButtonInteraction}, patterns, timeoutMs, userId,
                           messageId)

proc waitForButton*(binding: AppBinding; pattern: string;
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  binding.waitForButton([pattern], timeoutMs, userId, messageId)

proc waitForSelect*(binding: AppBinding; patterns: openArray[string];
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  binding.waitForComponent({SelectInteraction}, patterns, timeoutMs, userId,
                           messageId)

proc waitForSelect*(binding: AppBinding; pattern: string;
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  binding.waitForSelect([pattern], timeoutMs, userId, messageId)

proc waitForComponent*(ctx: InteractionContext;
    kinds: set[ComponentInteractionKind]; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  if ctx.responseState == Pending:
    raise newException(InvalidResponseStateError,
      "waitForComponent requires the current interaction to be acknowledged")
  ctx.bindingValue.waitForComponent(kinds, patterns, timeoutMs, userId,
                                    messageId)

proc waitForButton*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ctx.waitForComponent({ButtonInteraction}, patterns, timeoutMs, userId,
                       messageId)

proc waitForButton*(ctx: InteractionContext; pattern: string;
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ctx.waitForButton([pattern], timeoutMs, userId, messageId)

proc waitForSelect*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ctx.waitForComponent({SelectInteraction}, patterns, timeoutMs, userId,
                       messageId)

proc waitForSelect*(ctx: InteractionContext; pattern: string;
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ctx.waitForSelect([pattern], timeoutMs, userId, messageId)

proc awaitModal(binding: AppBinding; waiter: ModalWaiter;
                timeoutMs: int): Future[Option[ModalContext]] {.async.} =
  if timeoutMs <= 0:
    raise newException(ValueError, "a waiter timeout must be positive")
  if not binding.accepting: return none(ModalContext)
  binding.modalWaiters.add waiter
  if await withTimeout(waiter.future, timeoutMs): return waiter.future.read
  if waiter.future.finished: return waiter.future.read
  let index = binding.modalWaiters.find(waiter)
  if index >= 0: binding.modalWaiters.delete(index)
  if not waiter.future.finished:
    waiter.future.complete(none(ModalContext))
  return none(ModalContext)

proc waitForModal*(binding: AppBinding; patterns: openArray[string];
    timeoutMs = 300_000; userId = none(UserId)):
    Future[Option[ModalContext]] =
  if binding.isNil:
    raise newException(ValueError, "a modal waiter requires a binding")
  let waiter = ModalWaiter(patterns: parsePatterns(patterns), userId: userId,
    future: newFuture[Option[ModalContext]]("dimslash.waitForModal"))
  binding.awaitModal(waiter, timeoutMs)

proc waitForModal*(binding: AppBinding; pattern: string;
    timeoutMs = 300_000; userId = none(UserId)):
    Future[Option[ModalContext]] =
  binding.waitForModal([pattern], timeoutMs, userId)

proc waitForModal*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 300_000; userId: Option[UserId] = ctx.invokerId):
    Future[Option[ModalContext]] =
  if ctx.responseState == Pending:
    raise newException(InvalidResponseStateError,
      "waitForModal requires the current interaction to be acknowledged")
  ctx.bindingValue.waitForModal(patterns, timeoutMs, userId)

proc waitForModal*(ctx: InteractionContext; pattern: string;
    timeoutMs = 300_000; userId: Option[UserId] = ctx.invokerId):
    Future[Option[ModalContext]] =
  ctx.waitForModal([pattern], timeoutMs, userId)

proc disableAll*(rows: openArray[ClassicActionRow]):
    seq[ClassicActionRow] =
  for row in rows:
    var disabled = row
    for component in disabled.components.mitems:
      case component.kind
      of ClassicButton: component.button.disabled = true
      of ClassicSelect: component.selectMenu.disabled = true
    result.add disabled

proc disabledCopy(component: V2Component): V2Component =
  if component.isNil: return nil
  case component.kind
  of TextDisplay:
    result = textDisplay(component.text)
  of V2ActionRow:
    result = V2Component(kind: V2ActionRow)
    for child in component.interactiveComponents:
      var disabled = child
      case disabled.kind
      of ClassicButton: disabled.button.disabled = true
      of ClassicSelect: disabled.selectMenu.disabled = true
      result.interactiveComponents.add disabled
  of Section:
    var accessory = component.sectionAccessory
    if accessory.kind == AccessoryButton:
      accessory.accessoryButton.disabled = true
    result = V2Component(kind: Section,
      sectionTexts: component.sectionTexts, sectionAccessory: accessory)
  of MediaGallery:
    result = V2Component(kind: MediaGallery,
                         mediaItems: component.mediaItems)
  of FileDisplay:
    result = V2Component(kind: FileDisplay, fileItem: component.fileItem)
  of Separator:
    result = V2Component(kind: Separator, divider: component.divider,
                         spacing: component.spacing)
  of Container:
    result = V2Component(kind: Container,
      accentColor: component.accentColor,
      containerSpoiler: component.containerSpoiler)
    for child in component.containerComponents:
      result.containerComponents.add disabledCopy(child)

proc disableAll*(components: openArray[V2Component]): seq[V2Component] =
  for component in components: result.add disabledCopy(component)

proc sendFlowMessage(ctx: InteractionContext; body: MessageBody):
    Future[Message] {.async.} =
  case ctx.responseState
  of Pending:
    return await ctx.respond(body)
  of DeferredReply, DeferredUpdate:
    return await ctx.editOriginal(body)
  of Responded:
    return await ctx.followup(body)
  of OutcomeUnknown:
    raise newException(ResponseOutcomeUnknownError,
      "cannot start a flow after an ambiguous response")

proc editFlowMessage(ctx: InteractionContext; messageId: MessageId;
                     body: MessageBody): Future[Message] =
  if messageId == OriginalMessageId: ctx.editOriginal(body)
  else: ctx.editFollowup(messageId, body)

proc confirm*(ctx: InteractionContext; prompt: string;
              yesLabel = "Yes"; noLabel = "No";
              timeoutMs = 60_000; ephemeral = true): Future[bool] {.async.} =
  let yesId = ctx.scopedId("confirm:yes")
  let noId = ctx.scopedId("confirm:no")
  var body = classicMessage(prompt, ephemeral)
  body.rows = @[actionRow(
    button(yesLabel, yesId, Success),
    button(noLabel, noId, Danger))]
  let message = await ctx.sendFlowMessage(body.messageBody)
  let press = await ctx.waitForButton([yesId, noId], timeoutMs,
                                      messageId = some(message.id))
  body.rows = disableAll(body.rows)
  body.ephemeral = false
  if press.isNone:
    discard await ctx.editFlowMessage(message.id, body.messageBody)
    return false
  discard await press.get.update(body.messageBody)
  return press.get.customId == yesId

proc pagerBody(ctx: InteractionContext; page: Embed; index, total: int;
               previousId, nextId: string; disabled: bool;
               ephemeral: bool): ClassicMessage =
  result = classicMessage(ephemeral = ephemeral)
  result.embeds = @[page]
  result.rows = @[actionRow(
    button("Previous", previousId, Secondary,
           disabled = disabled or index == 0),
    button($(index + 1) & " / " & $total, ctx.scopedId("pager:label"),
           Secondary, disabled = true),
    button("Next", nextId, Secondary,
           disabled = disabled or index == total - 1))]

proc paginateImpl(ctx: InteractionContext; pages: seq[Embed];
                  timeoutMs: int; ephemeral: bool): Future[void] {.async.} =
  if pages.len == 0:
    raise newException(ValueError, "paginate requires at least one page")
  if pages.len == 1:
    var body = classicMessage(ephemeral = ephemeral)
    body.embeds = @[pages[0]]
    discard await ctx.sendFlowMessage(body.messageBody)
    return
  let previousId = ctx.scopedId("pager:previous")
  let nextId = ctx.scopedId("pager:next")
  var index = 0
  let first = ctx.pagerBody(pages[0], index, pages.len, previousId, nextId,
                            false, ephemeral)
  let message = await ctx.sendFlowMessage(first.messageBody)
  while true:
    let press = await ctx.waitForButton([previousId, nextId], timeoutMs,
                                        messageId = some(message.id))
    if press.isNone:
      let disabled = ctx.pagerBody(pages[index], index, pages.len,
        previousId, nextId, true, false)
      discard await ctx.editFlowMessage(message.id, disabled.messageBody)
      return
    if press.get.customId == previousId and index > 0: dec index
    elif press.get.customId == nextId and index < pages.len - 1: inc index
    let updated = ctx.pagerBody(pages[index], index, pages.len,
      previousId, nextId, false, false)
    discard await press.get.update(updated.messageBody)

proc paginate*(ctx: InteractionContext; pages: openArray[Embed];
               timeoutMs = 120_000; ephemeral = false): Future[void] =
  ctx.paginateImpl(@pages, timeoutMs, ephemeral)


proc validateSlashName(value, subject: string) =
  if value.runeLen notin 1 .. 32:
    raise newException(RouteDefinitionError,
      subject & " must contain 1..32 characters")
  for character in value.runes:
    if character.isUpper or character.isWhiteSpace or
        int(character) < 0x20 or int(character) in 0x7f .. 0x9f or
        int(character) in {ord('/'), ord('\\')}:
      raise newException(RouteDefinitionError,
        subject & " is not a valid Discord command name: " & value)

proc validateContextCommandName(value: string) =
  if value.runeLen notin 1 .. 32 or value.strip.len == 0:
    raise newException(RouteDefinitionError,
      "context command name must contain 1..32 visible characters")
  for character in value.runes:
    if int(character) < 0x20 or int(character) in 0x7f .. 0x9f:
      raise newException(RouteDefinitionError,
        "context command name must contain 1..32 visible characters")

proc validateDescription(value, subject: string) =
  if value.len notin 1 .. 100:
    raise newException(RouteDefinitionError,
      subject & " must contain 1..100 characters")

proc validateSlashRoute(route: SlashRoute) =
  validateSlashName(route.name, "slash command name")
  validateDescription(route.description, "slash command description")
  for index, segment in route.path:
    validateSlashName(segment, "slash command path segment")
    validateDescription(route.pathDescriptions[index],
                        "slash command path description")
  var names = initTable[string, bool]()
  var optionalSeen = false
  for option in route.options:
    validateSlashName(option.name, "slash option name")
    validateDescription(option.description, "slash option description")
    if names.hasKey(option.name):
      raise newException(RouteDefinitionError,
        "duplicate slash option: " & option.name)
    names[option.name] = true
    if not option.required: optionalSeen = true
    elif optionalSeen:
      raise newException(RouteDefinitionError,
        "required slash options must precede optional options")
    if (option.minValue.isSome or option.maxValue.isSome) and
        option.kind notin {IntegerOption, NumberOption}:
      raise newException(RouteDefinitionError,
        "numeric bounds require an integer or number option: " & option.name)
    if (option.minLength.isSome or option.maxLength.isSome) and
        option.kind != StringOption:
      raise newException(RouteDefinitionError,
        "length bounds require a string option: " & option.name)
    if option.choices.len > 0 and
        option.kind notin {StringOption, IntegerOption, NumberOption}:
      raise newException(RouteDefinitionError,
        "choices require a scalar option: " & option.name)
    if option.channelKinds.len > 0 and option.kind != ChannelOption:
      raise newException(RouteDefinitionError,
        "channel constraints require a channel option: " & option.name)

proc addSlashRoute(routes: var Routes; route: SlashRoute) =
  validateSlashRoute(route)
  let key = (@[route.name] & route.path).join("/")
  if routes.slashRoutes.hasKey(key):
    raise newException(RouteDefinitionError,
      "duplicate slash command path: " & key)
  for _, existing in routes.slashRoutes:
    if existing.name == route.name:
      if existing.description != route.description:
        raise newException(RouteDefinitionError,
          "command descriptions disagree for: " & route.name)
      if existing.path.len == 0 or route.path.len == 0:
        raise newException(RouteDefinitionError,
          "a slash command cannot mix a root handler and subcommands: " &
          route.name)
  routes.slashRoutes[key] = route

proc slashRaw*(routes: var Routes; name, description: string;
               options: seq[CommandOption]; handler: SlashHandler) =
  routes.addSlashRoute(SlashRoute(name: name, description: description,
                                  options: options, handler: handler))

proc subcommandRaw(routes: var Routes; name, description: string;
                   path, pathDescriptions: seq[string];
                   options: seq[CommandOption]; handler: SlashHandler) =
  if path.len notin 1 .. 2 or path.len != pathDescriptions.len:
    raise newException(RouteDefinitionError,
      "slash subcommand paths must contain a subcommand or group/subcommand")
  routes.addSlashRoute(SlashRoute(
    name: name, description: description, path: path,
    pathDescriptions: pathDescriptions, options: options, handler: handler))

proc button*(routes: var Routes; pattern: string;
             handler: ComponentHandler) =
  for route in routes.buttonRoutes:
    if not route.isSelect and route.pattern.raw == pattern:
      raise newException(RouteDefinitionError,
        "duplicate button route: " & pattern)
  routes.buttonRoutes.add ComponentRoute(
    pattern: parsePattern(pattern), isSelect: false, handler: handler)

proc select*(routes: var Routes; pattern: string;
             handler: ComponentHandler) =
  for route in routes.buttonRoutes:
    if route.isSelect and route.pattern.raw == pattern:
      raise newException(RouteDefinitionError,
        "duplicate select route: " & pattern)
  routes.buttonRoutes.add ComponentRoute(
    pattern: parsePattern(pattern), isSelect: true, handler: handler)

proc userCommand*(routes: var Routes; name: string;
                  handler: UserCommandHandler) =
  validateContextCommandName(name)
  if routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "duplicate user command: " & name)
  routes.userRoutes[name] = NamedRoute[UserCommandHandler](
    name: name, handler: handler)

proc messageCommand*(routes: var Routes; name: string;
                     handler: MessageCommandHandler) =
  validateContextCommandName(name)
  if routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "duplicate message command: " & name)
  routes.messageRoutes[name] = NamedRoute[MessageCommandHandler](
    name: name, handler: handler)

proc checkSlash*(routes: var Routes; path: string; check: SlashCheck) =
  if check.isNil:
    raise newException(RouteDefinitionError, "a slash check cannot be nil")
  if not routes.slashRoutes.hasKey(path):
    raise newException(RouteDefinitionError,
      "cannot check an unknown slash command path: " & path)
  let typed = check
  routes.slashRoutes[path].checks.add proc(
      ctx: InteractionContext): Future[CheckDecision] =
    typed(SlashCommandContext(ctx))

proc checkUserCommand*(routes: var Routes; name: string;
                       check: UserCommandCheck) =
  if check.isNil or not routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot check an unknown user command: " & name)
  let typed = check
  routes.userRoutes[name].checks.add proc(
      ctx: InteractionContext): Future[CheckDecision] =
    typed(UserCommandContext(ctx))

proc checkMessageCommand*(routes: var Routes; name: string;
                          check: MessageCommandCheck) =
  if check.isNil or not routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot check an unknown message command: " & name)
  let typed = check
  routes.messageRoutes[name].checks.add proc(
      ctx: InteractionContext): Future[CheckDecision] =
    typed(MessageCommandContext(ctx))

proc addComponentCheck(routes: var Routes; pattern: string; isSelect: bool;
                       check: ComponentCheck) =
  if check.isNil:
    raise newException(RouteDefinitionError, "a component check cannot be nil")
  for route in routes.buttonRoutes.mitems:
    if route.isSelect == isSelect and route.pattern.raw == pattern:
      let typed = check
      route.checks.add proc(
          ctx: InteractionContext): Future[CheckDecision] =
        typed(ComponentContext(ctx))
      return
  raise newException(RouteDefinitionError,
    "cannot check an unknown component route: " & pattern)

proc checkButton*(routes: var Routes; pattern: string;
                  check: ComponentCheck) =
  routes.addComponentCheck(pattern, false, check)

proc checkSelect*(routes: var Routes; pattern: string;
                  check: ComponentCheck) =
  routes.addComponentCheck(pattern, true, check)

proc checkModal*(routes: var Routes; pattern: string; check: ModalCheck) =
  if check.isNil:
    raise newException(RouteDefinitionError, "a modal check cannot be nil")
  for route in routes.modalRoutes.mitems:
    if route.pattern.raw == pattern:
      let typed = check
      route.checks.add proc(
          ctx: InteractionContext): Future[CheckDecision] =
        typed(ModalContext(ctx))
      return
  raise newException(RouteDefinitionError,
    "cannot check an unknown modal route: " & pattern)

proc cooldownSlash*(routes: var Routes; path: string; rule: CooldownRule) =
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  if not routes.slashRoutes.hasKey(path):
    raise newException(RouteDefinitionError,
      "cannot configure cooldown for unknown slash path: " & path)
  routes.slashRoutes[path].cooldown = some(rule)

proc cooldownUserCommand*(routes: var Routes; name: string;
                          rule: CooldownRule) =
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  if not routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure cooldown for unknown user command: " & name)
  routes.userRoutes[name].cooldown = some(rule)

proc cooldownMessageCommand*(routes: var Routes; name: string;
                             rule: CooldownRule) =
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  if not routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure cooldown for unknown message command: " & name)
  routes.messageRoutes[name].cooldown = some(rule)

proc setComponentCooldown(routes: var Routes; pattern: string;
                          isSelect: bool; rule: CooldownRule) =
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  for route in routes.buttonRoutes.mitems:
    if route.isSelect == isSelect and route.pattern.raw == pattern:
      route.cooldown = some(rule)
      return
  raise newException(RouteDefinitionError,
    "cannot configure cooldown for unknown component route: " & pattern)

proc cooldownButton*(routes: var Routes; pattern: string;
                     rule: CooldownRule) =
  routes.setComponentCooldown(pattern, false, rule)

proc cooldownSelect*(routes: var Routes; pattern: string;
                     rule: CooldownRule) =
  routes.setComponentCooldown(pattern, true, rule)

proc cooldownModal*(routes: var Routes; pattern: string;
                    rule: CooldownRule) =
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  for route in routes.modalRoutes.mitems:
    if route.pattern.raw == pattern:
      route.cooldown = some(rule)
      return
  raise newException(RouteDefinitionError,
    "cannot configure cooldown for unknown modal route: " & pattern)

proc commandMetadata(defaultMemberPermissions: Option[uint64]; nsfw: bool;
                     contexts: Option[set[InteractionContextKind]];
                     integrations: Option[set[IntegrationKind]];
                     nameLocalizations,
                     descriptionLocalizations: Table[string, string]):
    CommandMetadata =
  CommandMetadata(
    defaultMemberPermissions: defaultMemberPermissions,
    nsfw: nsfw, contexts: contexts, integrations: integrations,
    nameLocalizations: nameLocalizations,
    descriptionLocalizations: descriptionLocalizations)

proc configureSlash*(routes: var Routes; name: string;
                     defaultMemberPermissions = none(uint64);
                     nsfw = false;
                     contexts = none(set[InteractionContextKind]);
                     integrations = none(set[IntegrationKind]);
                     nameLocalizations = Table[string, string]();
                     descriptionLocalizations = Table[string, string]()) =
  var found = false
  let metadata = commandMetadata(defaultMemberPermissions, nsfw, contexts,
    integrations, nameLocalizations, descriptionLocalizations)
  for _, route in routes.slashRoutes.mpairs:
    if route.name == name:
      route.metadata = metadata
      found = true
  if not found:
    raise newException(RouteDefinitionError,
      "cannot configure an unknown slash command: " & name)

proc configureUserCommand*(routes: var Routes; name: string;
    defaultMemberPermissions = none(uint64); nsfw = false;
    contexts = none(set[InteractionContextKind]);
    integrations = none(set[IntegrationKind]);
    nameLocalizations = Table[string, string]()) =
  if not routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure an unknown user command: " & name)
  routes.userRoutes[name].metadata = commandMetadata(
    defaultMemberPermissions, nsfw, contexts, integrations,
    nameLocalizations, Table[string, string]())

proc configureMessageCommand*(routes: var Routes; name: string;
    defaultMemberPermissions = none(uint64); nsfw = false;
    contexts = none(set[InteractionContextKind]);
    integrations = none(set[IntegrationKind]);
    nameLocalizations = Table[string, string]()) =
  if not routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure an unknown message command: " & name)
  routes.messageRoutes[name].metadata = commandMetadata(
    defaultMemberPermissions, nsfw, contexts, integrations,
    nameLocalizations, Table[string, string]())

proc autocomplete*(routes: var Routes; commandPath, optionName: string;
                   handler: AutocompleteHandler) =
  if not routes.slashRoutes.hasKey(commandPath):
    raise newException(RouteDefinitionError,
      "autocomplete requires an existing slash command path: " & commandPath)
  var route = routes.slashRoutes[commandPath]
  var found = false
  for option in route.options.mitems:
    if option.name == optionName:
      if option.kind notin {StringOption, IntegerOption, NumberOption}:
        raise newException(RouteDefinitionError,
          "autocomplete is not valid for option: " & optionName)
      if option.choices.len > 0:
        raise newException(RouteDefinitionError,
          "autocomplete and fixed choices are mutually exclusive: " &
          optionName)
      option.autocomplete = true
      found = true
      break
  if not found:
    raise newException(RouteDefinitionError,
      "autocomplete option does not exist: " & optionName)
  route.autocompleteHandlers[optionName] = handler
  routes.slashRoutes[commandPath] = route

proc modalRaw(routes: var Routes; pattern: string; handler: ModalHandler) =
  for route in routes.modalRoutes:
    if route.pattern.raw == pattern:
      raise newException(RouteDefinitionError,
        "duplicate modal route: " & pattern)
  routes.modalRoutes.add ModalRoute(
    pattern: parsePattern(pattern), handler: handler)

proc defaultErrorHandler(ctx: InteractionContext;
                         error: ref CatchableError): Future[ErrorAction]
                         {.async.} =
  if ctx of AutocompleteContext:
    return ErrorAction(kind: CompleteAutocomplete)
  if error of UserRejectionError:
    let rejection = cast[ref UserRejectionError](error)
    return ErrorAction(kind: RespondEphemeral,
                       message: rejection.userMessage)
  return ErrorAction(kind: RespondEphemeral,
                     message: "Something went wrong while handling this " &
                              "interaction.")

proc newDiscordApp*(factory: RouteFactory;
                    onError: ErrorHandler = nil): DiscordApp =
  var routes = Routes(
    slashRoutes: initOrderedTable[string, SlashRoute](),
    userRoutes: initOrderedTable[string, NamedRoute[UserCommandHandler]](),
    messageRoutes:
      initOrderedTable[string, NamedRoute[MessageCommandHandler]]())
  factory(routes)
  DiscordApp(routesValue: routes,
             errorHandlerValue: if onError.isNil: defaultErrorHandler
                                else: onError)

proc globalScope*(): CommandScope = CommandScope(kind: GlobalCommands)

proc guildScope*(guildId: GuildId): CommandScope =
  CommandScope(kind: GuildCommands, guildId: guildId)

proc toJson(option: CommandOption): JsonNode =
  result = %*{
    "type": int(option.kind),
    "name": option.name,
    "description": option.description,
    "required": option.required
  }
  if option.minValue.isSome:
    result["min_value"] =
      if option.kind == IntegerOption: %int(option.minValue.get)
      else: %option.minValue.get
  if option.maxValue.isSome:
    result["max_value"] =
      if option.kind == IntegerOption: %int(option.maxValue.get)
      else: %option.maxValue.get
  if option.minLength.isSome:
    result["min_length"] = %option.minLength.get
  if option.maxLength.isSome:
    result["max_length"] = %option.maxLength.get
  if option.autocomplete:
    result["autocomplete"] = %true
  if option.choices.len > 0:
    result["choices"] = newJArray()
    for choice in option.choices:
      result["choices"].add %*{
        "name": choice.name,
        "value": choice.value
      }
  if option.channelKinds.len > 0:
    result["channel_types"] = newJArray()
    for kind in option.channelKinds:
      result["channel_types"].add %int(kind)
  if option.nameLocalizations.len > 0:
    result["name_localizations"] = %option.nameLocalizations
  if option.descriptionLocalizations.len > 0:
    result["description_localizations"] = %option.descriptionLocalizations

proc applyMetadata(command: JsonNode; metadata: CommandMetadata;
                   includeDescription: bool) =
  if metadata.defaultMemberPermissions.isSome:
    command["default_member_permissions"] =
      %($metadata.defaultMemberPermissions.get)
  if metadata.nsfw: command["nsfw"] = %true
  if metadata.contexts.isSome:
    command["contexts"] = newJArray()
    for context in InteractionContextKind:
      if context in metadata.contexts.get:
        command["contexts"].add %int(context)
  if metadata.integrations.isSome:
    command["integration_types"] = newJArray()
    for integration in IntegrationKind:
      if integration in metadata.integrations.get:
        command["integration_types"].add %int(integration)
  if metadata.nameLocalizations.len > 0:
    command["name_localizations"] = %metadata.nameLocalizations
  if includeDescription and metadata.descriptionLocalizations.len > 0:
    command["description_localizations"] =
      %metadata.descriptionLocalizations

proc commands*(app: DiscordApp): JsonNode =
  ## Returns a copy of the authoritative application-command payload.
  var slashCommands = initOrderedTable[string, JsonNode]()
  for _, route in app.routesValue.slashRoutes:
    if not slashCommands.hasKey(route.name):
      slashCommands[route.name] = %*{
        "type": 1,
        "name": route.name,
        "description": route.description
      }
      slashCommands[route.name].applyMetadata(route.metadata, true)
    let command = slashCommands[route.name]
    var leafOptions = newJArray()
    if route.options.len > 0:
      for option in route.options:
        leafOptions.add option.toJson
    case route.path.len
    of 0:
      if leafOptions.len > 0: command["options"] = leafOptions
    of 1:
      if not command.hasKey("options"): command["options"] = newJArray()
      var subcommand = %*{
        "type": 1,
        "name": route.path[0],
        "description": route.pathDescriptions[0]
      }
      if leafOptions.len > 0: subcommand["options"] = leafOptions
      command["options"].add subcommand
    of 2:
      if not command.hasKey("options"): command["options"] = newJArray()
      var group: JsonNode
      for candidate in command["options"]:
        if candidate["type"].getInt == 2 and
            candidate["name"].getStr == route.path[0]:
          group = candidate
          break
      if group.isNil:
        group = %*{
          "type": 2,
          "name": route.path[0],
          "description": route.pathDescriptions[0],
          "options": []
        }
        command["options"].add group
      elif group["description"].getStr != route.pathDescriptions[0]:
        raise newException(RouteDefinitionError,
          "group descriptions disagree for: " & route.path[0])
      var subcommand = %*{
        "type": 1,
        "name": route.path[1],
        "description": route.pathDescriptions[1]
      }
      if leafOptions.len > 0: subcommand["options"] = leafOptions
      group["options"].add subcommand
    else:
      raise newException(RouteDefinitionError, "invalid slash route path")
  result = newJArray()
  for _, command in slashCommands:
    result.add command
  for name, route in app.routesValue.userRoutes:
    let command = %*{"type": 2, "name": name}
    command.applyMetadata(route.metadata, false)
    result.add command
  for name, route in app.routesValue.messageRoutes:
    let command = %*{"type": 3, "name": name}
    command.applyMetadata(route.metadata, false)
    result.add command

macro derivedCommandOption(T: typedesc; name, description: static string;
                           required: static bool): CommandOption =
  let nameNode = newLit(name)
  let descriptionNode = newLit(description)
  let requiredNode = newLit(required)
  let typeName = T.repr
  var kind: NimNode
  case typeName
  of "string": kind = bindSym"StringOption"
  of "int": kind = bindSym"IntegerOption"
  of "bool": kind = bindSym"BooleanOption"
  of "float": kind = bindSym"NumberOption"
  of "User", "Member": kind = bindSym"UserOption"
  of "Role": kind = bindSym"RoleOption"
  of "ResolvedChannel": kind = bindSym"ChannelOption"
  of "Mentionable": kind = bindSym"MentionableOption"
  of "Attachment": kind = bindSym"AttachmentOption"
  else:
    discard
  if not kind.isNil:
    return quote do:
      CommandOption(name: `nameNode`, description: `descriptionNode`,
                    required: `requiredNode`, kind: `kind`)

  let implementation = T.getType[1]
  case implementation.kind
  of nnkEnumTy:
    if implementation.len <= 1 or implementation.len > 26:
      error("slash option enums must contain 1..25 values", T)
    var choices = newNimNode(nnkBracket)
    for field in implementation[1 .. ^1]:
      field.expectKind nnkSym
      let wire = field.strVal
      let fieldImplementation = field.getImpl
      let label =
        if fieldImplementation.kind in {nnkStrLit, nnkRStrLit,
                                        nnkTripleStrLit}:
          fieldImplementation.strVal
        else:
          wire
      choices.add newCall(bindSym"choice", newLit(label), newLit(wire))
    let choiceSequence = newCall(bindSym"@", choices)
    result = quote do:
      CommandOption(name: `nameNode`, description: `descriptionNode`,
                    required: `requiredNode`, kind: StringOption,
                    choices: `choiceSequence`)
  of nnkBracketExpr:
    const integers = {nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit,
      nnkInt64Lit, nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit,
      nnkUInt64Lit}
    if implementation.len != 3 or not implementation[0].eqIdent("range") or
        implementation[1].kind notin integers or
        implementation[2].kind notin integers:
      error("derived ranges must have integer bounds", T)
    let lowValue = newLit(float(implementation[1].intVal))
    let highValue = newLit(float(implementation[2].intVal))
    result = quote do:
      CommandOption(name: `nameNode`, description: `descriptionNode`,
                    required: `requiredNode`, kind: IntegerOption,
                    minValue: some(`lowValue`), maxValue: some(`highValue`))
  of nnkSym:
    let declaration = implementation.getImpl
    if declaration.kind != nnkTypeDef or
        declaration[2].kind != nnkDistinctTy:
      error("unsupported slash option type: " & typeName, T)
    let base = declaration[2][0]
    let distinctKind =
      if base.eqIdent("string"): bindSym"StringOption"
      elif base.eqIdent("int"): bindSym"IntegerOption"
      else:
        error("distinct slash options must wrap string or int", T)
        nil
    result = quote do:
      CommandOption(name: `nameNode`, description: `descriptionNode`,
                    required: `requiredNode`, kind: `distinctKind`)
  else:
    error("unsupported slash option type: " & typeName, T)

proc baseOptionType(typeNode: NimNode): tuple[node: NimNode, optional: bool] =
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2 and
      typeNode[0].eqIdent("Option"):
    return (typeNode[1], true)
  (typeNode, false)

proc expandSlash(routes: NimNode; name, description: string;
                 path, pathDescriptions: seq[string];
                 handler: NimNode): NimNode {.compileTime.} =
  if handler.kind notin {nnkProcDef, nnkLambda}:
    error("slash handler must be a proc", handler)
  let params = handler.params
  if params.len < 2:
    error("slash handler must receive a SlashCommandContext", handler)
  var definitions = newNimNode(nnkBracket)
  var arguments: seq[NimNode]
  let contextSymbol = genSym(nskParam, "ctx")
  var sawOptional = false
  for index in 2 ..< params.len:
    let declaration = params[index]
    if declaration.kind != nnkIdentDefs or declaration.len < 3:
      error("unsupported slash handler parameter", declaration)
    let parameterName = declaration[0]
    var typeNode = declaration[^2]
    let defaultValue = declaration[^1]
    let bareName = if parameterName.kind == nnkPragmaExpr:
                     parameterName[0]
                   else:
                     parameterName
    var wireName = bareName.strVal
    var optionDescription = wireName
    var minValue: NimNode
    var maxValue: NimNode
    var minLength: NimNode
    var maxLength: NimNode
    var choiceValues: NimNode
    var channelKinds: NimNode
    var nameLocalizations: NimNode
    var descriptionLocalizations: NimNode
    if parameterName.kind == nnkPragmaExpr:
      wireName = parameterName[0].strVal
      for pragma in parameterName[1]:
        if pragma.kind != nnkExprColonExpr:
          error("option pragmas require a value", pragma)
        case pragma[0].strVal
        of "description", "desc": optionDescription = pragma[1].strVal
        of "name": wireName = pragma[1].strVal
        of "min":
          minValue = newCall(bindSym"some",
            newCall(bindSym"float", pragma[1]))
        of "max":
          maxValue = newCall(bindSym"some",
            newCall(bindSym"float", pragma[1]))
        of "minLength", "minLen":
          minLength = newCall(bindSym"some", pragma[1])
        of "maxLength", "maxLen":
          maxLength = newCall(bindSym"some", pragma[1])
        of "choices":
          pragma[1].expectKind nnkTableConstr
          if pragma[1].len notin 1 .. 25:
            error("choices must contain 1..25 values", pragma)
          var values = newNimNode(nnkBracket)
          for entry in pragma[1]:
            entry.expectKind nnkExprColonExpr
            values.add newCall(bindSym"choice", entry[0], entry[1])
          choiceValues = newCall(bindSym"@", values)
        of "channels": channelKinds = pragma[1]
        of "nameLoc": nameLocalizations = pragma[1]
        of "descLoc": descriptionLocalizations = pragma[1]
        else: error("unknown slash option pragma: " & pragma[0].strVal,
                    pragma)
    let base = baseOptionType(typeNode)
    typeNode = base.node
    let optional = base.optional or defaultValue.kind != nnkEmpty
    let required = not optional
    if required and sawOptional:
      error("required slash options must precede optional options",
            declaration)
    if optional: sawOptional = true
    let wireNameLiteral = macros.newLit(wireName)
    let descriptionValue = macros.newLit(optionDescription)
    let requiredValue = macros.newLit(required)
    let optionSymbol = genSym(nskVar, "option")
    let derived = newCall(bindSym"derivedCommandOption", typeNode,
                          wireNameLiteral, descriptionValue, requiredValue)
    var optionBody = newStmtList(quote do:
      var `optionSymbol` = `derived`)
    if not minValue.isNil:
      optionBody.add quote do:
        `optionSymbol`.minValue = `minValue`
    if not maxValue.isNil:
      optionBody.add quote do:
        `optionSymbol`.maxValue = `maxValue`
    if not minLength.isNil:
      optionBody.add quote do:
        `optionSymbol`.minLength = `minLength`
    if not maxLength.isNil:
      optionBody.add quote do:
        `optionSymbol`.maxLength = `maxLength`
    if not choiceValues.isNil:
      optionBody.add quote do:
        `optionSymbol`.choices = `choiceValues`
    if not channelKinds.isNil:
      let channel = genSym(nskForVar, "channel")
      optionBody.add quote do:
        for `channel` in `channelKinds`:
          `optionSymbol`.channelKinds.add `channel`
    if not nameLocalizations.isNil:
      optionBody.add quote do:
        `optionSymbol`.nameLocalizations = toTable(`nameLocalizations`)
    if not descriptionLocalizations.isNil:
      optionBody.add quote do:
        `optionSymbol`.descriptionLocalizations =
          toTable(`descriptionLocalizations`)
    optionBody.add optionSymbol
    definitions.add quote do:
      block:
        `optionBody`
    let optionalCall = newCall(
      newTree(nnkBracketExpr, bindSym"optionalOption", typeNode),
      contextSymbol, wireNameLiteral)
    if base.optional:
      arguments.add optionalCall
    elif defaultValue.kind != nnkEmpty:
      arguments.add quote do:
        block:
          let supplied = `optionalCall`
          if supplied.isSome: supplied.get else: `defaultValue`
    else:
      arguments.add newCall(
        newTree(nnkBracketExpr, bindSym"requiredOption", typeNode),
        contextSymbol, wireNameLiteral)
  let handlerSymbol = genSym(nskLet, "typedHandler")
  let options = newCall(bindSym"@", definitions)
  let nameLiteral = newLit(name)
  let descriptionLiteral = newLit(description)
  var handlerCall = newCall(handlerSymbol, contextSymbol)
  for argument in arguments:
    handlerCall.add argument
  let wrapper = quote do:
    proc(`contextSymbol`: SlashCommandContext): Future[void] =
      `handlerCall`
  if path.len == 0:
    result = quote do:
      block:
        let `handlerSymbol` = `handler`
        slashRaw(`routes`, `nameLiteral`, `descriptionLiteral`, `options`,
                 `wrapper`)
  else:
    let pathLiteral = newLit(path)
    let pathDescriptionsLiteral = newLit(pathDescriptions)
    result = quote do:
      block:
        let `handlerSymbol` = `handler`
        subcommandRaw(`routes`, `nameLiteral`, `descriptionLiteral`,
          `pathLiteral`, `pathDescriptionsLiteral`, `options`, `wrapper`)

macro slash*(routes: var Routes; name, description: static string;
             handler: untyped): untyped =
  expandSlash(routes, name, description, @[], @[], handler)

macro subcommand*(routes: var Routes;
                  commandName, commandDescription: static string;
                  name, description: static string;
                  handler: untyped): untyped =
  expandSlash(routes, commandName, commandDescription, @[name],
              @[description], handler)

macro groupSubcommand*(routes: var Routes;
                       commandName, commandDescription: static string;
                       groupName, groupDescription: static string;
                       name, description: static string;
                       handler: untyped): untyped =
  expandSlash(routes, commandName, commandDescription,
              @[groupName, name], @[groupDescription, description], handler)

proc expandModal(routes: NimNode; pattern: string;
                 handler: NimNode): NimNode {.compileTime.} =
  if handler.kind notin {nnkProcDef, nnkLambda}:
    error("modal handler must be a proc", handler)
  let params = handler.params
  if params.len < 2:
    error("modal handler must receive a ModalContext", handler)
  let contextSymbol = genSym(nskParam, "ctx")
  var arguments: seq[NimNode]
  for index in 2 ..< params.len:
    let declaration = params[index]
    if declaration.kind != nnkIdentDefs or declaration.len < 3:
      error("unsupported modal handler parameter", declaration)
    let parameterName = declaration[0]
    let declaredType = declaration[^2]
    let defaultValue = declaration[^1]
    let bareName = if parameterName.kind == nnkPragmaExpr:
                     parameterName[0]
                   else:
                     parameterName
    var wireName = bareName.strVal
    var label = wireName
    if parameterName.kind == nnkPragmaExpr:
      for pragma in parameterName[1]:
        if pragma.kind != nnkExprColonExpr:
          error("modal field pragmas require a value", pragma)
        case pragma[0].strVal
        of "name": wireName = pragma[1].strVal
        of "description", "desc": label = pragma[1].strVal
        else: error("unknown modal field pragma: " & pragma[0].strVal,
                    pragma)
    let base = baseOptionType(declaredType)
    if base.node.repr notin ["string", "int", "float"]:
      error("modal text fields support string, int, and float", declaredType)
    let wireLiteral = newLit(wireName)
    let labelLiteral = newLit(label)
    let optionalCall = newCall(
      newTree(nnkBracketExpr, bindSym"optionalModalField", base.node),
      contextSymbol, wireLiteral, labelLiteral)
    if base.optional:
      if defaultValue.kind != nnkEmpty:
        error("Option modal fields cannot have a default", declaration)
      arguments.add optionalCall
    elif defaultValue.kind != nnkEmpty:
      arguments.add quote do:
        block:
          let supplied = `optionalCall`
          if supplied.isSome: supplied.get else: `defaultValue`
    else:
      arguments.add newCall(
        newTree(nnkBracketExpr, bindSym"requiredModalField", base.node),
        contextSymbol, wireLiteral, labelLiteral)
  let handlerSymbol = genSym(nskLet, "typedHandler")
  var handlerCall = newCall(handlerSymbol, contextSymbol)
  for argument in arguments: handlerCall.add argument
  let wrapper = quote do:
    proc(`contextSymbol`: ModalContext): Future[void] =
      `handlerCall`
  let patternLiteral = newLit(pattern)
  result = quote do:
    block:
      let `handlerSymbol` = `handler`
      modalRaw(`routes`, `patternLiteral`, `wrapper`)

macro modal*(routes: var Routes; pattern: static string;
             handler: untyped): untyped =
  expandModal(routes, pattern, handler)

proc jsonString(node: JsonNode; key: string): string =
  if node.kind != JObject or not node.hasKey(key) or
      node[key].kind != JString:
    raise newException(InvalidInteractionError,
      "interaction field is missing or invalid: " & key)
  node[key].getStr

proc decodeUser(node: JsonNode): User =
  User(idValue: UserId(node.jsonString("id")),
       usernameValue: node.jsonString("username"))

proc decodeMember(node: JsonNode; user: User): Member =
  result.userValue = user
  if node.hasKey("nick") and node["nick"].kind == JString:
    result.nicknameValue = some(node["nick"].getStr)
  if node.hasKey("permissions") and node["permissions"].kind == JString:
    try:
      result.permissionsValue = some(Permissions(
        parseBiggestUInt(node["permissions"].getStr)))
    except ValueError:
      raise newException(InvalidInteractionError,
        "member permissions are invalid")

proc decodeRole(node: JsonNode): Role =
  Role(idValue: RoleId(node.jsonString("id")),
       nameValue: node.jsonString("name"))

proc decodeChannel(node: JsonNode): ResolvedChannel =
  result.idValue = ChannelId(node.jsonString("id"))
  if node.hasKey("name") and node["name"].kind == JString:
    result.nameValue = some(node["name"].getStr)

proc decodeAttachment(node: JsonNode): Attachment =
  result.idValue = AttachmentId(node.jsonString("id"))
  result.filenameValue = node.jsonString("filename")
  result.urlValue = node.jsonString("url")

proc decodeMessage(node: JsonNode): Message =
  result.idValue = MessageId(node.jsonString("id"))
  if node.hasKey("content"): result.contentValue = node["content"].getStr
  if node.hasKey("author"):
    result.authorValue = some(decodeUser(node["author"]))

proc decodeInteraction*(raw: JsonNode): Interaction =
  result.rawValue = raw.copy
  result.idValue = InteractionId(raw.jsonString("id"))
  result.applicationIdValue = ApplicationId(raw.jsonString("application_id"))
  result.tokenValue = raw.jsonString("token")
  if raw.hasKey("guild_id"):
    result.guildIdValue = some(GuildId(raw["guild_id"].getStr))
  if raw.hasKey("channel_id"):
    result.channelIdValue = some(ChannelId(raw["channel_id"].getStr))
  if raw.hasKey("member") and raw["member"].hasKey("user"):
    let user = decodeUser(raw["member"]["user"])
    result.userValue = some(user)
    result.memberValue = some(decodeMember(raw["member"], user))
  elif raw.hasKey("user"):
    result.userValue = some(decodeUser(raw["user"]))
  if raw.hasKey("locale") and raw["locale"].kind == JString:
    result.localeValue = some(raw["locale"].getStr)
  if raw.hasKey("guild_locale") and raw["guild_locale"].kind == JString:
    result.guildLocaleValue = some(raw["guild_locale"].getStr)
  if raw.hasKey("app_permissions") and
      raw["app_permissions"].kind == JString:
    try:
      result.appPermissionsValue = Permissions(
        parseBiggestUInt(raw["app_permissions"].getStr))
    except ValueError:
      raise newException(InvalidInteractionError,
        "application permissions are invalid")
  if raw.hasKey("message"):
    result.messageValue = some(decodeMessage(raw["message"]))
  case raw["type"].getInt
  of 2:
    case raw["data"]["type"].getInt
    of 1: result.kindValue = SlashCommand
    of 2: result.kindValue = UserCommand
    of 3: result.kindValue = MessageCommand
    else:
      raise newException(InvalidInteractionError,
        "unknown application command type")
  of 3: result.kindValue = MessageComponent
  of 4: result.kindValue = Autocomplete
  of 5: result.kindValue = ModalSubmit
  else:
    raise newException(InvalidInteractionError, "unsupported interaction type")

proc decodeOptions(data: JsonNode): JsonNode =
  result = newJObject()
  if not data.hasKey("options"): return
  for option in data["options"]:
    if option.hasKey("value"):
      result[option.jsonString("name")] = option["value"].copy

proc decodeLeaf(data: JsonNode): tuple[path: seq[string], options: JsonNode] =
  var leaf = data
  while leaf.hasKey("options") and leaf["options"].kind == JArray and
      leaf["options"].len == 1:
    let candidate = leaf["options"][0]
    if candidate{"type"}.getInt notin [1, 2]: break
    result.path.add candidate.jsonString("name")
    leaf = candidate
  result.options = decodeOptions(leaf)

proc focusedOption(data: JsonNode): tuple[name, value: string] =
  if not data.hasKey("options"): return
  for option in data["options"]:
    if option{"focused"}.getBool(false):
      result.name = option.jsonString("name")
      result.value =
        if option["value"].kind == JString: option["value"].getStr
        else: $option["value"]
      return
    let nested = focusedOption(option)
    if nested.name.len > 0: return nested

proc decodeModalFields(node: JsonNode; result: var Table[string, string]) =
  if node.kind == JArray:
    for child in node: decodeModalFields(child, result)
  elif node.kind == JObject:
    if node.hasKey("custom_id") and node.hasKey("value"):
      result[node["custom_id"].getStr] = node["value"].getStr
    if node.hasKey("components"):
      decodeModalFields(node["components"], result)
    if node.hasKey("component"):
      decodeModalFields(node["component"], result)

proc newController(sink: ResponseSink; interaction: Interaction):
    ResponseController =
  ResponseController(sink: sink, interactionId: interaction.idValue,
    applicationId: interaction.applicationIdValue,
    token: interaction.tokenValue, state: Pending)

proc applyError(binding: AppBinding; ctx: InteractionContext;
                error: ref CatchableError): Future[void] {.async.} =
  let action = await binding.app.errorHandlerValue(ctx, error)
  case action.kind
  of Reraise: raise error
  of Ignore: discard
  of RespondEphemeral:
    case ctx.response.state
    of Pending:
      discard await ctx.respond(action.message, ephemeral = true)
    of DeferredReply, DeferredUpdate:
      discard await ctx.editOriginal(action.message)
    of Responded:
      discard await ctx.followup(action.message, ephemeral = true)
    of OutcomeUnknown:
      discard
  of CompleteAutocomplete:
    if ctx.response.state == Pending:
      await ctx.response.sendInitial(InitialAutocomplete,
                                     %*{"choices": []}, Responded)

proc systemMonotonicMilliseconds(): int64 =
  getMonoTime().ticks div 1_000_000

proc checkCooldown*(ctx: InteractionContext; key: string;
                    rule: CooldownRule) =
  if ctx.bindingValue.isNil:
    raise newException(DimSlashError,
      "checkCooldown requires a bound interaction context")
  if key.len == 0:
    raise newException(ValueError, "a cooldown key cannot be empty")
  if rule.durationMs <= 0:
    raise newException(ValueError,
      "a cooldown duration must be greater than zero")
  let now = ctx.bindingValue.monotonicMilliseconds()
  var expired: seq[string]
  for entry, expiresAt in ctx.bindingValue.cooldowns:
    if expiresAt <= now: expired.add entry
  for entry in expired: ctx.bindingValue.cooldowns.del(entry)
  let subject = case rule.scope
    of GlobalCooldown:
      "global"
    of UserCooldown:
      if ctx.interactionValue.userValue.isNone:
        raise userRejection("This cooldown requires an invoking user.")
      "user:" & $ctx.interactionValue.userValue.get.id
    of GuildCooldown:
      if ctx.interactionValue.guildIdValue.isNone:
        raise userRejection("This cooldown requires a guild interaction.")
      "guild:" & $ctx.interactionValue.guildIdValue.get
  let concrete = key & "\x1f" & subject
  if ctx.bindingValue.cooldowns.hasKey(concrete):
    let remaining = ctx.bindingValue.cooldowns[concrete] - now
    raise userRejection("This interaction is on cooldown; retry in " &
      $remaining & " ms.")
  let expiresAt =
    if now > high(int64) - rule.durationMs: high(int64)
    else: now + rule.durationMs
  ctx.bindingValue.cooldowns[concrete] = expiresAt

proc runRoute(binding: AppBinding; ctx: InteractionContext; key: string;
              checks: seq[InteractionCheck]; cooldown: Option[CooldownRule];
              handler: proc(): Future[void]): Future[void] {.async.} =
  for check in checks:
    let decision = await check(ctx)
    if decision.kind == CheckRejected:
      raise userRejection(decision.rejectionMessage)
  if cooldown.isSome:
    ctx.checkCooldown(key, cooldown.get)
  await handler()

proc invoke(binding: AppBinding; ctx: InteractionContext;
            handler: proc(): Future[void]): Future[void] {.async.} =
  var failure: ref CatchableError
  try:
    await handler()
  except CatchableError as error:
    failure = error
  if not failure.isNil:
    await binding.applyError(ctx, failure)
  elif ctx.response.state == Pending:
    await binding.applyError(ctx,
      newException(MissingInitialResponseError,
        "the handler completed without acknowledging the interaction"))

proc newComponentContext(binding: AppBinding; interaction: Interaction;
    controller: ResponseController; data: JsonNode; customId: string;
    captures: Table[string, string]): ComponentContext =
  var values: seq[string]
  if data.hasKey("values"):
    for value in data["values"]: values.add value.getStr
  ComponentContext(interactionValue: interaction, response: controller,
    bindingValue: binding, customIdValue: customId, valuesValue: values,
    resolvedValue: data{"resolved"}, capturesValue: captures)

proc newModalContext(binding: AppBinding; interaction: Interaction;
    controller: ResponseController; data: JsonNode; customId: string;
    captures: Table[string, string]): ModalContext =
  var fields = initTable[string, string]()
  if data.hasKey("components"):
    decodeModalFields(data["components"], fields)
  let modalSource =
    if interaction.messageValue.isSome:
      ModalSource(kindValue: ComponentModalSource,
                  messageValue: interaction.messageValue)
    else:
      ModalSource(kindValue: CommandModalSource)
  ModalContext(interactionValue: interaction, response: controller,
    bindingValue: binding, customIdValue: customId, capturesValue: captures,
    fieldsValue: fields, resolvedValue: data{"resolved"},
    sourceValue: some(modalSource))

proc matches(waiterUser: Option[UserId]; interaction: Interaction): bool =
  waiterUser.isNone or
    (interaction.userValue.isSome and
     interaction.userValue.get.id == waiterUser.get)

proc matches(messageId: Option[MessageId]; interaction: Interaction): bool =
  messageId.isNone or
    (interaction.messageValue.isSome and
     interaction.messageValue.get.id == messageId.get)

proc matchAny(patterns: seq[Pattern]; customId: string):
    Option[Table[string, string]] =
  for pattern in patterns:
    let captures = pattern.match(customId)
    if captures.isSome: return captures

proc dispatch*(binding: AppBinding; raw: JsonNode): Future[bool] {.async.} =
  if not binding.accepting: return false
  inc binding.activeRequests
  defer:
    dec binding.activeRequests
    if not binding.drained.isNil and binding.activeRequests == 0 and
        not binding.drained.finished:
      binding.drained.complete()
  let interaction = decodeInteraction(raw)
  let controller = newController(binding.sink, interaction)
  let data = raw["data"]
  case interaction.kindValue
  of SlashCommand:
    let name = data.jsonString("name")
    let leaf = decodeLeaf(data)
    let routeKey = (@[name] & leaf.path).join("/")
    if not binding.app.routesValue.slashRoutes.hasKey(routeKey): return false
    let route = binding.app.routesValue.slashRoutes[routeKey]
    let ctx = SlashCommandContext(interactionValue: interaction,
      response: controller, bindingValue: binding, commandNameValue: name,
      commandPathValue: leaf.path, optionsValue: leaf.options,
      resolvedValue: data{"resolved"})
    await binding.invoke(ctx, proc(): Future[void] =
      binding.runRoute(ctx, "slash:" & routeKey, route.checks,
        route.cooldown, proc(): Future[void] = route.handler(ctx)))
    return true
  of UserCommand:
    let name = data.jsonString("name")
    if not binding.app.routesValue.userRoutes.hasKey(name): return false
    let targetId = data.jsonString("target_id")
    let resolved = data{"resolved"}
    if resolved.isNil or not resolved.hasKey("users") or
        not resolved["users"].hasKey(targetId):
      raise newException(InvalidInteractionError,
        "user command target is not resolved")
    let route = binding.app.routesValue.userRoutes[name]
    let targetUser = decodeUser(resolved["users"][targetId])
    let targetMember =
      if resolved.hasKey("members") and
          resolved["members"].hasKey(targetId):
        some(decodeMember(resolved["members"][targetId], targetUser))
      else:
        none(Member)
    let ctx = UserCommandContext(interactionValue: interaction,
      response: controller, bindingValue: binding,
      targetValue: targetUser, targetMemberValue: targetMember)
    await binding.invoke(ctx, proc(): Future[void] =
      binding.runRoute(ctx, "user:" & name, route.checks,
        route.cooldown, proc(): Future[void] = route.handler(ctx)))
    return true
  of MessageCommand:
    let name = data.jsonString("name")
    if not binding.app.routesValue.messageRoutes.hasKey(name): return false
    let targetId = data.jsonString("target_id")
    let resolved = data{"resolved"}
    if resolved.isNil or not resolved.hasKey("messages") or
        not resolved["messages"].hasKey(targetId):
      raise newException(InvalidInteractionError,
        "message command target is not resolved")
    let route = binding.app.routesValue.messageRoutes[name]
    let ctx = MessageCommandContext(interactionValue: interaction,
      response: controller, bindingValue: binding,
      targetValue: decodeMessage(resolved["messages"][targetId]))
    await binding.invoke(ctx, proc(): Future[void] =
      binding.runRoute(ctx, "message:" & name, route.checks,
        route.cooldown, proc(): Future[void] = route.handler(ctx)))
    return true
  of Autocomplete:
    let name = data.jsonString("name")
    let leaf = decodeLeaf(data)
    let routeKey = (@[name] & leaf.path).join("/")
    if not binding.app.routesValue.slashRoutes.hasKey(routeKey): return false
    let route = binding.app.routesValue.slashRoutes[routeKey]
    let focused = focusedOption(data)
    if not route.autocompleteHandlers.hasKey(focused.name): return false
    let handler = route.autocompleteHandlers[focused.name]
    let ctx = AutocompleteContext(interactionValue: interaction,
      response: controller, bindingValue: binding, commandNameValue: name,
      focusedNameValue: focused.name, focusedValueValue: focused.value,
      optionsValue: leaf.options, resolvedValue: data{"resolved"})
    await binding.invoke(ctx,
      proc(): Future[void] = handler(ctx))
    return true
  of MessageComponent:
    let customId = data.jsonString("custom_id")
    let isSelect = data{"component_type"}.getInt(2) != 2
    let interactionKind =
      if isSelect: SelectInteraction else: ButtonInteraction
    for index, waiter in binding.componentWaiters:
      if interactionKind notin waiter.kinds or
          not waiter.userId.matches(interaction) or
          not waiter.messageId.matches(interaction):
        continue
      let captures = waiter.patterns.matchAny(customId)
      if captures.isSome:
        let ctx = binding.newComponentContext(
          interaction, controller, data, customId, captures.get)
        binding.componentWaiters.delete(index)
        if not waiter.future.finished:
          waiter.future.complete(some(ctx))
        return true
    var selected = -1
    var selectedCaptures = none(Table[string, string])
    var bestExact = -1
    var bestLiteral = -1
    for index, route in binding.app.routesValue.buttonRoutes:
      if route.isSelect != isSelect: continue
      let captures = route.pattern.match(customId)
      if captures.isNone: continue
      let score = route.pattern.rank
      if score.exact > bestExact or
          (score.exact == bestExact and score.literal > bestLiteral):
        selected = index
        selectedCaptures = captures
        bestExact = score.exact
        bestLiteral = score.literal
    if selected >= 0:
      let route = binding.app.routesValue.buttonRoutes[selected]
      let handler = route.handler
      let ctx = binding.newComponentContext(
        interaction, controller, data, customId, selectedCaptures.get)
      let routeKey = (if route.isSelect: "select:" else: "button:") &
        route.pattern.raw
      let checks = route.checks
      let cooldown = route.cooldown
      await binding.invoke(ctx, proc(): Future[void] =
        binding.runRoute(ctx, routeKey, checks, cooldown,
          proc(): Future[void] = handler(ctx)))
      return true
    return false
  of ModalSubmit:
    let customId = data.jsonString("custom_id")
    for index, waiter in binding.modalWaiters:
      if not waiter.userId.matches(interaction): continue
      let captures = waiter.patterns.matchAny(customId)
      if captures.isSome:
        let ctx = binding.newModalContext(
          interaction, controller, data, customId, captures.get)
        binding.modalWaiters.delete(index)
        if not waiter.future.finished:
          waiter.future.complete(some(ctx))
        return true
    var selected = -1
    var selectedCaptures = none(Table[string, string])
    var bestExact = -1
    var bestLiteral = -1
    for index, route in binding.app.routesValue.modalRoutes:
      let captures = route.pattern.match(customId)
      if captures.isNone: continue
      let score = route.pattern.rank
      if score.exact > bestExact or
          (score.exact == bestExact and score.literal > bestLiteral):
        selected = index
        selectedCaptures = captures
        bestExact = score.exact
        bestLiteral = score.literal
    if selected >= 0:
      let route = binding.app.routesValue.modalRoutes[selected]
      let handler = route.handler
      let ctx = binding.newModalContext(
        interaction, controller, data, customId, selectedCaptures.get)
      let routeKey = "modal:" & route.pattern.raw
      let checks = route.checks
      let cooldown = route.cooldown
      await binding.invoke(ctx, proc(): Future[void] =
        binding.runRoute(ctx, routeKey, checks, cooldown,
          proc(): Future[void] = handler(ctx)))
      return true
    return false
proc requestStop*(binding: AppBinding) =
  binding.accepting = false
  for waiter in binding.componentWaiters:
    if not waiter.future.finished:
      waiter.future.complete(none(ComponentContext))
  binding.componentWaiters.setLen(0)
  for waiter in binding.modalWaiters:
    if not waiter.future.finished:
      waiter.future.complete(none(ModalContext))
  binding.modalWaiters.setLen(0)

proc waitUntilDrained(binding: AppBinding): Future[void] =
  binding.requestStop()
  if binding.activeRequests == 0:
    let completed = newFuture[void]("dimslash.stop")
    completed.complete()
    return completed
  if binding.drained.isNil:
    binding.drained = newFuture[void]("dimslash.stop")
  binding.drained

proc classifyInitialError(error: ref CatchableError): ref CatchableError =
  if error of discord.DiscordHttpError:
    let httpError = cast[discord.DiscordHttpError](error)
    if httpError.code notin [0, 40060, 10062] and
        httpError.code notin 500 .. 599:
      return newException(ResponseRejectedError, error.msg)
  newException(ResponseAmbiguousError, error.msg)

proc uploadContentType(filename: string; mimeDb: MimeDB): string =
  let extension = splitFile(filename).ext
  if extension.len > 1:
    let detected = mimeDb.getMimetype(extension[1 .. ^1])
    if detected.len > 0: return detected
  "application/octet-stream"

proc multipart(payload: JsonNode; files: seq[UploadedFile]): MultipartData =
  if files.len == 0: return nil
  result = newMultipartData()
  let mimeDb = newMimetypes()
  for index, file in files:
    if file.filename.len == 0:
      raise newException(ValueError, "an uploaded file needs a filename")
    result.add("files[" & $index & "]", file.content, file.filename,
      uploadContentType(file.filename, mimeDb), useStream = false)
  result.add("payload_json", $payload, contentType = "application/json")

proc newDiscordSink(client: discord.DiscordClient): ResponseSink =
  let api = client.api
  result = ResponseSink()
  result.initial = proc(interactionId: InteractionId; token: string;
      kind: InitialResponseKind; data: JsonNode;
      files: seq[UploadedFile]): Future[void] {.async.} =
    let responseType = case kind
      of InitialMessage: 4
      of InitialDeferredMessage: 5
      of InitialDeferredUpdate: 6
      of InitialUpdate: 7
      of InitialAutocomplete: 8
      of InitialModal: 9
    try:
      let payload = %*{"type": responseType, "data": data}
      discard await api.request("POST",
        discord.endpointInteractionsCallback($interactionId, token),
        $payload, mp = multipart(payload, files))
    except CatchableError as error:
      raise classifyInitialError(error)
  result.launchActivity = proc(interactionId: InteractionId;
      token: string): Future[ActivityInstance] {.async.} =
    var raw: JsonNode
    try:
      raw = await api.request("POST",
        discord.endpointInteractionsCallback($interactionId, token) &
          "?with_response=true",
        $(%*{"type": 12}))
    except CatchableError as error:
      raise classifyInitialError(error)
    if raw.hasKey("resource") and raw["resource"].kind == JObject and
        raw["resource"].hasKey("activity_instance") and
        raw["resource"]["activity_instance"].kind == JObject and
        raw["resource"]["activity_instance"].hasKey("id"):
      return ActivityInstance(idValue:
        raw["resource"]["activity_instance"]["id"].getStr)
    if raw.hasKey("interaction") and raw["interaction"].kind == JObject and
        raw["interaction"].hasKey("activity_instance_id"):
      return ActivityInstance(idValue:
        raw["interaction"]["activity_instance_id"].getStr)
    raise newException(InvalidInteractionError,
      "Discord did not return an Activity instance id")
  result.createFollowup = proc(applicationId: ApplicationId; token: string;
      data: JsonNode; files: seq[UploadedFile]): Future[Message] {.async.} =
    let components = data.hasKey("components") and data["components"].len > 0
    let endpoint = discord.endpointWebhookToken($applicationId, token) &
      "?wait=true" & (if components: "&with_components=true" else: "")
    let raw = await api.request("POST",
      endpoint, $data, mp = multipart(data, files))
    return decodeMessage(raw)
  result.editMessage = proc(applicationId: ApplicationId; token: string;
      messageId: MessageId; data: JsonNode;
      files: seq[UploadedFile]): Future[Message] {.async.} =
    let components = data.hasKey("components") and data["components"].len > 0
    let endpoint = discord.endpointWebhookMessage(
      $applicationId, token, $messageId) &
      (if components: "?with_components=true" else: "")
    let raw = await api.request("PATCH",
      endpoint, $data, mp = multipart(data, files))
    return decodeMessage(raw)
  result.getMessage = proc(applicationId: ApplicationId; token: string;
      messageId: MessageId): Future[Message] {.async.} =
    let raw = await api.request("GET",
      discord.endpointWebhookMessage($applicationId, token, $messageId))
    return decodeMessage(raw)
  result.deleteMessage = proc(applicationId: ApplicationId; token: string;
      messageId: MessageId): Future[void] {.async.} =
    discard await api.request("DELETE",
      discord.endpointWebhookMessage($applicationId, token, $messageId))

proc newDiscordCommandSyncSink(
    client: discord.DiscordClient): CommandSyncSink =
  let api = client.api
  result = CommandSyncSink()
  result.resolveApplicationId = proc(): Future[ApplicationId] {.async.} =
    let application = await api.getCurrentApplication()
    return ApplicationId(application.id)
  result.putCommands = proc(applicationId: ApplicationId; scope: CommandScope;
      commands: JsonNode): Future[void] {.async.} =
    let endpoint = case scope.kind
      of GlobalCommands:
        discord.endpointGlobalCommands($applicationId)
      of GuildCommands:
        discord.endpointGuildCommands($applicationId, $scope.guildId)
    discard await api.request("PUT", endpoint, $commands)

proc validateManagedScopes(scopes: openArray[CommandScope]) =
  var seen = initHashSet[string]()
  for scope in scopes:
    let key = case scope.kind
      of GlobalCommands: "global"
      of GuildCommands: "guild:" & $scope.guildId
    if key in seen:
      raise newException(ValueError, "duplicate managed command scope: " & key)
    seen.incl key

proc bindGateway*(app: DiscordApp; token: string;
                  managedScopes = @[globalScope()];
                  gatewayIntents: set[GatewayIntent] = {Guilds};
                  messageContentIntent = false;
                  autoReconnect = true): AppBinding =
  ## Creates a gateway runtime. Configuration is intentionally supplied
  ## directly here; the route-only `DiscordApp` remains reusable.
  validateManagedScopes(managedScopes)
  let client = discord.newDiscordClient(token)
  AppBinding(app: app, sink: newDiscordSink(client),
             commandSink: newDiscordCommandSyncSink(client), client: client,
             managedScopes: managedScopes, accepting: true,
             cooldowns: initTable[string, int64](),
             monotonicMilliseconds: systemMonotonicMilliseconds,
             gatewayIntents: gatewayIntents,
             messageContentIntent: messageContentIntent,
             autoReconnect: autoReconnect)

proc resolveApplicationId(binding: AppBinding): Future[ApplicationId]
    {.async.} =
  if $binding.applicationId == "":
    if binding.commandSink.isNil:
      raise newException(DimSlashError,
        "command sync is unavailable on this binding")
    binding.applicationId = await binding.commandSink.resolveApplicationId()
  return binding.applicationId

proc syncCommands*(binding: AppBinding): Future[seq[SyncResult]] {.async.} =
  ## Bulk-overwrites every explicitly managed scope. An empty local route
  ## table therefore clears that scope; scopes not listed on the binding are
  ## untouched.
  if binding.commandSink.isNil:
    raise newException(DimSlashError,
      "command sync is unavailable on this binding")
  let applicationId = await binding.resolveApplicationId()
  let payload = binding.app.commands
  for scope in binding.managedScopes:
    await binding.commandSink.putCommands(applicationId, scope, payload)
    result.add SyncResult(scope: scope, commandCount: payload.len)
  binding.commandsSynced = true

proc install*(binding: AppBinding; autoSync = true) =
  if binding.client.isNil:
    raise newException(DimSlashError,
      "install requires a gateway binding")
  if binding.installed: return
  binding.installed = true
  binding.previousDispatch = binding.client.events.on_dispatch
  binding.previousReady = binding.client.events.on_ready

  binding.client.events.on_dispatch = proc(shard: discord.Shard;
      event: string; data: JsonNode) {.async.} =
    var handled = false
    if event == "INTERACTION_CREATE" and binding.accepting:
      handled = await binding.dispatch(data)
    if not handled and not binding.previousDispatch.isNil:
      await binding.previousDispatch(shard, event, data)

  binding.client.events.on_ready = proc(shard: discord.Shard;
      ready: discord.Ready) {.async.} =
    var syncFailure: ref CatchableError
    if autoSync and not binding.commandsSynced:
      try:
        discard await binding.syncCommands()
      except CatchableError as error:
        syncFailure = error
    if not binding.previousReady.isNil:
      await binding.previousReady(shard, ready)
    if not syncFailure.isNil: raise syncFailure

proc discordGatewayIntents(intents: set[GatewayIntent]):
    set[discord.GatewayIntent] =
  for intent in intents:
    result.incl case intent
      of Guilds: discord.giGuilds
      of GuildMembers: discord.giGuildMembers
      of GuildModeration: discord.giGuildModeration
      of GuildEmojisAndStickers: discord.giGuildEmojisAndStickers
      of GuildIntegrations: discord.giGuildIntegrations
      of GuildWebhooks: discord.giGuildWebhooks
      of GuildInvites: discord.giGuildInvites
      of GuildVoiceStates: discord.giGuildVoiceStates
      of GuildPresences: discord.giGuildPresences
      of GuildMessages: discord.giGuildMessages
      of GuildMessageReactions: discord.giGuildMessageReactions
      of GuildMessageTyping: discord.giGuildMessageTyping
      of DirectMessages: discord.giDirectMessages
      of DirectMessageReactions: discord.giDirectMessageReactions
      of DirectMessageTyping: discord.giDirectMessageTyping
      of MessageContent: discord.giMessageContent
      of GuildScheduledEvents: discord.giGuildScheduledEvents
      of AutoModerationConfiguration:
        discord.giAutoModerationConfiguration
      of AutoModerationExecution: discord.giAutoModerationExecution
      of GuildMessagePolls: discord.giGuildMessagePolls
      of DirectMessagePolls: discord.giDirectMessagePolls

proc start*(binding: AppBinding; autoSync = true): Future[void] {.async.} =
  binding.install(autoSync)
  await binding.client.startSession(
    autoreconnect = binding.autoReconnect,
    gateway_intents = discordGatewayIntents(binding.gatewayIntents),
    content_intent = binding.messageContentIntent)

proc requestDetach*(binding: AppBinding) =
  binding.requestStop()

proc detach*(binding: AppBinding): Future[void] {.async.} =
  binding.requestDetach()
  await binding.waitUntilDrained()
  if binding.installed and not binding.client.isNil:
    binding.client.events.on_dispatch = binding.previousDispatch
    binding.client.events.on_ready = binding.previousReady
    binding.installed = false

proc stop*(binding: AppBinding): Future[void] {.async.} =
  binding.requestStop()
  await binding.waitUntilDrained()
  if not binding.client.isNil:
    await binding.client.endSession()

when defined(dimslashTesting):
  type
    RecordedCall* = object
      name*: string
      data*: JsonNode
      files*: seq[UploadedFile]

    TestTransport* = ref object
      calls*: seq[RecordedCall]
      nextMessageId*: int
      applicationId*: ApplicationId
      rejectInitial*: bool
      failInitialAmbiguously*: bool

  proc messageFrom(data: JsonNode; id: string): Message =
    result.idValue = MessageId(id)
    if data.hasKey("content"): result.contentValue = data["content"].getStr

  proc newTestTransport*(): TestTransport =
    TestTransport(nextMessageId: 1,
                  applicationId: ApplicationId("application-1"))

  proc testSink(transport: TestTransport): ResponseSink =
    result = ResponseSink()
    result.initial = proc(interactionId: InteractionId; token: string;
                          kind: InitialResponseKind;
                          data: JsonNode;
                          files: seq[UploadedFile]): Future[void] {.async.} =
      transport.calls.add RecordedCall(name: "initial", data: %*{
        "interaction_id": $interactionId, "kind": int(kind), "data": data},
        files: files)
      if transport.rejectInitial:
        raise newException(ResponseRejectedError, "rejected")
      if transport.failInitialAmbiguously:
        raise newException(ResponseAmbiguousError, "connection closed")
    result.createFollowup = proc(applicationId: ApplicationId; token: string;
        data: JsonNode;
        files: seq[UploadedFile]): Future[Message] {.async.} =
      transport.calls.add RecordedCall(name: "followup", data: data,
                                       files: files)
      let id = "message-" & $transport.nextMessageId
      inc transport.nextMessageId
      return messageFrom(data, id)
    result.editMessage = proc(applicationId: ApplicationId; token: string;
        messageId: MessageId; data: JsonNode;
        files: seq[UploadedFile]): Future[Message] {.async.} =
      transport.calls.add RecordedCall(name: "edit", data: data,
                                       files: files)
      return messageFrom(data, $messageId)
    result.getMessage = proc(applicationId: ApplicationId; token: string;
        messageId: MessageId): Future[Message] {.async.} =
      transport.calls.add RecordedCall(name: "get", data: %*{
        "message_id": $messageId})
      return messageFrom(newJObject(), $messageId)
    result.deleteMessage = proc(applicationId: ApplicationId; token: string;
        messageId: MessageId): Future[void] {.async.} =
      transport.calls.add RecordedCall(name: "delete", data: %*{
        "message_id": $messageId})
    result.launchActivity = proc(interactionId: InteractionId;
        token: string): Future[ActivityInstance] {.async.} =
      transport.calls.add RecordedCall(name: "launchActivity", data: %*{
        "interaction_id": $interactionId})
      return ActivityInstance(idValue: "activity-1")

  proc testCommandSink(transport: TestTransport): CommandSyncSink =
    result = CommandSyncSink()
    result.resolveApplicationId = proc(): Future[ApplicationId] {.async.} =
      transport.calls.add RecordedCall(name: "resolveApplicationId")
      return transport.applicationId
    result.putCommands = proc(applicationId: ApplicationId;
        scope: CommandScope; commands: JsonNode): Future[void] {.async.} =
      var data = %*{
        "application_id": $applicationId,
        "scope": (if scope.kind == GlobalCommands: "global" else: "guild"),
        "commands": commands
      }
      if scope.kind == GuildCommands: data["guild_id"] = %($scope.guildId)
      transport.calls.add RecordedCall(name: "putCommands", data: data)

  proc bindForTesting*(app: DiscordApp;
                       transport: TestTransport;
                       monotonicMilliseconds:
                         proc(): int64 = nil;
                       managedScopes = @[globalScope()]): AppBinding =
    validateManagedScopes(managedScopes)
    AppBinding(app: app, sink: transport.testSink,
      commandSink: transport.testCommandSink, accepting: true,
      managedScopes: managedScopes,
      cooldowns: initTable[string, int64](),
      monotonicMilliseconds:
        if monotonicMilliseconds.isNil: systemMonotonicMilliseconds
        else: monotonicMilliseconds)

  proc state*(transport: TestTransport): int = transport.calls.len
