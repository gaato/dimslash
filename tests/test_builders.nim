import std/[options, unittest]
import dimscord

import ../src/dimslash/builders

suite "embed builder":
  test "keywords map onto the Embed object":
    let e = embed:
      title "Vote"
      description "Pick a side"
      color 0x5865F2
      url "https://example.com"
      timestamp "2026-07-11T00:00:00Z"
      image "https://example.com/banner.png"
      thumbnail "https://example.com/icon.png"
      author "gaato", url = "https://gaato.net", icon = "https://a.png"
      footer "closes soon", icon = "https://f.png"
      field "Ayes", "12", inline = true
      field "Noes", "3"
    check e.title == some "Vote"
    check e.description == some "Pick a side"
    check e.color == some 0x5865F2
    check e.url == some "https://example.com"
    check e.timestamp == some "2026-07-11T00:00:00Z"
    check e.image.get.url == "https://example.com/banner.png"
    check e.thumbnail.get.url == "https://example.com/icon.png"
    check e.author.get.name == "gaato"
    check e.author.get.url == some "https://gaato.net"
    check e.author.get.icon_url == some "https://a.png"
    check e.footer.get.text == "closes soon"
    check e.footer.get.icon_url == some "https://f.png"
    let fields = e.fields.get
    check fields.len == 2
    check fields[0].name == "Ayes"
    check fields[0].inline == some true
    check fields[1].inline.isNone

  test "expressions work as values":
    let n = 42
    let e = embed:
      title "Result: " & $n
      color n * 2
    check e.title == some "Result: 42"
    check e.color == some 84

  test "unknown keywords are rejected":
    check not compiles(embed do:
      titel "typo")

suite "row builder":
  test "buttons and link buttons":
    let r = row:
      button "Yes", "vote:yes", style = bsSuccess
      button "No", "vote:no", style = bsDanger, disabled = true
      linkButton "Docs", "https://example.com"
    check r.kind == mctActionRow
    check r.components.len == 3
    check r.components[0].style == bsSuccess
    check r.components[0].custom_id == some "vote:yes"
    check r.components[1].disabled == some true
    check r.components[2].style == bsLink
    check r.components[2].url == some "https://example.com"

  test "select with options":
    let r = row:
      select "menu", placeholder = "Pick", minValues = 1, maxValues = 2:
        option "Aye", "yes", desc = "For the motion"
        option "Nay", "no", default = true
    let menu = r.components[0]
    check menu.kind == mctSelectMenu
    check menu.custom_id == some "menu"
    check menu.placeholder == some "Pick"
    check menu.max_values == some 2
    check menu.options.len == 2
    check menu.options[0].description == some "For the motion"
    check menu.options[1].default == some true

  test "entity selects":
    let r1 = row:
      userSelect "pick:user", placeholder = "Who?"
    check r1.components[0].kind == mctUserSelect
    check r1.components[0].placeholder == some "Who?"
    let r2 = row:
      channelSelect "pick:channel", channels = {ctGuildText}
    check r2.components[0].kind == mctChannelSelect
    check r2.components[0].channel_types == @[ctGuildText]
    let r3 = row:
      roleSelect "pick:role"
    check r3.components[0].kind == mctRoleSelect
    let r4 = row:
      mentionableSelect "pick:any"
    check r4.components[0].kind == mctMentionableSelect

  test "unknown component keywords are rejected":
    check not compiles(row do:
      knopf "nein", "id")

  test "a select sharing a row is rejected at compile time":
    check not compiles(row do:
      button "A", "a"
      select "menu", placeholder = "Pick":
        option "x", "x")
    check not compiles(row do:
      roleSelect "pick:role"
      mentionableSelect "pick:any")

suite "rows builder":
  test "nested row blocks become a seq of action rows":
    let comps = rows:
      row:
        button "A", "a"
      row:
        button "B", "b"
        button "C", "c"
    check comps.len == 2
    check comps[0].components.len == 1
    check comps[1].components.len == 2
    check comps[1].components[1].custom_id == some "c"

  test "non-row statements are rejected":
    check not compiles(rows do:
      button "A", "a")
