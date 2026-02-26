# Async Handoff

This guide covers explicit async boundaries via `mpsc_handoff`.

References:
- [`/lua/termichatter/segment/mpsc.lua`](/lua/termichatter/segment/mpsc.lua)
- [`/lua/termichatter/consumer.lua`](/lua/termichatter/consumer.lua)
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)

## Basic Pattern

Insert `mpsc_handoff` in the pipe where you want a queue boundary.

```lua
local app = termichatter({ source = "myapp" })
app.pipe = termichatter.Pipe({
  "timestamper",
  "mpsc_handoff",
  "cloudevent",
})

app:info("async message")
```

## Custom Handoff

```lua
local segment = require("termichatter.segment")
local handoff = segment.mpsc_handoff({
  strategy = "fork", -- self | clone | fork
})

app.pipe = termichatter.Pipe({ handoff, "cloudevent" })
```

## Lifecycle

- handoff queue consumers start via segment lifecycle (`ensure_prepared`)
- line lifecycle APIs control orchestration:
  - `line:ensure_prepared()`
  - `line:ensure_stopped()`
  - `line:close()`

## Manual Continuation Mode

For manual testing/control, disable auto-start and pop envelopes yourself.

```lua
local app = termichatter({ autoStartConsumers = false })
local handoff = termichatter.segment.mpsc_handoff()
app.pipe = termichatter.Pipe({ handoff, "capture" })

app:log({ message = "manual" })

local envelope = handoff.queue:pop()
local continuation = envelope[termichatter.segment.HANDOFF_FIELD]
continuation:next()
```
