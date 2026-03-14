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

## Run at a Glance

| Surface | What it does | Why it matters |
|---------|--------------|----------------|
| `Run.new(line, config)` | Creates run object and optionally starts execution | Entry point for per-message execution context |
| `run:execute()` | Main pipeline loop | Defines exact segment-walking behavior |
| `run:next(element?)` | Continue from current cursor + 1 | Core primitive for continuation re-entry |
| `run:emit(element, strategy?)` | Fan-out convenience | Produces additional run paths cheaply |
| `run:clone(new_input)` | Lightweight child run | Shares parent/line state where safe |
| `run:fork(new_input?)` | More independent child run | Breaks ownership for mutable fields |
| `run:sync()` | Reconcile cursor with splice journal | Keeps cursor correct during dynamic pipe mutation |
| `run:own(field)` | Take local ownership of field | Escape read-through when isolation is needed |
| `run.continuation` | Optional run-owned continuation tracking field | Supports async boundary handoff bookkeeping |

## What a Run Actually Owns

A run typically owns `type`, `line`, `pipe`, `pos`, `input`, and `_rev`. Everything else is resolved through metatable lookup.

That means handlers can read values such as `run.source`, `run.filter`, and `run.registry` without explicit plumbing because missing run keys fall through to line keys. See [`/doc/metatables.md`](/doc/metatables.md) for full chain behavior.

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

1. `run:sync()` reconciles cursor position against pipe splice journal.
2. Current pipe entry is read and resolved (name lookup, factory materialization, or direct table/function use).
3. If the segment exposes `ensure_prepared(context)`, it is called for this run/position before handler execution.
4. The segment handler is resolved and invoked as `handler(run)`.
5. Handler return is applied to run state using return semantics below.
6. Cursor advances (`run.pos = run.pos + 1`) and `run:sync()` runs again.
7. When cursor moves past end, final non-`nil` input is pushed to output queue.
8. Final `run.input` is returned.

The loop is simple by design: resolve, prepare, execute, apply result, advance.

## Handler Return Semantics (Run Interpretation)

Run-level interpretation is strict and simple:

- `false`: stop this run path immediately.
- non-`nil` (except `false`): replace `run.input`.
- `nil`: preserve existing `run.input`.

This is the core contract that async boundary segments rely on.

## Async Boundary Continuation Flow

Async boundary handlers use stop-now/continue-later behavior:

1. boundary `handler(run)` transfers continuation ownership to async transport (queue/task/pending)
2. boundary returns `false` to stop inline path now
3. later, continuation run calls `:next(...)` to resume downstream

Why this matters:

- it prevents double flow (inline path continuing while async path also resumes)
- it keeps run control deterministic (all deferred progress is explicit `:next(...)`)

Continuation tracking:

- ownership is run-centric
- `run.continuation` is the tracking field
- single-slot continuation tracking is acceptable

Related boundary usage: [`/doc/segment.md`](/doc/segment.md), [`/doc/line.md`](/doc/line.md).

## `run:next(element?)`

`run:next()` advances cursor by one and continues execution.

- `run:next(element)` replaces `run.input` before advancing
- `run:next()` advances with current input unchanged
- if already at end, it pushes to output directly

This is the primitive used by continuation runs to re-enter pipeline flow.

## Fan-Out and Independence

### `run:emit(element, strategy?)`

`run:emit` is fan-out convenience. It creates a continuation run via strategy and immediately `:next()`s it.

Strategies:

- `self`: mutate and continue same run path (lowest overhead)
- `clone`: lightweight child run with shared ownership (low overhead)
- `fork`: more independent run context (higher overhead)

### `run:clone(new_input)` and `run:fork(new_input?)`

- `run:clone(new_input)` creates a lightweight child run with parent read-through; child owns `input` and `pos`.
- `run:fork(new_input?)` is clone plus ownership break for key fields (`own("pipe")`, `own("fact")`).

## Pipe Synchronization (`run:sync()`)

Runs track `_rev` and reconcile position against pipe splice journal.

This allows in-flight runs to survive dynamic pipe mutation (for example resolver-driven splices) without losing cursor correctness.

## Ownership Controls (`run:own`, `run:set_fact`)

`run:own(field)` explicitly breaks read-through for that field.

Special handling:

- `own("pipe")` clones current pipe for independent mutation.
- `own("fact")` snapshots visible fact state into run-owned table.

`run:set_fact(name, value?)` lazily creates run-local fact overlay with fallback to line fact.

## Control Runs and Protocol Fields

Not every run carries a normal data payload. Protocol runs use run fields as control plane.

Completion protocol fields:

- `pipe_line_protocol = true`: marks run as protocol/control run
- `mpsc_completion`: control signal (`hello`, `done`, `shutdown`)
- `mpsc_completion_name`: optional attribution/identity

These are interpreted by protocol-aware segments (not by run core itself).

## Practical Debug Checklist

When run behavior feels wrong, check:

1. handler returns `false` at async handoff boundaries.
2. continuation resumes exactly once.
3. `run:sync()` behavior after runtime pipe splices.
4. `run.input` update/keep/stop semantics match handler returns.
5. output queue receives final non-`nil` payload.

## Relationship to Other Core Components

Run sits in the middle of the core model:

- **Line** creates runs and orchestrates lifecycle around execution. See [`/doc/line.md`](/doc/line.md).
- **Segment** defines handler/lifecycle semantics run executes. See [`/doc/segment.md`](/doc/segment.md).
- **Registry** resolves named segment entries used during run execution. See [`/doc/registry.md`](/doc/registry.md).
