# Line Lifecycle

This guide describes the runtime lifecycle APIs on `Line`.

References:
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)
- [`/lua/termichatter/done.lua`](/lua/termichatter/done.lua)
- [`/doc/selecting.md`](/doc/selecting.md)

## Deferreds on Line

Each line has one line-scoped deferred handle created at construction time:

- `line.stopped` resolves when stop hooks finish.

Both support:

- `:resolve(value)`
- `:await(timeout?, interval?)`
- `:on_resolve(callback)`
- `:is_resolved()`

## `line:ensure_prepared()`

Runs `segment.ensure_prepared(context)` for each segment in the pipe.

- collects returned `task_or_tasks`
- awaits all collected tasks before returning
- intended to be idempotent at segment level

`line:prepare_segments()` is currently an alias kept for migration.

## `line:ensure_stopped()`

Runs stop lifecycle for the whole pipe.

- collects each segment's `segment.stopped` handle (if present)
- calls `segment.ensure_stopped(context)` and collects returned `task_or_tasks`
- awaits all collected tasks
- resolves `line.stopped`

## `line:close()`

High-level shutdown path.

Current behavior:

1. calls `line:ensure_prepared()`
2. calls `line:ensure_stopped()`

Control flags:

- `line.auto_completion_done_on_close = false` disables completion segment auto-emitting `done` on stop.

## Context Objects Passed to Segment Hooks

`init`, `ensure_prepared`, and `ensure_stopped` hooks receive context tables that include:

- `line`
- `pos`
- `segment`

`ensure_prepared` and `ensure_stopped` also include `force = true` when called from line lifecycle helpers.

## Waiting by Segment Type

Use selector-based waiting when you need stop lifecycle for a subset of segments:

```lua
local completion_stop = line:stopped_live("completion")
line:close()
completion_stop:await(1000, 10)
```
