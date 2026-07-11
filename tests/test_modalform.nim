import std/[asyncdispatch, json, options, strutils, tables, unittest]
import dimscord

import ../src/dimslash
import ./helpers

proc input(id, value: string): MessageComponent =
  MessageComponent(kind: mctActionRow, components: @[
    MessageComponent(kind: mctTextInput, custom_id: some id,
                     value: some value)])

suite "modalForm declaration":
  test "fields carry labels, styles, and requiredness":
    let handler = newTestHandler(newRecorder())
    let form = handler.modalForm("feedback:{topic}", "Feedback"):
      ## Subject
      subject {.maxLen: 100.}: string
      ## Details
      detail {.paragraph, placeholder: "Tell us more".}: Option[string]
      ## Rating (1-5)
      rating: int
      submit:
        discard (topic, subject, detail, rating)
    check form.pattern == "feedback:{topic}"
    check form.title == "Feedback"
    check form.fields.len == 3
    check form.fields[0].customId == "subject"
    check form.fields[0].label == "Subject"
    check form.fields[0].required
    check form.fields[0].maxLen == 100
    check form.fields[0].style == tisShort
    check form.fields[1].style == tisParagraph
    check form.fields[1].placeholder == "Tell us more"
    check not form.fields[1].required
    check form.fields[2].label == "Rating (1-5)"
    # the submit handler is registered under the pattern
    check handler.registry.modals.patterns.len == 1

suite "showModal(form)":
  test "builds the modal and fills the captures":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    let form = handler.modalForm("report:{kind}:{n:int}", "Report"):
      ## What happened?
      details {.paragraph.}: string
      submit:
        discard (kind, n, details)
    let ctx = InteractionContext(handler: handler,
      interaction: mkSlashInteraction("cmd",
        initTable[string, ApplicationCommandInteractionDataOption]()))
    waitFor ctx.showModal(form, "abuse", 42)
    check rec.names == @["createModal"]
    check rec.calls[0].args["custom_id"].getStr == "report:abuse:42"
    check rec.calls[0].args["title"].getStr == "Report"
    check rec.calls[0].args["inputs"].len == 1
    check rec.calls[0].args["inputs"][0]["custom_id"].getStr == "details"
    check rec.calls[0].args["inputs"][0]["style"].getInt == int tisParagraph

  test "capture count and type mismatches raise":
    let handler = newTestHandler(newRecorder())
    let form = handler.modalForm("page:{n:int}", "Page"):
      ## note
      note: string
      submit:
        discard (n, note)
    let ctx = InteractionContext(handler: handler,
      interaction: mkSlashInteraction("cmd",
        initTable[string, ApplicationCommandInteractionDataOption]()))
    expect DimslashError:
      waitFor ctx.showModal(form)
    expect DimslashError:
      waitFor ctx.showModal(form, 1, 2)
    expect DimslashError:
      waitFor ctx.showModal(form, "abc")

suite "modalForm submit":
  test "typed fields and captures reach the body":
    let handler = newTestHandler(newRecorder())
    var got = ""
    discard handler.modalForm("fb:{topic}", "Feedback"):
      ## Subject
      subject: string
      ## Rating
      rating: int
      ## Details
      detail: Option[string]
      submit:
        got = topic & "/" & subject & "/" & $rating & "/" & $detail
    check waitFor handler.handleInteraction(nil, mkModalInteraction("fb:bug",
      @[input("subject", "crash"), input("rating", "5"),
        input("detail", "")]))
    check got == "bug/crash/5/none(string)"

  test "optional fields with text become some":
    let handler = newTestHandler(newRecorder())
    var got = none string
    discard handler.modalForm("opt", "Optional"):
      ## Extra
      extra: Option[string]
      submit:
        got = extra
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("opt", @[input("extra", "hi")]))
    check got == some "hi"

  test "a non-numeric int field raises UserError with the label":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    handler.onError = defaultOnError
    var ran = false
    discard handler.modalForm("num", "Numbers"):
      ## Your age
      age: int
      submit:
        ran = true
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("num", @[input("age", "old enough")]))
    check not ran
    check rec.names == @["createResponse"]
    check rec.calls[0].args["data"]["content"].getStr.contains("Your age")
    check rec.calls[0].args["data"]["flags"].getInt == cast[int]({mfEphemeral})

  test "optional int parses or stays none":
    let handler = newTestHandler(newRecorder())
    var got = none int
    discard handler.modalForm("optnum", "Numbers"):
      ## Count
      count: Option[int]
      submit:
        got = count
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("optnum", @[input("count", "")]))
    check got == none int
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("optnum", @[input("count", " 7 ")]))
    check got == some 7

  test "form-level check lines see the parsed fields":
    let rec = newRecorder()
    let handler = newTestHandler(rec)
    handler.onError = defaultOnError
    var ran = false
    discard handler.modalForm("rate", "Rate us"):
      ## Rating (1-5)
      rating: int
      check rating in 1 .. 5, "rating must be 1-5"
      submit:
        ran = true
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("rate", @[input("rating", "9")]))
    check not ran
    check rec.calls[0].args["data"]["content"].getStr == "rating must be 1-5"
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("rate", @[input("rating", "4")]))
    check ran

  test "float fields parse":
    let handler = newTestHandler(newRecorder())
    var got = 0.0
    discard handler.modalForm("fl", "Floats"):
      ## Amount
      amount: float
      submit:
        got = amount
    check waitFor handler.handleInteraction(nil,
      mkModalInteraction("fl", @[input("amount", "3.5")]))
    check got == 3.5

suite "modalForm rejections":
  let handler = newTestHandler(newRecorder())

  test "more than five fields are rejected":
    check not compiles(
      modalForm(handler, "big", "Too big") do:
        a: string
        b: string
        c: string
        d: string
        e: string
        f: string
        submit: discard)

  test "duplicate field names are rejected":
    check not compiles(
      modalForm(handler, "dup", "Duplicates") do:
        x: string
        x: int
        submit: discard)

  test "unsupported field types are rejected":
    check not compiles(
      modalForm(handler, "bool", "Bools") do:
        flag: bool
        submit: discard)

  test "defaults are rejected":
    check not compiles(
      modalForm(handler, "def", "Defaults") do:
        x: string = "hi"
        submit: discard)

  test "missing submit is rejected":
    check not compiles(
      modalForm(handler, "nosub", "No submit") do:
        x: string)

  test "field colliding with a capture is rejected":
    check not compiles(
      modalForm(handler, "clash:{x}", "Clash") do:
        x: string
        submit: discard x)
