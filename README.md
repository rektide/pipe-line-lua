# pipe-line

> Structured data-flow pipeline for Lua, with async queue handoff via [coop.nvim](https://github.com/gregorias/coop.nvim)

pipe-line gives you a composable processing pipeline that's easy to start with and grows with your needs. At its simplest, it's a structured logger — `app:info("hello")` sends a message through a chain of segments that timestamp it, tag it with a source, and push it to an output queue. But because every piece of the pipeline is a first-class object you can inspect, splice, clone, and extend, the same model scales to async processing, fan-out, dependency-injected segment graphs, and coordinated shutdown.

Messages flow through an ordered sequence of **segments**. Each segment transforms, filters, or enriches the data. Segments are resolved by name from a **registry**, so pipelines are declarative — just a list of names — until the moment they run. A **lattice resolver** can even fill in missing segments automatically based on dependency metadata. When you need an async boundary, drop in an `mpsc_handoff` and the pipeline splits into sync and async halves connected by a queue.

## Core Runtime Model

```
Registry (segment library)
    ↓ resolve by name
  Line (pipeline config + output)
    ↓ creates
  Run (cursor walking the pipe, executing segments)
    ↓ pushes to
  Output (mpsc queue → outputter)
```

| Term | Description |
|------|-------------|
| **Line** | Pipeline definition: holds a pipe, registry, output queue, and config. Create child lines for module-scoped context. |
| **Pipe** | Ordered array of segments — a first-class object with revision tracking and splice journaling. |
| **Segment** | Processing step: `handler(run)` plus optional lifecycle hooks (`init`, `ensure_prepared`, `ensure_stopped`) and dependency metadata (`wants`/`emits`). |
| **Run** | Lightweight cursor that walks a pipe, executing each segment in order. Supports clone/fork for fan-out and independence. |
| **Registry** | Library of known segment types, indexed by name. Maintains an `emits_index` for lattice resolver dependency injection. Supports inheritance via `derive()`. |
| **Fact** | Named capability tracked on line and/or run — the currency of the lattice resolver. Segments declare what they `want` and what they `emit`. |

## Installation

Requires [coop.nvim](https://github.com/gregorias/coop.nvim).

```lua
-- lazy.nvim
{
    "rektide/pipe-line",
    dependencies = { "gregorias/coop.nvim" },
}
```

## Quick Start

```lua
local pipeline = require("pipe-line")

-- Create a pipeline (module is callable)
local app = pipeline({ source = "myapp:main" })

-- Log directly on the line
app:info("Application starting")
app:error("Something went wrong")

-- Create thin child lines for module context
local startup = app:child("startup")
startup:info("Initializing")
startup:debug("Config loaded", { config = { debug = true } })

-- Messages arrive in app.output (an mpsc queue)
```

Log methods: `error`, `warn`, `info`, `debug`, `trace`, and generic `log`. Each normalizes a payload through the line's `sourcer` and level system, then sends it through the pipe via `line:run()`.

Levels are numeric multiples of 10 (error=10, warn=20, info=30, log=40, debug=50, trace=60). Control the default with `pipeline.set_default_level("info")`.

## Segment Contract

The segment contract is centered on one run-facing verb ([`/doc/segment-authoring.md`](/doc/segment-authoring.md)):

```lua
handler(run)
```

Lifecycle hooks:

- `init(context)` — per-instance setup when segment is materialized
- `ensure_prepared(context)` — readiness/start hook (idempotent)
- `ensure_stopped(context)` — stop hook (idempotent)

### Minimal Segment

```lua
registry:register("tagger", function(run)
    run.input.tagged = true
    return run.input
end)
```

### Table Segment with Metadata

```lua
registry:register("validator", {
    type = "validator",
    wants = { "time" },        -- facts this segment requires
    emits = { "validated" },   -- facts this segment produces
    handler = function(run)
        run.input.validated = true
        return run.input
    end,
})
```

### Handler Return Semantics

- **table** → replaces `run.input` for the next segment
- **`false`** → stops this run path (message filtered)
- **`nil`** → keeps current `run.input` unchanged

Boundary segments typically return `false` after handing off a continuation, then call `continuation:next(...)` later.

### Protocol-Aware Segments

`segment.define(spec)` wraps handler behavior with protocol pass-through defaults, keeping completion protocol handling consistent across custom segments ([`/lua/pipe-line/segment/define.lua`](/lua/pipe-line/segment/define.lua)).

## Async Model

Async handoff is explicit: insert an `mpsc_handoff` segment where you want a queue boundary ([`/doc/async-handoff.md`](/doc/async-handoff.md)).

```lua
local app = pipeline({ source = "myapp" })

app.pipe = pipeline.Pipe({
    "timestamper",
    "mpsc_handoff",   -- explicit async boundary (independent queue)
    "cloudevent",
    "module_filter",
})

app:info("async message")

-- Shutdown
app:close():await(500, 10)
```

Handoff queue consumers start automatically via segment lifecycle (`ensure_prepared`). Disable with `autoStartConsumers = false` and call `line:ensure_prepared()` manually later.

### Custom Handoff

```lua
local segment = require("pipe-line.segment")
local handoff = segment.mpsc_handoff({ strategy = "fork" })
```

Strategy controls how the continuation run is created: `self` (default, zero-alloc), `clone` (lightweight copy), or `fork` (fully independent).

### Run-Owned Continuation

Continuation tracking is run-centric. `mpsc_handoff` carries continuation runs across the queue boundary; it transports them, it doesn't redefine run semantics. If per-run continuation bookkeeping is needed, use `run.continuation` ([`/doc/segment-instancing.md`](/doc/segment-instancing.md)).

## Stop Model

Line lifecycle orchestration follows a prepare → stop sequence ([`/doc/lifecycle.md`](/doc/lifecycle.md)):

```lua
-- High-level shutdown:
app:close()  -- calls ensure_prepared(), then ensure_stopped()

-- Or step by step:
app:ensure_prepared()
app:ensure_stopped()
```

Each line owns a `stopped` future. `ensure_stopped()` collects segment stop handles, calls `segment.ensure_stopped(context)` on each, awaits all, and resolves `line.stopped`.

For task transport segments, stop strategy is selected by `stop_type` ([`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)):

- `stop_drain` (default) — drains pending work before final resolution
- `stop_immediate` — prioritizes prompt stop

### Waiting by Segment Type

Use selector-based live stop handles for targeted waits ([`/doc/selecting.md`](/doc/selecting.md)):

```lua
local completion_stopped = app:stopped_live("completion")
app:close()
completion_stopped:await(1000, 10)
```

## Line

Create a line by calling the module:

```lua
local app = pipeline({ source = "myapp" })
```

Configuration:

| Field | Description |
|-------|-------------|
| `source` | Local source segment for this line |
| `pipe` | Array of segment names (default: `timestamper`, `ingester`, `cloudevent`, `module_filter`, `completion`) |
| `registry` | Segment registry (default: global registry) |
| `output` | Output mpsc queue (default: new queue) |
| `filter` | Pattern or function for module filtering |
| `parent` | Parent Line for inheritance |
| `auto_id` | Auto-assign runtime segment ids (default: `true`) |
| `auto_fork` | Use segment `fork()` when available (default: `true`) |
| `auto_instance` | Create thin runtime segment instances (default: `true`) |
| `auto_completion_done_on_close` | Auto-emit completion `done` on close (default: `true`) |
| `autoStartConsumers` | Auto-start handoff queue consumers (default: `true`) |

### Child Lines and Forks

Child lines are thin — they inherit from the parent via metatable and share pipe/output/fact ([`/doc/metatables.md#child-vs-fork`](/doc/metatables.md#child-vs-fork)):

```lua
local auth = app:child("auth")
local jwt = auth:child("jwt")

jwt:full_source()  -- "myapp:auth:jwt"
```

Forks are independent — they own their own pipe, output, and fact:

```lua
local worker = app:fork("worker")
```

### Adding Segments at Runtime

```lua
-- Insert a named segment with a handler
app:addSegment("my_enricher", function(run)
    run.input.enriched = true
    return run.input
end)

-- Insert an async boundary at position 2
app:addHandoff(2, { strategy = "clone" })
```

## Pipe

The ordered sequence of segments. A first-class object with revision tracking and splice journaling:

```lua
local Pipe = require("pipe-line.pipe")

local p = Pipe({ "timestamper", "enricher", "validator" })
p:splice(2, 0, "new_segment")  -- insert at position 2
p:clone()                       -- independent copy
p.rev                           -- revision counter
```

Runs track pipe revision and sync their position after splices via `run:sync()`.

## Run

A run is a lightweight cursor that walks the pipe one segment at a time. When you call `app:info("hello")`, the line creates a run, sets `run.input` to the normalized message payload, and calls `run:execute()`. The run iterates through each segment in order — resolving names from the registry, calling `handler(run)`, and updating `run.input` with whatever the handler returns. When it falls off the end, it pushes the final `run.input` to the line's output queue.

The run also acts as the segment's window into the pipeline. Segments read `run.input` for the current element, and because the run's metatable chains to the line, fields like `run.source`, `run.filter`, and `run.registry` are all available without explicit plumbing ([`/doc/metatables.md#run-to-line`](/doc/metatables.md#run-to-line)).

```lua
local Run = require("pipe-line.run")

-- Usually you don't create runs directly — line:run() does it.
-- But for testing or custom control:
local r = Run(line, { input = { message = "hello" }, noStart = true })
r:execute()  -- walk the pipe from current pos to end
```

### Fan-Out

A segment can produce multiple outputs by cloning or forking the run. Each clone gets its own `input` but shares everything else with the parent — pipe, fact, output — keeping fan-out cheap. Use `emit` for the common case:

```lua
registry:register("splitter", function(run)
    for _, part in ipairs(run.input.parts) do
        run:emit(part)           -- clone + next: each part continues independently
    end
    -- return nil: we handled forwarding ourselves
end)
```

When you need full independence — your own pipe, your own fact table — fork instead:

```lua
local independent = run:fork(new_element)  -- owns everything, detached from line
```

### Ownership and Independence

Runs start out lightweight and share everything with the line via metatable read-through ([`/doc/metatables.md#cheap-derivation`](/doc/metatables.md#cheap-derivation)). You can selectively take ownership of individual fields when you need isolation — `run:own("pipe")` snapshots the pipe so splices don't affect the parent, `run:own("fact")` snapshots the fact table, and `run:set_fact("name")` lazily creates a per-run fact overlay without touching the line ([`/doc/metatables.md#breaking-chains`](/doc/metatables.md#breaking-chains)).

| Operation | Cost | When to use |
|-----------|------|-------------|
| `run:next()` | 0 alloc | Normal single-element flow — just advance the cursor |
| `run:emit(el)` | 1 small table | Fan-out: clone + next in one call |
| `run:clone(el)` | 1 small table | Fan-out when you need the child run reference |
| `run:clone(el)` + `set_fact()` | 2 small tables | Fan-out with per-element fact tracking |
| `run:fork(el)` | Everything cloned | Full detach — independent pipe, fact, output |

### Pipe Sync

If the pipe is spliced while a run is in flight (e.g. by the lattice resolver), the run adjusts its position on the next `execute()` or `next()` call using the pipe's splice journal. This keeps the run's cursor consistent even as the pipe mutates underneath it.

## Registry

Repository of known segments. Supports inheritance via `derive()`, which creates a child registry that reads through to its parent via metatable ([`/doc/metatables.md#registry-derivation`](/doc/metatables.md#registry-derivation)):

```lua
local Registry = require("pipe-line.registry")

-- Global registry (pre-populated with built-in segments)
local reg = pipeline.registry
reg:register("my_segment", handler)

-- Child registry inheriting from parent
local child_reg = reg:derive()
child_reg:register("local_segment", handler)
```

The registry maintains an `emits_index` — a map from fact name to segments that emit it — updated incrementally on each `register()` call. Use `registry:get_emits_index()` for the effective index across the inheritance chain.

## Lattice Resolver

A segment that dynamically splices dependency-satisfying segments into the pipe at runtime. It inspects downstream `wants`, queries the registry's `emits_index`, computes a topological sort (Kahn's algorithm), and splices the result.

```lua
local app = pipeline({
    pipe = { "timestamper", "lattice_resolver", "final_output" },
})

-- If final_output wants: ["enriched", "validated"]
-- and the registry has enricher (emits: ["enriched"])
-- and validator (wants: ["time"], emits: ["validated"])
--
-- The resolver will splice them in:
-- [timestamper, enricher, validator, final_output]
```

Options (read from run, inheritable from line):

| Option | Description |
|--------|-------------|
| `resolver_keep` | Keep the resolver in the pipe after resolving (default: `false`) |
| `resolver_lookahead` | Max downstream segments to scan (default: all) |
| `resolver_emits_index` | Pre-built emits index to use |

Static resolution without running:

```lua
local resolver = require("pipe-line.resolver")
resolver.resolve_line(my_line)  -- modifies line.pipe directly
```

## Segment Instancing

Registry entries are shared prototypes. The line runtime creates per-line instances automatically via metatable delegation, controlled by `auto_fork`, `auto_instance`, and `auto_id` ([`/doc/segment-instancing.md`](/doc/segment-instancing.md), [`/doc/metatables.md#segment-instance-delegation`](/doc/metatables.md#segment-instance-delegation)).

Each runtime segment table exposes:

- `type` — selector identity (matched by `line:select_segments("type_name")`)
- `id` — unique runtime identity per line slot

## Completion Protocol

Implements the [mpsc-completion](https://github.com/rektide/mpsc-completion) protocol for coordinating async pipeline shutdown ([`/doc/completion-protocol.md`](/doc/completion-protocol.md)):

```lua
local protocol = require("pipe-line.protocol")

-- Build protocol runs (control is on run fields, not input)
local hello = protocol.completion.completion_run("hello", "worker:a")
local done = protocol.completion.completion_run("done", "worker:a")

app:run(hello)
app:run(done)
```

The built-in `completion` segment tracks hello/done accounting and resolves its `stopped` future when settled (done ≥ hello).

## Output

Messages that complete the pipe are pushed to the line's `output` queue:

```lua
local coop = require("coop")
local app = pipeline({ source = "myapp" })

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
| `outputter.jsonl(config)` | Write JSON Lines |
| `outputter.fanout(config)` | Forward to multiple outputters |

```lua
local outputter = require("pipe-line.outputter")

local bufOut = outputter.buffer({
    name = "MyLog",
    queue = app.output,
})
bufOut:start_async()

local fan = outputter.fanout({
    outputters = { bufOut, fileOut },
    queue = app.output,
})
```

### Driver

Schedule periodic execution:

```lua
local driver = require("pipe-line.driver")

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

## Built-in Segments

| Segment | Wants | Emits | Description |
|---------|-------|-------|-------------|
| `timestamper` | — | `time` | Add `time` field with `vim.uv.hrtime()` |
| `cloudevent` | — | `cloudevent` | Add `id`, `source`, `type`, `specversion` |
| `module_filter` | — | — | Filter by source pattern (string or function) |
| `level_filter` | — | — | Filter by log level (`max_level` on line or run) |
| `ingester` | — | — | Apply custom decoration function (`ingest` on line or run) |
| `completion` | — | — | Track completion protocol; resolve `stopped` when settled |
| `lattice_resolver` | — | — | Dependency injection via pipeline self-rewriting |

Async boundary helper:

| Helper | Description |
|--------|-------------|
| `segment.mpsc_handoff(config)` | Create explicit queue handoff segment (strategy: `self`/`clone`/`fork`) |

## Structured Messages

Messages are Lua tables with conventional fields:

| Field | Description |
|-------|-------------|
| `time` | High-resolution timestamp (hrtime nanoseconds) |
| `id` | UUID v4 identifier |
| `source` | Origin URI (e.g. `"myapp:auth:jwt"`) |
| `type` | Event type (`"pipe-line.log"`) |
| `specversion` | CloudEvents version (`"1.0"`) |
| `level` | Numeric log level (multiples of 10) |
| `message` | Human-readable message string |

## Further Reading

Core documentation:

- Segment authoring and hook contracts: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Segment instancing and selectors: [`/doc/segment-instancing.md`](/doc/segment-instancing.md)
- Selector utilities and live stop waiting: [`/doc/selecting.md`](/doc/selecting.md)
- Line lifecycle orchestration: [`/doc/lifecycle.md`](/doc/lifecycle.md)
- Async queue boundaries: [`/doc/async-handoff.md`](/doc/async-handoff.md)
- Completion control protocol: [`/doc/completion-protocol.md`](/doc/completion-protocol.md)
- Metatable chains and ownership model: [`/doc/metatables.md`](/doc/metatables.md)

Architecture decisions:

- Transport policy interface: [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)
- Stop drain and cancel signal: [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)
- ADR index: [`/doc/adr/README.md`](/doc/adr/README.md)

## Testing

```bash
# Run all tests
nvim -l tests/busted.lua

# Run specific test file
nvim -l tests/busted.lua tests/pipe-line/run_spec.lua
```

## Benchmarking

```bash
# Full benchmark pass with history tracking
cargo run --bin bench-history

# Reports at target/criterion/report/index.html
```

## Module Reference

| Module | Export | Description |
|--------|--------|-------------|
| `pipe-line` | callable → Line | Entry point, registers built-in segments |
| `pipe-line.line` | Line | Pipeline class, callable constructor |
| `pipe-line.pipe` | Pipe | Segment sequence, callable constructor |
| `pipe-line.run` | Run | Execution cursor, callable constructor |
| `pipe-line.registry` | Registry | Segment repository, callable constructor |
| `pipe-line.segment` | table | Built-in segment definitions |
| `pipe-line.segment.define` | table | Segment definition wrapper with protocol pass-through |
| `pipe-line.resolver` | table | Lattice resolver + Kahn's sort |
| `pipe-line.consumer` | table | Async mpsc queue consumer for handoff boundaries |
| `pipe-line.outputter` | table | Output destinations (buffer, file, jsonl, fanout) |
| `pipe-line.driver` | table | Periodic scheduling (interval, rescheduler) |
| `pipe-line.protocol` | table | Completion/shutdown protocol |
| `pipe-line.log` | table | Level constants, normalization, source composition |
| `pipe-line.inherit` | table | Metatable inheritance utility |

## License

MIT
