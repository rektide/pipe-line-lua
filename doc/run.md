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

| Access surface | Field / behavior | Notes |
|----------------|------------------|-------|
| run-owned | `type = "run"` | Identity marker |
| run-owned | `line` | Owning line reference |
| run-owned | `pipe` | Active pipe reference for this run |
| run-owned | `pos` | Cursor position in pipe |
| run-owned | `input` | Current element/payload |
| run-owned | `_rev` | Pipe revision snapshot used by `sync()` |
| read-through | `run[k] -> line[k]` | If key is not run-owned, lookup falls through to line |
| practical effect | `run.source`, `run.filter`, `run.registry`, etc. | Handler can read line-scoped values without explicit argument plumbing |

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

| `auto_start` value | Startup behavior |
|--------------------|------------------|
| omitted / `true` | `run:execute()` runs immediately |
| `false` | run is created without immediate execution |

## Execution Algorithm (`run:execute()`)

`run:execute()` is the core loop.

| Step | Operation | Why |
|------|-----------|-----|
| 1 | `run:sync()` | Reconcile cursor with splice journal changes |
| 2 | read current pipe entry | Identify next segment to execute |
| 3 | resolve/materialize segment | Convert names/factories into executable segment form |
| 4 | call `seg:ensure_prepared(context)` if present | Ensure segment-side readiness before handler call |
| 5 | resolve and invoke `handler(run)` | Execute per-message segment logic |
| 6 | apply return semantics | Decide stop/update/keep behavior for run state |
| 7 | increment `run.pos` and sync again | Advance cursor safely across potential pipe mutations |
| 8 | on completion, push final `run.input` to output if non-`nil` | Emit terminal output |
| 9 | return final `run.input` | Provide caller-visible result |

## Handler Return Semantics (Run Interpretation)

Run-level interpretation is strict and simple:

| Handler result | Run behavior |
|----------------|--------------|
| `false` | stop this run path immediately |
| non-`nil` (except `false`) | replace `run.input` |
| `nil` | preserve existing `run.input` |

This is the core contract that async boundary segments rely on.

## Async Boundary Continuation Flow

Async boundary handlers use stop-now/continue-later behavior:

| Phase | Action |
|-------|--------|
| handoff | boundary `handler(run)` transfers continuation ownership (queue/task/pending) |
| inline stop | boundary returns `false` |
| deferred resume | continuation run later calls `:next(...)` from downstream position |

Why this matters:

| Guarantee | Outcome |
|-----------|---------|
| no double flow | Avoids inline path continuing while async path also resumes later |
| explicit continuation | Keeps run control semantics deterministic |

Continuation tracking:

| Field | Ownership | Shape |
|-------|-----------|-------|
| `run.continuation` | run-owned | flexible; single-slot is acceptable |

Related boundary usage: [`/doc/segment.md`](/doc/segment.md), [`/doc/line.md`](/doc/line.md).

## `run:next(element?)`

`run:next()` advances cursor by one and continues execution.

| Case | Behavior |
|------|----------|
| `run:next(element)` | replace `run.input`, then advance |
| `run:next()` | keep current `run.input`, then advance |
| cursor at end | push to output directly |

This is the primitive used by continuation runs to re-enter pipeline flow.

## Fan-Out and Independence

### `run:emit(element, strategy?)`

| Property | Behavior |
|----------|----------|
| purpose | fan-out convenience |
| mechanism | creates continuation run via strategy and immediately `:next()` it |

Strategies:

| Strategy | Behavior | Cost profile |
|----------|----------|--------------|
| `self` | mutate and continue same run path | lowest overhead |
| `clone` | lightweight child run with shared ownership model | low overhead |
| `fork` | more independent run context | higher overhead |

### `run:clone(new_input)` and `run:fork(new_input?)`

| Method | Behavior |
|--------|----------|
| `run:clone(new_input)` | creates lightweight child run with parent read-through; child owns `input` and `pos` |
| `run:fork(new_input?)` | clone plus ownership break for key fields (`own("pipe")`, `own("fact")`) |

## Pipe Synchronization (`run:sync()`)

Runs track `_rev` and reconcile position against pipe splice journal.

This allows in-flight runs to survive dynamic pipe mutation (for example resolver-driven splices) without losing cursor correctness.

## Ownership Controls (`run:own`, `run:set_fact`)

`run:own(field)` explicitly breaks read-through for that field.

Special handling:

| Field | `own(field)` behavior |
|-------|------------------------|
| `"pipe"` | clones current pipe for independent mutation |
| `"fact"` | snapshots visible fact state into run-owned table |

`run:set_fact(name, value?)` lazily creates run-local fact overlay with fallback to line fact.

## Control Runs and Protocol Fields

Not every run carries a normal data payload. Protocol runs use run fields as control plane.

Completion protocol fields:

| Field | Meaning |
|-------|---------|
| `pipe_line_protocol = true` | marks run as protocol/control run |
| `mpsc_completion` | control signal (`hello`, `done`, `shutdown`) |
| `mpsc_completion_name` | optional identity/attribution for control signal |

These are interpreted by protocol-aware segments (not by run core itself).

## Practical Debug Checklist

When run behavior feels wrong, check:

| Checkpoint | Why |
|------------|-----|
| handler returns `false` at async handoff boundaries | prevents duplicate inline + async continuation flow |
| continuation resumes exactly once | avoids duplicate downstream execution |
| `run:sync()` behavior after pipe splices | catches cursor drift after runtime pipe mutation |
| `run.input` update/keep/stop semantics | validates handler return contract usage |
| output queue receives final non-`nil` payload | validates terminal output push path |

## Relationship to Other Core Components

| Component | Relationship to Run |
|-----------|---------------------|
| [`/doc/line.md`](/doc/line.md) | creates runs and orchestrates lifecycle around execution |
| [`/doc/segment.md`](/doc/segment.md) | defines handler/lifecycle semantics that run executes |
| [`/doc/registry.md`](/doc/registry.md) | resolves named segment entries used during run execution |
