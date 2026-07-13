## Public types and operations for DimSlash interaction applications.
##
## The API has three ownership layers. `DiscordApp` is an immutable route
## definition; `AppBinding` owns mutable gateway/runtime state; specialized
## contexts own the response capability for a single request. Discord and
## Dimscord objects do not escape into handlers: identifiers, resolved entities,
## messages, embeds, components, and interaction snapshots are DimSlash-owned.
##
## Response operations enforce `ResponseState`. Immediate response operations
## require `Pending`; defer transitions permit `editOriginal`; follow-ups and
## webhook edits require an acknowledged interaction. `OutcomeUnknown` is a
## terminal safety state used when delivery cannot be proven either accepted or
## rejected.
##
## Route factories declare persistent commands and custom-ID routes. Checks run
## before binding-owned cooldowns. Collector operations are short-lived and take
## precedence over persistent component/modal routes. Binding shutdown first
## quiesces new work, wakes collectors, and then drains active handlers.
##
## Most users should import the top-level `dimslash` module, which also re-exports
## async dispatch, JSON, and option helpers used in handler declarations.

import std/[asyncdispatch, enumutils, hashes, httpclient, json, macros,
            mimetypes, monotimes, options, os, sequtils, sets, strutils,
            tables, typetraits, unicode]
import dimscord as discord
import dimscord/restapi/requester

type
  ApplicationId* = distinct string ## Discord snowflake identifying an application.
  InteractionId* = distinct string ## Discord snowflake identifying one interaction.
  MessageId* = distinct string ## Discord snowflake identifying a message.
  UserId* = distinct string ## Discord snowflake identifying a user.
  GuildId* = distinct string ## Discord snowflake identifying a guild.
  ChannelId* = distinct string ## Discord snowflake identifying a channel.
  RoleId* = distinct string ## Discord snowflake identifying a role.
  AttachmentId* = distinct string ## Discord snowflake identifying an attachment.
  Permissions* = distinct uint64 ## Discord permission bits without a Dimscord dependency.

  DimSlashError* = object of CatchableError ## Base class for recoverable DimSlash failures.
  RouteDefinitionError* = object of DimSlashError
    ## Raised while constructing an invalid or conflicting route table.
  InvalidInteractionError* = object of DimSlashError
    ## Raised when a Discord interaction payload is missing required data or
    ## contains an unsupported wire value.
  InvalidResponseStateError* = object of DimSlashError
    ## Raised when a response operation is illegal in the current state.
  ResponseOutcomeUnknownError* = object of DimSlashError
    ## Raised after transport failure leaves initial-response delivery unknown.
    ## Further mutations are refused because retrying could acknowledge twice.
  MissingInitialResponseError* = object of DimSlashError
    ## Raised after a handler returns without acknowledging its interaction.
  UserRejectionError* = object of CatchableError
    ## A deliberate user-facing rejection handled by the default error policy.
    ## Construct it with `userRejection` so the safe message survives async
    ## traceback decoration.
    userMessageValue: string

  User* = object ## Minimal DimSlash-owned Discord user snapshot.
    idValue: UserId
    usernameValue: string

  Member* = object ## Guild membership data resolved for an interaction.
                   ## The contained `User` is always present; nickname and
                   ## permissions depend on the Discord payload.
    userValue: User
    nicknameValue: Option[string]
    permissionsValue: Option[Permissions]

  Role* = object ## Minimal Discord role resolved from command or select data.
    idValue: RoleId
    nameValue: string

  ResolvedChannel* = object ## Minimal Discord channel resolved by an interaction.
                            ## The name is absent when Discord omits it.
    idValue: ChannelId
    nameValue: Option[string]

  Attachment* = object ## Existing Discord attachment supplied to a command.
    idValue: AttachmentId
    filenameValue: string
    urlValue: string

  Message* = object ## DimSlash-owned message result or interaction snapshot.
                    ## Only fields guaranteed useful to interaction handlers
                    ## are retained; use `Interaction.raw` for unsupported data.
    idValue: MessageId
    contentValue: string
    authorValue: Option[User]

  ActivityInstance* = object ## Activity instance returned by a launch callback.
    idValue: string

  MentionableKind* = enum ## Concrete entity stored in a `Mentionable` value.
    MentionableUser, ## A user was selected or resolved.
    MentionableRole  ## A role was selected or resolved.

  Mentionable* = object ## A resolved user-or-role command value.
    case kind*: MentionableKind ## Selects the active variant.
    of MentionableUser:
      mentionedUser*: User ## Resolved user for `MentionableUser`.
    of MentionableRole:
      mentionedRole*: Role ## Resolved role for `MentionableRole`.

  EmbedMedia* = object ## URL-backed image used by an embed.
    url*: string ## HTTPS, attachment, or Discord-supported media URL.

  EmbedAuthor* = object ## Author header displayed at the top of an embed.
    name*: string ## Visible author text.
    url*: Option[string] ## Optional link opened from the author name.
    iconUrl*: Option[string] ## Optional icon shown beside the author.

  EmbedFooter* = object ## Footer displayed below an embed.
    text*: string ## Visible footer text.
    iconUrl*: Option[string] ## Optional icon shown beside the footer.

  EmbedField* = object ## One named value in an embed field grid.
    name*: string ## Field heading.
    value*: string ## Field body; Discord markdown is supported.
    inline*: bool ## Whether Discord may lay this field beside another.

  Embed* = object ## Classic Discord embed payload owned by DimSlash.
                  ## Discord length and aggregate limits still apply when sent.
    title*: Option[string] ## Optional title text.
    description*: Option[string] ## Optional markdown body.
    url*: Option[string] ## Optional link associated with the title.
    timestamp*: Option[string] ## Optional ISO-8601 timestamp.
    color*: Option[int] ## Optional RGB color in `0x000000..0xFFFFFF`.
    footer*: Option[EmbedFooter] ## Optional footer.
    image*: Option[EmbedMedia] ## Optional large image.
    thumbnail*: Option[EmbedMedia] ## Optional thumbnail image.
    author*: Option[EmbedAuthor] ## Optional author header.
    fields*: seq[EmbedField] ## Ordered embed fields.

  AllowedMentions* = object ## Controls which mention syntax Discord expands.
                             ## The default value suppresses every automatic
                             ## mention and is therefore safe for user text.
    parseEveryone*: bool ## Allow `@everyone` and `@here` parsing.
    parseUsers*: bool ## Parse all user mentions in message content.
    parseRoles*: bool ## Parse all role mentions in message content.
    repliedUser*: bool ## Mention the author of a replied-to message.
    users*: seq[UserId] ## Explicit user IDs allowed to receive a mention.
    roles*: seq[RoleId] ## Explicit role IDs allowed to receive a mention.

  UploadedFile* = object ## In-memory file attached through multipart upload.
    filename*: string ## Plain basename used for the Discord attachment.
    content*: string ## Raw file bytes; the string need not be UTF-8.
    description*: Option[string] ## Optional attachment description or alt text.

  ButtonStyle* = enum ## Visual and behavioral Discord button style.
    Primary = 1, ## Blurple action button with a custom ID.
    Secondary = 2, ## Neutral grey action button with a custom ID.
    Success = 3, ## Green action button with a custom ID.
    Danger = 4, ## Red destructive-action button with a custom ID.
    Link = 5 ## URL button that does not create an interaction.

  Button* = object ## Interactive or link button used in classic and V2 layouts.
                   ## Prefer `button` or `linkButton`; they enforce the
                   ## mutually exclusive custom-ID and URL forms.
    label*: string ## Visible button label.
    style*: ButtonStyle ## Button appearance and interaction behavior.
    customId*: Option[string] ## Developer ID emitted by non-link buttons.
    url*: Option[string] ## Destination used only by `Link` buttons.
    disabled*: bool ## Whether Discord renders the button as unavailable.

  SelectOption* = object ## One option in a string select menu.
    label*: string ## Visible option label.
    value*: string ## Opaque value returned in `ComponentContext.values`.
    description*: Option[string] ## Optional secondary text.
    default*: bool ## Whether the option starts selected.

  SelectMenuKind* = enum ## Entity family selected by a Discord select menu.
    StringSelect = 3, ## Selects caller-defined string options.
    UserSelect = 5, ## Selects guild users.
    RoleSelect = 6, ## Selects guild roles.
    MentionableSelect = 7, ## Selects users or roles.
    ChannelSelect = 8 ## Selects channels, optionally constrained by kind.

  SelectMenu* = object ## Select component submitted as one component interaction.
                       ## Prefer the typed select builders so Discord's
                       ## cardinality and option constraints are validated.
    kind*: SelectMenuKind ## Selected entity family.
    customId*: string ## Developer ID used for dispatch and captures.
    placeholder*: Option[string] ## Text shown while no value is selected.
    minValues*: int ## Minimum submitted selections.
    maxValues*: int ## Maximum submitted selections.
    disabled*: bool ## Whether Discord renders the menu as unavailable.
    options*: seq[SelectOption] ## Options used only by `StringSelect`.
    channelKinds*: seq[ChannelKind] ## Allowed kinds used only by `ChannelSelect`.

  ClassicComponentKind* = enum ## Component stored in a classic action row.
    ClassicButton, ## A button component.
    ClassicSelect ## A select menu component.

  ClassicComponent* = object ## Variant for one classic action-row child.
    case kind*: ClassicComponentKind ## Selects the active child.
    of ClassicButton:
      button*: Button ## Button child.
    of ClassicSelect:
      selectMenu*: SelectMenu ## Select-menu child.

  ClassicActionRow* = object ## Top-level classic component row.
    components*: seq[ClassicComponent] ## Up to five buttons or exactly one select.

  ClassicMessage* = object ## Traditional Discord message response payload.
                            ## Construct it with `classicMessage`, then add
                            ## embeds, rows, mentions, or files as needed.
    content*: Option[string] ## Optional message text.
    embeds*: seq[Embed] ## Ordered embeds; Discord currently accepts at most ten.
    rows*: seq[ClassicActionRow] ## Top-level classic action rows.
    allowedMentions*: AllowedMentions ## Mention expansion policy.
    files*: seq[UploadedFile] ## New multipart attachments.
    ephemeral*: bool ## Make an initial response or follow-up visible only to its invoker.
    tts*: bool ## Request text-to-speech delivery where Discord supports it.

  V2ComponentKind* = enum ## Layout node available in Components V2 messages.
    TextDisplay, ## Markdown text block.
    V2ActionRow, ## Row containing buttons or one select menu.
    Section, ## One to three text blocks with a button or thumbnail accessory.
    MediaGallery, ## Gallery of one or more media items.
    FileDisplay, ## Display for an uploaded `attachment://` file.
    Separator, ## Optional divider and vertical spacing.
    Container ## Nested visual group with optional accent and spoiler state.

  MediaItem* = object ## Media reference used by V2 galleries and accessories.
    url*: string ## HTTPS or `attachment://filename` media URL.
    description*: Option[string] ## Optional media description or alt text.
    spoiler*: bool ## Whether Discord hides the media behind a spoiler.

  SectionAccessoryKind* = enum ## Accessory displayed beside a V2 section.
    AccessoryButton, ## Interactive or link button.
    AccessoryThumbnail ## Non-interactive thumbnail media.

  SectionAccessory* = object ## Button-or-thumbnail variant for a V2 section.
    case kind*: SectionAccessoryKind ## Selects the active accessory.
    of AccessoryButton:
      accessoryButton*: Button ## Button accessory.
    of AccessoryThumbnail:
      thumbnail*: MediaItem ## Thumbnail accessory.

  V2Component* = ref object ## One validated Components V2 layout node.
                            ## Nodes are references so containers can be built
                            ## recursively; constructors reject cycles and
                            ## illegal nesting before serialization.
    case kind*: V2ComponentKind ## Selects the active node payload.
    of TextDisplay:
      text*: string ## Markdown displayed by a text node.
    of V2ActionRow:
      interactiveComponents*: seq[ClassicComponent] ## Interactive row children.
    of Section:
      sectionTexts*: seq[string] ## One to three ordered markdown blocks.
      sectionAccessory*: SectionAccessory ## Accessory beside the section text.
    of MediaGallery:
      mediaItems*: seq[MediaItem] ## Ordered gallery media.
    of FileDisplay:
      fileItem*: MediaItem ## Uploaded file reference.
    of Separator:
      divider*: bool ## Whether a visible divider is rendered.
      spacing*: range[1 .. 2] ## Discord spacing size: 1 small, 2 large.
    of Container:
      containerComponents*: seq[V2Component] ## Nested V2 children.
      accentColor*: Option[int] ## Optional RGB accent in `0x000000..0xFFFFFF`.
      containerSpoiler*: bool ## Whether the entire container is hidden as a spoiler.

  V2Message* = object ## Message whose content is entirely Components V2.
                      ## Discord does not allow converting an existing V2
                      ## original response back to classic content or embeds.
    components*: seq[V2Component] ## Top-level V2 layout nodes.
    allowedMentions*: AllowedMentions ## Mention expansion policy for text nodes.
    files*: seq[UploadedFile] ## Files referenced by file or media nodes.
    ephemeral*: bool ## Make an initial response or follow-up invoker-only.

  MessageBodyKind* = enum ## Wire representation carried by `MessageBody`.
    ClassicBody, ## Content, embeds, and classic action rows.
    ComponentsV2Body ## Components V2 layout with the V2 message flag.

  MessageBody* = object ## Explicit classic-or-V2 response/edit payload.
    case kind*: MessageBodyKind ## Selects the active representation.
    of ClassicBody:
      classic*: ClassicMessage ## Classic message payload.
    of ComponentsV2Body:
      v2*: V2Message ## Components V2 payload.

  InteractionKind* = enum ## High-level Discord interaction category.
    SlashCommand, ## Chat-input application command.
    UserCommand, ## User context-menu command.
    MessageCommand, ## Message context-menu command.
    Autocomplete, ## Focused slash-option autocomplete request.
    MessageComponent, ## Button or select-menu submission.
    ModalSubmit ## Submitted modal form.

  Interaction* = object ## Immutable DimSlash-owned interaction snapshot.
                        ## Accessors return owned values or copies; `raw`
                        ## exposes a copy of the complete gateway payload for
                        ## fields not modeled by DimSlash.
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

  ResponseState* = enum ## Authoritative initial-response state for one context.
    Pending, ## No initial response has been attempted.
    DeferredReply, ## A deferred message acknowledgement was accepted.
    DeferredUpdate, ## A deferred source-message update was accepted.
    Responded, ## An immediate initial response was accepted.
    OutcomeUnknown ## Transport failure made acknowledgement delivery ambiguous.

  InitialResponseKind = enum
    InitialMessage
    InitialUpdate
    InitialDeferredMessage
    InitialDeferredUpdate
    InitialModal
    InitialAutocomplete

  ResponseRejectedError* = object of CatchableError
    ## Raised when Discord definitively rejects an initial response.
    ## The controller returns to `Pending`, so the error policy may choose a
    ## different legal initial response.
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
    ## Request-scoped response capability shared by specialized contexts.
    ## It owns the response state machine for exactly one interaction and must
    ## not be retained as application-global mutable state.
    interactionValue: Interaction
    response: ResponseController
    bindingValue: AppBinding

  SlashCommandContext* = ref object of InteractionContext
    ## Context for a typed slash-command or subcommand handler.
    commandNameValue: string
    commandPathValue: seq[string]
    optionsValue: JsonNode
    resolvedValue: JsonNode

  UserCommandContext* = ref object of InteractionContext
    ## Context for a user context-menu command with its resolved target.
    targetValue: User
    targetMemberValue: Option[Member]

  MessageCommandContext* = ref object of InteractionContext
    ## Context for a message context-menu command with its resolved target.
    targetValue: Message

  ComponentContext* = ref object of InteractionContext
    ## Context for a button or select submission.
    ## Captures come from the matched custom-ID pattern; resolved selections
    ## remain in Discord submission order.
    customIdValue: string
    valuesValue: seq[string]
    resolvedValue: JsonNode
    capturesValue: Table[string, string]

  ModalSourceKind* = enum ## Interaction class that originally opened a modal.
    CommandModalSource, ## Opened from an application command.
    ComponentModalSource ## Opened from a message component interaction.

  ModalSource* = object ## Capabilities inherited from the interaction opening a modal.
                        ## Component-origin submissions may include the source
                        ## message and may use `update` or `deferUpdate`.
    kindValue: ModalSourceKind
    messageValue: Option[Message]

  ModalContext* = ref object of InteractionContext
    ## Context for a submitted modal with decoded fields and optional source.
    customIdValue: string
    capturesValue: Table[string, string]
    fieldsValue: Table[string, string]
    resolvedValue: JsonNode
    sourceValue: Option[ModalSource]

  TextInputStyle* = enum ## Discord presentation style for a modal text input.
    ShortText = 1, ## Single-line input.
    ParagraphText = 2 ## Multi-line paragraph input.

  ModalInput* = object ## Text input wrapped in Discord's current Label component.
                       ## Prefer `textInput`, which validates ID and length
                       ## constraints before response authority is consumed.
    customId*: string ## Developer ID used as the typed handler parameter name.
    label*: string ## Visible Label heading.
    description*: Option[string] ## Optional Label description below the heading.
    style*: TextInputStyle ## Single-line or paragraph presentation.
    required*: bool ## Whether Discord requires a non-empty submission.
    minLength*: Option[int] ## Optional minimum input length.
    maxLength*: Option[int] ## Optional maximum input length.
    value*: Option[string] ## Optional pre-filled value.
    placeholder*: Option[string] ## Optional hint shown for an empty input.

  Modal* = object ## Modal response containing one or more text inputs.
    customId*: string ## Developer ID used for modal route matching.
    title*: string ## Dialog title displayed by Discord.
    inputs*: seq[ModalInput] ## Ordered Label-wrapped inputs.

  Choice* = object ## Named string, integer, or number autocomplete/command choice.
    name*: string ## Human-readable choice label.
    value*: JsonNode ## Scalar value returned to the command handler.

  AutocompleteContext* = ref object of InteractionContext
    ## Context for one focused slash-option autocomplete request.
    ## It can only be acknowledged with `complete`.
    commandNameValue: string
    focusedNameValue: string
    focusedValueValue: string
    optionsValue: JsonNode
    resolvedValue: JsonNode

  ErrorActionKind* = enum ## Explicit result returned by an `ErrorHandler`.
    Reraise, ## Propagate the caught error after policy evaluation.
    Ignore, ## Suppress the error without producing another response.
    RespondEphemeral, ## Send a safe invoker-only message if state permits.
    CompleteAutocomplete ## Return an empty autocomplete result if still pending.

  ErrorAction* = object ## State-aware recovery action for a caught handler error.
    case kind*: ErrorActionKind ## Selects the recovery behavior.
    of RespondEphemeral:
      message*: string ## Safe message shown to the invoking user.
    else:
      discard

  ErrorHandler* = proc(ctx: InteractionContext;
                       error: ref CatchableError): Future[ErrorAction]
    ## Async application error policy.
    ## DimSlash catches only `CatchableError`; `Defect` values bypass this hook.

  CheckDecisionKind* = enum ## Result of a route precondition.
    CheckPassed, ## Continue to later checks, cooldown, and handler dispatch.
    CheckRejected ## Stop dispatch and reject with a safe message.

  CheckDecision* = object ## Explicit allow-or-deny result from a route check.
    case kind*: CheckDecisionKind ## Selects the decision payload.
    of CheckPassed:
      discard
    of CheckRejected:
      rejectionMessage*: string ## Safe user-facing explanation.

  InteractionCheck = proc(ctx: InteractionContext): Future[CheckDecision]
  SlashCheck* = proc(ctx: SlashCommandContext): Future[CheckDecision]
    ## Async precondition for one slash-command path.
  UserCommandCheck* = proc(ctx: UserCommandContext): Future[CheckDecision]
    ## Async precondition for one user context-menu command.
  MessageCommandCheck* = proc(
    ctx: MessageCommandContext): Future[CheckDecision]
    ## Async precondition for one message context-menu command.
  ComponentCheck* = proc(ctx: ComponentContext): Future[CheckDecision]
    ## Async precondition for one button or select route.
  ModalCheck* = proc(ctx: ModalContext): Future[CheckDecision]
    ## Async precondition for one modal route.

  CooldownScope* = enum ## Principal sharing one route cooldown bucket.
    GlobalCooldown, ## Every invocation shares the same bucket.
    UserCooldown, ## Each invoking user has an independent bucket.
    GuildCooldown ## Each guild has an independent bucket; DMs are rejected.

  CooldownRule* = object ## Positive monotonic cooldown duration and partition.
    durationMs*: int64 ## Cooldown length in milliseconds; must be positive.
    scope*: CooldownScope ## Principal used to build the bucket key.

  OptionKind* = enum ## Discord slash-command option wire type.
    StringOption = 3, ## UTF-8 string value.
    IntegerOption = 4, ## Integer value within Discord's safe range.
    BooleanOption = 5, ## Boolean value.
    UserOption = 6, ## Resolved `User` or guild `Member`.
    ChannelOption = 7, ## Resolved `ResolvedChannel`.
    RoleOption = 8, ## Resolved `Role`.
    MentionableOption = 9, ## Resolved `Mentionable` user or role.
    NumberOption = 10, ## Floating-point number.
    AttachmentOption = 11 ## Resolved existing `Attachment`.

  ChannelKind* = enum ## Discord channel type used by channel option constraints.
    GuildText = 0, ## Guild text channel.
    DirectMessage = 1, ## One-to-one direct message.
    GuildVoice = 2, ## Guild voice channel.
    GroupDirectMessage = 3, ## Group direct message.
    GuildCategory = 4, ## Guild category.
    GuildAnnouncement = 5, ## Guild announcement channel.
    AnnouncementThread = 10, ## Thread in an announcement channel.
    PublicThread = 11, ## Public guild thread.
    PrivateThread = 12, ## Private guild thread.
    GuildStageVoice = 13, ## Guild stage channel.
    GuildDirectory = 14, ## Guild directory channel.
    GuildForum = 15, ## Guild forum channel.
    GuildMedia = 16 ## Guild media channel.

  InteractionContextKind* = enum ## Surface where an application command is usable.
    GuildContext = 0, ## A guild channel.
    BotDirectMessageContext = 1, ## Direct message with the installed bot.
    PrivateChannelContext = 2 ## Private channel for a user-installed app.

  IntegrationKind* = enum ## Installation owner allowed to invoke a command.
    GuildInstall = 0, ## Application installed to a guild.
    UserInstall = 1 ## Application installed to a user account.

  GatewayIntent* = enum ## Gateway event subscription requested by `bindGateway`.
                         ## Privileged intents must also be enabled in the
                         ## Discord developer portal.
    Guilds = 0, ## Guild create/update/delete and channel events.
    GuildMembers, ## Guild member events; privileged.
    GuildModeration, ## Ban and moderation events.
    GuildEmojisAndStickers, ## Emoji and sticker events.
    GuildIntegrations, ## Integration events.
    GuildWebhooks, ## Webhook update events.
    GuildInvites, ## Invite events.
    GuildVoiceStates, ## Voice-state events.
    GuildPresences, ## Presence events; privileged.
    GuildMessages, ## Guild message events.
    GuildMessageReactions, ## Reactions on guild messages.
    GuildMessageTyping, ## Typing indicators in guild channels.
    DirectMessages, ## Direct-message events.
    DirectMessageReactions, ## Reactions on direct messages.
    DirectMessageTyping, ## Typing indicators in direct messages.
    MessageContent, ## Message content fields; privileged.
    GuildScheduledEvents = 16, ## Scheduled-event updates.
    AutoModerationConfiguration = 20, ## AutoMod rule updates.
    AutoModerationExecution, ## AutoMod action executions.
    GuildMessagePolls = 24, ## Poll votes on guild messages.
    DirectMessagePolls ## Poll votes on direct messages.

  CommandMetadata = object
    defaultMemberPermissions: Option[uint64]
    nsfw: bool
    contexts: Option[set[InteractionContextKind]]
    integrations: Option[set[IntegrationKind]]
    nameLocalizations: Table[string, string]
    descriptionLocalizations: Table[string, string]

  CommandOption* = object ## Derived or explicitly supplied slash-option schema.
                          ## Typed route macros construct this from handler
                          ## parameters and their DimSlash pragmas.
    name*: string ## Discord option name.
    description*: string ## User-facing option description.
    kind*: OptionKind ## Wire type and handler decoding rule.
    required*: bool ## Whether omission is rejected before handler execution.
    minValue*: Option[float] ## Optional numeric lower bound.
    maxValue*: Option[float] ## Optional numeric upper bound.
    minLength*: Option[int] ## Optional string-length lower bound.
    maxLength*: Option[int] ## Optional string-length upper bound.
    autocomplete*: bool ## Whether a focused request uses an autocomplete route.
    choices*: seq[Choice] ## Static choices; mutually exclusive with autocomplete.
    channelKinds*: seq[ChannelKind] ## Allowed channel types for channel options.
    nameLocalizations*: Table[string, string] ## Locale-to-name translations.
    descriptionLocalizations*: Table[string, string]
      ## Locale-to-description translations.

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

  ComponentInteractionKind* = enum ## Component family accepted by a collector.
    ButtonInteraction, ## Button presses.
    SelectInteraction ## String or entity select submissions.

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

  Routes* = object ## Mutable route builder passed only to a `RouteFactory`.
                   ## After `newDiscordApp` returns, its frozen table is owned
                   ## by the app and no longer exposed for mutation.
    slashRoutes: OrderedTable[string, SlashRoute]
    userRoutes: OrderedTable[string, NamedRoute[UserCommandHandler]]
    messageRoutes: OrderedTable[string, NamedRoute[MessageCommandHandler]]
    buttonRoutes: seq[ComponentRoute]
    modalRoutes: seq[ModalRoute]

  RouteFactory* = proc(routes: var Routes)
    ## Closure that declares every persistent route and policy.
    ## `newDiscordApp` evaluates it exactly once.

  DiscordApp* = object ## Immutable route definition reusable across bindings.
                       ## It contains no token, gateway connection, cooldown
                       ## bucket, waiter, or request-scoped response state.
    routesValue: Routes
    errorHandlerValue: ErrorHandler

  AppBinding* = ref object ## Runtime attachment of one `DiscordApp` to one transport.
                           ## It owns gateway lifecycle, command-sync cache,
                           ## cooldown buckets, collectors, and active-request
                           ## draining. Create it with `bindGateway`.
    app: DiscordApp
    sink: ResponseSink
    commandSink: CommandSyncSink
    client: discord.DiscordClient
    previousDispatch: proc(shard: discord.Shard; event: string;
                           data: JsonNode): Future[void]
    previousReady: proc(shard: discord.Shard;
                        ready: discord.Ready): Future[void]
    stopGateway: proc(): Future[void]
    gatewaySession: Future[void]
    managedScopes: seq[CommandScope]
    applicationId: ApplicationId
    installed: bool
    commandsSynced: bool
    accepting: bool
    gatewayStopRequested: bool
    activeRequests: int
    drained: Future[void]
    cooldowns: Table[string, int64]
    monotonicMilliseconds: proc(): int64
    componentWaiters: seq[ComponentWaiter]
    modalWaiters: seq[ModalWaiter]
    gatewayIntents: set[GatewayIntent]
    messageContentIntent: bool
    autoReconnect: bool

  CommandScopeKind* = enum ## Discord application-command overwrite scope.
    GlobalCommands, ## Global commands available according to command contexts.
    GuildCommands ## Commands registered to one guild for immediate availability.

  CommandScope* = object ## Explicit command scope managed by an `AppBinding`.
                         ## Every listed scope is authoritatively bulk-overwritten;
                         ## unlisted scopes are never touched.
    case kind*: CommandScopeKind ## Selects global or guild registration.
    of GlobalCommands:
      discard
    of GuildCommands:
      guildId*: GuildId ## Guild receiving the overwrite.

  SyncResult* = object ## Result summary for one completed scope overwrite.
    scope*: CommandScope ## Scope that Discord accepted.
    commandCount*: int ## Number of local commands written to that scope.

const
  OriginalMessageId = MessageId("@original")
  ComponentsV2MessageFlag = 1 shl 15
  DimscordDisconnectedMessage = "Shard(s) disconnected."

template description*(value: static string) {.pragma.}
  ## Sets a typed handler parameter's Discord option description.
template desc*(value: static string) {.pragma.}
  ## Short alias for the `description` parameter pragma.
template min*(value: untyped) {.pragma.}
  ## Sets the inclusive numeric minimum for a slash option.
template max*(value: untyped) {.pragma.}
  ## Sets the inclusive numeric maximum for a slash option.
template minLength*(value: static int) {.pragma.}
  ## Sets the inclusive minimum length for a string slash option.
template maxLength*(value: static int) {.pragma.}
  ## Sets the inclusive maximum length for a string slash option.
template minLen*(value: static int) {.pragma.}
  ## Short alias for the `minLength` parameter pragma.
template maxLen*(value: static int) {.pragma.}
  ## Short alias for the `maxLength` parameter pragma.
template name*(value: static string) {.pragma.}
  ## Overrides the Discord wire name derived from a handler parameter.
template choices*(value: untyped) {.pragma.}
  ## Supplies static `Choice` values for a scalar slash option.
template channels*(value: untyped) {.pragma.}
  ## Restricts a channel option to a set of `ChannelKind` values.
template nameLoc*(value: untyped) {.pragma.}
  ## Supplies locale-to-name translations for a slash option.
template descLoc*(value: untyped) {.pragma.}
  ## Supplies locale-to-description translations for a slash option.

proc `$`*(value: ApplicationId | InteractionId | MessageId | UserId |
                 GuildId | ChannelId | RoleId | AttachmentId): string =
  ## Returns the original Discord snowflake text without numeric conversion.
  string(value)

proc toUint64*(value: Permissions): uint64 =
  ## Returns the raw Discord permission bit mask.
  uint64(value)

proc containsAll*(value, required: Permissions): bool =
  ## Reports whether every bit in `required` is present in `value`.
  (uint64(value) and uint64(required)) == uint64(required)

proc `==`*(left, right: ApplicationId): bool {.borrow.}
  ## Compares application snowflakes by their wire text.
proc `==`*(left, right: InteractionId): bool {.borrow.}
  ## Compares interaction snowflakes by their wire text.
proc `==`*(left, right: MessageId): bool {.borrow.}
  ## Compares message snowflakes by their wire text.
proc `==`*(left, right: UserId): bool {.borrow.}
  ## Compares user snowflakes by their wire text.
proc `==`*(left, right: GuildId): bool {.borrow.}
  ## Compares guild snowflakes by their wire text.
proc `==`*(left, right: ChannelId): bool {.borrow.}
  ## Compares channel snowflakes by their wire text.
proc `==`*(left, right: RoleId): bool {.borrow.}
  ## Compares role snowflakes by their wire text.
proc `==`*(left, right: AttachmentId): bool {.borrow.}
  ## Compares attachment snowflakes by their wire text.
proc hash*(value: ApplicationId): Hash {.borrow.}
  ## Hashes an application ID for use in Nim containers.
proc hash*(value: InteractionId): Hash {.borrow.}
  ## Hashes an interaction ID for use in Nim containers.
proc hash*(value: MessageId): Hash {.borrow.}
  ## Hashes a message ID for use in Nim containers.
proc hash*(value: UserId): Hash {.borrow.}
  ## Hashes a user ID for use in Nim containers.
proc hash*(value: GuildId): Hash {.borrow.}
  ## Hashes a guild ID for use in Nim containers.
proc hash*(value: ChannelId): Hash {.borrow.}
  ## Hashes a channel ID for use in Nim containers.
proc hash*(value: RoleId): Hash {.borrow.}
  ## Hashes a role ID for use in Nim containers.
proc hash*(value: AttachmentId): Hash {.borrow.}
  ## Hashes an attachment ID for use in Nim containers.

proc id*(value: User): UserId =
  ## Returns the user's Discord snowflake.
  value.idValue
proc username*(value: User): string =
  ## Returns the current username supplied with the interaction.
  value.usernameValue
proc user*(value: Member): User =
  ## Returns the user account belonging to this guild member.
  value.userValue
proc nickname*(value: Member): Option[string] =
  ## Returns the guild nickname when Discord included one.
  value.nicknameValue
proc permissions*(value: Member): Option[Permissions] =
  ## Returns interaction-resolved member permissions when available.
  value.permissionsValue
proc id*(value: Role): RoleId =
  ## Returns the role's Discord snowflake.
  value.idValue
proc name*(value: Role): string =
  ## Returns the role name supplied with the interaction.
  value.nameValue
proc id*(value: ResolvedChannel): ChannelId =
  ## Returns the channel's Discord snowflake.
  value.idValue
proc name*(value: ResolvedChannel): Option[string] =
  ## Returns the channel name when Discord included it.
  value.nameValue
proc id*(value: Attachment): AttachmentId =
  ## Returns the existing attachment's Discord snowflake.
  value.idValue
proc filename*(value: Attachment): string =
  ## Returns the existing attachment's filename.
  value.filenameValue
proc url*(value: Attachment): string =
  ## Returns Discord's URL for downloading the existing attachment.
  value.urlValue
proc id*(value: Message): MessageId =
  ## Returns the message's Discord snowflake.
  value.idValue
proc content*(value: Message): string =
  ## Returns the message content present in the response or interaction payload.
  value.contentValue
proc author*(value: Message): Option[User] =
  ## Returns the message author when Discord included it.
  value.authorValue
proc id*(value: ActivityInstance): string =
  ## Returns Discord's opaque launched-activity instance ID.
  value.idValue

proc id*(value: Interaction): InteractionId =
  ## Returns the interaction snowflake.
  value.idValue
proc applicationId*(value: Interaction): ApplicationId =
  ## Returns the application that owns the interaction.
  value.applicationIdValue
proc kind*(value: Interaction): InteractionKind =
  ## Returns the decoded high-level interaction category.
  value.kindValue
proc guildId*(value: Interaction): Option[GuildId] =
  ## Returns the invoking guild, or none for non-guild interactions.
  value.guildIdValue
proc channelId*(value: Interaction): Option[ChannelId] =
  ## Returns the invoking channel when Discord supplied one.
  value.channelIdValue
proc user*(value: Interaction): Option[User] =
  ## Returns the invoking user when present in the payload.
  value.userValue
proc member*(value: Interaction): Option[Member] =
  ## Returns guild membership data for a guild invocation.
  value.memberValue
proc message*(value: Interaction): Option[Message] =
  ## Returns the source message for component interactions when present.
  value.messageValue
proc locale*(value: Interaction): Option[string] =
  ## Returns the invoking user's Discord locale.
  value.localeValue
proc guildLocale*(value: Interaction): Option[string] =
  ## Returns the guild's preferred locale when present.
  value.guildLocaleValue
proc appPermissions*(value: Interaction): Permissions =
  ## Returns the application's effective permissions in the invoking channel.
  value.appPermissionsValue
proc raw*(value: Interaction): JsonNode =
  ## Returns a deep copy of the complete gateway interaction payload.
  ## Mutating the result cannot alter context state.
  value.rawValue.copy

proc interaction*(ctx: InteractionContext): Interaction =
  ## Returns the immutable owned snapshot for this request.
  ctx.interactionValue
proc responseState*(ctx: InteractionContext): ResponseState =
  ## Returns the current authoritative initial-response state.
  ctx.response.state
proc commandName*(ctx: SlashCommandContext): string =
  ## Returns the top-level slash-command name.
  ctx.commandNameValue
proc commandPath*(ctx: SlashCommandContext): seq[string] =
  ## Returns a copy of the matched subcommand path, excluding the root name.
  for segment in ctx.commandPathValue: result.add segment
proc target*(ctx: UserCommandContext): User =
  ## Returns the resolved target user of a user context-menu command.
  ctx.targetValue
proc targetMember*(ctx: UserCommandContext): Option[Member] =
  ## Returns the target's guild membership when invoked in a guild.
  ctx.targetMemberValue
proc target*(ctx: MessageCommandContext): Message =
  ## Returns the resolved target message of a message context-menu command.
  ctx.targetValue
proc customId*(ctx: ComponentContext | ModalContext): string =
  ## Returns the complete submitted custom ID before capture extraction.
  ctx.customIdValue
proc values*(ctx: ComponentContext): seq[string] =
  ## Returns a copy of raw select values in Discord submission order.
  for value in ctx.valuesValue: result.add value
proc fields*(ctx: ModalContext): Table[string, string] =
  ## Returns a copy of submitted modal fields keyed by input custom ID.
  for name, value in ctx.fieldsValue: result[name] = value
proc field*(ctx: ModalContext; name: string): Option[string] =
  ## Returns one submitted modal field without performing type conversion.
  if ctx.fieldsValue.hasKey(name): some(ctx.fieldsValue[name])
  else: none(string)
proc source*(ctx: ModalContext): Option[ModalSource] =
  ## Returns how the modal was opened when Discord supplied source metadata.
  ctx.sourceValue
proc kind*(source: ModalSource): ModalSourceKind =
  ## Returns whether a command or component opened the modal.
  source.kindValue
proc message*(source: ModalSource): Option[Message] =
  ## Returns the source message for a component-opened modal when present.
  source.messageValue
proc focusedName*(ctx: AutocompleteContext): string =
  ## Returns the wire name of the option currently being completed.
  ctx.focusedNameValue
proc focusedValue*(ctx: AutocompleteContext): string =
  ## Returns the focused option value as typed so far.
  ctx.focusedValueValue

proc requireUser(ctx: InteractionContext): User =
  if ctx.interactionValue.userValue.isNone:
    raise newException(InvalidInteractionError,
      "interaction has no invoking user")
  ctx.interactionValue.userValue.get

proc user*(ctx: InteractionContext): User =
  ## Returns the invoking user, raising `InvalidInteractionError` when absent.
  ctx.requireUser()

proc member*(ctx: InteractionContext): Option[Member] =
  ## Returns invoking guild-member data, or none outside a guild.
  ctx.interactionValue.memberValue

proc guildId*(ctx: InteractionContext): Option[GuildId] =
  ## Returns the invoking guild ID, or none outside a guild.
  ctx.interactionValue.guildIdValue

proc channelId*(ctx: InteractionContext): Option[ChannelId] =
  ## Returns the invoking channel ID when Discord supplied it.
  ctx.interactionValue.channelIdValue

proc locale*(ctx: InteractionContext): Option[string] =
  ## Returns the invoking user's locale when supplied.
  ctx.interactionValue.localeValue

proc guildLocale*(ctx: InteractionContext): Option[string] =
  ## Returns the guild's preferred locale when supplied.
  ctx.interactionValue.guildLocaleValue

proc appPermissions*(ctx: InteractionContext): Permissions =
  ## Returns the application's effective permissions in the invoking channel.
  ctx.interactionValue.appPermissionsValue

proc inGuild*(ctx: InteractionContext): bool =
  ## Reports whether this interaction belongs to a guild.
  ctx.interactionValue.guildIdValue.isSome

proc embed*(title = ""; description = "";
            color = none(int)): Embed =
  ## Creates an embed with optional title, description, and RGB color.
  ## Raises `ValueError` when `color` is outside `0x000000..0xFFFFFF`.
  if title.len > 0: result.title = some(title)
  if description.len > 0: result.description = some(description)
  if color.isSome:
    if color.get notin 0 .. 0xFFFFFF:
      raise newException(ValueError,
        "an embed color must be between 0x000000 and 0xFFFFFF")
    result.color = color

proc embedMedia*(url: string): EmbedMedia =
  ## Creates an embed image reference.
  ## Raises `ValueError` when `url` is empty.
  if url.len == 0: raise newException(ValueError, "embed media needs a URL")
  EmbedMedia(url: url)

proc embedAuthor*(name: string; url = ""; iconUrl = ""): EmbedAuthor =
  ## Creates an embed author header, omitting blank optional URLs.
  ## Raises `ValueError` when `name` is empty.
  if name.len == 0: raise newException(ValueError, "embed author needs a name")
  result.name = name
  if url.len > 0: result.url = some(url)
  if iconUrl.len > 0: result.iconUrl = some(iconUrl)

proc embedFooter*(text: string; iconUrl = ""): EmbedFooter =
  ## Creates an embed footer, omitting a blank icon URL.
  ## Raises `ValueError` when `text` is empty.
  if text.len == 0: raise newException(ValueError, "embed footer needs text")
  result.text = text
  if iconUrl.len > 0: result.iconUrl = some(iconUrl)

proc embedField*(name, value: string; inline = false): EmbedField =
  ## Creates one embed field.
  ## Raises `ValueError` when either visible string is empty.
  if name.len == 0 or value.len == 0:
    raise newException(ValueError,
      "an embed field needs a non-empty name and value")
  EmbedField(name: name, value: value, inline: inline)

proc add*(value: var Embed; field: sink EmbedField) =
  ## Appends `field` to an embed, consuming the field value.
  ## Raises `ValueError` once Discord's 25-field limit is reached.
  if value.fields.len >= 25:
    raise newException(ValueError, "an embed allows at most 25 fields")
  value.fields.add field

proc classicMessage*(content = ""; ephemeral = false): ClassicMessage =
  ## Creates a classic message response with optional content.
  ## Mention parsing initially follows Discord's normal behavior; assign
  ## `noMentions()` when incorporating untrusted text.
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
  ## Validates and creates a Components V2 message.
  ## Raises `ValueError` for nil nodes, cycles, duplicate custom IDs, illegal
  ## nesting, invalid child counts, or more than 40 total components.
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
  ## Validates and wraps a classic message for response or edit operations.
  ## Enforces Discord limits for content, embeds, rows, files, row shape, and
  ## unique custom IDs; invalid input raises `ValueError` before any request.
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
  ## Validates and wraps a Components V2 message for response or edit operations.
  ## Invalid file or component structure raises `ValueError` before any request.
  if value.files.len > 10:
    raise newException(ValueError, "a message allows at most 10 uploaded files")
  discard componentsV2(value.components, value.ephemeral)
  MessageBody(kind: ComponentsV2Body, v2: value)

proc button*(label, customId: string; style = Primary;
             disabled = false): Button =
  ## Creates an interactive non-link button.
  ## Labels must contain 1..80 characters, custom IDs 1..100, and `style`
  ## cannot be `Link`; violations raise `ValueError`.
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
  ## Creates a URL button that opens a link and emits no interaction.
  ## Raises `ValueError` unless the label is 1..80 and URL is 1..512 characters.
  if label.len notin 1 .. 80:
    raise newException(ValueError,
      "a button label must contain 1..80 characters")
  if url.len notin 1 .. 512:
    raise newException(ValueError,
      "a link button URL must contain 1..512 characters")
  Button(label: label, url: some(url), style: Link, disabled: disabled)

proc actionRow*(buttons: varargs[Button]): ClassicActionRow =
  ## Creates a classic row containing 1..5 buttons.
  ## Raises `ValueError` outside that range.
  if buttons.len notin 1 .. 5:
    raise newException(ValueError, "an action row requires 1..5 buttons")
  for value in buttons:
    result.components.add ClassicComponent(kind: ClassicButton,
                                            button: value)

proc selectOption*(label, value: string; description = "";
                   default = false): SelectOption =
  ## Creates one string-select option.
  ## Label and value must contain 1..100 characters and description at most 100;
  ## otherwise `ValueError` is raised.
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
  ## Creates a string select with 1..25 caller-defined options.
  ## Validates custom ID, placeholder, selection cardinality, and default count;
  ## invalid combinations raise `ValueError`.
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
  ## Creates a Discord user select.
  ## Selection cardinality must satisfy `0 <= minValues <= maxValues <= 25`.
  entitySelect(UserSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc roleSelect*(customId: string; placeholder = ""; minValues = 1;
                 maxValues = 1; disabled = false): SelectMenu =
  ## Creates a Discord role select with validated ID and cardinality.
  entitySelect(RoleSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc mentionableSelect*(customId: string; placeholder = ""; minValues = 1;
                        maxValues = 1; disabled = false): SelectMenu =
  ## Creates a select that accepts users and roles in one ordered result.
  entitySelect(MentionableSelect, customId, placeholder, minValues, maxValues,
               disabled)

proc channelSelect*(customId: string; channelKinds: set[ChannelKind] = {};
                    placeholder = ""; minValues = 1; maxValues = 1;
                    disabled = false): SelectMenu =
  ## Creates a channel select optionally restricted to `channelKinds`.
  ## An empty set lets Discord offer every channel kind available to the user.
  result = entitySelect(ChannelSelect, customId, placeholder, minValues,
                        maxValues, disabled)
  for kind in channelKinds: result.channelKinds.add kind

proc actionRow*(menu: SelectMenu): ClassicActionRow =
  ## Wraps one select menu as the sole child of a classic action row.
  ClassicActionRow(components: @[
    ClassicComponent(kind: ClassicSelect, selectMenu: menu)
  ])

proc textDisplay*(content: string): V2Component =
  ## Creates a Components V2 markdown text node.
  ## Full length validation occurs when the containing message is wrapped.
  V2Component(kind: TextDisplay, text: content)

proc v2ActionRow*(buttons: varargs[Button]): V2Component =
  ## Creates a Components V2 action row containing 1..5 buttons.
  ## Raises `ValueError` outside that range.
  if buttons.len notin 1 .. 5:
    raise newException(ValueError, "an action row requires 1..5 buttons")
  result = V2Component(kind: V2ActionRow)
  for button in buttons:
    result.interactiveComponents.add ClassicComponent(
      kind: ClassicButton, button: button)

proc v2ActionRow*(menu: SelectMenu): V2Component =
  ## Creates a Components V2 action row whose sole child is `menu`.
  V2Component(kind: V2ActionRow, interactiveComponents: @[
    ClassicComponent(kind: ClassicSelect, selectMenu: menu)
  ])

proc mediaItem*(url: string; description = "";
                spoiler = false): MediaItem =
  ## Creates a V2 media reference with optional description and spoiler state.
  ## The containing node validates whether its URL form is legal.
  result = MediaItem(url: url, spoiler: spoiler)
  if description.len > 0: result.description = some(description)

proc buttonAccessory*(button: Button): SectionAccessory =
  ## Wraps a valid interactive or link button as a section accessory.
  ## Raises `ValueError` if the raw `Button` has neither custom ID nor URL.
  if button.style == Link or button.customId.isSome:
    return SectionAccessory(kind: AccessoryButton,
                            accessoryButton: button)
  raise newException(ValueError, "a section button needs a custom id or URL")

proc thumbnailAccessory*(url: string; description = "";
                         spoiler = false): SectionAccessory =
  ## Creates a thumbnail accessory for a Components V2 section.
  SectionAccessory(kind: AccessoryThumbnail,
    thumbnail: mediaItem(url, description, spoiler))

proc section*(texts: openArray[string];
              accessory: SectionAccessory): V2Component =
  ## Creates a section with 1..3 markdown text blocks and one accessory.
  ## Raises `ValueError` for an invalid text-block count.
  if texts.len notin 1 .. 3:
    raise newException(ValueError,
      "a Components V2 section requires 1..3 text displays")
  V2Component(kind: Section, sectionTexts: @texts,
              sectionAccessory: accessory)

proc mediaGallery*(items: openArray[MediaItem]): V2Component =
  ## Creates a media gallery containing 1..10 items.
  ## Raises `ValueError` outside that range.
  if items.len notin 1 .. 10:
    raise newException(ValueError,
      "a Components V2 media gallery requires 1..10 items")
  V2Component(kind: MediaGallery, mediaItems: @items)

proc fileDisplay*(attachmentUrl: string; spoiler = false): V2Component =
  ## Creates a V2 file display for `attachment://filename`.
  ## Raises `ValueError` for network URLs or an empty attachment filename.
  if not attachmentUrl.startsWith("attachment://") or
      attachmentUrl.len == "attachment://".len:
    raise newException(ValueError,
      "a file display URL must use attachment://<filename>")
  V2Component(kind: FileDisplay,
              fileItem: mediaItem(attachmentUrl, spoiler = spoiler))

proc separator*(divider = true; spacing: range[1 .. 2] = 1): V2Component =
  ## Creates a V2 separator with small (`1`) or large (`2`) spacing.
  V2Component(kind: Separator, divider: divider, spacing: spacing)

proc container*(components: openArray[V2Component];
                accentColor = none(int); spoiler = false): V2Component =
  ## Creates a non-empty V2 container with optional RGB accent and spoiler.
  ## Nested containers and complete tree constraints are checked by
  ## `componentsV2`; invalid emptiness or color raises `ValueError` immediately.
  if components.len == 0:
    raise newException(ValueError,
      "a Components V2 container cannot be empty")
  if accentColor.isSome and accentColor.get notin 0 .. 0xFFFFFF:
    raise newException(ValueError,
      "a container accent color must be between 0x000000 and 0xFFFFFF")
  V2Component(kind: Container, containerComponents: @components,
              accentColor: accentColor, containerSpoiler: spoiler)

proc userRejection*(message: string): ref UserRejectionError =
  ## Creates a deliberate user-facing rejection with a stable safe message.
  ## Raise the returned exception from a handler or check helper; the default
  ## error policy responds ephemerally without exposing an async traceback.
  result = newException(UserRejectionError, message)
  result.userMessageValue = message

proc userMessage*(error: ref UserRejectionError): string =
  ## Returns only the safe rejection text, excluding async traceback decoration.
  if error.userMessageValue.len > 0: error.userMessageValue
  else: error.msg.split("\nAsync traceback:")[0]

proc allow*(): CheckDecision =
  ## Creates a passing route-check decision.
  CheckDecision(kind: CheckPassed)

proc deny*(message: string): CheckDecision =
  ## Creates a rejected route-check decision with a safe user-facing message.
  ## Raises `ValueError` when `message` is empty.
  if message.len == 0:
    raise newException(ValueError, "a rejected check needs a message")
  CheckDecision(kind: CheckRejected, rejectionMessage: message)

proc cooldownRule*(durationMs: int64;
                   scope = UserCooldown): CooldownRule =
  ## Creates a validated binding-owned monotonic cooldown rule.
  ## Raises `ValueError` unless `durationMs` is positive.
  if durationMs <= 0:
    raise newException(ValueError,
      "a cooldown duration must be greater than zero")
  CooldownRule(durationMs: durationMs, scope: scope)

proc noMentions*(): AllowedMentions =
  ## Returns a policy that suppresses all automatic and reply mentions.
  AllowedMentions()

proc uploadedFile*(filename, content: string;
                   description = ""): UploadedFile =
  ## Creates an in-memory multipart upload.
  ## `filename` must be a non-empty basename with no path components;
  ## violations raise `ValueError`. `content` may contain arbitrary bytes.
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
  ## Describes one modal text input using Discord's Label representation.
  ## Cross-field and wire length constraints are validated by `modalDialog`.
  result = ModalInput(customId: customId, label: label, style: style,
    required: required, minLength: minLength, maxLength: maxLength,
    value: value, placeholder: placeholder)
  if description.len > 0: result.description = some(description)

proc modalDialog*(customId, title: string;
                  inputs: varargs[ModalInput]): Modal =
  ## Validates and creates a modal containing 1..5 uniquely identified inputs.
  ## Raises `ValueError` for Discord ID, title, label, count, or length-bound
  ## violations before the modal can consume response authority.
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
  ## Creates a string-valued slash or autocomplete choice.
  Choice(name: name, value: %value)

proc choice*(name: string; value: int): Choice =
  ## Creates an integer-valued slash or autocomplete choice.
  Choice(name: name, value: %value)

proc choice*(name: string; value: float): Choice =
  ## Creates a number-valued slash or autocomplete choice.
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
  result["flags"] = %(
    ComponentsV2MessageFlag or (if value.ephemeral: 64 else: 0))
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

proc requireCompatibleBody(controller: ResponseController;
                           body: MessageBody) =
  if controller.originalUsesV2 and body.kind != ComponentsV2Body:
    raise newException(InvalidResponseStateError,
      "a Components V2 message cannot be converted back to classic content")

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
  ## Sends the one immediate message response and fetches its created message.
  ## Legal only in `Pending`; success moves to `Responded`. A definite Discord
  ## rejection leaves the state pending, while an ambiguous transport failure
  ## moves it to `OutcomeUnknown` and raises `ResponseOutcomeUnknownError`.
  ctx.response.requireState({Pending}, "respond")
  await ctx.response.sendInitial(InitialMessage, body.toJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc respond*(ctx: InteractionContext; content: string;
              ephemeral = false): Future[Message] =
  ## Sends a plain classic initial response and returns the created message.
  ## This is the convenience form of `respond(classicMessage(...).messageBody)`.
  ctx.respond(classicMessage(content, ephemeral).messageBody)

proc deferReply*(ctx: InteractionContext;
                 ephemeral = false): Future[void] {.async.} =
  ## Acknowledges now and reserves an original message for a later edit.
  ## Legal only in `Pending`; success moves to `DeferredReply`. The ephemeral
  ## choice is fixed by this acknowledgement and cannot be changed later.
  ctx.response.requireState({Pending}, "deferReply")
  let flags = if ephemeral: 64 else: 0
  await ctx.response.sendInitial(InitialDeferredMessage, %*{"flags": flags},
                                 DeferredReply)

proc update*(ctx: ComponentContext;
             body: MessageBody): Future[Message] {.async.} =
  ## Immediately replaces the component's source message and returns it.
  ## Legal only in `Pending`; success moves to `Responded`. Edit semantics
  ## explicitly clear omitted classic fields, and a V2 original cannot later
  ## be converted back to classic content.
  ctx.response.requireState({Pending}, "update")
  ctx.response.requireCompatibleBody(body)
  await ctx.response.sendInitial(InitialUpdate, body.toEditJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc update*(ctx: ComponentContext; content: string): Future[Message] =
  ## Replaces a component's source message with plain classic content.
  ctx.update(classicMessage(content).messageBody)

proc deferUpdate*(ctx: ComponentContext): Future[void] {.async.} =
  ## Acknowledges a component without changing its source message yet.
  ## Legal only in `Pending`; success moves to `DeferredUpdate`, after which
  ## `editOriginal` or `followup` may be used.
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
  ## Replaces the source message of a component-opened modal and returns it.
  ## Raises `InvalidResponseStateError` for command-opened modals or when the
  ## initial response is no longer pending.
  ctx.requireComponentSource("update")
  ctx.response.requireState({Pending}, "update")
  ctx.response.requireCompatibleBody(body)
  await ctx.response.sendInitial(InitialUpdate, body.toEditJson, Responded,
                                 body.files)
  ctx.response.originalUsesV2 = body.kind == ComponentsV2Body
  return await ctx.response.sink.getMessage(
    ctx.response.applicationId, ctx.response.token, OriginalMessageId)

proc update*(ctx: ModalContext; content: string): Future[Message] =
  ## Replaces a component-opened modal's source message with plain content.
  ctx.update(classicMessage(content).messageBody)

proc deferUpdate*(ctx: ModalContext): Future[void] {.async.} =
  ## Defers the source-message update of a component-opened modal.
  ## Command-opened or source-less modals cannot use this acknowledgement.
  ctx.requireComponentSource("deferUpdate")
  ctx.response.requireState({Pending}, "deferUpdate")
  await ctx.response.sendInitial(InitialDeferredUpdate, newJObject(),
                                 DeferredUpdate)

proc editOriginal*(ctx: InteractionContext;
                   body: MessageBody): Future[Message] {.async.} =
  ## Edits and returns the original interaction response.
  ## Legal after defer or response, and turns either deferred state into
  ## `Responded`. Raises `InvalidResponseStateError` before acknowledgement or
  ## when attempting to convert a Components V2 original back to classic.
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "editOriginal")
  ctx.response.requireCompatibleBody(body)
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
  ## Opens `modal` as the initial response to a command or component.
  ## Legal only in `Pending`; success consumes response authority and moves to
  ## `Responded`. Use `modalDialog` to validate raw modal values first.
  ctx.response.requireState({Pending}, "showModal")
  await ctx.response.sendInitial(InitialModal, modal.toJson, Responded)

proc launchActivity*(ctx: SlashCommandContext | UserCommandContext |
    MessageCommandContext | ComponentContext | ModalContext):
    Future[ActivityInstance] {.async.} =
  ## Launches a Discord Activity as the one initial callback response.
  ## Returns Discord's activity instance on success. An ambiguous transport
  ## failure moves the context to `OutcomeUnknown` because retrying may launch
  ## twice; autocomplete interactions do not support this operation.
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
  ## Completes an autocomplete interaction with at most 25 choices.
  ## Choice names must contain 1..100 characters. Validation failures raise
  ## `ValueError` without consuming the pending response.
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
  ## Edits the original response to plain classic content and returns it.
  ## A Components V2 original rejects this convenience overload.
  ctx.editOriginal(classicMessage(content).messageBody)

proc followup*(ctx: InteractionContext;
               body: MessageBody): Future[Message] {.async.} =
  ## Creates and returns a follow-up message after acknowledgement.
  ## Legal in deferred or responded states. Follow-ups do not change the
  ## initial-response state and may independently be classic or Components V2.
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "followup")
  return await ctx.response.sink.createFollowup(
    ctx.response.applicationId, ctx.response.token, body.toJson, body.files)

proc followup*(ctx: InteractionContext; content: string;
               ephemeral = false): Future[Message] =
  ## Creates a plain classic follow-up and returns the created message.
  ctx.followup(classicMessage(content, ephemeral).messageBody)

proc editFollowup*(ctx: InteractionContext; messageId: MessageId;
                   body: MessageBody): Future[Message] {.async.} =
  ## Edits and returns a previously created interaction message.
  ## Passing `MessageId("@original")` delegates to `editOriginal`; other IDs
  ## require an acknowledged context and use Discord webhook edit semantics.
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
  ## Edits an interaction message to plain classic content and returns it.
  ctx.editFollowup(messageId, classicMessage(content).messageBody)

proc original*(ctx: InteractionContext): Future[Message] =
  ## Fetches the current original interaction response from Discord.
  ## Discord rejects the request when no original message exists.
  ctx.response.sink.getMessage(ctx.response.applicationId,
                               ctx.response.token, OriginalMessageId)

proc deleteOriginal*(ctx: InteractionContext): Future[void] {.async.} =
  ## Deletes the original response after acknowledgement.
  ## Raises `InvalidResponseStateError` while still pending or outcome-unknown.
  ctx.response.requireState({DeferredReply, DeferredUpdate, Responded},
                            "deleteOriginal")
  await ctx.response.sink.deleteMessage(ctx.response.applicationId,
                                        ctx.response.token,
                                        OriginalMessageId)

proc deleteFollowup*(ctx: InteractionContext;
                     messageId: MessageId): Future[void] {.async.} =
  ## Deletes a follow-up message after acknowledgement.
  ## `MessageId("@original")` is accepted as an alias for `deleteOriginal`.
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
  ## Decodes selected users in Discord submission order.
  ## Raises `InvalidInteractionError` if any selected ID lacks resolved data.
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("users", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected user is not resolved: " & id)
    result.add decodeUser(entity.get)

proc selectedMembers*(ctx: ComponentContext): seq[Member] =
  ## Decodes selected guild members in submission order.
  ## Both resolved member and user objects are required for every value.
  for id in ctx.valuesValue:
    let member = ctx.resolvedValue.resolvedEntity("members", id)
    let user = ctx.resolvedValue.resolvedEntity("users", id)
    if member.isNone or user.isNone:
      raise newException(InvalidInteractionError,
        "selected member is not resolved: " & id)
    result.add decodeMember(member.get, decodeUser(user.get))

proc selectedRoles*(ctx: ComponentContext): seq[Role] =
  ## Decodes selected roles in Discord submission order.
  ## Missing resolved role data raises `InvalidInteractionError`.
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("roles", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected role is not resolved: " & id)
    result.add decodeRole(entity.get)

proc selectedChannels*(ctx: ComponentContext): seq[ResolvedChannel] =
  ## Decodes selected channels in Discord submission order.
  ## Missing resolved channel data raises `InvalidInteractionError`.
  for id in ctx.valuesValue:
    let entity = ctx.resolvedValue.resolvedEntity("channels", id)
    if entity.isNone:
      raise newException(InvalidInteractionError,
        "selected channel is not resolved: " & id)
    result.add decodeChannel(entity.get)

proc selectedMentionables*(ctx: ComponentContext): seq[Mentionable] =
  ## Decodes selected users and roles into one ordered variant sequence.
  ## A value absent from both resolved collections raises
  ## `InvalidInteractionError`.
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
  ## Decodes one required slash option by its Discord wire name.
  ## Supported targets are scalar primitives, DimSlash resolved models,
  ## enums, integer ranges, and distinct string/int types. Missing, malformed,
  ## unresolved, or out-of-range data raises `InvalidInteractionError`.
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
  ## Decodes an optional slash option, returning none only when it was omitted.
  ## A present but malformed value raises the same errors as `requiredOption`.
  let value = ctx.optionJson(name)
  if value.isNone:
    return none(T)
  some(requiredOption[T](ctx, name))

proc capture*(ctx: ComponentContext | ModalContext; name: string): string =
  ## Returns a named string or integer capture from the matched custom-ID route.
  ## Raises `InvalidInteractionError` when the route declared no such capture.
  if not ctx.capturesValue.hasKey(name):
    raise newException(InvalidInteractionError, "capture is missing: " & name)
  ctx.capturesValue[name]

proc captureInt*(ctx: ComponentContext | ModalContext; name: string): int =
  ## Parses a named custom-ID capture as an integer.
  ## Missing or non-integer values raise `InvalidInteractionError`.
  try:
    parseInt(ctx.capture(name))
  except ValueError:
    raise newException(InvalidInteractionError,
      "capture is not an integer: " & name)

proc requiredModalField*[T](ctx: ModalContext; name: string;
                            label = ""): T =
  ## Decodes a required modal field as `string`, `int`, or `float`.
  ## Missing fields raise `InvalidInteractionError`; invalid numeric text raises
  ## `UserRejectionError` using `label` as its user-facing name when supplied.
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
  ## Decodes a non-blank optional modal field as `string`, `int`, or `float`.
  ## Missing and whitespace-only input return none; malformed numeric text is a
  ## `UserRejectionError` suitable for the default ephemeral error policy.
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
  ## Returns the invoking user's ID when the interaction contains a user.
  if interaction.userValue.isSome:
    some(interaction.userValue.get.id)
  else:
    none(UserId)

proc invokerId*(ctx: InteractionContext): Option[UserId] =
  ## Returns the invoking user's ID from a request context when available.
  ctx.interactionValue.invokerId

proc scopedId*(ctx: InteractionContext; tag: string): string =
  ## Builds a per-interaction custom ID as `ds:<tag>:<interaction-id>`.
  ## Raises `ValueError` when the result exceeds Discord's 100-character limit.
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
  ## Collects the first matching button or select before persistent routes run.
  ## Patterns use the same `{name}` and `{name:int}` captures as routes.
  ## Optional user/message filters prevent unrelated presses. Returns none on
  ## timeout or binding shutdown; invalid input raises `ValueError`.
  if binding.isNil:
    raise newException(ValueError, "a component waiter requires a binding")
  let waiter = ComponentWaiter(kinds: kinds,
    patterns: parsePatterns(patterns), userId: userId, messageId: messageId,
    future: newFuture[Option[ComponentContext]]("dimslash.waitForComponent"))
  binding.awaitComponent(waiter, timeoutMs)

proc waitForButton*(binding: AppBinding; patterns: openArray[string];
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one button press matching any pattern on `binding`.
  ## No user filter is applied unless `userId` is supplied.
  binding.waitForComponent({ButtonInteraction}, patterns, timeoutMs, userId,
                           messageId)

proc waitForButton*(binding: AppBinding; pattern: string;
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one button press matching a single pattern.
  binding.waitForButton([pattern], timeoutMs, userId, messageId)

proc waitForSelect*(binding: AppBinding; patterns: openArray[string];
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one string or entity select matching any pattern.
  ## Decode resolved values from the returned context with `selectedUsers`,
  ## `selectedRoles`, `selectedChannels`, or `selectedMentionables`.
  binding.waitForComponent({SelectInteraction}, patterns, timeoutMs, userId,
                           messageId)

proc waitForSelect*(binding: AppBinding; pattern: string;
    timeoutMs = 60_000; userId = none(UserId);
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one select submission matching a single pattern.
  binding.waitForSelect([pattern], timeoutMs, userId, messageId)

proc waitForComponent*(ctx: InteractionContext;
    kinds: set[ComponentInteractionKind]; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects the next matching component for an acknowledged request.
  ## By default only the invoking user may satisfy it. Raises
  ## `InvalidResponseStateError` while the initial response is still pending;
  ## returns none on timeout or shutdown.
  if ctx.responseState == Pending:
    raise newException(InvalidResponseStateError,
      "waitForComponent requires the current interaction to be acknowledged")
  ctx.bindingValue.waitForComponent(kinds, patterns, timeoutMs, userId,
                                    messageId)

proc waitForButton*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one of several button patterns, defaulting to the invoking user.
  ctx.waitForComponent({ButtonInteraction}, patterns, timeoutMs, userId,
                       messageId)

proc waitForButton*(ctx: InteractionContext; pattern: string;
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one button pattern, defaulting to the invoking user.
  ctx.waitForButton([pattern], timeoutMs, userId, messageId)

proc waitForSelect*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one of several select patterns, defaulting to the invoking user.
  ctx.waitForComponent({SelectInteraction}, patterns, timeoutMs, userId,
                       messageId)

proc waitForSelect*(ctx: InteractionContext; pattern: string;
    timeoutMs = 60_000; userId: Option[UserId] = ctx.invokerId;
    messageId = none(MessageId)): Future[Option[ComponentContext]] =
  ## Collects one select pattern, defaulting to the invoking user.
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
  ## Collects the first modal submission matching any pattern before routes run.
  ## Returns none on timeout or shutdown. No user filter is applied unless
  ## `userId` is supplied; an empty pattern list or non-positive timeout raises
  ## `ValueError`.
  if binding.isNil:
    raise newException(ValueError, "a modal waiter requires a binding")
  let waiter = ModalWaiter(patterns: parsePatterns(patterns), userId: userId,
    future: newFuture[Option[ModalContext]]("dimslash.waitForModal"))
  binding.awaitModal(waiter, timeoutMs)

proc waitForModal*(binding: AppBinding; pattern: string;
    timeoutMs = 300_000; userId = none(UserId)):
    Future[Option[ModalContext]] =
  ## Collects one modal submission matching a single pattern.
  binding.waitForModal([pattern], timeoutMs, userId)

proc waitForModal*(ctx: InteractionContext; patterns: openArray[string];
    timeoutMs = 300_000; userId: Option[UserId] = ctx.invokerId):
    Future[Option[ModalContext]] =
  ## Collects a modal submitted after this request was acknowledged.
  ## The invoking user is the default filter. Pending response state raises
  ## `InvalidResponseStateError`; timeout or shutdown returns none.
  if ctx.responseState == Pending:
    raise newException(InvalidResponseStateError,
      "waitForModal requires the current interaction to be acknowledged")
  ctx.bindingValue.waitForModal(patterns, timeoutMs, userId)

proc waitForModal*(ctx: InteractionContext; pattern: string;
    timeoutMs = 300_000; userId: Option[UserId] = ctx.invokerId):
    Future[Option[ModalContext]] =
  ## Collects one modal pattern, defaulting to the invoking user.
  ctx.waitForModal([pattern], timeoutMs, userId)

proc disableAll*(rows: openArray[ClassicActionRow]):
    seq[ClassicActionRow] =
  ## Returns copied classic rows with every button and select disabled.
  ## The input rows are not mutated.
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
  ## Deep-copies a V2 tree and disables every interactive descendant.
  ## Non-interactive layout and media values are preserved; input nodes are not
  ## mutated and nil nodes remain nil.
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
  ## Runs a two-button confirmation flow scoped to this interaction and user.
  ## It responds, edits a defer, or follows up according to current state, then
  ## disables both buttons. Returns true only for the affirmative press; timeout
  ## and shutdown return false. Transport and response-state errors propagate.
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
  ## Runs a previous/next embed paginator scoped to this interaction and user.
  ## One page is sent without controls; an empty list raises `ValueError`.
  ## On timeout or shutdown the final page remains visible with controls disabled.
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
  ## Registers a root slash command from an explicit option schema and handler.
  ## Prefer the typed `slash` macro for normal use. Invalid Discord names,
  ## descriptions, option order/schema, duplicates, or root/subcommand conflicts
  ## raise `RouteDefinitionError` during app construction.
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
  ## Registers a persistent button route for a custom-ID pattern.
  ## Patterns support `{name}` string and `{name:int}` integer captures.
  ## Duplicate patterns or malformed captures raise `RouteDefinitionError`.
  for route in routes.buttonRoutes:
    if not route.isSelect and route.pattern.raw == pattern:
      raise newException(RouteDefinitionError,
        "duplicate button route: " & pattern)
  routes.buttonRoutes.add ComponentRoute(
    pattern: parsePattern(pattern), isSelect: false, handler: handler)

proc select*(routes: var Routes; pattern: string;
             handler: ComponentHandler) =
  ## Registers a persistent select route for a custom-ID pattern.
  ## Button and select namespaces are separate. During dispatch, exact matches
  ## win, then longer literal prefixes, then registration order.
  for route in routes.buttonRoutes:
    if route.isSelect and route.pattern.raw == pattern:
      raise newException(RouteDefinitionError,
        "duplicate select route: " & pattern)
  routes.buttonRoutes.add ComponentRoute(
    pattern: parsePattern(pattern), isSelect: true, handler: handler)

proc userCommand*(routes: var Routes; name: string;
                  handler: UserCommandHandler) =
  ## Registers a user context-menu command with its typed target context.
  ## Names must contain 1..32 visible Unicode characters and be unique.
  validateContextCommandName(name)
  if routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "duplicate user command: " & name)
  routes.userRoutes[name] = NamedRoute[UserCommandHandler](
    name: name, handler: handler)

proc messageCommand*(routes: var Routes; name: string;
                     handler: MessageCommandHandler) =
  ## Registers a message context-menu command with its typed target context.
  ## Invalid or duplicate names raise `RouteDefinitionError`.
  validateContextCommandName(name)
  if routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "duplicate message command: " & name)
  routes.messageRoutes[name] = NamedRoute[MessageCommandHandler](
    name: name, handler: handler)

proc checkSlash*(routes: var Routes; path: string; check: SlashCheck) =
  ## Appends an async precondition to an existing slash path.
  ## Checks run in registration order before cooldown acquisition; a rejection
  ## stops dispatch without consuming the route's cooldown.
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
  ## Appends an async precondition to an existing user command.
  ## A nil check or unknown command raises `RouteDefinitionError`.
  if check.isNil or not routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot check an unknown user command: " & name)
  let typed = check
  routes.userRoutes[name].checks.add proc(
      ctx: InteractionContext): Future[CheckDecision] =
    typed(UserCommandContext(ctx))

proc checkMessageCommand*(routes: var Routes; name: string;
                          check: MessageCommandCheck) =
  ## Appends an async precondition to an existing message command.
  ## A nil check or unknown command raises `RouteDefinitionError`.
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
  ## Appends an async precondition to an existing button pattern.
  routes.addComponentCheck(pattern, false, check)

proc checkSelect*(routes: var Routes; pattern: string;
                  check: ComponentCheck) =
  ## Appends an async precondition to an existing select pattern.
  routes.addComponentCheck(pattern, true, check)

proc checkModal*(routes: var Routes; pattern: string; check: ModalCheck) =
  ## Appends an async precondition to an existing modal pattern.
  ## A nil check or unknown pattern raises `RouteDefinitionError`.
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
  ## Assigns or replaces the cooldown for an existing slash path.
  ## Buckets are owned by each `AppBinding`; invalid duration or unknown path
  ## raises `RouteDefinitionError`.
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  if not routes.slashRoutes.hasKey(path):
    raise newException(RouteDefinitionError,
      "cannot configure cooldown for unknown slash path: " & path)
  routes.slashRoutes[path].cooldown = some(rule)

proc cooldownUserCommand*(routes: var Routes; name: string;
                          rule: CooldownRule) =
  ## Assigns or replaces a binding-local cooldown for a user command.
  if rule.durationMs <= 0:
    raise newException(RouteDefinitionError,
      "a cooldown duration must be greater than zero")
  if not routes.userRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure cooldown for unknown user command: " & name)
  routes.userRoutes[name].cooldown = some(rule)

proc cooldownMessageCommand*(routes: var Routes; name: string;
                             rule: CooldownRule) =
  ## Assigns or replaces a binding-local cooldown for a message command.
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
  ## Assigns or replaces a cooldown for an existing button pattern.
  ## Captured values do not create distinct route identities; the registered
  ## pattern and selected cooldown scope determine the bucket.
  routes.setComponentCooldown(pattern, false, rule)

proc cooldownSelect*(routes: var Routes; pattern: string;
                     rule: CooldownRule) =
  ## Assigns or replaces a cooldown for an existing select pattern.
  routes.setComponentCooldown(pattern, true, rule)

proc cooldownModal*(routes: var Routes; pattern: string;
                    rule: CooldownRule) =
  ## Assigns or replaces a cooldown for an existing modal pattern.
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
  ## Applies Discord command metadata to every path under slash root `name`.
  ## `none` leaves Discord's default permissions, contexts, or integrations;
  ## localization tables are copied into the sync payload. Unknown roots raise
  ## `RouteDefinitionError`.
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
  ## Applies permissions, NSFW, surface, install, and name-localization metadata
  ## to an existing user context-menu command.
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
  ## Applies permissions, NSFW, surface, install, and name-localization metadata
  ## to an existing message context-menu command.
  if not routes.messageRoutes.hasKey(name):
    raise newException(RouteDefinitionError,
      "cannot configure an unknown message command: " & name)
  routes.messageRoutes[name].metadata = commandMetadata(
    defaultMemberPermissions, nsfw, contexts, integrations,
    nameLocalizations, Table[string, string]())

proc autocomplete*(routes: var Routes; commandPath, optionName: string;
                   handler: AutocompleteHandler) =
  ## Attaches an autocomplete handler to an existing scalar slash option.
  ## `commandPath` uses slash-separated root/subcommand segments. Autocomplete
  ## is valid only for string, integer, and number options without fixed choices;
  ## violations raise `RouteDefinitionError`.
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
  ## Evaluates `factory` exactly once and freezes its routes into an app.
  ## The resulting value contains no token or live runtime state and may be
  ## bound independently. Route-definition failures propagate immediately.
  ## When `onError` is nil, user rejections get their safe ephemeral text,
  ## autocomplete failures get an empty result, and other catchable failures
  ## get a generic ephemeral message; `Defect` values are never caught.
  var routes = Routes(
    slashRoutes: initOrderedTable[string, SlashRoute](),
    userRoutes: initOrderedTable[string, NamedRoute[UserCommandHandler]](),
    messageRoutes:
      initOrderedTable[string, NamedRoute[MessageCommandHandler]]())
  factory(routes)
  DiscordApp(routesValue: routes,
             errorHandlerValue: if onError.isNil: defaultErrorHandler
                                else: onError)

proc globalScope*(): CommandScope =
  ## Selects the global application-command overwrite endpoint.
  CommandScope(kind: GlobalCommands)

proc guildScope*(guildId: GuildId): CommandScope =
  ## Selects the application-command overwrite endpoint for `guildId`.
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
  ## Builds a fresh authoritative Discord application-command array.
  ## Slash paths are grouped into subcommand structures; metadata and context
  ## commands are included. Mutating the returned JSON cannot change `app`.
  ## Conflicting group descriptions raise `RouteDefinitionError`.
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
  ## Registers a root slash command and derives its option schema from `handler`.
  ## The handler must start with `SlashCommandContext` and return `Future[void]`;
  ## later parameters become Discord options. `Option[T]` or a default makes an
  ## option optional. Supported types include primitives, owned resolved models,
  ## enums, integer ranges, and distinct string/int types. Parameter pragmas
  ## configure descriptions, bounds, choices, channel types, and localizations.
  ## Invalid handler shapes fail at compile time; route conflicts fail while
  ## constructing `DiscordApp`.
  ##
  ## .. code-block:: nim
  ##   routes.slash("greet", "Greets someone",
  ##     proc(ctx: SlashCommandContext;
  ##          name {.description: "Person to greet".}: string;
  ##          count {.min: 1, max: 5.}: int = 1) {.async.} =
  ##       discard await ctx.respond(("Hello, " & name & "! ").repeat(count)))
  expandSlash(routes, name, description, @[], @[], handler)

macro subcommand*(routes: var Routes;
                  commandName, commandDescription: static string;
                  name, description: static string;
                  handler: untyped): untyped =
  ## Registers one typed subcommand beneath `commandName`.
  ## All routes sharing the root must agree on `commandDescription`, and a root
  ## handler cannot coexist with subcommands. Handler option derivation matches
  ## `slash`.
  expandSlash(routes, commandName, commandDescription, @[name],
              @[description], handler)

macro groupSubcommand*(routes: var Routes;
                       commandName, commandDescription: static string;
                       groupName, groupDescription: static string;
                       name, description: static string;
                       handler: untyped): untyped =
  ## Registers one typed subcommand beneath a command group.
  ## Paths are addressed elsewhere as `command/group/subcommand`; duplicate or
  ## inconsistent root/group definitions raise `RouteDefinitionError`.
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
  ## Registers a modal route and derives typed fields from `handler` parameters.
  ## The handler must start with `ModalContext`; remaining `string`, `int`, and
  ## `float` parameters decode submitted text. `Option[T]` or defaults accept
  ## blank/omitted fields, while numeric conversion failures become safe
  ## `UserRejectionError` values. The `name` pragma overrides the input custom
  ## ID and `description`/`desc` supplies its user-facing validation label.
  ##
  ## .. code-block:: nim
  ##   routes.modal("feedback:{ticket:int}",
  ##     proc(ctx: ModalContext;
  ##          reason {.description: "Reason".}: string;
  ##          score: Option[int]) {.async.} =
  ##       discard await ctx.respond(reason & ": " & $score.get(0)))
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
  ## Validates and decodes a Discord gateway interaction into an owned snapshot.
  ## Supports slash, user, message, autocomplete, component, and modal-submit
  ## payloads. Required/malformed fields, numeric permission failures, and
  ## unsupported wire kinds raise `InvalidInteractionError`. The original JSON
  ## is deep-copied for later access through `raw`.
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
  let raw = interaction.rawValue
  let originalUsesV2 =
    raw.kind == JObject and raw.hasKey("message") and
    raw["message"].kind == JObject and raw["message"].hasKey("flags") and
    (raw["message"]["flags"].getInt and ComponentsV2MessageFlag) != 0
  ResponseController(sink: sink, interactionId: interaction.idValue,
    applicationId: interaction.applicationIdValue,
    token: interaction.tokenValue, state: Pending,
    originalUsesV2: originalUsesV2)

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
  ## Atomically checks and consumes one binding-owned cooldown bucket.
  ## `key` identifies the operation while `rule.scope` partitions it globally,
  ## by user, or by guild. A live bucket or unavailable principal raises a safe
  ## `UserRejectionError`. Empty keys, non-positive durations, and unbound
  ## contexts raise programming/configuration errors.
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
  ## Decodes and routes one raw `INTERACTION_CREATE` payload.
  ## Returns true when a collector or persistent route owns it, false when the
  ## binding is quiescing or no route matches. Collectors take precedence over
  ## persistent routes. Handlers run checks, then cooldown acquisition, then the
  ## typed closure; catchable failures use the app error policy and a missing
  ## acknowledgement becomes `MissingInitialResponseError`. Decode failures and
  ## `Defect` values propagate.
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
  ## Quiesces the binding synchronously without waiting or closing the gateway.
  ## New dispatches return false and every pending collector completes with none.
  ## Active handlers continue so callers may subsequently `detach` or `stop`
  ## and await a clean drain.
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

proc disconnectShard(shard: discord.Shard): Future[void]
    {.async.} =
  try:
    await shard.disconnect(should_reconnect = false)
  except Defect:
    raise
  except Exception as error:
    if not error.msg.startsWith(DimscordDisconnectedMessage):
      raise
  shard.cache.clear()

proc stopDiscordGateway(client: discord.DiscordClient;
                        session: Future[void]): Future[void] {.async.} =
  # Dimscord snapshots autoreconnect in each gateway reader. A reader that was
  # already running may reconnect once after the first close, so keep closing
  # any reopened shard until that session future settles.
  client.autoreconnect = false
  for shard in client.shards.values:
    await disconnectShard(shard)
  while not session.isNil and not session.finished:
    for shard in client.shards.values:
      if not shard.stop:
        await disconnectShard(shard)
    await sleepAsync(50)

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
  ## Creates a gateway runtime without starting its session.
  ## Runtime configuration is supplied directly so the route-only `DiscordApp`
  ## remains reusable. `managedScopes` are the only command scopes later
  ## overwritten by `syncCommands`; duplicates raise `ValueError`. Privileged
  ## gateway intents must be enabled in Discord's developer portal. The token is
  ## retained by Dimscord's client and is never stored in `DiscordApp`.
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
  ## Authoritatively bulk-overwrites every explicitly managed command scope.
  ## An empty local route table clears each listed scope; unlisted scopes remain
  ## untouched. Application ID resolution is cached per binding. Results follow
  ## managed-scope order, and transport failures propagate without marking the
  ## binding synchronized so a later ready event may retry.
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
  ## Installs DimSlash dispatch and ready hooks into the gateway client once.
  ## Existing hooks are preserved and chained for events DimSlash does not own.
  ## With `autoSync`, the first successful ready event calls `syncCommands`;
  ## prior ready callbacks still run if synchronization fails. Repeated calls
  ## are idempotent; non-gateway bindings raise `DimSlashError`.
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
  ## Installs the binding and runs its configured gateway session until it ends.
  ## Gateway intents, message-content access, and reconnect behavior come from
  ## `bindGateway`. Connection, sync, callback, and handler failures propagate,
  ## except for session termination observed after an explicit concurrent
  ## `stop`.
  binding.install(autoSync)
  binding.gatewaySession = binding.client.startSession(
    autoreconnect = binding.autoReconnect,
    gateway_intents = discordGatewayIntents(binding.gatewayIntents),
    content_intent = binding.messageContentIntent)
  try:
    await binding.gatewaySession
  except Defect:
    raise
  except Exception:
    if not binding.gatewayStopRequested:
      raise

proc requestDetach*(binding: AppBinding) =
  ## Begins non-blocking detachment by quiescing dispatch and waking collectors.
  ## Call `detach` to wait for active handlers and restore prior gateway hooks.
  binding.requestStop()

proc detach*(binding: AppBinding): Future[void] {.async.} =
  ## Quiesces, drains active handlers, and restores the gateway's prior hooks.
  ## It does not close the underlying gateway session, allowing another owner to
  ## continue using the client. Repeated calls after detachment are harmless.
  binding.requestDetach()
  await binding.waitUntilDrained()
  if binding.installed and not binding.client.isNil:
    binding.client.events.on_dispatch = binding.previousDispatch
    binding.client.events.on_ready = binding.previousReady
    binding.installed = false

proc stop*(binding: AppBinding): Future[void] {.async.} =
  ## Quiesces, drains active handlers, and closes the gateway session.
  ## Pending collectors complete with none before the drain. Use `detach`
  ## instead when the shared client must remain connected.
  binding.gatewayStopRequested = true
  binding.requestStop()
  await binding.waitUntilDrained()
  if not binding.client.isNil:
    await stopDiscordGateway(binding.client, binding.gatewaySession)
  elif not binding.stopGateway.isNil:
    try:
      await binding.stopGateway()
    except Defect:
      raise
    except Exception as error:
      if not error.msg.startsWith(DimscordDisconnectedMessage):
        raise

when defined(dimslashTesting):
  type
    RecordedCall* = object ## One response or command-sync operation captured by tests.
      name*: string ## Stable operation name such as `initial`, `edit`, or `putCommands`.
      data*: JsonNode ## Deep-owned payload supplied to the fake transport.
      files*: seq[UploadedFile] ## Multipart files supplied with the operation.

    TestTransport* = ref object ## Deterministic in-memory transport for API tests.
      calls*: seq[RecordedCall] ## Operations in execution order.
      nextMessageId*: int ## Counter used for synthetic follow-up IDs.
      applicationId*: ApplicationId ## ID returned during command synchronization.
      rejectInitial*: bool ## Make the next initial response fail definitively.
      failInitialAmbiguously*: bool ## Simulate an unknown initial-response outcome.
      failStopWithDisconnect*: bool
        ## Make gateway shutdown raise Dimscord's normal-disconnect exception.

  proc messageFrom(data: JsonNode; id: string): Message =
    result.idValue = MessageId(id)
    if data.hasKey("content"): result.contentValue = data["content"].getStr

  proc newTestTransport*(): TestTransport =
    ## Creates an empty deterministic transport with a synthetic application ID.
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
    ## Binds `app` to an in-memory transport without a gateway client.
    ## An injected monotonic clock makes cooldown tests deterministic. Duplicate
    ## managed scopes raise `ValueError`. Gateway start and hook installation
    ## are unavailable; `stop` still quiesces and drains handlers.
    validateManagedScopes(managedScopes)
    let stopGateway = proc(): Future[void] {.async.} =
      if transport.failStopWithDisconnect:
        raise newException(Exception, DimscordDisconnectedMessage)
    AppBinding(app: app, sink: transport.testSink,
      commandSink: transport.testCommandSink, accepting: true,
      stopGateway: stopGateway,
      managedScopes: managedScopes,
      cooldowns: initTable[string, int64](),
      monotonicMilliseconds:
        if monotonicMilliseconds.isNil: systemMonotonicMilliseconds
        else: monotonicMilliseconds)

  proc state*(transport: TestTransport): int =
    ## Returns the number of recorded transport operations.
    transport.calls.len
