# dimslash

`dimscord`向けの Interaction 中心コマンドハンドラです。`dimscmd`に近い使い心地で、Slash/User/Message command を宣言的に扱えます。

## 現在の対応範囲
- ✅ Slash Command
- ✅ User Command
- ✅ Message Command
- ✅ Button Component
- ✅ Select Component
- ✅ Modal Submit
- ✅ Autocomplete
- ✅ 起動時のコマンド同期（bulk overwrite）

## インストール
```bash
nimble install dimslash
```

## 最短セットアップ
```nim
import dimscord, asyncdispatch
import dimslash

let discord = newDiscordClient("TOKEN")
var handler = newInteractionHandler(discord)

handler.addSlash("ping", "pongを返します") do:
  await handler.reply(i, "pong")

proc onReady(s: Shard, r: Ready) {.event(discord).} =
  await handler.registerCommands()

proc interactionCreate(s: Shard, i: Interaction) {.event(discord).} =
  discard await handler.handleInteraction(s, i)

waitFor discord.startSession(gateway_intents = {giGuilds})
```

## Typed Slash Args（dimscmdライク）
Slash option から引数を自動で取り出せます。

```nim
handler.addSlash("sum", "2つの数値を足します") do (i: Interaction, a: int, b: int):
  await handler.reply(i, $(a + b))

handler.addSlash("maybe", "オプショナル値の例") do (i: Interaction, x: Option[int]):
  if x.isSome:
    await handler.reply(i, "x=" & $x.get)
  else:
    await handler.reply(i, "x is missing")
```

初版で対応している型:
- `string`
- `int`
- `bool`
- `float`
- `User`
- `Role`
- `Option[T]`（上記型のT）

コールバックを明示で渡したい場合は `addSlashProc` も使えます。

## サンプルコード
- 最小構成: [examples/basic_interactions.nim](examples/basic_interactions.nim)
- typed args: [examples/typed_slash_args.nim](examples/typed_slash_args.nim)
- component/modal: [examples/scaffold_interactions.nim](examples/scaffold_interactions.nim)
- 応用ワークフロー: [examples/advanced_workflow.nim](examples/advanced_workflow.nim)
- UIショーケース（button/select/modal）: [examples/ui_showcase.nim](examples/ui_showcase.nim)

## Button / Select / Modal DSL
`do`記法で宣言でき、`custom_id`でdispatchされます。

```nim
handler.addButton("confirm:delete", proc (s: Shard, i: Interaction) {.async.} =
  await handler.reply(i, "button clicked")
)

handler.addSelect("pick:role", proc (s: Shard, i: Interaction) {.async.} =
  let picked = selectValues(i)
  await handler.reply(i, "picked=" & $picked)
)

handler.addModal("feedback:modal", proc (s: Shard, i: Interaction) {.async.} =
  let feedback = modalValue(i, "feedback")
  await handler.reply(i, feedback.get(""))
)

handler.addAutocomplete("sum", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "1", input & "2", input & "3"])
)

# optionName で対象オプションを限定
handler.addAutocomplete("search", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-repo", input & "-user"])
, optionName = "query")

# addSlash で登録済み option 名にのみ紐づける（検証付き）
handler.addSlash("search", "Search repositories") do (i: Interaction, query: string):
  discard

handler.addAutocompleteForOption("search", "query", proc (s: Shard, i: Interaction) {.async.} =
  let input = focusedOptionValue(i).get("")
  await handler.suggest(i, @[input & "-repo", input & "-user"])
)
```

利用できる抽出ヘルパ:
- `customId(i)`
- `selectValues(i)`
- `modalValues(i)`
- `modalValue(i, fieldCustomId)`
- `focusedOptionName(i)` / `focusedOptionValue(i)`
- `suggest(i, choices)`

## APIドキュメント生成
```bash
nimble docs
```

出力先:
- [docs/dimslash.html](docs/dimslash.html)
