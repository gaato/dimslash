# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Docs Deploy](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/pages-on-tag.yml?label=Docs%20Deploy)](https://github.com/gaato/dimslash/actions/workflows/pages-on-tag.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

[dimscord](https://github.com/krisppurg/dimscord) 向けの、マクロによる宣言的インタラクションハンドラです。スラッシュコマンド(オプションメタデータ完全対応)、コンテキストメニュー、ボタン、セレクト、モーダル、オートコンプリートを、コンパイル時検証つきで書けます。コマンド同期は差分検知つきです。さらに、await できるコンポーネント(`waitForButton`)、confirm / paginate フロー、チェック&クールダウン、型付きモーダルフォーム、embed / コンポーネントのビルダーブロックが載っています。

> **English**: [README.md](README.md)

## インストール

```bash
nimble install dimslash
```

## 最短セットアップ

```nim
import dimscord, dimslash, std/random

let discord = newDiscordClient("TOKEN")
let handler = newInteractionHandler(discord)

handler.slash("roll", "サイコロを振る"):
  ## 面の数
  sides {.min: 2, max: 1000.}: int = 6
  execute:
    await ctx.reply($rand(1 .. sides) & " が出ました")

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  discard await handler.syncCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds})
```

`## doc` コメントがそのまま Discord UI のオプション説明になり、`min`/`max` は実際の入力制約として同期されます。デフォルト値をつけると Discord 上では省略可能に、Nim 側では素の `int` のまま扱えます。

## slash ブロック

```nim
handler.slash("order", "メニューから注文する"):
  guild = "GUILD_ID"                 # コマンド設定(任意)
  permissions = {permManageGuild}
  ## 注文する品
  item {.choices: {"コーヒー": "coffee", "紅茶": "tea"}.}: string
  ## 個数
  amount {.min: 1, max: 10.}: int = 1
  ## 厨房へのメモ
  note {.maxLen: 100.}: Option[string]
  execute:
    await ctx.reply($amount & "x " & item, ephemeral = true)
```

**オプション型**: `string` / `int` / `float` / `bool` / `User` / `Member` / `Role` / `Channel` / `Mentionable` / `Attachment`。いずれも `Option[T]` かデフォルト値つき(Discord 上は省略可・Nim 上は非 Option)にできます。

**オプションプラグマ**: `desc`、`name`(送信名の上書き)、`min`/`max`、`minLen`/`maxLen`、`choices`、`channels`、`nameLoc`/`descLoc`。

**コマンド設定**(`key = value` 行): `guild`、`permissions`、`nsfw`、`contexts`、`integrations`、`nameLocalizations`、`descriptionLocalizations`、`cooldown`。加えて `check` ガード行(後述)。

名前の小文字規則、required→optional の順序、重複、choices の上限、グループの深さ、autocomplete の対象——チェックできるものはすべてコンパイル時に検証されます。実行時の 400 ではなくコンパイルエラーになります。

## サブコマンド

```nim
handler.slash("admin", "管理コマンド"):
  permissions = {permManageGuild}
  group "member", "メンバー管理":
    sub "warn", "警告する":
      ## 対象
      target: User
      execute:
        await ctx.reply(target.username & " に警告しました", ephemeral = true)
  sub "audit", "監査ログを見る":
    execute:
      await ctx.reply("...")
```

## オートコンプリート

```nim
handler.slash("search", "ドキュメントを検索"):
  ## 検索語
  query: string
  autocomplete query:                 # オプションとの対応はコンパイル時に検証
    await ctx.suggest(allDocs.filterIt(ctx.focusedValue in it))
  execute:
    await ctx.reply(query & " の検索結果")
```

同期時にオプションへ `autocomplete: true` が自動で付くので、Discord が確実にイベントを送ってきます。

## コンポーネントとモーダル

custom_id には型つきキャプチャ(`{name}` は string、`{name:int}` は int)を書けて、ハンドラ本文でそのまま変数になります:

```nim
handler.button("page:{n:int}"):
  await ctx.update(pages[n], components = pager(n))

handler.select("role_picker"):
  await ctx.reply("選択: " & ctx.values.join(", "))

handler.modal("feedback:{topic}"):
  await ctx.reply(topic & " についてのご意見ありがとうございます: " &
                  ctx.field("subject").get("(なし)"))

handler.user("ユーザー情報"):          # コンテキストメニュー
  await ctx.reply(ctx.target.username & " です", ephemeral = true)

handler.message("引用"):
  await ctx.reply("> " & ctx.target.content)
```

## 型付きモーダルフォーム

`modalForm` はモーダルの入力欄と submit ハンドラを1ブロックで宣言し、どのハンドラからでも開けるフォームを返します:

```nim
let feedback = handler.modalForm("feedback:{topic}", "フィードバック"):
  ## 件名
  subject {.maxLen: 100.}: string
  ## 評価 (1-5)
  rating {.placeholder: "5".}: int
  ## 詳細
  detail {.paragraph.}: Option[string]
  check rating in 1 .. 5, "評価は 1〜5 でお願いします。"
  submit:
    await ctx.reply(topic & ": " & subject & " → " & $rating,
                    ephemeral = true)

# 別の場所から(キャプチャは宣言順に埋まる):
await ctx.showModal(feedback, "bug")
```

テキスト入力はワイヤ上では常に文字列なので、`int`/`float` フィールドは submit 時にパースされます——不正な値はクラッシュではなく丁寧な ephemeral 返信(`UserError`)になります。`Option[T]` は Discord 上で任意入力になり、未入力は `none`。フィールドプラグマ: `label`、`name`、`placeholder`、`value`、`minLen`/`maxLen`、`paragraph`。

## await できるコンポーネント

ハンドラを登録する代わりに、その場でインタラクションを待てます:

```nim
handler.slash("quiz", "クイズに答える"):
  execute:
    let two = ctx.scopedId("quiz:2")    # この実行に固有の custom_id
    let four = ctx.scopedId("quiz:4")
    await ctx.reply("2 + 2 は?", components = buttonsFor(two, four))
    let press = await ctx.waitForButton([two, four], timeout = 30)
    if press.isNone:
      await ctx.reply("時間切れ!", ephemeral = true)
    else:
      await press.get.update("押したのは " & press.get.customId)
```

`waitForButton` / `waitForSelect` / `waitForModal` はレジストリより先にチェックされる一回きりの waiter を登録し、発火した時点で外れます。タイムアウトでは `none` が返ります。`ctx` 版はデフォルトで呼び出したユーザーだけを受け付けます(誰でも良ければ `user = ""`、`message = …` でメッセージ絞り込み)。返ってきたコンテキストへの応答は呼び出し側の仕事です。パターンも他と同じで、`waitForButton("page:{n:int}")` なら `press.get.captures` に `n` が入ります。

## 出来合いのフロー

```nim
if await ctx.confirm("本当に**全部**消しますか?"):
  await ctx.reply("消しました。", ephemeral = true)   # 自動で followup

await ctx.paginate(guideEmbeds)   # ◀ 1 / 5 ▶
```

`confirm` は Yes/No ボタンを出して待ち、Yes のときだけ `true`(タイムアウトは `false`)。`paginate` は呼び出したユーザーにページ送りを提供し、タイムアウトでボタンを無効化します。どちらも waiter の上に作られていて、自前のメッセージを編集し、応答状態機械を尊重します(応答済みなら followup として送る)。自作フロー向けに `disableAll(components)` も公開しています。インタラクショントークンの寿命は15分なので、タイムアウトはそれ未満に。

## チェック・クールダウン・ユーザー向けエラー

```nim
handler.slash("daily", "デイリー報酬を受け取る"):
  check ctx.inGuild, "サーバー内でのみ使えます。"
  cooldown = (86_400, cbUser)
  execute:
    if alreadyClaimed(ctx.user.id):
      fail "今日はもう受け取りましたよね?"
    await ctx.reply("どうぞ!")
```

- `check <条件>, "メッセージ"`(または `check:` ブロック)は `execute` の前に走り、宣言済みオプションを参照できます。サブコマンドを持つコマンドに書けば全 leaf に継承されます。
- `cooldown = 秒数` または `(秒数, cbUser|cbGuild|cbChannel|cbGlobal)` は時間内の再使用を拒否します(チェックの後に効くので、チェック失敗でクールダウンは消費されません)。`slash`/`user`/`message` に加え、`button`/`select`/`modal` ブロックでも使えます。
- `fail "メッセージ"` はハンドラ内のどこでも `UserError` を投げられます。デフォルトのエラーフックはログではなく、そのメッセージを ephemeral で返信します。

## embed / コンポーネントビルダー

```nim
let card = embed:
  title "投票: " & motion
  description "60秒以内にどうぞ。"
  color 0x5865F2
  field "賛成", "12", inline = true
  footer "1人1票"

let comps = rows:
  row:
    button "賛成", "vote:aye", style = bsSuccess
    button "反対", "vote:nay", style = bsDanger
  row:
    select "vote:menu", placeholder = "こちらからでも":
      option "賛成", "yes", desc = "動議に賛成"
      option "反対", "no"

await ctx.reply(embeds = @[card], components = comps)
```

名前付き引数は dimscord のビルダーへそのまま渡ります。エンティティセレクト(`userSelect`、`roleSelect`、`mentionableSelect`、`channelSelect`)にも対応し、Discord のレイアウト規則(セレクトは1行を占有)はコンパイル時に検証されます。

## コンテキストオブジェクト

すべてのハンドラは `ctx` を受け取ります。型つきアクセサ(`ctx.user`、`ctx.member`、`ctx.guildId`、`ctx.target`、`ctx.values`、`ctx.fields` など)と、応答状態を追跡するヘルパーがあります:

| ヘルパー | 動作 |
| --- | --- |
| `reply(...)` | 初回応答 → defer 後はプレースホルダ編集 → 以降は自動で followup |
| `deferReply(ephemeral)` | 「考え中…」プレースホルダ |
| `followup(...)` / `edit(...)` / `delete()` / `original()` | followup と @original の管理 |
| `update(...)` / `deferUpdate()` | コンポーネントが付いたメッセージ自体を編集 |
| `showModal(form, captures...)` / `showModal(id, title, components)` | `modalForm` または手組みのモーダルを開く |
| `suggest(choices)` | オートコンプリート候補(string / ペア / int / float) |
| `confirm(...)` / `paginate(...)` / `waitFor*` | 上述のフローと waiter |

content 系ヘルパーは共通で `content`、`embeds`、`components`、`attachments`、`files`、`allowedMentions`、`ephemeral`、`tts` を受け付けます。

ハンドラ内の例外は `handler.onError`(デフォルト: ログ + 未応答なら ephemeral なエラー返信。`nil` にすると再送出)へ、未登録のインタラクションは `handler.onUnknown` へ流れます。

## 差分検知つきコマンド同期

`syncCommands()` はスコープ(グローバル+各ギルド)ごとに Discord の現状を取得して登録内容と比較し、**変更があったときだけ** PUT します。起動のたびに全上書きしません。`syncCommands(force = true)` で無条件上書きです。

```nim
proc onReady(s: Shard, r: Ready) {.event(discord).} =
  for scope in await handler.syncCommands():
    echo scope.scope, ": ", scope.commandCount,
      " commands, updated=", scope.updated
```

## 0.0.x からの移行

0.1.0 は API を刷新した全面書き直しです:

| 0.0.x | 0.1.0 |
| --- | --- |
| `addSlash("x", "d") do (i: Interaction, a: int): ...` | `slash("x", "d"):` + `## 説明` + `a: int` + `execute:` |
| `handler.reply(i, "text")` | `ctx.reply("text")` |
| `addUser` / `addMessage` | `user` / `message` ブロック(`ctx.target`) |
| `addButton` / `addSelect` / `addModal` | `button` / `select` / `modal` ブロック+`{capture}` パターン |
| `addAutocomplete(...)` / `addAutocompleteForOption` | slash ブロック内の `autocomplete <option>:` |
| `selectValues(i)` / `modalValue(i, id)` | `ctx.values` / `ctx.field(id)` |
| `registerCommands()` | `syncCommands()`(オプションメタデータ送信+差分検知) |
| `handler.deferResponse(i)` / `followup` | `ctx.deferReply()` / `ctx.followup(...)` |

なお 0.0.x はオプションのメタデータを Discord に一切送っておらず、型つき引数が Discord UI に表示されないバグがありました。0.1.0 で修正されています。

## サンプル

- 最小構成: [examples/basic_interactions.nim](examples/basic_interactions.nim)
- 全オプション型: [examples/typed_slash_args.nim](examples/typed_slash_args.nim)
- サブコマンド・パターン・モーダル: [examples/advanced_workflow.nim](examples/advanced_workflow.nim)
- ボタン・セレクト・embed: [examples/ui_showcase.nim](examples/ui_showcase.nim)
- フロー・waiter・モーダルフォーム・ビルダー: [examples/interactive_flows.nim](examples/interactive_flows.nim)

## API ドキュメント生成

```bash
nimble docs
```

出力: [docs/dimslash.html](docs/dimslash.html)
