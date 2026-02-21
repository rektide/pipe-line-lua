# termichatter-nvim

> Structured data-flow pipeline for Neovim, atop coop.nvim.

## glossary

| term       | description                                                                    |
| ---------- | ------------------------------------------------------------------------------ |
| `line`     | a pipeline definition: holds a `pipe`, a registry, output                      |
| `pipe`     | the connected sequence of segment — a first-class array with rev/splice/clone  |
| `segment`  | a processing component, a handler, in a pipe                                   |
| `run`      | a lightweight cursor/context that walks a pipe, visiting segment               |
| `registry` | a repository of known segment type                                             |
| `fact`     | a named capability or state, tracked on line and/or run                        |

## architecture

```
Registry (segment library)
    ↓
  Line (pipeline definition, holds pipe + config)
    ↓
  Run (cursor walking the pipe, executing segment)
    ↓
 Output (final destination queue)
```

a line holds a pipe. a pipe is an array of segment name. the registry resolves segment name to handler. a run walks the pipe, calling each handler in turn, carrying the element being processed as `run.input`. at the end of the pipe, the element lands in the output queue.

the run reads through to the line for everything it doesn't own. metatable inheritance, all the way down: run → line → registry. zero-cost until the run needs to diverge.

## installation

Requires [coop.nvim](https://github.com/gregorias/coop.nvim) as a dependency.

```lua
{
    "rektide/nvim-termichatter",
    dependencies = { "gregorias/coop.nvim" },
}
```

## quick start

```lua
local termichatter = require("termichatter")

local app = termichatter.makePipeline({
    source = "myapp:main",
})

local log = app:baseLogger({ module = "startup" })

log.info("Application starting")
log.debug({ message = "Config loaded", config = { debug = true } })
log.error("Something went wrong")
```

## line

> The pipeline definition. a series of segment.

a line holds a pipe, a registry, an output queue, and arbitrary context. line clone to make child line. child line inherit from parent via metatable.

| field        | description                                                |
| ------------ | ---------------------------------------------------------- |
| `type="line"`| type identifier                                            |
| `pipe`       | first-class pipe object (array of segment + rev/splice)    |
| `mpsc`       | sparse table of MpscQueue for async segment                |
| `output`     | MpscQueue — final destination for processed element        |
| `fact`       | table of named fact this line establishes                   |
| `registry`   | reference to segment registry                              |
| `clone()`    | copies the line, with fresh pipe, mpsc, output             |
| `run()`      | create a Run from this line                                |

```lua
local line = require("termichatter.line")

local myLine = line:clone({
    pipe = { "timestamper", "enricher", "validator" },
    source = "myapp",
})

-- modify the pipe
myLine.pipe:splice(2, 0, "new_segment")

-- create async stage
myLine:ensure_mpsc(3)
```

**notes:**

- `clone()` creates a fresh pipe from entries, fresh MpscQueue for output. child inherits parent via metatable.
- `resolve_segment(name)` walks the inheritance chain to find a handler: checks self, then registry, then parent line.

## pipe

> The connected sequence of segment. a first-class array object.

pipe is both an array (integer key hold segment name/handler) and an object (hash key hold `rev`, `splice`, `clone`, `splice_journal`). this is the atomic unit of pipeline structure.

| field             | description                                                |
| ----------------- | ---------------------------------------------------------- |
| `[1], [2], ...`   | segment name (string) or handler (function/table)          |
| `rev`             | revision counter, incremented on every splice              |
| `splice_journal`  | array of `{ rev, start, deleted, inserted }` entry         |
| `splice()`        | modify segment in place, record journal, increment rev     |
| `clone()`         | independent copy with same segment, own rev/journal        |

```lua
local Pipe = require("termichatter.pipe")

local p = Pipe.new({ "timestamper", "cloudevent", "output" })
p:splice(2, 0, "validator")  -- insert at position 2
-- p is now: { "timestamper", "validator", "cloudevent", "output" }
-- p.rev == 1

local p2 = p:clone()  -- independent copy
p2:splice(1, 1)       -- delete timestamper from clone only
-- p2.rev == 2, p.rev still == 1
```

**notes:**

- `splice(startIndex, deleteCount, ...)` mirrors JS Array.splice. inserts new segment, removes old, records journal entry.
- `splice_journal` enables run to sync position after the pipe changes under it.
- `clone()` copies segment and inherits parent's rev. fresh journal.

## run

> A lightweight cursor/context that walks a pipe.

the run is the execution context for one element flowing through the pipeline. it reads through to the line for everything it doesn't own. methods live on a prototype, not copied per instance.

| field        | description                                                |
| ------------ | ---------------------------------------------------------- |
| `type="run"` | type identifier                                            |
| `line`       | reference to the underlying line                           |
| `pipe`       | shared reference to line's pipe (until `own("pipe")`)      |
| `pos`        | current position in the pipe                               |
| `input`      | the element being processed                                |
| `fact`       | lazily created per-run fact (reads through to line.fact)    |
| `_rev`       | last synced pipe revision                                  |

### run method

| method          | description                                                    |
| --------------- | -------------------------------------------------------------- |
| `execute()`     | walk pipe from current pos, calling each segment               |
| `next(element)` | advance pos and continue. optional new input for fan-out       |
| `resolve(seg)`  | resolve segment name/table/function to callable                |
| `sync()`        | replay pipe's splice_journal to adjust pos after splice        |
| `set_fact()`    | lazily create local fact table, write with read-through to line |
| `own(field)`    | sever dependency: snapshot a field locally                     |
| `clone(input)`  | lightweight fan-out: new run sharing pipe/fact/line             |
| `fork(input)`   | full independence: clone + own pipe + own fact                 |
| `is_async(pos)` | check if position has mpsc queue                               |
| `get_queue(pos)`| get MpscQueue at position                                      |

```lua
-- segment receive the run as their sole argument
local function my_segment(run)
    run.input.processed = true
    return run.input
end

-- fan-out: one element becomes many
local function splitter(run)
    for _, part in ipairs(run.input.part) do
        local child = run:clone(part)
        child:next()
    end
    -- return nil: we handled forwarding
end
```

### independence spectrum

the run starts maximally thin. it shares everything with the line. you sever connection only when needed.

| operation                  | cost           | what's owned         | use case                     |
| -------------------------- | -------------- | -------------------- | ---------------------------- |
| just advance (`next()`)    | 0 alloc        | nothing new          | normal single-element flow   |
| `clone(el)`                | 1 small table  | input, pos           | fan-out, lightweight         |
| `clone(el)` + `set_fact()` | 2 small table  | input, pos, fact     | per-element fact             |
| `clone(el)` + `own("pipe")`| 1 + pipe clone | input, pos, pipe     | element that splice own path |
| `fork(el)`                 | everything     | all field            | full detach                  |

### fact

fact on a run read through to `line.fact` via metatable. `set_fact(name)` lazily creates a local fact table with `__index` to `line.fact`. reads are free. writes allocate once.

```lua
-- line-level fact (shared by all run)
myLine.fact.time = true

-- per-element fact (lazy, only allocated when written)
function validator(run)
    run:set_fact("validated")
    return run.input
end

-- reading: run.fact.time works naturally via metatable
-- run.fact.validated works after set_fact
```

### splice sync

when the line's pipe is spliced while a run is in-flight, the run's position may go stale. `sync()` replays the pipe's splice_journal to adjust pos. called automatically at the top of `execute()`.

```lua
-- run shares line's pipe (default)
-- line.pipe:splice(2, 0, "new_segment")
-- on next execute(), run:sync() replays journal, adjusts pos

-- run owns its pipe (after own("pipe") or fork())
-- sync() is a no-op: the run has its own independent pipe
```

## segment

> A processing component in a pipe.

segment are function that receive the run as their sole argument. they return the (possibly modified) input to continue, `false` to stop the pipeline, or `nil` if they handled forwarding themselves (fan-out).

| return    | meaning                                      |
| --------- | -------------------------------------------- |
| `input`   | continue pipeline with this value             |
| `false`   | stop pipeline (element filtered)             |
| `nil`     | segment handled forwarding (fan-out via next) |

### built-in segment

| segment          | description                               |
| ---------------- | ----------------------------------------- |
| `timestamper`    | add `time` field with `vim.uv.hrtime()`   |
| `cloudevent`     | add `id`, `source`, `type`, `specversion` |
| `module_filter`  | filter by source pattern                  |
| `priority_filter`| filter by log level                       |
| `ingester`       | apply custom decoration function          |

## registry

> Repository of known segment type.

the registry holds segment by name. line inherit from a registry for segment resolution. sub-registry inherit from parent via metatable.

```lua
local registry = require("termichatter.registry")

registry:register("my_segment", function(run)
    run.input.custom = "value"
    return run.input
end)

-- create derived registry
local myRegistry = registry:derive()
myRegistry:register("local_segment", handler)
```

## async execution

segment can execute asynchronously via mpsc queue. when a run hits a position with a queue, it pushes the element into the queue and stops. a consumer pops from the queue and continues execution.

```lua
local app = termichatter.makePipeline({ source = "myapp" })

-- add async stage at position 2
app:ensure_mpsc(2)

-- start consumer
app:startConsumer()

-- log (will async through position 2)
log.info("async message")

-- stop consumer
app:stopConsumer()
```

### completion protocol

uses [mpsc-completion](https://github.com/rektide/mpsc-completion) for knowing when all producer are done:

| signal      | meaning                                       |
| ----------- | --------------------------------------------- |
| `hello`     | a producer has started                        |
| `done`      | a producer has finished                       |
| `shutdown`  | all producer are done (hello count == done count) |

```lua
local protocol = require("termichatter.protocol")

-- signals
protocol.hello   -- { type = "termichatter.completion.hello" }
protocol.done    -- { type = "termichatter.completion.done" }
protocol.shutdown -- { type = "termichatter.shutdown" }

-- tracker for reference counting
local tracker = protocol.createTracker(outputQueue)
tracker:hello()
tracker:done()  -- emits shutdown when balanced
```

## outputter

| type     | description                |
| -------- | -------------------------- |
| `buffer` | write to nvim buffer       |
| `file`   | append to file             |
| `jsonl`  | write JSON Line            |
| `fanout` | forward to multiple output |

```lua
local outputter = require("termichatter.outputter")

local bufOut = outputter.buffer({ name = "MyLog" })
local fileOut = outputter.file({ filename = "/var/log/myapp.log" })
local jsonOut = outputter.jsonl({ filename = "event.jsonl" })
local fan = outputter.fanout({ outputter = { bufOut, fileOut } })
```

## driver

schedule periodic execution for consumer.

```lua
local driver = require("termichatter.driver")

-- fixed interval
local d = driver.interval(100, function() end)
d.start()
d.stop()

-- adaptive backoff
local d = driver.rescheduler({
    interval = 50,
    backoff = 1.5,
    maxInterval = 2000,
}, callback)
```

## structured message

message are Lua table with conventional field based on CloudEvents spec.

| field           | description                              |
| --------------- | ---------------------------------------- |
| `time`          | high-resolution timestamp (hrtime)       |
| `id`            | unique identifier (UUID v4)              |
| `source`        | origin URI (e.g., "myapp:auth:jwt")      |
| `type`          | event type ("termichatter.log")          |
| `specversion`   | CloudEvents version ("1.0")              |
| `priority`      | log level name (error, warn, info, ...)  |
| `priorityLevel` | numeric priority (1-6)                   |
| `message`       | human-readable message string            |

## recursive context

termichatter uses metatable inheritance throughout. a message might inherit context from:

```
termichatter (root) → app line → auth line → jwt logger → message
```

each level can override or extend field from its parent. lookup walks up the inheritance chain.

```lua
local app = termichatter.makePipeline({
    source = "myapp",
    environment = "production",
})

local auth = app:makePipeline({
    source = "myapp:auth",
    component = "authentication",
})

print(auth.environment)  -- "production" (inherited)
```

## testing

```bash
nvim -l tests/busted.lua
```

## implementation history

the `implementations/` directory contains prior iteration of the core pipeline:

| implementation       | description                                              |
| -------------------- | -------------------------------------------------------- |
| `v1`                 | original monolithic pipeline with parallel array pattern |
| `single-stage-table` | coalesced handler + queue into single table per stage    |
| `single-stage-mode`  | explicit `mode` field for sync vs mpsc intent            |
| `sync-or-mpsc-core`  | minimalist ~210 line experimental core                   |
| `pipecopy`           | first pass at line/pipe/run/registry decomposition       |
| `pipeflow`           | lattice-pipe-resolver design exploration                 |

design review and future direction: [`doc/review/pipecopy-next.md`](/doc/review/pipecopy-next.md)

## license

MIT
