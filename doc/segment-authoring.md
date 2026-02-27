# Segment Authoring

This guide describes the runtime contract for writing custom segments.

References:
- [`/lua/termichatter/segment.lua`](/lua/termichatter/segment.lua)
- [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua)
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)

## Minimal Segment

The smallest segment is a function receiving `run`.

```lua
registry:register("tagger", function(run)
  run.input.tagged = true
  return run.input
end)
```

Return semantics:

- `table` (or other non-nil value): becomes next input
- `false`: stop pipeline
- `nil`: keep current input unchanged

## Table Segment Shape

A segment table can include metadata and lifecycle hooks.

```lua
registry:register("my_segment", {
  type = "my_segment",
  wants = { "time" },
  emits = { "validated" },
  init = function(self, ctx)
    -- optional one-time setup per line slot
  end,
  ensure_prepared = function(self, ctx)
    -- optional startup/readiness hook
    -- may return task or task list
  end,
  ensure_stopped = function(self, ctx)
    -- optional shutdown hook
    -- may return task or task list
  end,
  handler = function(run)
    run.input.validated = true
    return run.input
  end,
})
```

## Segment Layers

Segment behavior is easiest to reason about in three layers:

1. **Spec layer**: static table fields (`type`, `wants`, `emits`, handler references).
2. **Instance layer**: per-line state initialization in `init(context)`.
3. **Run layer**: per-message behavior in `handler(run)`.

Use `init` for per-instance defaults and runtime state (queues, futures, counters), not shared prototype mutation.

## Lifecycle Hooks

The line runtime can call:

- `init(context)`
- `ensure_prepared(context)`
- `ensure_stopped(context)`

Context includes hook-specific keys:

- `init(context)`: `line`, `pos`, `segment`
- `ensure_prepared(context)`: `line`, `pos`, `segment`, `force` (line lifecycle path)
- `ensure_stopped(context)`: `line`, `pos`, `segment`, `force` (line lifecycle path)

`run:execute()` may call `ensure_prepared` with `line`, `run`, `pos`, `segment`.

`ensure_prepared` and `ensure_stopped` are expected to be idempotent.

## Protocol-Aware Segments

`segment.define(...)` provides default control-message behavior:

- protocol runs are passed through
- protocol runs are not processed by handler unless opted in

Use:

```lua
local define = require("termichatter.segment.define").define

local my_segment = define({
  type = "my_segment",
  handler = function(run)
    return run.input
  end,
})
```

`segment.define` is the core segment contract utility. Transport-specific wrappers (task/mpsc variants) should compose on top of this contract rather than redefine segment lifecycle semantics.

## Segment Runtime Identity

Per-line runtime instances are selected by `type`.

- keep `type` stable and explicit
- `id` may be assigned by line runtime when `auto_id` is enabled

See [`/doc/segment-instancing.md`](/doc/segment-instancing.md) for details.
