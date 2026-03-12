# MPSC Decomposition Tasks

> Superseded by: [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md) and [`/doc/segment-authoring.md`](/doc/segment-authoring.md).
>
> This task breakdown assumes `handler_async` and dispatch vocabulary that are no longer part of the current segment contract.

This note turns Option 3 from [`/doc/discovery/mpsc-decomposition.md`](/doc/discovery/mpsc-decomposition.md) into an implementation-oriented task plan, with coop awaitable semantics baked in.

Related references:
- [`/doc/discovery/mpsc-decomposition.md`](/doc/discovery/mpsc-decomposition.md)
- [`/doc/discovery/coop2.md`](/doc/discovery/coop2.md)
- [`/lua/termichatter/segment/mpsc.lua`](/lua/termichatter/segment/mpsc.lua)
- [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)
- [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)

## Confirmed Semantics

- `shutdown` in this context includes the completion control signal path (`termichatter_protocol + mpsc_completion="shutdown"`).
- We do not currently have a dedicated pipe-level `close` hook; lifecycle hooks are segment-level (`ensure_prepared`, `ensure_stopped`) orchestrated by line lifecycle.
- Completion protocol is run-field based and should remain separate from payload data (`run.input`).

## Coop Awaitable Model (for segment async)

From coop docs, both `Task` and `Future` are awaitables (they provide `:await(...)`).

Design implication for termichatter:
- `handler_async` can safely return either a single awaitable or a list of awaitables.
- Runtime only needs awaitable detection by shape (`type(v)=="table" and type(v.await)=="function"`).
- We do not need to branch on concrete coop types (`Task` vs `Future`) in pipeline core.

## Option 3 Target: Generic Queue Boundary Factory

Create a reusable boundary builder, then specialize mpsc handoff on top.

Proposed module:
- [`/lua/termichatter/segment/queue_boundary.lua`](/lua/termichatter/segment/queue_boundary.lua)

Proposed API:

```lua
queue_boundary.create({
  type = "mpsc_handoff",
  queue = function(config, line) ... end,
  to_envelope = function(run, segment) ... end,
  from_envelope = function(payload, segment) ... end,
  dispatch = function(decoded, context) ... end,
  ensure_runtime = function(line, queue, boundary) ... end,
  stop_runtime = function(line, queue, boundary) ... end,
})
```

This keeps policy in segment configuration and puts loop/runtime ownership in reusable pieces.

## Async Return Contract (`handler_async`)

### Proposed contract

- `handler` stays sync.
- `handler_async` opts segment into awaitable return semantics.
- Return values for `handler_async`:
  - immediate: `false | nil | value`
  - awaitable: `task_or_future`
  - list: `{ task_or_future, ... }`

### Initial policy

- If list is returned, await the first awaitable, treat the rest as detached background tasks.
- Detached tasks are segment-owned, not globally tracked by runtime.

Why this policy:
- preserves simple continuation semantics
- avoids global task registry complexity
- still allows advanced segments to manage/cancel background tasks in `ensure_stopped`

## Shutdown + Detached Tasks

Trigger sources for shutdown behavior:
- completion control signals (`mpsc_completion="shutdown"`)
- explicit `line:close()` lifecycle

Expected behavior:
- boundary/runtime cancellation should stop queue workers
- detached tasks are only canceled if segment explicitly tracks and cancels them

Completion accounting guidance:
- tasks that should block `line.done` must emit completion hello/done protocol runs
- best-effort detached tasks should not affect completion accounting

## Task Breakdown

1. Add queue boundary skeleton module
   - create `queue_boundary.create(...)`
   - move common boundary shape (`type`, queue ownership, lifecycle delegation)

2. Extract mpsc envelope module
   - add `segment/mpsc/envelope.lua`
   - implement `wrap`, `unwrap`, `is_envelope`
   - migrate `HANDOFF_FIELD` constant ownership here

3. Extract consumer loop adapter
   - add `segment/mpsc/consumer_loop.lua`
   - API: `run(queue, decode, dispatch, on_error?)`

4. Extract mpsc runtime module
   - add `segment/mpsc/runtime.lua`
   - own queue task lifecycle (`ensure_queue_consumer`, `stop_queue_consumer`, await helpers)
   - reuse existing cancellation semantics from [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)

5. Rebuild mpsc segment using queue boundary factory
   - add `segment/mpsc/segment.lua`
   - keep public API compatibility in [`/lua/termichatter/segment/mpsc.lua`](/lua/termichatter/segment/mpsc.lua) as facade during migration

6. Extend segment definition for async
   - in [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua), add `handler_async` support
   - reject ambiguous spec (`handler` and `handler_async` both defined) unless explicit precedence is chosen

7. Add awaitable normalization helper
   - new utility in `util` or dedicated async helper module
   - detect awaitable by `await` method
   - normalize `task_or_tasks` behavior (`await first, detach rest`)

8. Wire async continuation through boundary
   - when async result needs continuation, enqueue continuation payload through queue boundary rather than blocking execute path

9. Expand completion-focused tests
   - control signal pass-through with boundaries
   - close/shutdown behavior for boundary workers
   - detached-task behavior and completion accounting expectations

10. Decommission direct consumer ownership from non-boundary code
   - keep `consumer.lua` as adapter or fold into `segment/mpsc/runtime.lua`
   - remove duplicate lifecycle paths

## Test Matrix (must-have)

- Envelope decode errors do not crash unrelated queues.
- Queue runtime start/stop idempotency per queue instance.
- `handler_async` single awaitable continuation works through boundary.
- `handler_async` task list: first awaited, others detached.
- Detached tasks can be canceled by segment `ensure_stopped` when segment opts in.
- Completion settle remains correct under mixed sync/async boundaries.
- `shutdown` signal path triggers proper stop behavior.

## Open Decisions

- Should detached tasks have an optional runtime-owned tracking mode (`track_detached=true`) for observability?
- Should queue boundary expose per-boundary identifiers for tracing and diagnostics?
- Should async continuation always require explicit boundary presence, or may runtime insert one automatically?
