# ADR: Transport Policy Interface Shape

- Status: Accepted
- Date: 2026-02-27
- Decision makers: termichatter maintainers

## Decision

Async segment wrappers (`defineMpsc`, `defineSafeTask`, `defineTask`) will be built from a shared transport skeleton plus injected transport policy objects.

The policy interface is the stable extension seam.

## Context

Recent refactors reduced wrapper size but still needed a clear, explicit contract for which logic is shared and which is transport-specific.

Relevant implementation files:

- [`/lua/termichatter/segment/define/transport.lua`](/lua/termichatter/segment/define/transport.lua)
- [`/lua/termichatter/segment/define/transport/mpsc.lua`](/lua/termichatter/segment/define/transport/mpsc.lua)
- [`/lua/termichatter/segment/define/transport/task.lua`](/lua/termichatter/segment/define/transport/task.lua)
- [`/lua/termichatter/segment/define/common.lua`](/lua/termichatter/segment/define/common.lua)

## Policy contract

Each policy object should implement the following shape:

- `type: string` transport identity (for example `mpsc`, `safe_task`, `task`)
- `configure_segment(segment)` optional segment defaults
- `ensure_prepared(segment, context, runtime) -> awaitable|awaitable[]|nil`
- `dispatch(segment, run, continuation, runtime)`
- `ensure_stopped(segment, context, runtime) -> awaitable|awaitable[]|nil`

`runtime` currently provides:

- `wrapped_handler`
- `handler_generator`

Additional runtime fields may be added intentionally, with this ADR as the source of truth.

## Naming decision

Transport identity should be represented by `type`, not `mode`.

- `mode` is considered a private compatibility detail where still present.
- New callsites and docs should describe transport by `type`.

## Rationale

- Makes shared lifecycle explicit and transport behavior injectable.
- Keeps wrappers tiny and declarative.
- Lets us add transports without changing wrapper skeleton logic.
- Provides a concrete review checklist for new transport policies.

## Consequences

Positive:

- Better readability and traceability of async behavior.
- Easier targeted testing per transport policy.
- Reduced need for large procedural wrapper modules.

Tradeoffs:

- Requires discipline to keep policy shape consistent.
- Runtime context growth must be controlled to avoid hidden coupling.

## Deferred / not decided

- Whether transport policies should expose optional metrics hooks in this interface.
- Whether `type` should be mandatory at runtime validation boundaries.
