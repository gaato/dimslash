# Package

version       = "0.1.0"
author        = "Gakuto Furuya"
description   = "Intaractive command handler for Dimscord"
license       = "BlueOak-1.0.0"
srcDir        = "src"


# Dependencies

requires "nim >= 2.0.6"

requires "dimscord >= 1.8.0"

task docs, "Generate API docs into docs/" :
  exec "nim doc -d:ssl --project --index:on --outdir:docs src/dimslash.nim"