# pipe-line

Structured data-flow pipeline for Lua, with explicit async boundaries powered by [coop.nvim](https://github.com/gregorias/coop.nvim).

## Core Flow

```text
caller -> Line -> Run executes Pipe (Segment resolved by Registry) -> output queue
```

`pipe-line` is run-centric: each message is a `Run` cursor walking a declared `Pipe` on a `Line`.

## Runtime Model

| Piece | Runtime `type` | Constructor | Inheritance / lookup chain | Role |
|---|---|---|---|---|
| Module entry | n/a | `require("pipe-line")` callable | n/a | Creates a `Line` with default registry |
| `Line` | `"line"` | `pipeline(config)` or `pipeline.Line(config)` | own fields -> `Line` methods -> parent line | Declared pipeline and lifecycle owner |
| `Run` | `"run"` | `pipeline.Run(line, config)` or `line:run(...)` | own fields -> `Run` methods -> line | Executor cursor for one run path |
| `Pipe` | table/array | `pipeline.Pipe({...})` | own fields/entries -> `Pipe` methods | Ordered segment sequence with splice journal |
| Segment instance | segment-defined | resolved by line | own fields -> segment prototype | Per-line segment runtime state |
| Registry | `"registry"` | `pipeline.registry` or `pipeline.registry(config)` | own entries -> parent registry | Segment library (`register`, `resolve`, `derive`) |

For metatable chains and ownership details, see [`/doc/metatables.md`](/doc/metatables.md).

## Run (Executor)

`Run` is the execution engine. `Run:execute()` walks the pipe from `run.pos`, resolves each segment, calls `handler(run)`, and updates flow based on handler return values.

### Run Contract

| API | Purpose |
|---|---|
| `run:execute()` | Walk current pipe from current position |
| `run:next(value?)` | Continue to next segment (optionally overriding input) |
| `run:emit(value, strategy?)` | Fan-out convenience (`clone` by default) |
| `run:clone(value?)` | Lightweight child run sharing parent-owned state |
| `run:fork(value?)` | Independent child run (owns pipe/fact) |
| `run:own(field)` | Take ownership of a field (`pipe`, `fact`, etc.) |
| `run:set_fact(name, value?)` | Set per-run fact with line fallback |

### Handler Return Semantics

Inside `Run:execute()`, `handler(run)` return values are interpreted as:

- non-`nil`: replace `run.input`
- `nil`: keep current `run.input`
- `false`: stop this run path immediately

### Continuation Handoff

Async boundary segments commonly:

1. hand off a continuation run to async transport,
2. return `false` now,
3. call `continuation:next(...)` later.

When tracking is needed, continuation is run-owned at `run.continuation`.

See [`/doc/continuation-handoff.md`](/doc/continuation-handoff.md).

## Declared Pipe-line (Line / Pipe / Segment)

### Line

`Line` is the declared pipeline plus lifecycle orchestration.

Important config fields:

| Field | Meaning |
|---|---|
| `source` | Source segment for log metadata |
| `pipe` | Pipe entries (names/tables/functions) |
| `registry` | Registry used for name resolution |
| `output` | Output queue |
| `auto_id` | Auto-assign runtime segment ids |
| `auto_fork` | Use segment `fork()` when present |
| `auto_instance` | Create thin runtime instances when needed |
| `autoStartConsumers` | Start handoff consumers during prepare path |

Core line lifecycle:

- `line:ensure_prepared()`
- `line:ensure_stopped()`
- `line:close()` (prepare then stop)

See [`/doc/lifecycle.md`](/doc/lifecycle.md).

### Pipe

`Pipe` is an ordered sequence with revision tracking and splice journaling.

- supports insertion/removal via splice
- `Run:sync()` uses pipe splice journal to keep cursor position valid

### Segment

Segment contract is handler-first:

| Hook / field | Purpose |
|---|---|
| `type` | Stable segment identity |
| `init(context)` | Per-instance setup |
| `ensure_prepared(context)` | Readiness/start hook |
| `handler(run)` | Per-message processing entrypoint |
| `ensure_stopped(context)` | Shutdown hook |
| `wants` / `emits` | Dependency metadata for resolver |

`segment.define(...)` applies protocol-aware handler wrapping defaults.

See [`/doc/segment-authoring.md`](/doc/segment-authoring.md) and [`/doc/segment-instancing.md`](/doc/segment-instancing.md).

## Registry

Registry is the segment library.

| API | Purpose |
|---|---|
| `registry:register(name, handler_or_segment)` | Register or replace a segment |
| `registry:resolve(name)` | Resolve by name with parent fallback |
| `registry:derive(config?)` | Create child registry inheriting parent entries |
| `registry:get_emits_index()` | Effective emits index (merged with parent) |

Derived registries inherit parent behavior through metatables and maintain local override/index state.

## Async Boundaries

Async handoff is explicit using `mpsc_handoff`.

```lua
local pipeline = require("pipe-line")

local app = pipeline({ source = "myapp" })
app.pipe = pipeline.Pipe({
  "timestamper",
  "mpsc_handoff",
  "cloudevent",
  "completion",
})

app:info("async message")
```

Manual continuation mode (for tests/control) is documented in [`/doc/async-handoff.md`](/doc/async-handoff.md).

## Completion and Shutdown

Completion control runs are protocol fields on `run`, not payload fields on `run.input`.

- completion signals: `hello`, `done`, `shutdown`
- built-in `completion` segment tracks settled state and exposes stop awaitable behavior

See [`/doc/completion-protocol.md`](/doc/completion-protocol.md).

Stop strategy ADR (proposed) is documented at [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md).

## Quick Start

```lua
local pipeline = require("pipe-line")

local app = pipeline({ source = "myapp:main" })

app:info("booting")
app:error("something happened")

local auth = app:child("auth")
auth:debug("token seen")
```

## Built-in Segments

| Segment | Description |
|---|---|
| `timestamper` | Adds high-resolution time field |
| `ingester` | Optional enrichment/decoration hook |
| `cloudevent` | Adds CloudEvents envelope fields |
| `module_filter` | Source-based filtering |
| `level_filter` | Log level filtering |
| `completion` | Completion protocol accounting |
| `mpsc_handoff` | Explicit queue boundary |
| `lattice_resolver` | Runtime dependency splice/resolve |

## Docs Map

- Segment Contract: [`/doc/segment-authoring.md`](/doc/segment-authoring.md)
- Continuation Handoff: [`/doc/continuation-handoff.md`](/doc/continuation-handoff.md)
- Segment Instancing: [`/doc/segment-instancing.md`](/doc/segment-instancing.md)
- Lifecycle: [`/doc/lifecycle.md`](/doc/lifecycle.md)
- Async Handoff: [`/doc/async-handoff.md`](/doc/async-handoff.md)
- Completion Protocol: [`/doc/completion-protocol.md`](/doc/completion-protocol.md)
- ADR Index: [`/doc/adr/README.md`](/doc/adr/README.md)
- Transport Contract ADR: [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)
- Stop Strategy ADR: [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Testing

```bash
nvim -l tests/busted.lua
```

## License

MIT
