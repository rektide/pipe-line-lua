# Driver as Segment (Discovery)

This note reframes driver work around a clear position: **driver should be implemented as a segment type**, not as a detached utility-only abstraction.

The goal is to align driver behavior with the current architecture:

- `handler(run)` remains the run-facing verb
- lifecycle stays in `init` / `ensure_prepared` / `ensure_stopped`
- continuation ownership remains run-centric

This draft also clarifies how `mpsc_handoff` works today, since that is the most relevant reference path.

## Reference Materials

| Area | Source | Why it matters |
|------|--------|----------------|
| Current driver utility | [`/lua/pipe-line/driver.lua`](/lua/pipe-line/driver.lua) | Timer scheduling utility surface (`interval`, `rescheduler`) |
| Current mpsc segment | [`/lua/pipe-line/segment/mpsc.lua`](/lua/pipe-line/segment/mpsc.lua) | Current explicit async boundary segment entrypoint |
| MPSC transport policy | [`/lua/pipe-line/segment/define/transport/mpsc.lua`](/lua/pipe-line/segment/define/transport/mpsc.lua) | Existing reusable async transport shape |
| Task transport policy | [`/lua/pipe-line/segment/define/transport/task.lua`](/lua/pipe-line/segment/define/transport/task.lua) | Safe/unsafe task-backed async dispatch options |
| Transport composition skeleton | [`/lua/pipe-line/segment/define/transport.lua`](/lua/pipe-line/segment/define/transport.lua) | How transports layer on handler/lifecycle contract |
| Consumer implementation | [`/lua/pipe-line/consumer.lua`](/lua/pipe-line/consumer.lua) | Current queue-consumer lifecycle and stop behavior constraints |
| Segment model guide | [`/doc/segment.md`](/doc/segment.md) | Canonical segment contract and async/completion handoff strategy |
| Run model guide | [`/doc/run.md`](/doc/run.md) | Continuation semantics and run execution invariants |
| Line model guide | [`/doc/line.md`](/doc/line.md) | Lifecycle orchestration, selectors, stop integration |
| Transport ADR | [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md) | Handler-first transport contract direction |
| Stop strategy ADR (proposed) | [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md) | Future stop strategy contract constraints |

## Current State Review

## Driver today is utility-only

`driver.lua` currently provides two timer wrappers:

- `interval(ms, callback)`
- `rescheduler(config, callback)`

Both expose `{ start, stop }` (plus `reset` for rescheduler) and directly run callbacks via `vim.uv` timers.

What is missing relative to segment architecture:

- no `handler(run)` entrypoint
- no per-segment lifecycle context (`init`, `ensure_prepared`, `ensure_stopped`)
- no continuation semantics (`return false` then `continuation:next(...)`)
- no integration with line-level stop/wait orchestration

Implication: useful utility, but not yet aligned with the new async stage architecture.

## How mpsc works today (important reference)

`mpsc_handoff` is now composed through transport wrappers, not bespoke segment logic:

- wrapper: [`/lua/pipe-line/segment/define/mpsc.lua`](/lua/pipe-line/segment/define/mpsc.lua)
- policy impl: [`/lua/pipe-line/segment/define/transport/mpsc.lua`](/lua/pipe-line/segment/define/transport/mpsc.lua)
- composition core: [`/lua/pipe-line/segment/define/transport.lua`](/lua/pipe-line/segment/define/transport.lua)

Execution/lifecycle flow for mpsc today:

1. `mpsc_handoff` segment is created by `segment.mpsc_handoff(...)`.
2. On prepare, mpsc transport ensures queue defaults and optionally starts queue consumer (`line.auto_start_consumers`).
3. On `handler(run)`, transport builds continuation via `common.prepare_continuation(...)`, pushes envelope, and returns `false`.
4. Consumer pops envelope and calls `continuation:next()`.
5. On stop, transport requests queue consumer stop and returns awaitable(s) to line stop aggregation.

This is already close to the right abstraction for driver-as-segment.

## Why mpsc still feels unclear

Mpsc now has shared transport composition, but understanding requires reading multiple layers:

- `segment/mpsc.lua` (segment entry)
- `define/mpsc.lua` (wrapper composition)
- `transport/mpsc.lua` (actual behavior)
- `consumer.lua` (runtime loop)

That layering is good, but it hides behavior unless documented as one flow.

This document should become that bridge for driver design decisions.

## What is generalized vs not yet generalized

What is already generalized:

- transport interface pattern (`ensure_prepared`, `handler`, `ensure_stopped`)
- run-owned continuation handoff semantics

What is still uneven:

- stop strategy in task transport is ADR-defined but still TODO in implementation/docs
- `consumer.lua` stop/wait path still uses timeout-style waits (`task:await(timeout, interval)`), which is older behavior relative to newer async direction
- `driver.lua` sits outside the transport contract and lifecycle surface

## Design Direction

Treat driver as a **segment type** with explicit lifecycle and handler semantics.

Potential shape:

- driver segment owns scheduling state (timer/backoff) in `init`
- driver segment starts scheduler in `ensure_prepared`
- driver segment stops scheduler in `ensure_stopped`
- driver `handler(run)` defines what is enqueued/triggered and when continuation resumes

In other words:

- keep transport contract
- expose driver through segment contract
- no parallel API surface outside segment model

## Driver vs MPSC (target comparison)

| Dimension | `mpsc_handoff` today | `driver` as segment target |
|-----------|----------------------|----------------------------|
| Segment type | yes (`mpsc_handoff`) | yes (`driver_*` segment type) |
| `handler(run)` | hands off continuation and returns `false` | should do same where async boundary is intended |
| Prepare hook | starts/ensures consumer | starts/ensures scheduler |
| Stop hook | stops consumer, returns awaitable(s) | stops scheduler, returns awaitable(s) |
| Runtime state owner | segment + line consumer maps | segment instance state (`init`) |
| External utility dependency | queue + consumer | timer utility + possibly queue/continuations |
| Contract alignment | mostly aligned | should be fully aligned |

## Initial Implementation Prompt

Use the following prompt for implementation work:

```text
Implement driver as a first-class segment type that uses existing transport semantics.

Constraints
- Keep core segment contract: handler(run), init, ensure_prepared, ensure_stopped.
- Keep run-owned continuation model (run.continuation).
- Do not introduce handler_async.
- Do not bypass line lifecycle orchestration.

Goals
1) Add driver segment factory/type(s) (e.g. interval and rescheduler variants) under segment model.
2) Ensure lifecycle integration:
   - start scheduling in ensure_prepared
   - stop scheduling in ensure_stopped
3) Keep handler-first continuation semantics:
   - if handoff occurs, handler returns false
   - continuation resumes explicitly later
4) Add tests proving no duplicate flow, correct shutdown, and scheduler start/stop idempotence.

References
- /doc/segment.md
- /doc/run.md
- /doc/line.md
- /doc/adr/adr-transport-policy-interface.md
- /lua/pipe-line/segment/define/transport.lua
- /lua/pipe-line/driver.lua
- /lua/pipe-line/segment/mpsc.lua
- /lua/pipe-line/segment/define/transport/mpsc.lua

Non-goals for first pass
- full stop_type strategy implementation
- broad API redesign beyond introducing driver as a segment type
```

## Suggested Incremental Plan

1. Define driver segment API surface (config schema + type names).
2. Implement segment `init` state for timer/backoff and continuation tracking.
3. Implement `ensure_prepared`/`ensure_stopped` idempotently.
4. Implement `handler(run)` continuation behavior explicitly.
5. Add tests for start/stop idempotence, continuation single-resume, and close-time shutdown.
6. Reassess shared stop/wait helpers between driver and consumer.

## Key Risks and Checks

| Risk | Why it matters | Check |
|------|----------------|-------|
| Duplicate continuation flow | Could process same message twice | Assert driver boundary handler returns `false` and continuation resumes once |
| Lifecycle drift | Scheduler runs outside line stop model | Verify `close()` fully stops scheduled activity |
| Transport contract drift | Reintroducing parallel verbs (`dispatch`, `handler_async`) | Keep handler-first contract from ADR |
| Incomplete stop semantics | Stop strategy still TODO | Keep explicit TODO markers and avoid pretending completion |
| Hidden state ownership | Timer state leaks across lines | Keep state in per-segment instance via `init` |

## Open Questions

1. Should first driver segment be boundary-style (returns `false`) or transformer-style (inline) by default?
2. Should driver segment reuse mpsc envelope transport immediately or start with local task scheduling only?
3. Should `interval` and `rescheduler` be one segment with mode, or two explicit segment types?
4. How should stop strategy TODOs interact with scheduler teardown in first pass?

## Draft Conclusion

Docs are moving in the right direction, and mpsc already demonstrates the segment+transport composition pattern we should follow. The next step is not another standalone driver utility layer; it is to implement driver directly as a segment type that cleanly participates in existing handler and lifecycle contracts.
