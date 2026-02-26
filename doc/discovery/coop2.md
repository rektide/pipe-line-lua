# Coop2 Ideas

This note captures a next-pass direction for cooperative async behavior after the move away from queue payload sentinels.

References:
- [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)
- [`/lua/termichatter/outputter.lua`](/lua/termichatter/outputter.lua)
- [`/lua/termichatter/protocol.lua`](/lua/termichatter/protocol.lua)
- [`/lua/termichatter/segment/completion.lua`](/lua/termichatter/segment/completion.lua)
- [`/lua/termichatter/done.lua`](/lua/termichatter/done.lua)

## Current Direction

- Prefer explicit task lifecycle APIs over in-band queue shutdown payloads.
- Keep completion protocol on run fields (`termichatter_protocol`, `mpsc_completion`).
- Use a deferred (`line.done`) as the public settle point.

## Key Principle: Resolve State At Settle Time

When completion state settles (`done >= hello`), resolve `line.done` with the state snapshot directly.

This keeps one canonical result object and avoids splitting final state across separate outputs.

Suggested settle payload shape:

```lua
{
  hello = number,
  done = number,
  settled = true,
  resolved = true,
  signal = "done" | "shutdown",
  name = string|nil,
}
```

Notes:
- `resolved` is lifecycle-of-deferred state.
- `settled` is protocol convergence state.
- They are related but not equivalent in query-only handlers.

## Coop2 API Ideas

### 1) Normalize async runner lifecycle everywhere

For any async runner object (consumer/outputter/driver), expose:

- `start_async(...) -> task_or_tasks`
- `stop(timeout?, interval?) -> true`
- `await_stopped(timeout?, interval?) -> true`

Behavior:
- `start_async` is idempotent.
- `stop` cancels active tasks and then awaits stop.
- `await_stopped` tolerates already-stopped state.

### 2) Keep completion utilities composable

`protocol.completion` should remain query-friendly for custom handlers:

- `create_completion_state()`
- `query_completion(state, run)`

Custom segments can observe settle without resolving `line.done`.
Default completion segment resolves `line.done` on settle.

### 3) Optional future: async handler returns

If handlers may return awaitables later, require one small contract:

- awaitable exposes `on_resolve(callback)`

Then run execution can suspend/resume without blocking `vim.wait` in the hot path.

## Guardrails

- No queue payload sentinel protocol for lifecycle control.
- No hidden background task creation without explicit ownership.
- Cancel/await logic should live in one helper path per subsystem.

## Open Questions

- Should `line.done` resolve with only completion state, or a larger final run summary object?
- Should `signal = "shutdown"` be treated as settled terminal success or a distinct terminal class?
- Do we want a shared `task_lifecycle.lua` helper for `is_task_active`, cancel+await normalization?
