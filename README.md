# termichatter

> Structured data-flow pipeline for Neovim, with async queue handoff via [coop.nvim](https://github.com/gregorias/coop.nvim)

## Core Concept

```
Registry (segment library)
    ↓ resolve by name
  Line (pipeline config + output)
    ↓ creates
  Run (cursor walking the pipe, executing segment)
    ↓ pushes to
  Output (mpsc queue → outputter)
```

Messages flow through a **pipe** — an ordered sequence of **segment**. Each segment transforms, filters, or enriches the message. Segment are resolved by name from a **registry**. A **run** walks the pipe for each message, and a **lattice resolver** can dynamically splice dependency-satisfying segment into the pipe at runtime.

## Glossary

| Term | Description |
|------|-------------|
| **Line** | Pipeline definition: holds a pipe, registry, output queue, config |
| **Pipe** | Ordered array of segment, first-class object with `rev`/`splice`/`clone` |
| **Segment** | Processing component in a pipe (handler with optional `wants`/`emits` metadata) |
| **Run** | Lightweight cursor/context that walks a pipe, executing each segment |
| **Registry** | Repository of known segment type, indexed by name |
| **Fact** | Named capability tracked on line and/or run for dependency resolution |

## Installation

Requires [coop.nvim](https://github.com/gregorias/coop.nvim).

```lua
-- lazy.nvim
{
    "rektide/nvim-termichatter",
    dependencies = { "gregorias/coop.nvim" },
}
```

## Quick Start

```lua
local termichatter = require("termichatter")

-- Create a pipeline (module is callable)
local app = termichatter({ source = "myapp:main" })

-- Log directly on the line
app:info("Application starting")
app:error("Something went wrong")

-- Or create a logger with module context
local log = app:baseLogger({ module = "startup" })
log.info("Initializing")
log.debug({ message = "Config loaded", config = { debug = true } })

-- Messages arrive in app.output (an mpsc queue)
```

## Architecture

### Line

A Line is the pipeline definition. Create one by calling the module:

```lua
local app = termichatter({ source = "myapp" })
```

Configuration:

| Field | Description |
|-------|-------------|
| `source` | Default source URI for messages |
| `pipe` | Array of segment name (default: timestamper, ingester, cloudevent, module_filter) |
| `registry` | Segment registry (default: global registry) |
| `output` | Output mpsc queue (default: new queue) |
| `filter` | Pattern or function for module filtering |
| `parent` | Parent Line for inheritance |

Child line inherit config from parent via metatable:

```lua
local auth = app:derive({ source = "myapp:auth" })
print(auth.source)  -- "myapp:auth"
-- auth inherits app's registry, filter, etc.
```

### Pipe

The ordered sequence of segment. A first-class object with revision tracking and splice journaling.

```lua
local Pipe = require("termichatter.pipe")

local p = Pipe({ "timestamper", "enricher", "validator" })
p:splice(2, 0, "new_segment")  -- insert at position 2
p:clone()                       -- independent copy
p.rev                           -- revision counter
```

### Segment

A processing component. Can be a plain function or a table with metadata:

```lua
-- Simple function segment
registry:register("tagger", function(run)
    run.input.tagged = true
    return run.input
end)

-- Segment with dependency metadata (for lattice resolver)
registry:register("validator", {
    wants = { "time" },        -- fact this segment requires
    emits = { "validated" },   -- fact this segment produces
    handler = function(run)
        run.input.validated = true
        return run.input
    end,
})
```

Segment receive the **run** as their sole argument. Access the element via `run.input`, line config via `run.source`, `run.filter`, etc.

Return values:
- **table** — becomes the next segment's input
- **`false`** — stop the pipeline (message filtered)
- **`nil`** — segment handled forwarding itself (fan-out via `run:clone()`)

### Run

A lightweight cursor that walks the pipe. Supports cloning for fan-out and ownership for independence.

```lua
local Run = require("termichatter.run")

-- Normally created via line:run(), but can be manual:
local r = Run(line, { input = { message = "hello" }, noStart = true })
r:execute()    -- walk the pipe from current pos
r:next()       -- advance and continue
r:emit(el)     -- clone + next convenience for fan-out
r:clone(el)    -- lightweight copy for fan-out
r:fork(el)     -- fully independent copy
r:own("pipe")  -- take ownership, breaking line read-through
r:own("fact")  -- snapshot fact for independence
r:set_fact("time")  -- lazily create per-run fact
r:sync()       -- sync pos with line's pipe after splice
```

#### Fan-Out

A segment can emit multiple element by cloning the run:

```lua
registry:register("splitter", function(run)
    for _, part in ipairs(run.input.part) do
        run:emit(part)
    end
    -- return nil: we handled forwarding
end)
```

#### Independence Spectrum

| Operation | Cost | Use case |
|-----------|------|----------|
| `run:next()` | 0 alloc | Normal single-element flow |
| `run:emit(el)` | 1 small table | Fan-out convenience |
| `run:clone(el)` | 1 small table | Fan-out, shares everything |
| `run:clone(el)` + `set_fact()` | 2 small table | Per-element fact |
| `run:fork(el)` | Everything cloned | Full detach from line |

### Registry

Repository of known segment. Supports inheritance via `derive()`:

```lua
local Registry = require("termichatter.registry")

-- Global registry (pre-populated with built-in segment)
local reg = termichatter.registry
reg:register("my_segment", handler)

-- Child registry inheriting from parent
local child_reg = reg:derive()
child_reg:register("local_segment", handler)
```

The registry maintains an `emits_index` — a map from fact name to segment that emit it — updated incrementally on each `register()` call.

### Lattice Resolver

A segment that dynamically splices dependency-satisfying segment into the pipe at runtime. It inspects downstream `wants`, queries the registry's `emits_index`, computes a topological sort (Kahn's algorithm), and splices the result.

```lua
local app = termichatter({
    pipe = { "timestamper", "lattice_resolver", "final_output" },
})

-- If final_output wants: ["enriched", "validated"]
-- and the registry has enricher (emits: ["enriched"])
-- and validator (wants: ["time"], emits: ["validated"])
--
-- The resolver will splice them in:
-- [timestamper, enricher, validator, final_output]
```

Options (set on line or run):

| Option | Description |
|--------|-------------|
| `resolver_keep` | Keep the resolver in the pipe after resolving (default: false) |
| `resolver_lookahead` | Max downstream segment to scan (default: all) |
| `resolver_emits_index` | Pre-built emits index to use |

Static resolution without running:

```lua
local resolver = require("termichatter.resolver")
resolver.resolve_line(my_line)  -- modifies line.pipe directly
```

## Async Execution

Async handoff is explicit: insert a `mpsc_handoff` segment into the pipe.

```lua
local app = termichatter({ source = "myapp" })
local segment = require("termichatter.segment")

-- Optional custom boundary with strategy/queue control
local custom_handoff = segment.mpsc_handoff({ strategy = "fork" })

app.pipe = require("termichatter.pipe")({
    "timestamper",
    "mpsc_handoff", -- default boundary from registry (independent queue)
    -- custom_handoff, -- use this instead if you want custom strategy/queue
    "cloudevent",
    "module_filter",
})

-- Log (handoff consumer starts automatically)
app:info("async message")

-- Optional cleanup when shutting down
app:stopConsumer()

-- Advanced control: disable auto-start and start later
local delayed = termichatter({ autoStartConsumers = false })
delayed.pipe = require("termichatter.pipe")({ "mpsc_handoff", "cloudevent" })
delayed:info("queued, not yet consumed")
delayed:startConsumer() -- begin draining handoff queues
```

## Output

Message that complete the pipe are pushed to the line's `output` queue:

```lua
local coop = require("coop")
local app = termichatter({ source = "myapp" })

-- Consume output
coop.spawn(function()
    while true do
        local msg = app.output:pop()
        print(vim.inspect(msg))
    end
end)
```

### Outputter

| Type | Description |
|------|-------------|
| `outputter.buffer(config)` | Write to nvim buffer |
| `outputter.file(config)` | Append to file |
| `outputter.jsonl(config)` | Write JSON Line |
| `outputter.fanout(config)` | Forward to multiple outputter |

```lua
local outputter = require("termichatter.outputter")

-- Buffer outputter with queue-driven consumer
local bufOut = outputter.buffer({
    name = "MyLog",
    queue = app.output,
})
coop.spawn(function() bufOut:start() end)

-- Fanout to multiple destination
local fan = outputter.fanout({
    outputter = { bufOut, fileOut },
    queue = app.output,
})
```

### Driver

Schedule periodic execution:

```lua
local driver = require("termichatter.driver")

-- Fixed interval
local d = driver.interval(100, function()
    processMessage()
end)
d.start()
d.stop()

-- Adaptive backoff
local d = driver.rescheduler({
    interval = 50,
    backoff = 1.5,
    maxInterval = 2000,
}, callback)
```

## Completion Protocol

Implements the [mpsc-completion](https://github.com/rektide/mpsc-completion) protocol for coordinating async pipeline shutdown:

```lua
local protocol = require("termichatter.protocol")

-- Signal lifecycle
app.output:push(protocol.hello)  -- producer starting
app.output:push(protocol.done)   -- producer finished

-- Check signal
protocol.isCompletion(msg)  -- true for hello/done/shutdown
protocol.isShutdown(msg)    -- true for shutdown only

-- Reference counting tracker
local tracker = protocol.createTracker(app.output)
tracker:hello()
tracker:done()  -- emits shutdown when hello count == done count
```

## Built-in Segment

| Segment | Wants | Emits | Description |
|---------|-------|-------|-------------|
| `timestamper` | — | `time` | Add `time` field with `vim.uv.hrtime()` |
| `cloudevent` | — | `cloudevent` | Add `id`, `source`, `type`, `specversion` |
| `module_filter` | — | — | Filter by source pattern (string or function) |
| `priority_filter` | — | — | Filter by log level |
| `ingester` | — | — | Apply custom decoration function |
| `lattice_resolver` | — | — | Dependency injection via pipeline self-rewriting |

Async boundary helper:

| Helper | Description |
|--------|-------------|
| `segment.mpsc_handoff(config)` | Create explicit queue handoff segment (`config.queue` optional, segment strategy: `self`/`clone`/`fork`) |

## Structured Message

Message are Lua table with conventional field:

| Field | Description |
|-------|-------------|
| `time` | High-resolution timestamp (hrtime nanosecond) |
| `id` | UUID v4 identifier |
| `source` | Origin URI (e.g. `"myapp:auth:jwt"`) |
| `type` | Event type (`"termichatter.log"`) |
| `specversion` | CloudEvents version (`"1.0"`) |
| `priority` | Log level name (error, warn, info, debug, trace) |
| `priorityLevel` | Numeric priority (1–6) |
| `message` | Human-readable message string |

## Testing

```bash
# Run all test
nvim -l tests/busted.lua

# Run specific test file
nvim -l tests/busted.lua tests/termichatter/run_spec.lua
```

## Benchmarking

Benchmark each test suite through Rust Criterion:

```bash
# Full benchmark pass with history tracking
cargo run --bin bench-history

# Reports at target/criterion/report/index.html
```

## Module Reference

| Module | Export | Description |
|--------|--------|-------------|
| `termichatter` | callable → Line | Entry point, registers built-in segment |
| `termichatter.line` | Line | Pipeline class, callable constructor |
| `termichatter.pipe` | Pipe | Segment sequence, callable constructor |
| `termichatter.run` | Run | Execution cursor, callable constructor |
| `termichatter.registry` | Registry | Segment repository, callable constructor |
| `termichatter.segment` | table | Built-in segment definition |
| `termichatter.resolver` | table | Lattice resolver + Kahn's sort |
| `termichatter.consumer` | table | Async mpsc consumer |
| `termichatter.outputter` | table | Output destination (buffer, file, jsonl, fanout) |
| `termichatter.driver` | table | Periodic scheduling (interval, rescheduler) |
| `termichatter.protocol` | table | Completion/shutdown protocol |
| `termichatter.inherit` | table | Metatable inheritance utility |

## License

MIT
