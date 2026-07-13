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

suite "Components V2 layout builder":
  test "builds every supported component with nested containers and rows":
    let heading = "# Release notes"
    let ui = layout:
      text heading
      section:
        text "Version 2 is ready."
        text "Choose what to do next."
        thumbnail "https://example.com/icon.png", desc = "App icon"
      gallery:
        media "https://example.com/one.png", description = "First image"
        media "attachment://two.png", spoiler = true
      file "attachment://manual.pdf", spoiler = true
      separator divider = false, spacing = 2
      container accent = 0x5865F2, spoiler = true:
        text "Inside the container"
        row:
          button "Install", "release:install", style = bsSuccess
          linkButton "Docs", "https://example.com/docs"

    check ui.components.len == 6
    check ui.components[0].kind == mctTextDisplay
    check ui.components[0].content == heading

    let section = ui.components[1]
    check section.kind == mctSection
    check section.sect_components.len == 2
    check section.sect_components[1].content == "Choose what to do next."
    check section.accessory.kind == mctThumbnail
    check section.accessory.description == some "App icon"

    let gallery = ui.components[2]
    check gallery.kind == mctMediaGallery
    check gallery.items.len == 2
    check gallery.items[0].description == some "First image"
    check gallery.items[1].spoiler == some true

    check ui.components[3].kind == mctFile
    check ui.components[3].file.url == "attachment://manual.pdf"
    check ui.components[3].spoiler == some true
    check ui.components[4].kind == mctSeparator
    check ui.components[4].divider == some false
    check ui.components[4].spacing == some 2

    let container = ui.components[5]
    check container.kind == mctContainer
    check container.accent_color == some 0x5865F2
    check container.spoiler == some true
    check container.components.len == 2
    check container.components[1].kind == mctActionRow
    check container.components[1].components.len == 2

  test "a bare separator uses Discord defaults":
    let ui = layout:
      text "above"
      separator
      text "below"
    check ui.components[1].divider == some true
    check ui.components[1].spacing == some 1

  test "invalid nesting and fixed shapes are rejected at compile time":
    check not compiles(layout do:
      button "Loose", "button")
    check not compiles(layout do:
      section:
        text "No accessory")
    check not compiles(layout do:
      section:
        text "One"
        text "Two"
        text "Three"
        text "Four"
        button "Go", "go")
    check not compiles(layout do:
      section:
        text "Two accessories"
        button "Go", "go"
        thumbnail "https://example.com/icon.png")
    check not compiles(layout do:
      gallery:
        text "not media")
    check not compiles(layout do:
      container:
        container:
          text "nested")

  test "Discord limits with literal values are rejected at compile time":
    check not compiles(layout do:
      gallery:
        media "1"
        media "2"
        media "3"
        media "4"
        media "5"
        media "6"
        media "7"
        media "8"
        media "9"
        media "10"
        media "11")
    check not compiles(layout do:
      file "https://example.com/manual.pdf")
    check not compiles(layout do:
      file url = "https://example.com/manual.pdf")
    check not compiles(layout do:
      separator spacing = 3)
    check not compiles(layout do:
      separator true, 3)
    check not compiles(layout do:
      container accent = 0x1000000:
        text "bad color")
    check not compiles(layout do:
      row:
        button "1", "1"
        button "2", "2"
        button "3", "3"
        button "4", "4"
        button "5", "5"
        button "6", "6")

  test "the 40 component total includes nested children":
    check not compiles(layout do:
      text "1"
      text "2"
      text "3"
      text "4"
      text "5"
      text "6"
      text "7"
      text "8"
      text "9"
      text "10"
      text "11"
      text "12"
      text "13"
      text "14"
      text "15"
      text "16"
      text "17"
      text "18"
      text "19"
      text "20"
      text "21"
      text "22"
      text "23"
      text "24"
      text "25"
      text "26"
      text "27"
      text "28"
      text "29"
      text "30"
      text "31"
      text "32"
      text "33"
      text "34"
      text "35"
      text "36"
      text "37"
      text "38"
      text "39"
      section:
        text "40"
        button "41 and 42", "over")

  test "dynamic limit values are checked when the layout is built":
    let badFile = "https://example.com/file.txt"
    expect ValueError:
      discard layout:
        file badFile
    let badSpacing = 3
    expect ValueError:
      discard layout:
        separator spacing = badSpacing
    let badAccent = 0x1000000
    expect ValueError:
      discard layout:
        container accent = badAccent:
          text "bad"
    let negativeAccent = -1
    expect ValueError:
      discard layout:
        container accent = negativeAccent:
          text "also bad"
