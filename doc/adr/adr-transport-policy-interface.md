# ADR: Transport Policy Interface on Top of Core Segment Contract

- Status: Proposed
- Date: 2026-02-27
- Decision makers: termichatter maintainers

## Decision

Transport wrappers (`defineMpsc`, `defineSafeTask`, `defineTask`) must build on the core segment contract from [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua), not introduce parallel segment-shape rules.

Transport policy should be narrowly scoped to dispatch/runtime behavior.

`configure_segment` is removed from policy interface.

## Context

The current transport decomposition improved readability but still carried a policy hook (`configure_segment`) that conflates concerns:

- spec-time segment shape/defaults
- instance-time state initialization
- run-time dispatch behavior

Base docs already indicate these are separate layers:

- segment authoring: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- instancing model: [`/doc/segment-instancing.md`](/doc/segment-instancing.md)

## Core segment contract (unchanged)

Segment contract remains centered on:

- `init(context)`
- `ensure_prepared(context)`
- `handler(run)`
- `ensure_stopped(context)`

`init` is the preferred place for per-instance defaults/state setup.

## Transport policy contract (proposed)

Transport policy objects should expose:

- `type: string` (transport identity, for example `mpsc`, `safe_task`, `task`)
- `ensure_prepared(segment, context, runtime) -> awaitable|awaitable[]|nil`
- `dispatch(segment, run, continuation, runtime)`
- `ensure_stopped(segment, context, runtime) -> awaitable|awaitable[]|nil`

No `configure_segment` hook.

## Boundary of responsibilities

- **Segment spec defaults**: set in segment table construction/wrapper constructor.
- **Per-instance defaults**: set in `init`.
- **Transport runtime behavior**: transport policy hooks above.
- **Protocol wrapping**: stays in [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua).

## Rationale

- Keeps transport policies focused and auditable.
- Avoids hidden spec mutation paths.
- Aligns transport wrappers with documented segment lifecycle model.
- Makes `init` the single canonical instance-setup hook.

## Consequences

Positive:

- clearer authoring model from base docs to transport wrappers
- fewer places where defaults can be unexpectedly injected
- easier review of transport logic (dispatch + lifecycle only)

Tradeoffs:

- wrapper constructors may need to be explicit about required defaults
- some existing code paths using `configure_segment` need migration

## Implementation direction

1. Update transport builder in [`/lua/termichatter/segment/define/transport.lua`](/lua/termichatter/segment/define/transport.lua) to remove `configure_segment` calls.
2. Move any remaining default injection into wrapper construction and/or `init` methods.
3. Keep transport policies focused on `ensure_prepared`, `dispatch`, `ensure_stopped`.
4. Update segment docs/examples to show `init`-based state creation where needed.

## Deferred / not decided

- whether transport `type` should be validated at runtime in debug mode
- whether transport metrics hooks should be part of `runtime` contract
