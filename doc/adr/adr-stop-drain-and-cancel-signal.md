# ADR: Stop Semantics, Drain-First, and Explicit Cancel Signal

- Status: Proposed
- Date: 2026-02-27
- Decision makers: termichatter maintainers

## Decision

For task-based async segment transports, default stop behavior is **drain-first**.

- `ensure_stopped` should wait for full pending-drain completion by default.
- `stop_immediate` is an explicit opt-in behavior, not the default.

We also introduce an explicit cancel signal concept with optional acknowledgement chaining.

Stop strategy naming and config:

- strategy field: `stop_type`
- allowed values: `"stop_drain" | "stop_immediate"`
- default: `stop_type = "stop_drain"`

## Context

Current async segment lifecycle has multiple completion layers:

- local queue/pending drained
- runner task stopped
- segment stop handle resolved

Without explicit cancel signaling, these layers are harder to reason about and to compose.

Relevant files:

- [`/lua/termichatter/segment/define/transport/task.lua`](/lua/termichatter/segment/define/transport/task.lua)
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)

## Model

Task transport state should separate at least these completion concepts:

- `stopped_drain`: drain completion signal
- `stopped_immediate`: immediate-stop completion signal
- `stopped`: aggregate stop completion signal

These `stopped_*` values:

- are state signals, not actions
- are created lazily on demand
- do not imply procedure execution on read

Action verbs are separate procedures:

- `ensure_drain(...)` performs drain semantics
- `ensure_immediate(...)` performs immediate-stop semantics

Default `ensure_stopped` behavior:

1. issue cancel signal
2. execute `ensure_drain(...)`
3. resolve `stopped` when drain+runner termination conditions are met

`stop_immediate` behavior:

- bypass drain guarantees where permitted
- execute `ensure_immediate(...)`

Run specifiers/variants may contribute to the stop determiner, but they are not required to append themselves into `task_or_tasks` returned from lifecycle hooks. This is intentional flexibility.

## Lazy signal requirement

Cancel signal and related futures should be created lazily.

Goal:

- avoid per-segment object overhead when cancel path is unused
- still provide explicit signal semantics when needed

Likely implementation direction:

- per-segment state object with lazy fields
- optionally metatable-backed lazy initialization
- lazy creation for `stopped_drain`, `stopped_immediate`, and `stopped`

## Rationale

- Matches desired operational default: graceful stop and full drain.
- Makes cancellation explicit and composable across lifecycle layers.
- Reduces ambiguity between "asked to stop" and "fully stopped".

## Consequences

Positive:

- More predictable shutdown semantics.
- Clearer test surface for stop/cancel edge cases.
- Better base for future policy-specific stop tuning.

Tradeoffs:

- More state modeling in task transport.
- Slightly more ceremony than immediate cancel.

## Implementation direction

1. Add explicit stop policy fields to task transport config:
   - `stop_type = "stop_drain" | "stop_immediate"`
2. Introduce explicit stop strategy modules:
   - [`/lua/termichatter/segment/define/transport/stop/drain.lua`](/lua/termichatter/segment/define/transport/stop/drain.lua)
   - [`/lua/termichatter/segment/define/transport/stop/immediate.lua`](/lua/termichatter/segment/define/transport/stop/immediate.lua)
3. Introduce lazy cancel/drain/stopped signal state in task transport.
4. Update `ensure_stopped` to default to `stop_drain`.
5. Add tests covering:
   - default drain behavior
   - immediate cancel behavior
   - cancel acknowledgement ordering
   - lazy signal materialization
   - `task_or_tasks` optional participation by run specifiers

## Deferred / not decided

- Exact surface for exposing `stopped_drain` and `stopped_immediate` to segment authors.
- Whether stop strategy selection can be changed per-run or is segment-fixed.
