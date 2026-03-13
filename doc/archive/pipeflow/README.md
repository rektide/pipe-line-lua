# pipeflow

> Implicit-cursor pipeline where element flow directly through line

## Overview

pipeflow is a streamlined pipeline architecture that eliminates the explicit Run/cursor object. Instead of creating a cursor that walks the pipeline, element flow implicitly through the line—each pipe directly invokes the next, or pushes to an mpsc queue.

## Design Philosophy

**pipecopy**: Element wrapped in Run cursor that navigate pipeline
**pipeflow**: Element flow through line directly, no cursor object

This reduces allocation and simplifies the mental model: pipe are just function that receive input and context, then either return output or push to next stage.

## Core Concept

```
Registry (pipe library)
    ↓
  Line (pipeline + context)
    ↓
 input → pipe₁ → pipe₂ → pipe₃ → output
           ↓        ↓        ↓
        (sync)  (mpsc)   (sync)
```

## Quick Start

```lua
local pipeflow = require("termichatter")

local app = pipeflow.makeLine({
    source = "myapp:main",
    pipe = { "timestamper", "cloudevent", "module_filter" },
})

local log = app:logger({ module = "startup" })

log.info("Application starting")
log.debug({ message = "Config", data = { enabled = true } })
```

## Architecture

### Line

The line is both the pipeline definition and the execution context. No separate cursor object.

```lua
local line = require("termichatter.line")

local myLine = line:derive({
    pipe = { "timestamper", "transform", "output" },
    source = "myapp",
})

-- Send element through
myLine:send({ message = "hello" })
```

### Pipe Signature

Pipe receive `(input, line, pos)` instead of a Run object:

```lua
-- pipeflow pipe signature
local function my_pipe(input, line, pos)
    input.processed = true
    return input  -- Continue to next pipe
end

-- Compare to pipecopy
local function my_pipe_cursor(run)
    run.input.processed = true
    return run.input
end
```

### Flow Control

Pipe control flow by return value:

| Return | Behavior |
|--------|----------|
| `value` | Pass to next pipe (sync) or push to queue (async) |
| `nil` | Stop processing, element filtered |
| `false` | Explicit stop, element discarded |

### Multi-emit

Pipe can emit multiple element by calling `line:emit()`:

```lua
local function splitter(input, line, pos)
    for _, item in ipairs(input.items) do
        line:emit({ item = item }, pos + 1)
    end
    return nil  -- Original consumed
end
```

## Line API

```lua
-- Create derived line
local child = parent:derive(config)

-- Send element through pipeline
line:send(input)

-- Emit to specific position
line:emit(input, pos)

-- Modify pipeline
line:splice(start, deleteCount, ...)

-- Add async stage
line:async(pos)  -- Create mpsc at position
```

## Execution Model

### Sync Flow

For sync pipe, execution is a simple loop:

```lua
function line:send(input)
    local pos = 1
    while pos <= #self.pipe do
        local pipe = self:resolve(self.pipe[pos])
        local queue = self.mpsc[pos]
        
        if queue then
            queue:push({ input = input, pos = pos })
            return
        end
        
        input = pipe(input, self, pos)
        if input == nil then return end
        
        pos = pos + 1
    end
    
    self.output:push(input)
end
```

### Async Flow

Async stage pop from queue and continue:

```lua
function make_consumer(line, pos, queue)
    return function()
        while true do
            local item = queue:pop()
            line:emit(item.input, pos)
        end
    end
end
```

## Built-in Pipe

Same pipe library as pipecopy, different signature:

```lua
-- timestamper
function M.timestamper(input, line, pos)
    if type(input) == "table" then
        input.time = vim.uv.hrtime()
    end
    return input
end

-- cloudevent
function M.cloudevent(input, line, pos)
    input.id = input.id or uuid()
    input.source = input.source or line.source
    input.specversion = "1.0"
    input.type = input.type or "pipeflow.event"
    return input
end

-- module_filter
function M.module_filter(input, line, pos)
    local filter = line.filter
    if not filter then return input end
    
    local source = input.source
    if type(filter) == "string" then
        return source:match(filter) and input or nil
    end
    return filter(source, input, line) and input or nil
end
```

## Context Access

Pipe access line context directly:

```lua
local function context_aware(input, line, pos)
    -- Line field
    local source = line.source
    local filter = line.filter
    
    -- Registry lookup
    local other = line:resolve("other_pipe")
    
    -- Pipeline info
    local total = #line.pipe
    local remaining = total - pos
    
    return input
end
```

## Comparison: pipecopy vs pipeflow

| Aspect | pipecopy | pipeflow |
|--------|----------|----------|
| Cursor object | Explicit `Run` | None (implicit) |
| Pipe signature | `fn(run)` | `fn(input, line, pos)` |
| Position tracking | `run.pos` | `pos` argument |
| Input access | `run.input` | `input` argument |
| Context access | `run.line.field` | `line.field` |
| Multi-emit | `run:push()` loop | `line:emit()` call |
| Allocation | Run per element | None per element |
| Complexity | More flexible | Simpler model |

## When to Use

**pipeflow** (this implementation):
- High-throughput logging
- Simple transform pipeline
- Minimal allocation overhead
- Straightforward mental model

**pipecopy**:
- Pipeline introspection during execution
- Dynamic pipeline modification per-element
- Complex cursor navigation (goto, splice mid-run)
- Debugging with position/name tracking

## API Reference

### Line

| Method | Description |
|--------|-------------|
| `line:derive(config)` | Create child line |
| `line:send(input)` | Send through pipeline |
| `line:emit(input, pos)` | Emit to position |
| `line:splice(...)` | Modify pipeline |
| `line:async(pos)` | Add mpsc at position |
| `line:resolve(name)` | Resolve pipe from registry |
| `line:logger(config)` | Create logger with priority method |
| `line:prepare_segments()` | Prepare/start segment runtime hooks |
| `line:close()` | Send completion done and close prepared hooks |

### Registry

| Method | Description |
|--------|-------------|
| `registry:register(name, fn)` | Register pipe |
| `registry:resolve(name)` | Lookup pipe |
| `registry:derive(config)` | Create child registry |

## License

MIT
