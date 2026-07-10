# dimslash

[![CI](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/ci.yml?branch=main&label=CI)](https://github.com/gaato/dimslash/actions/workflows/ci.yml)
[![Docs Deploy](https://img.shields.io/github/actions/workflow/status/gaato/dimslash/pages-on-tag.yml?label=Docs%20Deploy)](https://github.com/gaato/dimslash/actions/workflows/pages-on-tag.yml)
[![Nim](https://img.shields.io/badge/Nim-%3E%3D2.0.6-FFC200?logo=nim)](https://nim-lang.org/)
[![License](https://img.shields.io/github/license/gaato/dimslash)](LICENSE.md)

[dimscord](https://github.com/krisppurg/dimscord) 向けの、マクロによる宣言的インタラクションハンドラです。スラッシュコマンド(オプションメタデータ完全対応)、コンテキストメニュー、ボタン、セレクト、モーダル、オートコンプリートを、コンパイル時検証つきで書けます。コマンド同期は差分検知つきです。

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

**コマンド設定**(`key = value` 行): `guild`、`permissions`、`nsfw`、`contexts`、`integrations`、`nameLocalizations`、`descriptionLocalizations`。

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

## コンテキストオブジェクト

すべてのハンドラは `ctx` を受け取ります。型つきアクセサ(`ctx.user`、`ctx.member`、`ctx.guildId`、`ctx.target`、`ctx.values`、`ctx.fields` など)と、応答状態を追跡するヘルパーがあります:

| ヘルパー | 動作 |
| --- | --- |
| `reply(...)` | 初回応答 → defer 後はプレースホルダ編集 → 以降は自動で followup |
| `deferReply(ephemeral)` | 「考え中…」プレースホルダ |
| `followup(...)` / `edit(...)` / `delete()` / `original()` | followup と @original の管理 |
| `update(...)` / `deferUpdate()` | コンポーネントが付いたメッセージ自体を編集 |
| `showModal(id, title, components)` | モーダルを開く(入力欄は `newTextInput` で) |
| `suggest(choices)` | オートコンプリート候補(string / ペア / int / float) |

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

## API ドキュメント生成

```bash
nimble docs
```

出力: [docs/dimslash.html](docs/dimslash.html)
