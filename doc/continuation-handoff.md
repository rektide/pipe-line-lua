# Continuation Handoff

This guide defines the continuation handoff contract used by async boundary segments.

References:

- [`/lua/termichatter/run.lua`](/lua/termichatter/run.lua)
- [`/lua/termichatter/segment/mpsc.lua`](/lua/termichatter/segment/mpsc.lua)
- [`/lua/termichatter/segment/define/transport/mpsc.lua`](/lua/termichatter/segment/define/transport/mpsc.lua)
- [`/lua/termichatter/segment/define/transport/task.lua`](/lua/termichatter/segment/define/transport/task.lua)
- [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- [`/doc/async-handoff.md`](/doc/async-handoff.md)

## Core Rule

When a boundary segment hands off a continuation run to async transport, it should:

1. hand off continuation ownership (`queue:push(...)`, pending list append, task handoff)
2. return `false` from `handler(run)`
3. resume later with `continuation:next(...)`

In short: **stop now, continue later**.

## Why Return `false`

`Run:execute()` interprets `false` as stop-this-run-path now.

This prevents double flow:

- wrong: inline path continues, and async path also continues later
- right: inline path stops at boundary, only continuation path resumes later

## Run Ownership

Continuation is run-owned.

- current tracking field: `run.continuation`
- continuation shape can remain simple (single slot is fine)

Boundary segments transport continuation runs; they do not redefine run semantics.

## Contract by Segment Type

### Sync segment

- returns transformed value (`run.input` replacement) or `nil`
- pipeline keeps executing inline

### Async boundary segment

- creates/selects a continuation run (for example via strategy helper)
- stores/transports that continuation
- returns `false`
- later calls `continuation:next(...)`

## Example: Queue Handoff Pattern

```lua
handler = function(run)
  local continuation = run -- or clone/fork strategy
  run.continuation = continuation
  queue:push({ continuation = continuation })
  return false
end

-- later, in worker/consumer:
local message = queue:pop()
message.continuation:next()
```

## Failure Modes to Avoid

- Returning `nil`/value after handoff and also calling `continuation:next(...)` later.
- Calling `continuation:next(...)` multiple times for the same handoff path.
- Treating continuation as segment-owned state rather than run-owned flow state.

## Lifecycle Relationship

`ensure_prepared` and `ensure_stopped` handle transport startup/shutdown around this contract.

- `handler(run)` decides when ownership moves to async transport.
- lifecycle hooks decide when workers/queues are available and when they stop.

See:

- [`/doc/lifecycle.md`](/doc/lifecycle.md)
- [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Practical Test Cases

- boundary handler returns `false` after handoff
- continuation resumes exactly once via `:next(...)`
- no duplicate downstream processing for one input
- line shutdown waits according to selected stop strategy (`stop_type`)
