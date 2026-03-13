# Documentation Fixes

Audit of existing documentation against current code state. Issues are grouped by file.

## [`/doc/discovery/readme-pipe-line.md`](/doc/discovery/readme-pipe-line.md)

### Broken discovery references

The "Secondary Sources" section references files that have been moved to `/doc/archive/`:

- `doc/discovery/coop2.md` → actually at [`/doc/archive/coop2.md`](/doc/archive/coop2.md)
- `doc/discovery/mpsc-decomp-tasks.md` → actually at [`/doc/archive/mpsc-decomp-tasks.md`](/doc/archive/mpsc-decomp-tasks.md)
- `doc/discovery/mpsc-decomposition.md` → actually at [`/doc/archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md)

## [`/doc/consumer.md`](/doc/consumer.md)

### Heavily outdated — does not reflect current consumer architecture

The consumer module has been substantially rewritten. The documented API surface no longer exists:

- **`consumer.create(config)`** — does not exist. Actual entry point is `consumer.make_consumer(queue)` which returns a plain coroutine function, or `consumer.start_consumer(line)` / `consumer.ensure_queue_consumer(line, queue)` for line-level consumer management.
- **`consumer.createPipeline()`** — does not exist. Pipelines are composed via `Line` + `Pipe` + segment, not via consumer chaining.
- **`consumer.withDriver()`** — does not exist. Driver module is separate (`pipe-line.driver`) and not integrated into consumer.
- **Returned consumer object methods** (`c:start()`, `c:spawn()`, `c:stop()`, `c:process()`, `c:isRunning()`, `c:addHandler()`) — none exist. Consumer is now a simple coroutine that pops from a queue and calls `continuation:next()` on handoff payloads.
- **Message flow diagram** — partially valid conceptually, but specifics are wrong. Consumer no longer checks for shutdown/completion signals directly; it processes handoff envelopes keyed by `HANDOFF_FIELD`.
- **Handler pipeline within consumer** — does not exist. Processing is done by the run cursor walking the pipe, not by consumer-internal handler chains.
- **References to `protocol.isShutdown`** — field does not exist with that name; protocol checking is `protocol.is_protocol(run)` from [`/lua/pipe-line/segment/completion.lua`](/lua/pipe-line/segment/completion.lua).
- **`pipe-line.drivers` module reference** — should be `pipe-line.driver` (singular).

**Recommendation**: Rewrite entirely or archive to `/doc/archive/`. Current consumer behavior is simple enough to cover in [`/doc/async-handoff.md`](/doc/async-handoff.md).

## [`/doc/async-handoff.md`](/doc/async-handoff.md)

### Minor code style inconsistencies

- Line 15: `pipe-line({ source = "myapp" })` — correct conceptually but `pipe-line` with a hyphen isn't a valid Lua identifier. Actual usage is `local pipeline = require("pipe-line"); pipeline({ source = "myapp" })`. Same on line 33.
- Line 16: `pipe-line.Pipe({...})` — same issue. Should be shown with a local variable.

### Missing reference to `line:addHandoff()`

[`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua) exposes `line:addHandoff(pos, config)` as a convenience for inserting handoff boundaries. This isn't documented anywhere.

## [`/doc/completion-protocol.md`](/doc/completion-protocol.md)

### Field name mismatch

- Document says `pipe-line_protocol = true` (line 15). Actual field name in code is `pipe_line_protocol` (underscore, no hyphen). See `completion.PROTOCOL_FIELD` in [`/lua/pipe-line/segment/completion.lua`](/lua/pipe-line/segment/completion.lua) line 5.

### Missing `ensure_prepared` auto-hello detail

- Document describes `ensure_prepared` emitting a `hello` but doesn't mention this only happens once per instance (`self._hello_emitted` guard). Worth noting for authors expecting multiple prepare cycles.

## [`/doc/lifecycle.md`](/doc/lifecycle.md)

### `prepare_segments()` alias noted but not deprecated

- Code (line 314-318 of [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)) has a TODO to remove `prepare_segments()`. Document mentions it as an alias without noting it's deprecated. Should explicitly call it deprecated.

## [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

### Implementation direction references unimplemented files

- References `/lua/pipe-line/segment/define/transport/stop/drain.lua` and `/lua/pipe-line/segment/define/transport/stop/immediate.lua` — neither exists. The `transport/stop/` directory does not exist.
- Strategy-specific verbs (`ensure_stopped_drain`, `ensure_stopped_immediate`) and strategy futures (`stopped_drain`, `stopped_immediate`) are not yet implemented in the task transport ([`/lua/pipe-line/segment/define/transport/task.lua`](/lua/pipe-line/segment/define/transport/task.lua)).
- The `stop_type` field is not read or dispatched anywhere in current code.
- ADR status is "Proposed" — this should be either progressed toward implementation or clearly marked as aspirational/planned.

## [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)

### Status is accurate

- The described contract aligns well with [`/lua/pipe-line/segment/define/transport.lua`](/lua/pipe-line/segment/define/transport.lua) and the transport implementations. `handler(run)` is the canonical entrypoint, `configure_segment` is absent, transport policies compose via `ensure_prepared`/`handler`/`ensure_stopped`.
- Minor: the ADR mentions `defineMpsc`, `defineSafeTask`, `defineTask` by camelCase names. Actual module files use `require("pipe-line.segment.define.mpsc")`, etc. Not wrong (these are conceptual names) but could confuse readers looking for identifiers.

## [`/doc/adr/README.md`](/doc/adr/README.md)

### Broken discovery link

- References `/doc/discovery/adr-async-boundary-segments.md` which exists, and `/doc/discovery/mpsc-decomposition.md` which does not exist at that path (it's at [`/doc/archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md)).

## [`/doc/segment-authoring.md`](/doc/segment-authoring.md)

### Accurate — no issues found

The described contract matches current code. `handler(run)`, lifecycle hooks, protocol pass-through via `define()`, return semantics, and continuation model are all verified against the implementation.

## [`/doc/segment-instancing.md`](/doc/segment-instancing.md)

### Accurate — no issues found

Instancing controls (`auto_id`, `auto_fork`, `auto_instance`), identity model (`type`/`id`), lifecycle interaction with `init`, and continuation ownership are all consistent with [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua).

## [`/doc/selecting.md`](/doc/selecting.md)

### Accurate — no issues found

`line:select_segments()` and `line:stopped_live()` match the code precisely.
