# ADR: Stop Semantics, Drain-First, and Explicit Cancel Signal

- Status: Proposed
- Date: 2026-02-27
- Decision makers: termichatter maintainers

## Decision

For task-based async segment transports, default stop behavior is **drain-first**.

- `ensure_stopped` should wait for full pending-drain completion by default.
- `cancel_immediate` is an explicit opt-in behavior, not the default.

We also introduce an explicit cancel signal concept with optional acknowledgement chaining.

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

- `drain_done`: all queued continuations acknowledged
- `cancel_done`: cancel signal observed and acknowledged by worker
- `stopped_done`: runner fully stopped

Default `ensure_stopped` behavior:

1. issue cancel signal
2. allow normal drain path to finish (unless `cancel_immediate`)
3. resolve when `drain_done` and `stopped_done` are satisfied

`cancel_immediate` behavior:

- bypass drain guarantees where permitted
- stop runner promptly

## Lazy signal requirement

Cancel signal and related futures should be created lazily.

Goal:

- avoid per-segment object overhead when cancel path is unused
- still provide explicit signal semantics when needed

Likely implementation direction:

- per-segment state object with lazy fields
- optionally metatable-backed lazy initialization

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
   - `stop.type = "drain" | "cancel_immediate"`
2. Introduce lazy cancel/drain/stopped signal state in task transport.
3. Update `ensure_stopped` to default to drain-first.
4. Add tests covering:
   - default drain behavior
   - immediate cancel behavior
   - cancel acknowledgement ordering

## Deferred / not decided

- Exact public API names for stop policy config.
- Whether `cancel_done` should be externally exposed or internal-only.
