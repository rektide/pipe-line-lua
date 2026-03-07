# Line Lifecycle

This guide describes lifecycle orchestration on `Line`.

References:

- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)
- [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Line Stop Future

Each line owns a stop future:

- `line.stopped`

`line:ensure_stopped()` resolves it after collected stop awaitables settle.

## `line:ensure_prepared()`

Runs `segment.ensure_prepared(context)` across the current pipe.

- collects returned `task_or_tasks`
- awaits all collected awaitables before returning
- expects hook idempotence at segment level

`line:prepare_segments()` remains an alias.

## `line:ensure_stopped()`

Runs stop lifecycle for the whole line.

- collects segment stop handles (`segment.stopped` where present)
- calls `segment.ensure_stopped(context)` and collects returned `task_or_tasks`
- awaits collected awaitables
- resolves `line.stopped`

## `line:close()`

High-level shutdown sequence:

1. `line:ensure_prepared()`
2. `line:ensure_stopped()`

## Hook Context Shape

Lifecycle context includes:

- `line`
- `pos`
- `segment`

Line lifecycle calls pass `force = true` to `ensure_prepared` and `ensure_stopped`.

## Strategy-Specific Stop (Task Transports)

Task transport stop strategy is selected by `stop_type`:

- `stop_drain` (default)
- `stop_immediate`

Generic `ensure_stopped` dispatches to strategy-specific verbs:

- `ensure_stopped_drain`
- `ensure_stopped_immediate`

Strategy completion signals:

- `stopped_drain`
- `stopped_immediate`
- `stopped`

See [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md).

## Waiting by Segment Type

For targeted waits, use selector-based live stop handles:

```lua
local completion_stop = line:stopped_live("completion")
line:close()
completion_stop:await(1000, 10)
```
