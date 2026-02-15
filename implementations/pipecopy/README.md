# pipecopy

> Structured data-flow pipeline with cursor-based execution for Neovim

## Overview

pipecopy provides a clean, composable pipeline architecture for structured message processing. Messages flow through a series of named "pipe" components, with optional async handoff via mpsc queues.

## Core Concept

```
Registry (pipe library)
    ↓
  Line (pipeline definition)
    ↓
  Run (cursor walking the line)
    ↓
 Output (final destination)
```

## Installation

Requires [coop.nvim](https://github.com/gregorias/coop.nvim).

```lua
{
    "rektide/nvim-termichatter",
    dependencies = { "gregorias/coop.nvim" },
}
```

## Quick Start

```lua
local pipecopy = require("termichatter")

-- Create a pipeline
local app = pipecopy.makePipeline({
    source = "myapp:main",
})

-- Create a logger
local log = app:baseLogger({ module = "startup" })

-- Log message
log.info("Application starting")
log.debug({ message = "Config loaded", config = { debug = true } })

-- Message are in app.output queue
```

## Architecture

### Registry

Repository of known pipe type. Pipe are registered by name and resolved during execution.

```lua
local registry = require("termichatter.registry")

-- Register custom pipe
registry:register("my_pipe", function(run)
    run.input.custom = "value"
    return run.input
end)

-- Create derived registry
local myRegistry = registry:derive()
myRegistry:register("local_pipe", handler)
```

### Line

A series of pipe that define a pipeline. Line hold configuration and can be cloned.

```lua
local line = require("termichatter.line")

-- Clone with custom pipe
local myLine = line:clone({
    pipe = { "timestamper", "my_pipe", "cloudevent" },
    source = "myapp",
})

-- Modify pipeline
myLine:splice(2, 0, "new_pipe")  -- Insert at position 2

-- Create async stage
myLine:ensure_mpsc(3)  -- Add mpsc queue at position 3
```

### Run

A cursor that walk the line, executing each pipe. Run inherit from their line via metatable.

```lua
-- Create and execute a run
local run = myLine:run({ input = { message = "hello" } })

-- Manual control
local run = myLine:run({ input = msg, noStart = true })
run:goto(2)           -- Jump to position
run:exec()            -- Execute current pipe
run:push(data)        -- Push to next stage
run:next()            -- Advance position
run:execute()         -- Run remaining pipe
```

### Pipe

Processing component in the pipeline. Pipe receive the Run as context.

```lua
-- Simple pipe function
local function my_pipe(run)
    local input = run.input
    input.processed = true
    return input  -- Return modified input
end

-- Pipe can access line context
local function context_pipe(run)
    local source = run.source or run.line.source
    run.input.source = source
    return run.input
end
```

## Built-in Pipe

| Pipe | Description |
|------|-------------|
| `timestamper` | Add `time` field with hrtime |
| `cloudevent` | Add `id`, `source`, `type`, `specversion` |
| `module_filter` | Filter by source pattern |
| `priority_filter` | Filter by log level |
| `ingester` | Apply custom decoration |

## Async Execution

Pipe can execute asynchronously via mpsc queue:

```lua
local app = pipecopy.makePipeline({
    source = "myapp",
})

-- Add async stage at position 2
app:ensure_mpsc(2)

-- Start consumer
app:startConsumer()

-- Log (will async through position 2)
log.info("async message")

-- Stop consumer
app:stopConsumer()
```

## Output

Message that complete the pipeline go to the output queue:

```lua
local app = pipecopy.makePipeline({ source = "myapp" })

-- Output queue
local output = app.output  -- MpscQueue

-- Create outputter
local bufOut = pipecopy.outputter.buffer({ name = "MyLog" })

-- Consume output
coop.spawn(function()
    while true do
        local msg = output:pop()
        bufOut:write(msg)
    end
end)
```

## Outputter

| Type | Description |
|------|-------------|
| `buffer` | Write to nvim buffer |
| `file` | Append to file |
| `jsonl` | Write JSON Line |
| `fanout` | Forward to multiple outputter |

## Driver

Schedule periodic execution:

```lua
-- Fixed interval
local driver = pipecopy.driver.interval(100, function()
    processMessage()
end)
driver.start()

-- Adaptive backoff
local driver = pipecopy.driver.rescheduler({
    interval = 50,
    backoff = 1.5,
    maxInterval = 2000,
}, callback)
```

## Inheritance

pipecopy uses metatable inheritance throughout:

```lua
local inherit = require("termichatter.inherit")

-- Derive child from parent
local child = inherit.derive(parent, { extra = "field" })

-- Walk inheritance chain
local value = inherit.walk_field(obj, "fieldName")

-- Walk with predicate
local result = inherit.walk_predicate(obj, function(o)
    if o.matches then return o end
end)
```

## API Reference

### termichatter (main)

| Function | Description |
|----------|-------------|
| `makePipeline(config)` | Create new line with logger method |
| `line:run(config)` | Create Run for input |
| `line:clone(config)` | Clone line with fresh queue |
| `line:splice(start, delete, ...)` | Modify pipeline |
| `line:baseLogger(config)` | Create logger with priority method |

### Run

| Method | Description |
|--------|-------------|
| `run:exec()` | Execute current pipe |
| `run:next()` | Advance to next position |
| `run:goto(target)` | Jump to position or name |
| `run:push(data)` | Push to next stage |
| `run:execute()` | Run remaining pipeline |
| `run:resolve(pipe)` | Resolve pipe to handler |
| `run:is_async(pos)` | Check if position is async |
| `run:splice(...)` | Modify run's pipe copy |

## License

MIT
