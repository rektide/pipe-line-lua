# Segment Selecting

This guide covers selecting runtime segment instances from a line.

References:
- [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)

## `line:select_segments(selector, opts?)`

Returns runtime segment tables matched by selector.

Selector forms:

- `nil` => all table segments
- `"type_name"` => match `seg.type`
- `function(seg, ctx)` => custom predicate

`ctx` fields:

- `line`
- `pos`

Examples:

```lua
local all = line:select_segments()
local completions = line:select_segments("completion")

local later_handoffs = line:select_segments(function(seg, ctx)
  return seg.type == "mpsc_handoff" and ctx.pos > 1
end)
```

## `line:stopped_live(selector)`

Returns a deferred that settles when all currently matching `seg.stopped` awaitables settle,
and also waits for newly appearing matching awaitables until no unseen ones remain.

```lua
local wait = line:stopped_live("completion")
local result = wait:await(1000, 10)
```

Use this to observe live segment stop state by type without hard-coding pipeline positions.
