import std/[httpclient, json, options, strutils, unittest]
import dimscord

import ../src/dimslash/[types, rest]

proc textComponent(value: string): MessageComponent =
  MessageComponent(kind: mctTextDisplay, content: value)

suite "message wire encoding":
  test "Components V2 initial responses omit every legacy content field":
    let data = messageDataJson(
      MessagePayload(
        content: none string,
        components: @[textComponent("# Hello")],
        flags: {mfEphemeral, mfIsComponentsV2}),
      mptInitialResponse)

    check data["flags"].getInt ==
      cast[int]({mfEphemeral, mfIsComponentsV2})
    check data["components"].len == 1
    check data["components"][0]["type"].getInt == int mctTextDisplay
    check not data.hasKey("content")
    check not data.hasKey("embeds")
    check not data.hasKey("tts")
    check not data.hasKey("attachments")
    check not data.hasKey("poll")

  test "Components V2 followups reject incompatible fields and uploads":
    expect DimslashError:
      discard messageDataJson(
        MessagePayload(
          content: some "legacy",
          components: @[textComponent("V2")],
          flags: {mfIsComponentsV2}),
        mptFollowup)

    expect DimslashError:
      discard messageDataJson(
        MessagePayload(
          components: @[textComponent("V2")],
          files: @[DiscordFile(name: "report.txt", body: "body")],
          flags: {mfIsComponentsV2}),
        mptFollowup)

    expect DimslashError:
      discard messageDataJson(
        MessagePayload(
          components: @[textComponent("V2")],
          flags: {mfIsComponentsV2},
          tts: true),
        mptFollowup)

  test "Components V2 edits explicitly clear legacy fields":
    let data = messageDataJson(
      MessagePayload(
        content: none string,
        components: @[textComponent("Replacement")],
        flags: {mfIsComponentsV2}),
      mptEdit)

    check data["content"].kind == JNull
    check data["embeds"].kind == JArray
    check data["embeds"].len == 0
    check data["attachments"].kind == JArray
    check data["attachments"].len == 0
    check data["components"].len == 1
    check data["poll"].kind == JNull

  test "legacy create payloads retain content semantics":
    let data = messageDataJson(
      MessagePayload(content: some "hello", tts: true),
      mptFollowup)

    check data["content"].getStr == "hello"
    check data["tts"].getBool
    check not data.hasKey("embeds")
    check not data.hasKey("flags")

  test "initial responses fail instead of silently dropping DiscordFile uploads":
    expect DimslashError:
      discard messageDataJson(
        MessagePayload(
          content: some "file",
          files: @[DiscordFile(name: "report.txt", body: "body")]),
        mptInitialResponse)

  test "initial Attachment multipart uses minimal matching metadata":
    let upload = Attachment(
      id: "server-side-id-must-not-leak",
      filename: "/tmp/report.txt",
      description: some "Release report",
      url: "https://read-only.example.invalid/report.txt",
      file: "raw-file-body")
    let payload = MessagePayload(
      content: none string,
      components: @[textComponent("Download")],
      attachments: @[upload],
      flags: {mfIsComponentsV2})
    var body = %*{
      "type": int irtChannelMessageWithSource,
      "data": messageDataJson(payload, mptInitialResponse)
    }
    var multipart: MultipartData

    addUploads(payload, body, multipart, mptInitialResponse)

    let metadata = body["data"]["attachments"][0]
    check metadata.len == 3
    check metadata["id"].getStr == "0"
    check metadata["filename"].getStr == "report.txt"
    check metadata["description"].getStr == "Release report"
    check not metadata.hasKey("file")
    check not metadata.hasKey("url")
    check "raw-file-body" notin $body
    check ($multipart).count("name=\"payload_json\"") == 1
    check "name=\"files[0]\"" in $multipart
