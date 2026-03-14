# Driver as Async Stage (Discovery)

This note is an initial draft for turning `driver` from a timer utility into a first-class async stage pattern.

It includes:

- a review of current implementation and docs
- a design prompt for implementation work
- a concrete direction that reuses the current transport model (`handler(run)`, lifecycle hooks, run-owned continuation)

## Reference Materials

| Area | Source | Why it matters |
|------|--------|----------------|
| Current driver utility | [`/lua/pipe-line/driver.lua`](/lua/pipe-line/driver.lua) | Today this is timer scheduling only, not a segment transport |
| Current mpsc segment | [`/lua/pipe-line/segment/mpsc.lua`](/lua/pipe-line/segment/mpsc.lua) | Current explicit async boundary entrypoint |
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

## 1) Driver today is not a segment transport

`driver.lua` currently provides two timer wrappers:

- `interval(ms, callback)`
- `rescheduler(config, callback)`

Both expose `{ start, stop }` (plus `reset` for rescheduler) and directly run callbacks via `vim.uv` timers. There is no continuation awareness, no segment lifecycle integration, and no stop strategy integration.

Implication: useful utility, but not yet aligned with the new async stage architecture.

## 2) MPSC path has become transport-oriented

`mpsc_handoff` is now composed through transport wrappers, not bespoke segment logic:

- segment wrapper: [`/lua/pipe-line/segment/define/mpsc.lua`](/lua/pipe-line/segment/define/mpsc.lua)
- policy impl: [`/lua/pipe-line/segment/define/transport/mpsc.lua`](/lua/pipe-line/segment/define/transport/mpsc.lua)
- composition core: [`/lua/pipe-line/segment/define/transport.lua`](/lua/pipe-line/segment/define/transport.lua)

This is the right direction toward reusable async stage mechanics.

## 3) We are partly there on “general async utility,” but not complete

What is already generalized:

- transport interface pattern (`ensure_prepared`, `handler`, `ensure_stopped`)
- run-owned continuation handoff semantics

What is still uneven:

- stop strategy in task transport is ADR-defined but still TODO in implementation/docs
- `consumer.lua` stop/wait path still uses timeout-style waits (`task:await(timeout, interval)`), which is older behavior relative to newer async direction
- `driver.lua` sits outside the transport contract and lifecycle surface

## Design Direction

Treat driver as an async stage primitive that can be composed as transport behavior, not as a side utility.

Potential shape:

- driver policy schedules when continuation work is attempted
- transport policy still owns how continuation is carried (`queue`, `task`, `pending`)
- line lifecycle owns start/stop orchestration through existing hooks

In other words:

- do not replace transport with driver
- compose driver scheduling with transport execution

## Initial Implementation Prompt

Use the following prompt for implementation work:

```text
Refactor pipe-line driver into an async stage scheduling primitive that composes with transport policies.

Constraints
- Keep core segment contract: handler(run), init, ensure_prepared, ensure_stopped.
- Keep run-owned continuation model (run.continuation).
- Do not introduce handler_async.
- Do not bypass line lifecycle orchestration.

Goals
1) Add a driver-aware transport or scheduling adapter that can wrap existing mpsc/task transport behavior.
2) Ensure lifecycle integration:
   - start scheduling in ensure_prepared
   - stop scheduling in ensure_stopped
3) Preserve current mpsc_handoff semantics (return false after handoff, resume continuation later).
4) Add tests proving no duplicate flow and correct shutdown behavior.

References
- /doc/segment.md
- /doc/run.md
- /doc/line.md
- /doc/adr/adr-transport-policy-interface.md
- /lua/pipe-line/segment/define/transport.lua
- /lua/pipe-line/driver.lua

Non-goals for first pass
- full stop_type strategy implementation
- broad API redesign beyond minimal composable driver stage integration
```

## Suggested Incremental Plan

1. Introduce a small driver scheduling adapter (no behavior change yet).
2. Integrate adapter into one transport path (mpsc first).
3. Add lifecycle tests for start/stop and no-duplicate resume.
4. Add one example in docs showing timer-scheduled continuation flow.
5. Reassess whether consumer and driver should share a common stop/wait helper.

## Key Risks and Checks

| Risk | Why it matters | Check |
|------|----------------|-------|
| Duplicate continuation flow | Could process same message twice | Assert boundary handler returns `false` and continuation resumes once |
| Lifecycle drift | Scheduler runs outside line stop model | Verify `close()` fully stops scheduled activity |
| Transport contract drift | Reintroducing parallel verbs (`dispatch`, `handler_async`) | Keep handler-first contract from ADR |
| Incomplete stop semantics | Stop strategy still TODO | Keep explicit TODO markers and avoid pretending completion |

## Open Questions

1. Should driver scheduling be represented as a dedicated segment type or transport adapter-only concern?
2. Should mpsc and task transports both support the same scheduling hooks from day one?
3. Should driver interval/backoff state be segment-instance-owned (`init`) or transport-state-owned?
4. How should stop strategy TODOs interact with scheduler teardown in first pass?

## Draft Conclusion

The docs are broadly moving in the right direction. Implementation has started moving from bespoke async behavior to transport composition, but driver remains outside that architecture. The next useful step is to compose driver scheduling into transport lifecycle without changing the core segment/run contract.
