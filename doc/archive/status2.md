Thinking: Outlining data unification approach
Committed.

- 04b69df6 — Expose protocol.is_protocol and align segment define lifecycle checks
  And yes, I agree on unifying line.done with final state.
  Right now line.done resolves with completion counters/signal, while the run output/final payload is separate. A clean next step is to make line.done resolve a single canonical object like:
- status: "done" | "shutdown" | "error"
- completion: { hello, done, settled, signal }
- final: final pipeline payload (if any)
- source: line:full_source()
- time: settle timestamp
  That gives one authoritative lifecycle result and avoids split-brain between output state and done state.

---

Thinking: Discussing async handler integration
Great question. Right now it would take a real execution model change, not just a type check.
Current blocker:

- Run:execute() is synchronous and assumes handler returns immediately (false/nil/value) in lua/termichatter/run.lua:109.
- If a handler returned a deferred now, it would just be treated as a regular value and become run.input (wrong behavior).
  What you’d need

1. Define async handler contract

- Decide what is “awaitable”:
  - likely table with on_resolve(cb) (best, non-blocking)
  - optionally await()/status() for coop tasks
- Decide resolved-value semantics:
  - resolve false -> stop
  - resolve nil -> keep current input
  - resolve value -> set input and continue

2. Add suspended continuation path in Run

- In Run:execute(), when handler returns awaitable:
  - mark run as suspended/pending
  - register callback that resumes the run at next segment
  - return immediately (no blocking vim.wait)
- Add guards against double-resume/reentrancy.

3. Add error/cancel semantics

- Need a path for rejected/cancelled async work.
- Options:
  - “let it fail” (bubble error, kill run)
  - or structured on_error path.
- Must define behavior when line:close() happens while run is pending.

4. Integrate with completion/done model

- Big one: line.done should not resolve before async handlers that are still pending.
- Either:
  - async handlers must emit completion hello/done themselves, or
  - runtime auto-wraps async returns with completion accounting (cleaner but more invasive).
    Design options
- Option A (smallest change, still non-trivial): callback-based resume only (on_resolve), no blocking waits.
- Option B (cleaner long-term): dual APIs execute_sync and execute_async, where async path supports awaitables explicitly.
- Option C (minimal surface): do not support returning promises; require async segments to use existing mpsc handoff and explicit continuation.
  My recommendation
- If you want promise-returning handlers, do Option A first (non-blocking callback resume).
- It aligns with your explicit lifecycle direction and avoids turning the whole engine into blocking waits.
  So: feasible, but medium complexity because it touches run control flow, close/done correctness, and cancellation semantics all at once.
