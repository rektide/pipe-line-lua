# Post-Async Improvements: Stabilization and Next Iteration

> Status: Discovery
> Date: 2026-03-16
> Context: async v5 implementation is landed and test suite has been rewritten
> Related: [async5.md](/doc/discovery/async5.md)

This document captures implementation follow-ups after landing async v5 (segment-owned aspects, gater/executor split, AsyncOp, error-as-data).

It is focused on making the current design more deterministic and easier to operate, not on compatibility with legacy boundary transport behavior.

## Current State Assessment

The current architecture is a strong improvement over boundary-segment transport:

- async behavior is implicit from handler return type in [`/lua/pipe-line/run.lua`](/lua/pipe-line/run.lua)
- async control lives in segment-owned aspects resolved by line in [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)
- ingress control is explicit in gater implementations such as [`/lua/pipe-line/gater/inflight.lua`](/lua/pipe-line/gater/inflight.lua)
- async execution is concentrated in executor implementations such as [`/lua/pipe-line/executor/buffered.lua`](/lua/pipe-line/executor/buffered.lua)
- failures are carried as data through [`/lua/pipe-line/errors.lua`](/lua/pipe-line/errors.lua)

The model is clean and workable. Remaining work is mostly semantic hardening and operational polish.

## Priority Improvements

## P0: Stop and Drain Coordination

### Problem

`stop_drain` and `stop_immediate` are currently handled per-aspect. In edge timing windows, gater and executor can make conflicting decisions (for example, gater dispatches while executor is already non-accepting).

### Why this matters

- shutdown behavior can become non-deterministic
- pending work can settle with avoidable stop errors
- tests can be flaky under load timing

### Recommendation

Introduce a segment-local async lifecycle state machine in runtime context:

- `running`
- `stopping_drain`
- `stopping_immediate`
- `stopped`

Then both gater and executor read a shared state instead of independent stop flags. Runtime owns transition ordering.

### Success criteria

- no race where gater dispatches to a closed executor during drain
- deterministic behavior under repeated stop calls
- explicit tests for drain and immediate behavior under queued/inflight work

## P0: Clarify `ensure_prepared` Contract

### Problem

`run:_begin_async(...)` currently calls `aspect:ensure_prepared(...)` inline before dispatch, but runtime does not handle async returned awaitables there.

### Why this matters

- aspect authors may assume async preparation is supported
- returned awaitables can be silently ignored

### Recommendation

Pick one explicit contract and enforce it:

1. synchronous-only `ensure_prepared` (recommended), or
2. async prepare support with explicit awaiting and failure behavior

Given current architecture, synchronous-only is simpler and safer.

### Success criteria

- docs and type annotations match real behavior
- runtime errors if async awaitables are returned when unsupported

## P0: Executor Direct Mode Semantics

### Problem

[`/lua/pipe-line/executor/direct.lua`](/lua/pipe-line/executor/direct.lua) currently reuses buffered behavior and does not provide distinct low-overhead direct semantics.

### Why this matters

- config values imply behavior that is not actually distinct
- users cannot reason about performance differences

### Recommendation

Either:

- implement real direct handoff semantics, or
- remove/defer direct executor until real implementation exists

### Success criteria

- direct mode has clearly documented and tested behavior differences
- or it is removed from defaults/registry until ready

## P1: Naming and Configuration Consistency

### Problem

stop option naming currently supports aliases (`gate_stop_type` and `gater_stop_type` style fallback logic).

### Recommendation

Choose one canonical namespace and keep aliases only temporarily.

Recommended canonical keys:

- `gate_stop_type`
- `executor_stop_type`
- `gate_inflight_max`
- `gate_inflight_pending`
- `gate_inflight_overflow`

### Success criteria

- one canonical key family in docs and code
- optional compatibility aliases isolated and marked deprecated

## P1: Async Contract Strictness

### Problem

[`/lua/pipe-line/async.lua`](/lua/pipe-line/async.lua) supports duck-typed awaitables and both `await`/`pawait` methods. This is convenient, but can hide contract mismatches.

### Recommendation

Move toward explicit contract:

- `task_fn` remains first-class
- external awaitables require explicit `async.awaitable(...)` wrapping
- define and enforce one await method preference (`pawait` preferred)

### Success criteria

- fewer runtime surprises from foreign awaitables
- clearer authoring guidance

## P1: Segment Splice Lifecycle Completion

### Problem

when segments are removed or replaced in pipe mutations, aspect stop lifecycle is not fully enforced in all paths.

### Recommendation

Complete splice-aware cleanup in line lifecycle:

- on removal: call `ensure_stopped` for removed segment and its aspects
- on replacement: stop old before adopting new

### Success criteria

- no leaked gater/executor workers after segment replacement/removal

## P2: Observability and Tuning Signals

### Problem

gater overflow and queue pressure are only visible by inspecting payload error structures.

### Recommendation

Add optional counters/hooks on line or aspect:

- inflight count
- pending count
- overflow count by policy
- settle status counters

### Success criteria

- operators can tune `gate_inflight_*` values using concrete signal

## P2: Broader Runtime Integration Tests

### Problem

current test suite is comprehensive for unit behavior, but many tests run with a stubbed `vim` environment.

### Recommendation

Add a small live Neovim integration lane for critical async paths:

1. async task_fn happy path
2. gate overflow behavior
3. stop_drain and stop_immediate under load

### Success criteria

- same behavior validated in both pure Lua and Neovim runtime contexts

## Suggested Implementation Order

1. unify stop state machine for gater/executor coordination
2. lock `ensure_prepared` contract and enforce it
3. decide direct executor fate (implement or remove)
4. normalize config naming and update docs
5. finish splice lifecycle cleanup
6. add observability counters/hooks
7. add live Neovim integration lane

## Explicit Non-Goals for This Follow-up

- restoring legacy `mpsc_handoff` or transport wrappers
- preserving backward-compatible APIs with removed modules
- adding advanced multi-consumer queue architecture in the same pass

## Decision Checkpoints Before Coding

Before implementing this follow-up, confirm these three choices:

1. Is `ensure_prepared` synchronous-only? (recommended: yes)
2. Is `executor.direct` implemented now or temporarily removed? (recommended: remove/defer)
3. Are stop policies globally coordinated by runtime state machine? (recommended: yes)

Once those are confirmed, implementation can proceed with low ambiguity.
