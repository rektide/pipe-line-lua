# Coop Tools for Termichatter

A mapping of coop.nvim tools to termichatter's architecture and requirements.

## Core Concurrency

### coop.task
**Use:** Pipeline handler execution, async processors

Pipeline stages that perform async operations (like I/O) should be task functions that can yield:

```lua
-- Async processor that can yield
local async_processor = function(self, msg)
  local err, data = uv.fs_read(...)
  msg.data = data
  self.log(msg)
end
```

### coop.spawn
**Use:** Starting background consumer receive loops

Driver implementations launch receive loops that run indefinitely:

```lua
-- Consumer loop for a pipeline stage
coop.spawn(function()
  while true do
    local msg = self.queues[index]:pop()
    self.pipeline[index](self, msg)
  end
end)
```

### coop.Future
**Use:** Completion protocol signaling

Stages signal completion via futures, allowing downstream consumers to know when all work is done:

```lua
-- Completion handshake
local done_future = coop.Future.new()
-- Producer signals done when finished
done_future:complete()
-- Consumer awaits all upstreams
done_future:await()
```

## Control Flow

### coop.control.gather
**Use:** Fan-out outputter pattern

Run multiple outputters concurrently and wait for all to complete:

```lua
-- Fan-out to multiple destinations
local outputter = function(self, msg)
  local tasks = {}
  for _, out in ipairs(self.fan_out.outputters) do
    table.insert(tasks, coop.spawn(function()
      out(self, msg)
    end))
  end
  coop.control.gather(tasks)
end
```

### coop.control.timeout
**Use:** Rescheduler driver backoff

Implement adaptive scheduling with backoff for quiet periods:

```lua
-- Rescheduler with quiet backoff
local rescheduler = function(self)
  local backoff = self.driver.rescheduler.backoff or 100
  while true do
    local had_work = process_queue(self)
    if not had_work then
      coop.control.timeout(backoff, function() end)()
      backoff = math.min(backoff * 2, max_backoff)
    else
      backoff = self.driver.rescheduler.base
    end
  end
end
```

### coop.control.shield
**Use:** Protecting completion signaling

Ensure completion signals aren't cancelled even if surrounding task is:

```lua
-- Critical completion should be shielded
coop.control.shield(function()
  completion_queue:push(completion.done)
end)
```

### coop.await_all
**Use:** Coordinating multiple consumers

Wait for all outputters or consumers to complete:

```lua
-- Wait for all outputs to finish draining
local tasks = {outputter1_task, outputter2_task, outputter3_task}
coop.await_all(tasks)
```

### coop.await_any
**Use:** Racing operations, finding available worker

Race between timeout and work, or find first available consumer:

```lua
-- Wait for first available worker or timeout
local worker_task = coop.spawn(wait_for_worker)
local timeout_task = coop.spawn(function()
  uv.sleep(5000)
  throw("timeout")
end)

local winner, remaining = coop.await_any({worker_task, timeout_task})
if winner == timeout_task then
  remaining[1]:cancel()
end
```

## Driver Implementation

### coop.uv-utils.sleep
**Use:** Interval and rescheduler timing

Both interval and rescheduler drivers use sleep for timing:

```lua
-- Interval driver - fixed period
local interval_driver = function(self)
  local interval = self.driver.interval or 100
  while true do
    uv.sleep(interval)
    process_queue(self)
  end
end

-- Rescheduler - trigger at start/end of work
local rescheduler_driver = function(self)
  while true do
    process_queue(self)
    uv.sleep(self.driver.rescheduler.quiet_delay or 50)
  end
end
```

### coop.task.yield
**Use:** Cooperative scheduling in loops

Yield control back to event loop during long-running operations:

```lua
-- Yield periodically in batch processing
for i, msg in ipairs(batch) do
  process(msg)
  if i % 100 == 0 then
    coop.task.yield()
  end
end
```

## I/O Operations

### coop.uv
**Use:** File outputter

Async file writing for logging to disk:

```lua
-- File outputter implementation
local file_outputter = function(self, msg)
  local err, fd = uv.fs_open(self.file.filename, "a", 438)
  if not err then
    local formatted = format_message(msg)
    uv.fs_write(fd, formatted)
    uv.fs_close(fd)
  end
end
```

### coop.uv-utils.StreamReader / StreamWriter
**Use:** Stream-based output destinations

Write to pipes, sockets, or other streams:

```lua
-- Stream writer outputter
local stream_outputter = function(self, msg, writer)
  writer:write(format_message(msg))
end
```

### coop.task-utils.cb_to_tf
**Use:** Converting vim async callbacks

Integrate with existing vim async APIs:

```lua
-- Convert vim.defer_fn or other callbacks to task functions
local sleep_async = coop.cb_to_tf(vim.defer_fn)
local delay = sleep_async(100)
delay()
```

## Pipeline Management

### coop.table-utils
**Use:** Manipulating pipeline/queues lists

Adding processors, splicing pipelines:

```lua
-- Add processor at position
local function addProcessor(self, processor, position)
  local pipeline = table_utils.shallow_copy(self.pipeline)
  local queues = table_utils.shallow_copy(self.queues)
  table_utils.safe_insert(pipeline, position, processor, #self.pipeline)
  table_utils.safe_insert(queues, position, coop.MpscQueue.new(), #self.queues)
  -- Create new module with updated pipeline
  return makePipeline({pipeline = pipeline, queues = queues})
end
```

### coop.functional-utils.shift_parameters
**Use:** Function decoration/currying

Transform functions for pipeline composition:

```lua
-- Create decorated logger with bound parameters
local error_logger = functional_utils.shift_parameters(logger, "error")
error_logger(self, "Something went wrong", {context = "file:write"})
```

## Module Inheritance

### self as context object
**Use:** Recursive module pattern

All functions reference `self` for module capabilities:

```lua
-- Processor uses self to access other pipeline tools
local processor = function(self, msg)
  msg.time = self.timestamper()  -- Use module's timestamper
  msg.module = self.name        -- Capture module name
  self.log(msg)                  -- Forward through pipeline
end
```

## Error Handling

### coop.copcall
**Use:** Protected execution of pipeline stages

Run handlers safely without crashing the pipeline:

```lua
-- Protected handler execution
local protected_handler = function(self, msg)
  local success, result = coop.copcall(function()
    return self.handler(self, msg)
  end)
  if not success then
    -- Log error and continue pipeline
    self.log_error(msg, result)
  end
end
```

## Cancellation

### Task:cancel
**Use:** Shutting down consumers, stopping drivers

Clean shutdown of pipeline components:

```lua
-- Cancel consumer tasks on shutdown
local consumer_task = coop.spawn(consumer_loop)
-- Later
consumer_task:cancel()
```

### coop.cb_to_tf with on_cancel
**Use:** Resource cleanup on cancellation

Clean up file handles, connections, etc:

```lua
local write_async = coop.cb_to_tf(vim.uv.fs_write, {
  on_cancel = function(args, ret)
    local fd = ret[1]
    uv.fs_close(fd)
  end
})
```

## Summary Table

| Coop Tool | Termichatter Use |
|-----------|------------------|
| `coop.task` | Async pipeline handlers, processors |
| `coop.spawn` | Consumer receive loops |
| `coop.Future` | Completion protocol signaling |
| `coop.control.gather` | Fan-out outputter |
| `coop.control.timeout` | Rescheduler backoff |
| `coop.control.shield` | Critical completion protection |
| `coop.await_all` | Coordinating multiple outputs |
| `coop.await_any` | Racing, worker selection |
| `coop.uv-utils.sleep` | Driver scheduling |
| `coop.task.yield` | Cooperative loop yielding |
| `coop.uv` | File outputter |
| `coop.uv-utils.StreamWriter` | Stream output |
| `coop.cb_to_tf` | Vim async integration |
| `coop.table-utils` | Pipeline manipulation |
| `coop.copcall` | Protected handler execution |
| `Task:cancel` | Shutdown, cleanup |
