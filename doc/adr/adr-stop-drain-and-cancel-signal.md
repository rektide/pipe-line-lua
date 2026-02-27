# ADR: Strategy-Specific Stop Futures and Verbs

- Status: Proposed
- Date: 2026-02-27
- Decision makers: termichatter maintainers

## Decision

Task transport stop behavior is strategy-driven with explicit strategy verbs and strategy futures.

- strategy field: `stop_type`
- supported values: `"stop_drain" | "stop_immediate"`
- default: `stop_type = "stop_drain"`

`ensure_stopped` must wait for the strategy selected by `stop_type`.

## API shape

`ensure_stopped` stays as the generic lifecycle entrypoint, and dispatches to explicit verbs:

- `ensure_stopped_drain(...)`
- `ensure_stopped_immediate(...)`

The strategy-specific verbs enact behavior. They are actions.

## Stop futures

Each task transport segment owns strategy futures created on start (during prepare/start of runner):

- `stopped_drain` (Coop future)
- `stopped_immediate` (Coop future)
- `stopped` (Coop future; aggregate for the segment)

These are state futures, not action triggers.

- They are created when the segment starts.
- They resolve when their corresponding completion condition is met.
- Reading them does not perform stop logic.

## Lifecycle semantics

`ensure_stopped` behavior:

1. read `stop_type`
2. call the matching strategy verb (`ensure_stopped_drain` or `ensure_stopped_immediate`)
3. wait for the corresponding strategy future
4. resolve/return `stopped` when the segment stop contract is complete

### `stop_drain`

- preferred default
- drains pending work before final stop resolution
- resolves `stopped_drain` when drain completion conditions are met

### `stop_immediate`

- explicit opt-in
- prioritizes prompt stop over full drain guarantees
- resolves `stopped_immediate` when immediate-stop conditions are met

## Aggregation and freedom

Stop completion can include multiple contributors (segment state, run specifiers, transport internals).

Important rule:

- contributors do not have to append themselves into `task_or_tasks` returned by lifecycle hooks

This flexibility is intentional; stop determination may be broader than the concrete awaitables returned by a specific hook call.

## Context

This ADR refines stop semantics for task transport decomposition work.

Relevant implementation files:

- [`/lua/termichatter/segment/define/transport/task.lua`](/lua/termichatter/segment/define/transport/task.lua)
- [`/lua/termichatter/segment/define/transport.lua`](/lua/termichatter/segment/define/transport.lua)
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)

Related discovery docs:

- [`/doc/discovery/mpsc-decomposition.md`](/doc/discovery/mpsc-decomposition.md)
- [`/doc/discovery/adr-async-boundary-segments.md`](/doc/discovery/adr-async-boundary-segments.md)

## Implementation direction

1. Introduce strategy modules:
   - [`/lua/termichatter/segment/define/transport/stop/drain.lua`](/lua/termichatter/segment/define/transport/stop/drain.lua)
   - [`/lua/termichatter/segment/define/transport/stop/immediate.lua`](/lua/termichatter/segment/define/transport/stop/immediate.lua)
2. Add strategy verb methods in task transport:
   - `ensure_stopped_drain`
   - `ensure_stopped_immediate`
3. Create `stopped_drain`, `stopped_immediate`, and `stopped` futures on segment start.
4. Route `ensure_stopped` through `stop_type` dispatch and await strategy-specific completion.
5. Add tests for:
   - default `stop_drain`
   - explicit `stop_immediate`
   - strategy future resolution ordering
   - aggregate `stopped` semantics

## Deferred / not decided

- exact precedence rules if run-level overrides attempt to change stop strategy
- whether strategy futures are public API or documented internal state only
