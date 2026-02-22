# pipenext-status

Assessment of the new Lua implementation in `lua/termichatter` and its test suites.

## Overview

termichatter-nvim is a structured data-flow pipeline system for Neovim built atop coop.nvim. The implementation uses a layered architecture:

```
Registry (segment library)
    ↓
  Line (pipeline definition, holds pipe + config)
    ↓
  Run (cursor walking the pipe, executing segment)
    ↓
 Output (final destination queue)
```

Key concepts:
- **line**: a pipeline definition holding a pipe, registry, output
- **pipe**: connected sequence of segment with rev/splice/clone capabilities
- **segment**: processing component/handler in a pipe
- **run**: lightweight cursor/context that walks a pipe
- **registry**: repository of known segment types
- **fact**: named capability or state tracked on line/run

## Test Suites Found

| File | Description |
| ---- | ----------- |
| [`tests/termichatter/init_spec.lua`](/tests/termichatter/init_spec.lua) | Tests for main init module |
| [`tests/termichatter/pipe_spec.lua`](/tests/termichatter/pipe_spec.lua) | Tests for pipe module |
| [`tests/termichatter/run_spec.lua`](/tests/termichatter/run_spec.lua) | Tests for run module |
| [`tests/termichatter/line_spec.lua`](/tests/termichatter/line_spec.lua) | Tests for line module (not found) |
| [`tests/termichatter/resolver_spec.lua`](/tests/termichatter/resolver_spec.lua) | Tests for lattice resolver |
| [`tests/termichatter/consumer_spec.lua`](/tests/termichatter/consumer_spec.lua) | Tests for async consumer |
| [`tests/termichatter/pipeline_spec.lua`](/tests/termichatter/pipeline_spec.lua) | Integration tests for full pipeline |
| [`tests/termichatter/integration_spec.lua`](/tests/termichatter/integration_spec.lua) | Integration tests |

## Test Runner

Tests are run via: `nvim -l tests/busted.lua`

---

# journal - initial exploration

Started by examining the project structure:

1. **Lua modules** in `lua/termichatter/`:
   - `init.lua` - main entry point
   - `line.lua` - pipeline definition
   - `pipe.lua` - connected sequence of segments
   - `run.lua` - execution cursor
   - `registry.lua` - segment repository
   - `resolver.lua` - lattice dependency resolver
   - `segment.lua` - built-in segments
   - `consumer.lua` - async consumer
   - `driver.lua` - scheduling
   - `outputter.lua` - output destinations
   - `protocol.lua` - completion protocol
   - `inherit.lua` - metatable utilities

2. **Test files** in `tests/termichatter/`:
   - 8 test spec files found
   - `busted.lua` is the test runner

Reference: [`README.md`](/README.md) for architecture documentation.

---

# journal - test suite assessment

Ran each test suite in isolation using `nvim -l tests/busted.lua tests/termichatter/<spec>.lua`

## Test Results Summary

| Test Suite | Status | Pass | Fail | Notes |
| ---------- | ------ | ---- | ---- | ----- |
| [`pipe_spec.lua`](/tests/termichatter/pipe_spec.lua) | ✅ PASS | 12 | 0 | All pipe operations work correctly |
| [`run_spec.lua`](/tests/termichatter/run_spec.lua) | ⚠️ FAIL | 17 | 1 | Fork test fails: fact inheritance broken |
| [`resolver_spec.lua`](/tests/termichatter/resolver_spec.lua) | ✅ PASS | 21 | 0 | Lattice resolver fully functional |
| [`consumer_spec.lua`](/tests/termichatter/consumer_spec.lua) | ✅ PASS | 4 | 0 | Async consumer working |
| [`init_spec.lua`](/tests/termichatter/init_spec.lua) | ⏱️ TIMEOUT | ? | ? | Tests start but process never exits |
| [`pipeline_spec.lua`](/tests/termichatter/pipeline_spec.lua) | ⏱️ TIMEOUT | ? | ? | Tests start but process never exits |
| [`integration_spec.lua`](/tests/termichatter/integration_spec.lua) | ⏱️ TIMEOUT | ? | ? | Tests start but process never exits |

## Known Failure: run_spec.lua - fork test

```
Failure -> tests/termichatter/run_spec.lua @ 243
termichatter.run fork creates fully independent run
tests/termichatter/run_spec.lua:260: Expected objects to be the same.
Passed in: (nil)
Expected: (boolean) true
```

The test at [`run_spec.lua:243`](/tests/termichatter/run_spec.lua:243) checks that `fork()` creates a fully independent run that snapshots all facts. The issue is in [`run.lua:own("fact")`](/lua/termichatter/run.lua:185-201):

```lua
function Run:own(field)
    ...
    elseif field == "fact" then
        local current = rawget(self, "fact")
        local snapshot = {}
        local line_fact = self.line and self.line.fact or {}
        for k, v in pairs(line_fact) do
            snapshot[k] = v
        end
        if current then
            for k, v in pairs(current) do
                if k ~= "__index" then
                    snapshot[k] = v
                end
            end
        end
        rawset(self, "fact", snapshot)
```

**Bug**: When a cloned run calls `own("fact")`, `rawget(self, "fact")` returns `nil` because the fact is inherited via metatable from the parent run. The clone's `__index` falls through to `rawget(parent_run, "fact")` but the `own` method doesn't access it this way - it uses `rawget` directly.

## Timeout Issue: init_spec, pipeline_spec, integration_spec

All three test suites that use async operations via `coop.spawn` and `task:await()` timeout instead of completing cleanly. The test output shows tests running (e.g., `**+++++++-`) but the process never exits.

**Root cause hypothesis**: The busted test framework may not be properly integrating with coop.nvim's event loop. Tests spawn coop tasks that complete, but the underlying event loop (libuv) may have pending handles/timers that prevent exit.

The test runner ([`tests/busted.lua`](/tests/busted.lua)) uses `lazy.nvim`'s busted integration and sets up luacov coverage. Neither explicitly shuts down the coop event loop.

---

# journal - deep dive: timeout root causes

## Analysis of timeout patterns

Examining the code reveals several potential causes for test timeout:

### 1. Outputter infinite loops

The outputter's `:start()` method in [`outputter.lua:42-53`](/lua/termichatter/outputter.lua:42-53):

```lua
function out:start()
    while true do
        local msg = queue:pop()  -- coop async wait
        if not msg then break end
        if protocol.isCompletion(msg) then break end
        self:write(msg)
    end
end
```

The loop waits on `queue:pop()` which is a coop async operation. Tests push `done` or `shutdown` to terminate, but if the coop task scheduling is off, the signal may not be processed.

### 2. Driver timers not cleaned up

Tests in [`init_spec.lua:234-280`](/tests/termichatter/init_spec.lua:234-280) test interval and rescheduler drivers:

```lua
it("calls callback on interval", function()
    local count = 0
    local driver = termichatter.drivers.interval(10, function()
        count = count + 1
    end)
    driver.start()
    vim.wait(50, function() return count >= 3 end, 5)
    driver.stop()
    assert.is_true(count >= 3)
end)
```

Even after `driver.stop()`, there may be pending libuv handles. The driver properly calls `timer:close()` but busted's event loop may still be waiting.

### 3. Coop task lifecycle

The busted test framework doesn't have native awareness of coop.nvim's coroutine scheduler. When a test completes:

1. Test assertions pass
2. Coop tasks may still be suspended on async operations
3. busted moves to next test or exits
4. If busted tries to exit, pending coop tasks block

### 4. integration_spec outputter pattern

In [`integration_spec.lua:26-61`](/tests/termichatter/integration_spec.lua:26-61):

```lua
local outTask = coop.spawn(function()
    bufOut:start()  -- Runs forever until completion signal
end)
module:info("Starting up")
module.outputQueue:push(termichatter.completion.done)
outTask:await(200, 10)  -- Wait for task to complete
vim.wait(100, ...)      -- Additional wait for buffer
```

The `outTask:await(200, 10)` should wait up to 200ms for the task to finish. But if the task never receives the `done` signal (due to queue ordering or timing), it hangs.

## Missing test suite: line_spec.lua

The test matrix lists `line_spec.lua` but this file does not exist. The line module ([`lua/termichatter/line.lua`](/lua/termichatter/line.lua)) has no dedicated tests.

---

# journal - code coverage analysis

## Core module test coverage

| Module | Tests | Coverage Notes |
| ------ | ----- | -------------- |
| [`init.lua`](/lua/termichatter/init.lua) | init_spec | Partially tested, timeout issues |
| [`line.lua`](/lua/termichatter/line.lua) | **none** | No dedicated tests |
| [`pipe.lua`](/lua/termichatter/pipe.lua) | pipe_spec | Fully tested ✅ |
| [`run.lua`](/lua/termichatter/run.lua) | run_spec | Good coverage, 1 fork bug |
| [`registry.lua`](/lua/termichatter/registry.lua) | resolver_spec | Tested indirectly |
| [`resolver.lua`](/lua/termichatter/resolver.lua) | resolver_spec | Fully tested ✅ |
| [`consumer.lua`](/lua/termichatter/consumer.lua) | consumer_spec | Basic coverage ✅ |
| [`segment.lua`](/lua/termichatter/segment.lua) | init_spec | Tested via init |
| [`driver.lua`](/lua/termichatter/driver.lua) | init_spec | Timeout issues |
| [`outputter.lua`](/lua/termichatter/outputter.lua) | integration_spec | Timeout issues |
| [`protocol.lua`](/lua/termichatter/protocol.lua) | init_spec, consumer_spec | Partial |
| [`inherit.lua`](/lua/termichatter/inherit.lua) | run_spec | Tested indirectly |

## Uncovered paths

- [`line:clone()`](/lua/termichatter/line.lua:16) with various config combinations
- [`line:resolve_segment()`](/lua/termichatter/line.lua:52) inheritance chain
- [`line:ensure_mpsc()`](/lua/termichatter/line.lua:82) and interaction with run
- Error handling paths in most modules

---

# Summary

## What's Working

1. **Core pipe operations** - splice, clone, journal tracking
2. **Run execution** - segment resolution, position tracking, output push
3. **Lattice resolver** - Kahn's algorithm, dependency injection
4. **Basic consumer** - async stage processing
5. **Registry** - segment registration and resolution

## What's Broken

### 1. Fork fact inheritance (run_spec.lua:243)

The `Run:fork()` method doesn't properly snapshot facts that are inherited via metatable. The `own("fact")` method uses `rawget(self, "fact")` which returns nil for cloned runs since facts are accessed via metatable.

**Fix location**: [`run.lua:185-201`](/lua/termichatter/run.lua:185-201)

### 2. Test timeout (init_spec, pipeline_spec, integration_spec)

Tests using coop.nvim async operations don't exit cleanly. Root causes:
- Outputter `:start()` loops wait indefinitely on queue
- Driver timers may not be fully cleaned up
- busted has no awareness of coop task lifecycle

**Fix locations**: 
- [`outputter.lua:42-53`](/lua/termichatter/outputter.lua:42-53)
- Test runner setup in [`tests/busted.lua`](/tests/busted.lua)

### 3. Missing line_spec.lua

The line module has no dedicated tests despite being a core component.

---

# Decision Points

1. **Fix fork or change test expectations?**
   - Fix: Update `own("fact")` to traverse metatable inheritance
   - Alternative: Change test to not expect line facts in fork snapshot

2. **How to handle test cleanup?**
   - Option A: Add explicit cleanup step to busted.lua that cancels all coop tasks
   - Option B: Use `vim.uv.stop()` after tests complete
   - Option C: Add timeout wrapper around each test
   - Option D: Refactor outputter to use non-blocking pattern

3. **Add line_spec.lua?**
   - Yes: Creates better isolation for line module bugs
   - No: Rely on integration tests to cover line behavior

4. **Protocol for completion tracking**
   - Current: Tests push `done` but don't track hello/done balance
   - Alternative: Use `protocol.createTracker()` in tests for proper coordination

---

# References

- [`README.md`](/README.md) - Architecture documentation
- [`doc/review/pipecopy-next.md`](/doc/review/pipecopy-next.md) - Design review
- [coop.nvim](https://github.com/gregorias/coop.nvim) - Async coroutine library
- [mpsc-completion](https://github.com/rektide/mpsc-completion) - Completion protocol spec
