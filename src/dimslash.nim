## DimSlash is a typed Discord interaction framework for Nim.
##
## Define immutable application routes with `newDiscordApp`, then attach the
## application to a gateway runtime with `bindGateway`.
##
## .. code-block:: nim
##   import dimslash
##
##   let app = newDiscordApp(proc(routes: var Routes) =
##     routes.slash("ping", "Replies with pong",
##       proc(ctx: SlashCommandContext) {.async.} =
##         discard await ctx.respond("pong"))
##   )
##
##   waitFor app.bindGateway("TOKEN").start()

import std/[asyncdispatch, json, options]
import dimslash/api

export api, asyncdispatch, json, options
