# Coop2 Ideas

This note captures the design direction after removing queue payload sentinels and moving toward explicit async lifecycle ownership.

References:
- [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)
- [`/lua/termichatter/outputter.lua`](/lua/termichatter/outputter.lua)
- [`/lua/termichatter/protocol.lua`](/lua/termichatter/protocol.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)
- [`/lua/termichatter/segment/define.lua`](/lua/termichatter/segment/define.lua)
- [`/lua/termichatter/done.lua`](/lua/termichatter/done.lua)

## Direction Summary

We are converging on three clear boundaries:

- Async lifecycle is explicit and task-owned (`start_async`, `stop`, `await_stopped`).
- Completion protocol is run-field based (`termichatter_protocol`, `mpsc_completion`).
- Deferred resolution ownership belongs to `line.done`, not protocol state.

This avoids the old ambiguity where queue payloads and protocol semantics were mixed.

## Vocabulary and Ownership

### Protocol state vs deferred state

This distinction must stay explicit:

- `completion_state` is protocol accounting state (`hello`, `done`, `settled`, optional metadata).
- `line.done` is deferred lifecycle state (`is_resolved()`, callbacks, await).

Important consequence:

- `settled` belongs in `completion_state`.
- `resolved` should not live in `completion_state`; it belongs to `line.done` or segment-local guard logic.

### Naming conventions

Use explicit names that reflect domain ownership:

- `completion_state` instead of generic `state`.
- `protocol.is_protocol(run)` as top-level entry for protocol identification.
- `protocol.completion.*` namespace for completion-specific behavior.

## Completion Model: Apply, Then Read State

We should move from query-result objects toward direct state mutation and direct reads.

Recommended completion API shape:

- `protocol.completion.create_completion_state()`
- `protocol.completion.apply(run, completion_state) -> boolean`

`apply` contract:

- returns `false` if the run is not a recognized completion protocol run
- updates `completion_state` in place for recognized completion signals
- sets `completion_state.settled = (done >= hello)`
- returns `true` when a completion signal was consumed

Example state shape:

```lua
{
  hello = number,
  done = number,
  settled = boolean,
  signal = "hello" | "done" | "shutdown" | nil,
  name = string|nil,
}
```

This supports both default and custom completion handlers without wrapper status tables.

## Line Done Resolution Rule

Primary rule:

- resolve `line.done` as soon as `completion_state.settled == true`

Recommended resolved payload:

- resolve with `completion_state` directly (or a shallow snapshot if we later want immutability)

Why this helps:

- one canonical terminal object
- no split between protocol settlement and deferred result payload
- easier to reason about in tests and integrations

## Segment Lifecycle Tooling

`segment.define` is now the start of lifecycle tooling.

Near-term expansion:

- keep `handler` as standard sync term
- add explicit async handler slot, likely `handler_async`
- reject conflicting definitions (`handler` and `handler_async` both set) unless we define strict precedence

This keeps current terminology while making async behavior explicit.

## Async Segment Usage

We should support async in a way that is explicit at the segment boundary and predictable for callers.

### Async return model

A segment can return either:

- an immediate pipeline value (`table`, `false`, or `nil`), or
- an awaitable (coop `Task` / `Future`, i.e. anything with `:await(...)`).

This allows gradual adoption: existing sync segments keep working unchanged.

### Two execution strategies

There are two valid async strategies; we should document both and prefer one by default.

1. **Inline await (simple, blocking)**
   - runtime awaits returned awaitable in `execute`
   - easiest implementation
   - blocks current run path while waiting

2. **Queue continuation (recommended default)**
   - runtime registers continuation and returns early from current run
   - completion resumes through an mpsc queue boundary
   - preserves non-blocking behavior and matches current handoff architecture

Recommendation: use queue continuation by default for `handler_async` so async segments behave like explicit pipeline boundaries.

### Segment.define shape for async

Proposed contract:

- `handler` for synchronous logic
- `handler_async` for awaitable logic
- reject ambiguous configs where both are present unless strict precedence is defined

Suggested behavior:

- `handler` runs in-place
- `handler_async` may return awaitable or immediate value
- runtime normalizes return value and routes continuation strategy

## Async Pipeline Patterns

### Pattern A: Inline async transform

Use when latency is acceptable and backpressure is desired.

```lua
local segment = require("termichatter.segment")

local fetch_profile = segment.define({
  type = "fetch_profile",
  handler_async = function(run)
    return coop.spawn(function()
      local profile = db:get_profile(run.input.user_id)
      return vim.tbl_extend("force", run.input, { profile = profile })
    end)
  end,
})
```

### Pattern B: Async fan-out via mpsc continuation

Use when throughput and responsiveness matter.

- emit hello/done protocol runs from producer boundaries
- resume continuations through mpsc queue workers
- let completion segment settle `line.done`

This is the same architecture already used by `mpsc_handoff`, generalized to async segment returns.

## Extending mpsc_handoff for Async

We likely do not need a separate async subsystem. We can extend current handoff mechanics instead:

- keep `mpsc_handoff` as the continuation boundary primitive
- add a helper that takes `(run, awaitable, strategy)`
- on awaitable completion, enqueue continuation payload to handoff queue

Benefits:

- no second lifecycle system
- same task ownership and stop/await semantics
- completion protocol (`hello`/`done`/`shutdown`) remains central

## Async + Completion Interop

When async segments produce work, completion signaling should stay explicit:

- producers emit `protocol.completion.completion_run("hello", name)` when async work starts
- emit `protocol.completion.completion_run("done", name)` when async work finishes
- completion segment updates `completion_state` and resolves `line.done` only when settled

This keeps completion accounting decoupled from specific async transport details.

## Async Runner API Normalization

For async-capable subsystems (consumer/outputter/driver), we should normalize on:

- `start_async(...) -> task | task[]`
- `stop(timeout?, interval?) -> true`
- `await_stopped(timeout?, interval?) -> true`

Behavior expectations:

- `start_async` is idempotent
- `stop` performs cancel and await sequence
- `await_stopped` tolerates already-stopped state

This reduces copy-paste cancellation logic in tests and consumer code.

## Completion Segment Responsibilities

Default completion segment should:

- ensure `line.completion_state` exists
- call `protocol.completion.apply(run, line.completion_state)`
- if `line.completion_state.settled` and `line.done` is unresolved, resolve `line.done`
- pass protocol runs onward by default, so other segments can also observe

Custom completion segments can:

- reuse `apply` for accounting
- observe `completion_state` directly
- choose not to resolve `line.done`

This gives flexibility without duplicating protocol math.

## Migration Notes

Near-term migration from current shape:

1. Add `protocol.completion.apply`.
2. Rename line internal `_completion_state` usages to `completion_state`.
3. Remove `query_completion` after callsites use `apply + completion_state` reads.
4. Keep `protocol.is_protocol` as the public protocol gate.

## Guardrails

- Do not reintroduce queue payload sentinels for lifecycle control.
- Do not hide background task ownership behind opaque side effects.
- Keep settle (`completion_state`) and resolve (`line.done`) semantics separate and explicit.
- Keep protocol utilities simple enough for custom segment reuse.

## Open Questions

- Should `line.done` resolve with the mutable `completion_state` table, or a snapshot copy?
- Should `shutdown` be treated as normal settled completion or a distinct terminal status class?
- Do we want a shared `task_lifecycle` helper module for active/cancel/await behavior?
