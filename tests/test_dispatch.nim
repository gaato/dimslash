import std/[unittest, asyncdispatch, tables]
import dimscord
import ../src/dimslash

proc nop(s: Shard, i: Interaction): Future[void] {.async.} =
  discard

suite "dispatch":
  test "ensureImplemented is currently a no-op":
    ensureImplemented(ckSlash)
    ensureImplemented(ckUser)
    ensureImplemented(ckMessage)
    ensureImplemented(ckButton)
    ensureImplemented(ckSelect)
    ensureImplemented(ckModal)
    ensureImplemented(ckAutocomplete)

  test "invalid interaction without command name":
    var handler = InteractionHandler(
      discord: nil,
      defaultGuildId: "",
      registry: newRegistry(),
      slashOptionNames: initOrderedTable[string, seq[string]]()
    )
    handler.addSlashProc("ping", "desc", nop)
    let i = Interaction(kind: itApplicationCommand)
    expect HandlerError:
      discard waitFor handler.handleInteraction(nil, i)
