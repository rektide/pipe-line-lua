# Run

`Run` is the execution cursor of pipe-line. A line defines the pipeline, but a run is what actually walks segment-by-segment, applies handler return semantics, and pushes completed output.

If you want to understand how a message moves through the system in exact order, this is the primary document.

## Reference Materials

| Area | Source | Why it matters |
|------|--------|----------------|
| Run implementation | [`/lua/pipe-line/run.lua`](/lua/pipe-line/run.lua) | Canonical execution algorithm (`execute`, `next`, `emit`, `clone`, `fork`) |
| Segment resolution + preparation | [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua) | Run depends on line-level segment resolution and per-segment readiness hooks |
| Segment contract | [`/doc/segment.md`](/doc/segment.md) | Defines `handler(run)` and return semantics used by run execution |
| Lifecycle orchestration | [`/doc/line.md`](/doc/line.md) | Explains prepare/stop phases that bracket run execution |
| Protocol control runs | [`/lua/pipe-line/segment/completion.lua`](/lua/pipe-line/segment/completion.lua) | Shows run-field protocol controls consumed by completion segment |
| Metatable lookup behavior | [`/doc/metatables.md`](/doc/metatables.md) | Explains why run can read line-owned fields transparently |

## What a Run Owns vs Reads

Typical run-owned fields:

- `type = "run"`
- `line`
- `pipe`
- `pos`
- `input`
- `_rev`

Run read-through behavior:

- `run[k]` falls through to line (`line[k]`) when run does not own `k`
- this is why handlers can read `run.source`, `run.filter`, `run.registry`, etc. without explicit wiring

Related model details: [`/doc/metatables.md`](/doc/metatables.md).

## Creation and Startup

Create through line:

```lua
local run = line:run({ input = payload })
```

Direct creation:

```lua
local Run = require("pipe-line.run")
local run = Run(line, { input = payload, auto_start = false })
```

Startup behavior:

- default: `auto_start` enabled (`run:execute()` runs immediately)
- `auto_start = false`: create run object without immediate execution

## Execution Algorithm (`run:execute()`)

`run:execute()` is the core loop.

1. call `run:sync()` to reconcile cursor position with pipe splice journal
2. while `run.pos <= #run.pipe`:
   - read segment at current position
   - resolve named segment references (string -> resolved segment)
   - materialize segment factories when applicable
   - call segment `ensure_prepared(context)` when present
   - resolve handler and invoke `handler(run)`
   - apply handler return semantics (below)
   - increment `run.pos`
   - call `run:sync()` again
3. when cursor passes end:
   - push `run.input` to output queue if non-`nil`
4. return final `run.input`

## Handler Return Semantics (Run Interpretation)

Run-level interpretation is strict and simple:

- `false`: stop this run path immediately
- non-`nil` (except `false`): replace `run.input`
- `nil`: preserve existing `run.input`

This is the core contract that async boundary segments rely on.

## Async Boundary Continuation Flow

Async boundary handlers use stop-now/continue-later behavior:

1. boundary `handler(run)` hands off continuation ownership (queue/task/pending)
2. boundary returns `false`
3. later, continuation run calls `:next(...)` to resume from downstream segment

Why this matters:

- prevents double flow (inline path + async path)
- keeps run semantics consistent: stop now, resume explicitly later

Continuation tracking:

- run-owned field: `run.continuation`
- single-slot continuation tracking is acceptable

Related boundary usage: [`/doc/segment.md`](/doc/segment.md), [`/doc/line.md`](/doc/line.md).

## `run:next(element?)`

`run:next()` advances cursor by one and continues execution.

- optional `element` replaces `run.input` before continuing
- if already at end, pushes to output directly

This is the primitive used by continuation runs to re-enter pipeline flow.

## Fan-Out and Independence

### `run:emit(element, strategy?)`

- convenience for fan-out
- creates continuation run via strategy and immediately `:next()` it

Strategies:

- `self`: mutate and continue same run path
- `clone`: lightweight child run (shared ownership)
- `fork`: more independent run context

### `run:clone(new_input)`

- creates lightweight child run with parent read-through
- child gets own `input` and `pos`
- shared view for many other fields

### `run:fork(new_input?)`

- clone + ownership break for key fields
- currently calls `own("pipe")` and `own("fact")`

## Pipe Synchronization (`run:sync()`)

Runs track `_rev` and reconcile position against pipe splice journal.

This allows in-flight runs to survive dynamic pipe mutation (for example resolver-driven splices) without losing cursor correctness.

## Ownership Controls (`run:own`, `run:set_fact`)

`run:own(field)` explicitly breaks read-through for that field.

Special handling:

- `own("pipe")`: clones current pipe for independent mutation
- `own("fact")`: snapshots visible fact state into run-owned table

`run:set_fact(name, value?)` lazily creates run-local fact overlay with fallback to line fact.

## Control Runs and Protocol Fields

Not every run carries a normal data payload. Protocol runs use run fields as control plane.

Completion protocol fields:

- `pipe_line_protocol = true`
- `mpsc_completion = "hello" | "done" | "shutdown"`
- `mpsc_completion_name` optional

These are interpreted by protocol-aware segments (not by run core itself).

## Practical Debug Checklist

When run behavior feels wrong, check:

1. is handler returning `false` where it should hand off async?
2. is continuation resumed exactly once?
3. did a dynamic splice move cursor position unexpectedly (check `run:sync()` behavior)?
4. is `run.input` being replaced/kept/stopped according to return semantics?
5. is output queue present and receiving non-`nil` final payload?

## Relationship to Other Core Components

- **Line** creates and orchestrates runs; run is execution substrate. See [`/doc/line.md`](/doc/line.md).
- **Segment** defines handler and lifecycle semantics that run executes. See [`/doc/segment.md`](/doc/segment.md).
- **Registry** resolves named segment entries used during run execution. See [`/doc/registry.md`](/doc/registry.md).
