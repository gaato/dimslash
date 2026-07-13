import std/[asyncdispatch, options, tables, unittest]
import dimscord

import ../src/dimslash
import ./helpers

type
  Flavor = enum
    vanilla
    chocolate = "Dark chocolate"
    strawberry
  Servings = range[1 .. 12]
  CustomerId = distinct string
  Priority = distinct int

suite "Nim-derived slash options":
  test "enum and range types derive Discord metadata":
    let handler = newTestHandler(newRecorder())
    handler.slash("dessert", "Build a dessert"):
      ## flavor
      flavor: Flavor
      ## servings
      servings: Servings
      ## second flavor
      extra: Option[Flavor]
      execute:
        discard (flavor, servings, extra)

    let opts = handler.registry.slash["dessert"].root.options
    check opts[0].kind == acotStr
    check opts[0].choices.len == 3
    check opts[0].choices[0].name == "vanilla"
    check opts[0].choices[0].value.strVal == "vanilla"
    check opts[0].choices[1].name == "Dark chocolate"
    check opts[0].choices[1].value.strVal == "chocolate"
    check opts[1].kind == acotInt
    check opts[1].minValue == some 1.0
    check opts[1].maxValue == some 12.0
    check opts[2].choices.len == 3
    check not opts[2].required

  test "handlers receive enum and range values without manual parsing":
    let handler = newTestHandler(newRecorder())
    var gotFlavor = vanilla
    var gotServings: Servings = 1
    var gotExtra = none Flavor
    handler.slash("dessert", "Build a dessert"):
      ## flavor
      flavor: Flavor
      ## servings
      servings: Servings
      ## extra
      extra: Option[Flavor]
      execute:
        gotFlavor = flavor
        gotServings = servings
        gotExtra = extra

    check waitFor handler.handleInteraction(nil, mkSlashInteraction("dessert",
      toOpts(strOpt("flavor", "chocolate"), intOpt("servings", 4),
             strOpt("extra", "strawberry"))))
    check gotFlavor == chocolate
    check gotServings == 4
    check gotExtra == some strawberry

  test "defaults preserve the caller-defined type":
    let handler = newTestHandler(newRecorder())
    var gotFlavor = vanilla
    var gotServings: Servings = 1
    handler.slash("defaults", "Use defaults"):
      ## flavor
      flavor: Flavor = strawberry
      ## servings
      servings: Servings = 3
      execute:
        gotFlavor = flavor
        gotServings = servings
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("defaults",
      initTable[string, ApplicationCommandInteractionDataOption]()))
    check gotFlavor == strawberry
    check gotServings == 3

  test "distinct string and int stay distinct in handler code":
    let handler = newTestHandler(newRecorder())
    var gotCustomer = CustomerId("")
    var gotPriority = Priority(0)
    handler.slash("domain", "Use domain values"):
      ## customer id
      customer: CustomerId
      ## priority
      priority: Priority
      execute:
        gotCustomer = customer
        gotPriority = priority
    let specs = handler.registry.slash["domain"].root.options
    check specs[0].kind == acotStr
    check specs[1].kind == acotInt
    check waitFor handler.handleInteraction(nil, mkSlashInteraction("domain",
      toOpts(strOpt("customer", "customer-42"), intOpt("priority", 7))))
    check string(gotCustomer) == "customer-42"
    check int(gotPriority) == 7

  test "malformed derived values fail extraction":
    let handler = newTestHandler(newRecorder())
    handler.onError = nil
    handler.slash("bounded", "Check bounds"):
      ## flavor
      flavor: Flavor
      ## servings
      servings: Servings
      execute:
        discard (flavor, servings)
    expect DimslashError:
      discard waitFor handler.handleInteraction(nil,
        mkSlashInteraction("bounded",
          toOpts(strOpt("flavor", "unknown"), intOpt("servings", 99))))

  test "unsupported caller-defined types are compile-time errors":
    type Unsupported = object
      value: string
    let handler = newTestHandler(newRecorder())
    check not compiles(
      slash(handler, "badtype", "Bad type") do:
        value: Unsupported
        execute:
          discard value)

  test "enum options cannot also use autocomplete":
    let handler = newTestHandler(newRecorder())
    check not compiles(
      slash(handler, "badcomplete", "Bad autocomplete") do:
        flavor: Flavor
        autocomplete flavor:
          discard
        execute:
          discard flavor)
