# Segment Authoring

This guide describes the segment contract and naming model used by pipe-line.

References:

- [`/lua/pipe-line/segment.lua`](/lua/pipe-line/segment.lua)
- [`/lua/pipe-line/segment/define.lua`](/lua/pipe-line/segment/define.lua)
- [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)
- [`/lua/pipe-line/run.lua`](/lua/pipe-line/run.lua)

## Core Contract

Segment behavior is centered on one run-facing verb:

- `handler(run)`

Lifecycle hooks remain:

- `init(context)`
- `ensure_prepared(context)`
- `ensure_stopped(context)`

## Minimal Segment

The smallest segment is a function taking `run`.

```lua
registry:register("tagger", function(run)
  run.input.tagged = true
  return run.input
end)
```

## Table Segment Shape

```lua
registry:register("my_segment", {
  type = "my_segment",
  wants = { "time" },
  emits = { "validated" },

  init = function(self, ctx)
    -- per-instance setup (state/futures/queues/counters)
  end,

  ensure_prepared = function(self, ctx)
    -- optional readiness/start hook
    -- may return awaitable or awaitable list
  end,

  handler = function(run)
    run.input.validated = true
    return run.input
  end,

  ensure_stopped = function(self, ctx)
    -- optional stop hook
    -- may return awaitable or awaitable list
  end,
})
```

## Run-Centric Continuation Model

`handler(run)` starts processing for this run path.

- sync segments usually return a value directly
- async boundary segments usually hand off and resume later via continuation run objects

If a segment needs to track continuation handles for a run, use:

- `run.continuation`

A single continuation slot is acceptable.

## Handler Return Semantics

Current shorthand semantics:

- non-`nil`: replaces `run.input`
- `false`: stop this run path
- `nil`: keep current `run.input` unchanged

Boundary segments often return `false` after handing off continuation, then call continuation `:next(...)` later.

## Segment Layers

Segment code is easiest to reason about in three layers:

1. **Spec layer**: static fields (`type`, `wants`, `emits`, hook definitions)
2. **Instance layer**: per-line setup in `init(context)`
3. **Run layer**: per-message behavior in `handler(run)`

Use `init` for per-instance defaults and state. Avoid mutating shared prototypes at run time.

## Lifecycle Context

Hook context keys:

- `init(context)`: `line`, `pos`, `segment`
- `ensure_prepared(context)`: `line`, `pos`, `segment`, `force` (line lifecycle path)
- `ensure_stopped(context)`: `line`, `pos`, `segment`, `force` (line lifecycle path)

`ensure_prepared` and `ensure_stopped` should be idempotent.

## Protocol-Aware Segments

`segment.define(...)` wraps handler behavior with protocol pass-through defaults.

```lua
local define = require("pipe-line.segment.define").define

local my_segment = define({
  type = "my_segment",
  handler = function(run)
    return run.input
  end,
})
```

This keeps protocol behavior consistent across custom segments.

## Runtime Identity

Per-line runtime segment instances are selected by `type`.

- keep `type` stable and explicit
- `id` may be assigned when `auto_id` is enabled

See [`/doc/segment-instancing.md`](/doc/segment-instancing.md).
