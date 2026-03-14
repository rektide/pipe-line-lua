# ADR: Transport Policy Interface on Top of Core Handler Contract

- Status: Proposed
- Date: 2026-02-27
- Decision makers: pipe-line maintainers

## Decision

Transport wrappers (`defineMpsc`, `defineSafeTask`, `defineTask`) build on the core segment contract from [`/lua/pipe-line/segment/define.lua`](/lua/pipe-line/segment/define.lua) and keep `handler(run)` as the per-message entrypoint.

- `handler_async` is not part of the core contract.
- `configure_segment` is removed from transport policy contract.
- transport policies use `handler` naming (not `dispatch`) for per-message transport behavior.

## Context

The decomposition work clarified that segment authoring has distinct layers:

- spec-time shape and defaults
- per-instance setup (`init`)
- per-run behavior (`handler(run)`)

When transport policy mutates spec shape (`configure_segment`) and uses a separate dispatch vocabulary, the model becomes hard to follow.

Related docs:

- [`/doc/segment.md`](/doc/segment.md)
- [`/doc/line.md`](/doc/line.md)
- [`/doc/run.md`](/doc/run.md)

## Core contract

Core segment lifecycle remains:

- `init(context)`
- `ensure_prepared(context)`
- `handler(run)`
- `ensure_stopped(context)`

`handler(run)` is the canonical "start processing this run" verb.

## Transport policy contract

Transport policy objects should expose:

- `type: string`
- `ensure_prepared(segment, context, runtime) -> awaitable|awaitable[]|nil`
- `handler(segment, run, runtime) -> any` (optional)
- `ensure_stopped(segment, context, runtime) -> awaitable|awaitable[]|nil`

Stop-strategy specializations may add:

- `ensure_stopped_drain(...)`
- `ensure_stopped_immediate(...)`

as defined by [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md).

## Continuation ownership

Continuation is run-owned. If tracking is needed, store it on:

- `run.continuation`

This ADR does not require a continuation map shape. A single continuation slot is acceptable.

## Boundary of responsibilities

- **Segment defaults**: set by segment constructor/wrapper and `init`.
- **Per-instance runtime state**: set by `init` on segment instance.
- **Per-run control flow**: initiated by `handler(run)`.
- **Transport lifecycle mechanics**: `ensure_prepared`/`ensure_stopped` policy hooks.
- **Transport message mechanics**: optional `transport.handler(...)` using handler naming.
- **Protocol pass-through rules**: remain in [`/lua/pipe-line/segment/define.lua`](/lua/pipe-line/segment/define.lua).

## Rationale

- keeps handler vocabulary stable for segment authors
- removes parallel message-processing verbs from policy layer
- aligns transport decomposition with base segment docs
- reduces cognitive load in wrapper internals

## Consequences

Positive:

- clearer relationship between segment contract and transport policy
- less hidden mutation surface in policy objects
- easier to reason about run-centric continuation flow

Tradeoffs:

- wrapper construction and `init` need explicit defaults where previously injected by policy
- transport internals still need discipline to avoid re-introducing alternate vocabulary

## Implementation direction

1. Keep transport builder focused on lifecycle + handler composition.
2. Remove `configure_segment` use from transport policies.
3. Keep transport per-message behavior on `handler` naming and run-owned continuation flow.
4. Keep segment docs authoritative for author-facing handler contract.

## Deferred / not decided

- whether `run.continuation` should be pre-created or allocated lazily
