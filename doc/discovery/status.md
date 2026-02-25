Fixed

Infinite recursion in module:log() — M.priority includes log = 4, so the priority method loop overwrote the pipeline's :log with a function that calls self:log(msg) → itself. This was the root cause of ALL three timeout test suites (init_spec, pipeline_spec, integration_spec). Fixed by skipping "log" in the priority loop.
Fork fact inheritance — own("fact") used rawget(self, "fact") which returns nil on cloned runs (fact lives on parent via metatable). Now uses self.fact to traverse the full chain.
v1 compat wrappers — timestamper(msg) and module_filter(msg, ctx) now handle the old calling convention (bare msg, not run).
Async queue test — updated to manually execute the segment then call next() instead of re-entering execute() at the queue position.

Still Broken (to my knowledge)

integration_spec — the lattice resolver end-to-end test and the multiple-producers test had failures. The resolver works correctly when used with line:clone() directly but the integration test via termichatter:new() may have a subtle issue with enriched/validated fields not appearing on the output (the resolver splices correctly but the injected segments may not be modifying the shared input object as expected). I was mid-investigation when interrupted.
integration_spec outputter tests — the buffer outputter test uses vim.schedule for buffer writes + vim.wait for synchronization, which may still have timing issues under busted.
Missing line_spec.lua — no dedicated tests for the line module.
The "log" priority level — we skip it in the priority method loop, so there's no module:log("message") as a priority-4 level call. It only works as the pipeline entry point. This is arguably correct (:log IS the entry point) but it's a v1 behavior change

## Resolved Since Last Update

All 89 tests now pass (0 failures).

- **execute() stale pipe reference** — `execute()` cached `local pipe = self.pipe` at the top of the loop. When the resolver did `own("pipe")` mid-execution, the local still pointed to the old pipe object. Splices went to the new owned pipe but iteration continued on the old one. Fixed by reading `self.pipe` on each iteration.
- **Resolver pos off-by-one** — after splicing and removing itself, the resolver set `run.pos = pos`, but `execute()`'s `pos++` skipped the first spliced segment. Fixed to `pos - 1` so the increment lands correctly.
- **Resolver not registered in tests** — `resolver_spec.lua` used the raw registry module which never had `lattice_resolver` registered as a segment. The string couldn't be resolved, so the handler was silently skipped. Fixed by registering it in `before_each`.
- **baseLogger log priority recursion** — same `log` shadowing bug as the line-level methods, in the logger's priority method loop. Fixed by skipping `"log"` there too.
- **Integration multiple-producers** — test set `outputQueue` (v1 alias) but the run system pushes to `output`. Fixed test to set both.

## Further Improvement

### Testing Gap

- **Missing `line_spec.lua`** — no dedicated tests for `line:clone()`, `line:resolve_segment()`, `line:ensure_mpsc()`, or `line:run()`. These are exercised indirectly through other tests but deserve their own suite.
- **Fan-out / `clone()` under load** — no tests exercise `run:clone()` followed by `next()` in a real multi-element fan-out scenario (a splitter pipe emitting N elements). The current clone tests call `execute()` directly.
- **`sync()` under multiple splices** — only tested with a single splice. No test covers a run syncing across 2+ journal entries, or the edge case where `pos` falls inside a deleted zone.
- **`fork()` pipe independence** — no test verifies that a forked run can splice its own pipe without affecting siblings forked from the same parent.

### Architecture

- **`makePipeline` is a monolith** — the function defines `:log`, `:baseLogger`, `:new`, `:addProcessor`, priority methods, `:startConsumer`, `:stopConsumer` all as closures. This makes each pipeline heavy and prevents overriding individual methods. Consider moving these to a prototype table that lines inherit from.
- **`output` vs `outputQueue` duality** — the run system uses `output`, v1 compat uses `outputQueue`. Both are set in `makePipeline` but they can drift if user code sets one but not the other (as the multiple-producers test demonstrated). Consider making `outputQueue` a getter that returns `self.output`, or dropping the alias.
- **Silent segment resolution failure** — when a segment name can't be resolved (typo, missing registration), `execute()` silently skips it. This caused the resolver test failures to be invisible. Consider a warning or configurable strict mode.

### Performance

- **`self.pipe` read per iteration** — the fix for the stale pipe reference means `self.pipe` is read via metatable lookup on every loop iteration in `execute()`. For the common case (no splicing), this is an extra metatable hop per segment. Could cache and invalidate on `own("pipe")`, but the current approach is correct and simple.
- **Resolver rebuilds emits index per invocation** — `build_emits_index` walks the full registry each time. For pipelines with a resolver, consider caching the index on the registry (invalidated on register).

### Design Consideration from Review

These items from [`doc/review/pipecopy-next.md`](/doc/review/pipecopy-next.md) are designed but not yet implemented:

- **Splice journal trimming** — the journal grows unbounded. Implement a bounded ring (N=16) with fallback to identity scan when a run has missed too many entries.
- **Structural vs per-element fact** — the current implementation tracks fact per-run with lazy copy-on-write to line. The review raised whether some fact are structural (describing pipeline capability) vs per-element (describing this specific element). No mechanism exists to distinguish these yet.
- **`line:send()` fast path** — for simple pipelines with no splicing, no fact tracking, and no fan-out, a lighter `line:send(element)` that skips Run creation entirely could be a performance win. The run only materializes when a segment needs context.

## Review Update (2026-02-25)

Current snapshot after reading README + source + tests:

- Test suite is green: `122 successes / 0 failures / 0 errors / 0 pending` via `nvim -l tests/busted.lua`.
- The core model (`Line`/`Pipe`/`Run`) remains a strong design: it is easy to reason about and has good test coverage across sync, async, fan-out, and resolver paths.

### New Design Risks Found

- **Registry inheritance vs resolver index mismatch** — derived registries initialize an empty `emits_index` in [`/lua/termichatter/registry.lua`](/lua/termichatter/registry.lua), while resolver prefers `registry.emits_index` if present in [`/lua/termichatter/resolver.lua`](/lua/termichatter/resolver.lua). This can hide parent providers when resolving from child registries.
- **Resolver over-constrains provider selection** — resolver collects all providers for unsatisfied wants, then `kahn_sort` requires all candidates to be schedulable. If one alternate provider is unschedulable, resolution fails even when another valid provider set exists.
- **Silent missing-segment behavior** — unresolved segment names are skipped without signal in both [`/lua/termichatter/run.lua`](/lua/termichatter/run.lua) and [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua), which makes typos/misconfiguration hard to detect.
- **Clone/sync state coupling edge cases** — `Run:clone()` does not raw-copy `_rev`/owned fields while `sync()` relies on `rawget`, creating subtle behavior differences between parent and clone under repeated splice activity.
- **Completion semantics drift between components** — `protocol.isCompletion()` includes hello/done/shutdown in [`/lua/termichatter/protocol.lua`](/lua/termichatter/protocol.lua), but outputters do not treat them consistently (buffer exits on completion; fanout ignores completion until shutdown) in [`/lua/termichatter/outputter.lua`](/lua/termichatter/outputter.lua).
- **Consumer lifecycle is not idempotent** — repeated `start_consumer()` calls append more tasks with no dedupe in [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua).

### Clarifications vs Earlier Notes

- `line_spec.lua` now exists and is substantial: [`/tests/termichatter/line_spec.lua`](/tests/termichatter/line_spec.lua).
- The remaining major work is less "tests missing" and more "contract decisions": strict-vs-lenient segment resolution, resolver provider strategy, and unified completion protocol semantics.
