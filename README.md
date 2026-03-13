# pipe-line

> Structured data-flow pipeline for Lua, with async queue handoff via [coop.nvim](https://github.com/gregorias/coop.nvim)

pipe-line is a composable pipeline library. Messages flow through an ordered sequence of **segments** — each transforming, filtering, or enriching the data. The primary use case is structured logging within Neovim, but the core model is general-purpose: any ordered processing pipeline with optional async boundaries and dependency injection.

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
| **Line** | Pipeline definition: holds a pipe, registry, output queue, config |
| **Pipe** | Ordered array of segments — first-class object with revision tracking and splice journaling |
| **Segment** | Processing component: `handler(run)` plus optional lifecycle hooks and metadata |
| **Run** | Lightweight cursor that walks a pipe, executing each segment |
| **Registry** | Repository of known segment types, indexed by name, with `emits_index` for dependency resolution |
| **Fact** | Named capability tracked on line and/or run for lattice resolver dependency injection |

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

Child lines are thin — they inherit from the parent via metatable and share pipe/output/fact:

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

A lightweight cursor that walks the pipe. Access the element via `run.input`, line config via the run's metatable chain to the line.

```lua
local Run = require("pipe-line.run")
local r = Run(line, { input = { message = "hello" }, noStart = true })
r:execute()    -- walk the pipe from current pos
r:next()       -- advance and continue
r:emit(el)     -- clone + next for fan-out
r:clone(el)    -- lightweight copy sharing everything with parent
r:fork(el)     -- fully independent copy (own pipe + fact)
r:own("pipe")  -- take ownership, breaking line read-through
r:set_fact("time")  -- lazily create per-run fact
```

### Independence Spectrum

| Operation | Cost | Use case |
|-----------|------|----------|
| `run:next()` | 0 alloc | Normal single-element flow |
| `run:emit(el)` | 1 small table | Fan-out convenience (default: clone strategy) |
| `run:clone(el)` | 1 small table | Fan-out, shares everything |
| `run:clone(el)` + `set_fact()` | 2 small tables | Per-element fact |
| `run:fork(el)` | Everything cloned | Full detach from line |

## Registry

Repository of known segments. Supports inheritance via `derive()`:

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

Registry entries are shared prototypes. The line runtime creates per-line instances automatically, controlled by `auto_fork`, `auto_instance`, and `auto_id` ([`/doc/segment-instancing.md`](/doc/segment-instancing.md)).

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
