import std/[unittest, tables]
import ../src/dimslash

suite "sync payload prep":
  test "can register slash user message commands":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    handler.addSlashProc("ping", "desc", nil)
    handler.addUser("userinfo", nil)
    handler.addMessage("quote", nil)

    let slash = handler.registry.find(ckSlash, "ping")
    let user = handler.registry.find(ckUser, "userinfo")
    let message = handler.registry.find(ckMessage, "quote")

    check slash.name == "ping"
    check user.name == "userinfo"
    check message.name == "quote"
