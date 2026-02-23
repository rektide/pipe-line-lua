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
