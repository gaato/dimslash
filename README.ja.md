# dimslash

Nim向けの型付きDiscordインタラクションフレームワークです。通信層には
[dimscord](https://github.com/krisppurg/dimscord)を使います。

新APIでは責務を三つに分けています。

- `DiscordApp`: 一度だけ構築される変更不能なルート定義
- `AppBinding`: gateway接続とライフサイクル
- 各種`Context`: リクエスト単位のデータと応答状態

## 最小例

```nim
import dimslash

let app = newDiscordApp(proc(routes: var Routes) =
  routes.slash("greet", "Greets somebody",
    proc(ctx: SlashCommandContext;
         name {.description: "Who to greet".}: string;
         count {.min: 1, max: 5.}: int = 1) {.async.} =
      discard await ctx.respond((name & "! ").repeat(count)))
)

waitFor app.bindGateway("TOKEN").start()
```

ハンドラの引数がコマンド登録用schemaと実行時decodeの正本です。サービスは
route factoryのclosureへ普通にcaptureできます。

## 明示的な応答API

`reply`が状態に応じて別の操作へ化ける設計はやめました。

```nim
await ctx.deferReply(ephemeral = true)
let original = await ctx.editOriginal("done")
let later = await ctx.followup("more details")
```

メッセージを生成・更新・取得する`respond`、`update`、`editOriginal`、
`editFollowup`、`followup`、`original`はすべて`Future[Message]`を返します。ACKだけを行う
`deferReply`、`deferUpdate`、modal表示、autocomplete完了は`Future[void]`
です。

初回応答がDiscordへ届いたか判断できない通信障害では`OutcomeUnknown`へ移り、
それ以降の変更操作を止めます。自動deferと自動retryはしません。

## component、modal、autocomplete

```nim
routes.button("page:{number:int}",
  proc(ctx: ComponentContext) {.async.} =
    discard await ctx.update("page " & $ctx.captureInt("number")))

routes.modal("report:{number:int}",
  proc(ctx: ModalContext;
       reason {.description: "Reason".}: string;
       score {.description: "Score".}: Option[int]) {.async.} =
    discard await ctx.respond(reason & ":" & $score.get(0)))

routes.autocomplete("search", "query",
  proc(ctx: AutocompleteContext) {.async.} =
    await ctx.complete([choice("Nim", "nim")]))
```

Classic action row、Components V2、modal inputは別の型です。V2へ移行した
original messageをclassic contentへ戻す編集も型と状態の境界で拒否します。

modalを開けるのはDiscordが許可する`SlashCommandContext`と
`ComponentContext`だけです。

```nim
await ctx.showModal(modalDialog("report:7", "Report",
  textInput("reason", "Reason", style = ParagraphText,
    description = "Explain what happened"),
  textInput("score", "Score", required = false)))
```

modalは現行Discord仕様の`Label` componentとして送ります。submit側の`source`で
command起点とcomponent起点を区別し、component起点だけが元messageへの`update`と
`deferUpdate`を使えます。

## check、cooldown、短命flow

checkは変更不能なrouteへ付けるasync closureです。生きたcooldown bucketは
`AppBinding`が所有し、checkで拒否された呼び出しはcooldownを消費しません。

```nim
routes.checkSlash("admin/ban",
  proc(ctx: SlashCommandContext): Future[CheckDecision] {.async.} =
    if ctx.inGuild: return allow()
    return deny("server only"))

routes.cooldownSlash("admin/ban", cooldownRule(5_000, UserCooldown))
```

短命collectorは永続routeと分離しています。Contextから開始した場合は既定で
呼び出したuserだけを受け付け、binding停止時には待機を解除します。

```nim
if await ctx.confirm("Continue?"):
  discard await ctx.followup("confirmed")

let press = await ctx.waitForButton("page:{number:int}", timeoutMs = 30_000)
```

embed paginatorには`paginate`を使います。待機中collectorは同じIDへ登録された
永続component/modal routeより先に処理されます。

## message model

Classic messageは所有embed、action row、select、allowed mentions、メモリ上のuploadを
扱います。Components V2にはtext display、section、media gallery、file、separator、
container、action rowがあります。

```nim
var body = classicMessage("report")
body.files = @[uploadedFile("report.txt", reportContents, "Daily report")]
discard await ctx.respond(body.messageBody)

discard await ctx.respond(componentsV2(@[
  textDisplay("# Release"),
  container([v2ActionRow(button("Install", "install"))])
]).messageBody)
```

message editは置換です。省略したclassic contentとattachmentも明示的に消します。
original messageをComponents V2へ移行した後はclassicへ戻せません。
`launchActivity`は初回応答として実行し、所有`ActivityInstance`を返します。

## Context menu

```nim
routes.userCommand("Inspect user",
  proc(ctx: UserCommandContext) {.async.} =
    discard await ctx.respond(ctx.target.username, ephemeral = true))

routes.messageCommand("Quote",
  proc(ctx: MessageCommandContext) {.async.} =
    discard await ctx.respond("> " & ctx.target.content))
```

## 初期化と管理scope

必須のconfig objectは置かず、実行時設定を`bindGateway`へ直接渡します。

```nim
let binding = app.bindGateway("TOKEN", managedScopes = @[
  globalScope(),
  guildScope(GuildId("123"))
], gatewayIntents = {Guilds, GuildMessages},
   messageContentIntent = false)
```

指定したscopeは空配列を含めてbulk overwriteする正本です。指定しなかったscope
には触れません。

`requestStop`と`requestDetach`は待たない通知です。`stop`と`detach`は新しい
interactionの受付を止め、実行中handlerがすべて終わるまでtimeoutなしで待ちます。

## エラー

想定内の拒否には`UserRejectionError`または`userRejection(message)`を使います。
既定policyはephemeral responseへ変換します。それ以外の`CatchableError`には一般的
な文面、autocompleteには空の候補を返します。`Defect`は意図的にcatchしません。

応答せずにhandlerが終了した場合は`MissingInitialResponseError`として同じpolicyへ
渡します。silent終了は明示的な選択ではありません。

## 境界

gateway bindingはdimscordの`on_dispatch`から`INTERACTION_CREATE`の生JSONを
受け取ります。公開modelはDimSlash所有の`Interaction`、`Message`、`User`と用途別
ID型です。dimscordのinteraction型は公開contractへ漏らしません。

## 開発

```fish
nimble test
nim c -d:ssl -d:release --path:src src/dimslash.nim
```
