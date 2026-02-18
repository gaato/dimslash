import std/unittest
import ../src/dimslash

suite "registry":
  test "register and find slash command":
    let reg = newRegistry()
    reg.register RegisteredCommand(kind: ckSlash, name: "ping", description: "", callback: nil)
    let found = reg.find(ckSlash, "Ping")
    check found.name == "ping"

  test "duplicate registration raises":
    let reg = newRegistry()
    reg.register RegisteredCommand(kind: ckSlash, name: "ping", description: "", callback: nil)
    expect ValueError:
      reg.register RegisteredCommand(kind: ckSlash, name: "PING", description: "", callback: nil)

  test "autocomplete allows option-specific handlers":
    let reg = newRegistry()
    reg.register RegisteredCommand(kind: ckAutocomplete, name: "search", optionName: "query", description: "", callback: nil)
    reg.register RegisteredCommand(kind: ckAutocomplete, name: "search", optionName: "tag", description: "", callback: nil)

    let query = reg.findAutocomplete("search", "query")
    let tag = reg.findAutocomplete("search", "tag")
    check query.optionName == "query"
    check tag.optionName == "tag"

  test "autocomplete falls back to generic handler":
    let reg = newRegistry()
    reg.register RegisteredCommand(kind: ckAutocomplete, name: "search", optionName: "", description: "", callback: nil)

    let found = reg.findAutocomplete("search", "unknown")
    check found.optionName == ""
