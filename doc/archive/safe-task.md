# Safe-Task and the Three Transports Design

> Status: Archived  
> Date: 2026-03-14  
> Period: 2026-02-25 to 2026-03-14

This document chronicles the design, implementation, and eventual simplification of the async transport layer in pipe-line (formerly termichatter). The core idea was a **transport policy system** with three distinct async strategies for segment handlers.

## The Three Transports

The design centered on three transport types, each with different async handoff semantics:

| Transport | Type | Behavior |
|-----------|------|----------|
| **mpsc** | `"mpsc"` | Queue-based boundary; continuation wrapped in envelope, pushed to MpscQueue, consumed by separate worker task |
| **safe-task** | `"safe_task"` | Buffered task runner; continuations queued in pending list, processed by long-lived task that waits on Future when idle |
| **task** (unsafe) | `"task"` | Direct task yield; continuation passed via `task.pyield()`, no buffering guarantees |

### Key Distinction: Safe vs Unsafe Task

- **safe-task**: Uses a `pending` queue and `wake` Future. When no work is available, the runner waits on the Future. New continuations are appended to `pending` and the Future is completed to wake the runner. This provides ordered, non-blocking handoff.

- **task (unsafe)**: Uses `task.pyield()` directly. The runner blocks waiting for a yield, and continuation is passed immediately. Simpler but less flexible - the producer must coordinate directly with the runner's yield timing.

## Chronology

### Phase 1: Decomposition Ideation (Feb 25-26)

**Commit [`1e0e55c`](/doc/archive/mpsc-decomposition.md)**: "decomp ideation"

Created two discovery documents exploring how to decompose `mpsc_handoff` into reusable pieces:

- [`mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md) - Options for splitting envelope, runtime, segment, consumer_loop, and discovery
- [`mpsc-decomp-tasks.md`](/doc/archive/mpsc-decomp-tasks.md) - Task breakdown for implementing Option 3 (generic queue boundary factory)

Key insight: The envelope concept `{ [HANDOFF_FIELD] = continuation }` should be separate from queue mechanics.

### Phase 2: Lifecycle Unification (Feb 26)

**Commit [`99fd038`]**: "Unify line lifecycle with ensure_prepared/ensure_stopped and coop await helpers"

Introduced standardized lifecycle hooks and awaitable normalization:
- `append_awaitable(list, awaited)` - recursively collects awaitables
- `compact_awaitables(list)` - returns nil/singleton/list as appropriate

**Commit [`af58e0a`]**: "Extract mpsc handoff segment into segment/mpsc module"

Moved mpsc_handoff from `segment.lua` to dedicated `segment/mpsc.lua`.

### Phase 3: Async-First Architecture (Feb 26)

**Commit [`937f23f`]**: "document async-first re-architecture plan"

The [`re-async.md`](/doc/archive/re-async.md) document outlined the goal: remove all `vim.wait` and timeout-based awaits from runtime. Key conclusions:

1. Enter task context at ingress, stay in task context throughout
2. `mpsc_handoff` is useful for explicit boundaries but not the only async mechanism
3. Runtime should use `await()/pawait()` or callback modes, never blocking waits

### Phase 4: Transport Layer Implementation (Feb 26)

**Commit [`e68a467`]**: "add mpsc segment define wrapper"

Created `segment/define/mpsc.lua` - a segment wrapper that:
- Manages queue lifecycle via consumer module
- Wraps handler to produce continuation and push to queue
- Returns false to stop current run (continuation resumes from queue)

**Commit [`e97cc37`]**: "add safe-task segment define wrapper"

Created `segment/define/safe-task.lua` - 154 lines implementing:
- `pending` queue for continuations
- `wake` Future for idle notification
- Runner task that loops: wait if empty, process if available
- `ensure_runner`, `dispatch_safe`, `is_task_active` helpers

**Commit [`762408c`]**: "add unsafe task segment define wrapper"

Created `segment/define/task.lua` - simpler variant using `task.pyield()` for direct handoff without buffering.

**Commit [`8e99f69`]**: "factor shared define helpers into common module"

Extracted `segment/define/common.lua` with shared utilities:
- `copy_spec`, `is_task_active`, `append_awaitable`, `compact_awaitables`
- `stop_result_or_false`, `prepare_continuation`

**Commit [`9288e58`]**: "extract shared task define core and slim safe-task wrapper"

Created `segment/define/task-core.lua` - unified implementation for both safe and unsafe modes:
- `ensure_state`, `ensure_processor`, `process_continuation`
- `create_safe_runner`, `create_unsafe_runner`, `ensure_runner`
- `build_segment(define, spec, mode)` - single factory with mode parameter

### Phase 5: Transport Abstraction (Feb 26)

**Commit [`12e6857`]**: "decompose define wrappers by transport and remove task-core"

Major refactor: replaced `task-core` with a **transport policy system**:

Deleted:
- `segment/define/task-core.lua`

Created:
- `segment/define/transport.lua` - generic segment builder accepting transport policy
- `segment/define/transport/mpsc.lua` - mpsc transport implementation
- `segment/define/transport/task.lua` - task transport (safe/unsafe modes)

Each transport implements:
```lua
{
  type = string,
  configure_segment = function(segment) end,
  ensure_prepared = function(segment, context, runtime) -> awaitable|nil end,
  dispatch = function(segment, run, continuation, runtime) end,
  ensure_stopped = function(segment, context, runtime) -> awaitable|nil end,
}
```

The `runtime` table provides:
- `wrapped_handler` - the user's handler wrapped by define
- `handler_generator` - optional custom processor generator

### Phase 6: ADRs and Semantics (Feb 26-27)

**Commit [`daf6d5f`]**: "add ADRs for transport policy and stop semantics"

Two Architecture Decision Records:

[`adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md):
- Codified the transport policy contract
- Established `type` (not `mode`) as transport identity
- Documented runtime context fields

[`adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md):
- Default stop = drain-first (wait for pending completion)
- `cancel_immediate` as opt-in behavior
- Lazy signal creation for cancel/drain/stopped futures

### Phase 7: Simplification (Mar 14)

**Commit [`a2639ab`]**: "Simplify async: delete transport layer, make run:execute() awaitable-aware"

The entire transport system was removed in favor of a simpler model:

Deleted:
- `consumer.lua` - replaced by `queue_driver` segment
- `segment/define/transport.lua`
- `segment/define/transport/task.lua`
- `segment/define/transport/mpsc.lua` (moved to different structure)
- `segment/define/task.lua`
- `segment/define/safe-task.lua`
- `segment/define/common.lua`

Added:
- `segment/queue_driver.lua` - ordinary segment that drives a queue

Changed:
- `run:execute()` now detects awaitable returns and spawns coop task automatically
- Added `run.done` Future, `_finish()`/`_stop()` helpers
- `mpsc.lua` simplified to push raw continuations (no envelope)

New model: **Any segment handler can return a coop future/task, and run:execute() automatically awaits it before continuing.**

## What Was Lost

### The Transport Policy Abstraction

The most significant loss is the **explicit transport policy interface**. The new model is simpler but less structured:

| Before (Transport Policy) | After (Direct Awaitable) |
|---------------------------|--------------------------|
| Explicit `type` field for categorization | No transport identity |
| Structured `ensure_prepared`/`dispatch`/`ensure_stopped` contract | Ad-hoc lifecycle in each segment |
| Reusable transport implementations | Each segment manages its own async |
| Clear separation of concerns | Handler returns awaitable directly |

### Safe-Task Pattern

The **safe-task buffered runner pattern** is no longer explicitly available:

```lua
-- The safe-task pattern (now lost as reusable abstraction):
-- 1. pending queue for incoming continuations
-- 2. wake Future for idle notification  
-- 3. runner task that loops: wait -> process -> repeat
-- 4. dispatch appends to pending, signals wake
```

This pattern can be reimplemented in user code, but the transport wrapper that made it trivial to apply is gone.

### Consumer Module

The `consumer.lua` module provided centralized queue consumer management:
- `ensure_queue_consumer(line, queue)` - idempotent consumer creation
- `stop_queue_consumer(line, queue)` - targeted stop
- `start_consumer(line)` / `stop(line)` - batch lifecycle

This is now handled by `queue_driver` segments, which is more composable but less centralized.

## What Remains

### Current Segment Structure

```
lua/pipe-line/segment/
  completion.lua   - protocol completion handling
  define.lua       - segment definition helper
  mpsc.lua         - handoff segment (simplified, no envelope)
  queue_driver.lua - queue consumption segment
```

### Current Async Model

```lua
-- Handler returns awaitable -> run:execute() spawns task
function my_async_segment.handler(run)
  return coop.spawn(function()
    -- async work
    return result
  end)
end
```

### Preserved Documents

- [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md) - transport contract (still exists)
- [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md) - stop semantics (still exists)
- [`/doc/archive/re-async.md`](/doc/archive/re-async.md) - async-first architecture plan
- [`/doc/archive/coop2.md`](/doc/archive/coop2.md) - lifecycle and completion design
- [`/doc/archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md) - decomposition options

## Design Lessons

1. **The transport abstraction was good architecture** - it cleanly separated "how to hand off async work" from "what the segment does". The simplification traded composability for reduced complexity.

2. **Safe-task vs unsafe-task** - the distinction matters. Buffered queue + wake Future (safe) vs direct yield (unsafe) have different ergonomics and guarantees. The unified model loses this explicit choice.

3. **Envelope pattern** - wrapping continuations in `{ [HANDOFF_FIELD] = continuation }` was removed. Raw continuations are now pushed directly. This is simpler but loses the metadata extensibility point.

4. **Handler-first contract** - the final model makes handlers directly return awaitables, which is more intuitive but puts more responsibility on segment authors to manage lifecycle correctly.

## Related Commits

| Hash | Date | Description |
|------|------|-------------|
| `1e0e55c` | Feb 26 01:05 | decomp ideation |
| `99fd038` | Feb 26 01:48 | Unify line lifecycle |
| `af58e0a` | Feb 26 00:34 | Extract mpsc to segment/mpsc.lua |
| `937f23f` | Feb 26 05:51 | document async-first re-architecture plan |
| `f0b409c` | Feb 26 06:10 | snapshot: switch deferred handles to coop futures |
| `e68a467` | Feb 26 06:42 | add mpsc segment define wrapper |
| `5b9a7b6` | Feb 26 06:43 | refactor mpsc_handoff to use mpsc define wrapper |
| `e97cc37` | Feb 26 06:44 | add safe-task segment define wrapper |
| `762408c` | Feb 26 06:44 | add unsafe task segment define wrapper |
| `8e99f69` | Feb 26 06:48 | factor shared define helpers into common module |
| `9288e58` | Feb 26 06:49 | extract shared task define core and slim safe-task wrapper |
| `12e6857` | Feb 26 18:18 | decompose define wrappers by transport and remove task-core |
| `daf6d5f` | Feb 26 23:02 | add ADRs for transport policy and stop semantics |
| `a2639ab` | Mar 14 06:05 | Simplify async: delete transport layer |
