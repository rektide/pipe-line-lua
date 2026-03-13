# Async Handoff

This guide covers explicit async boundaries via `mpsc_handoff`.

References:
- [`/lua/pipe-line/segment/mpsc.lua`](/lua/pipe-line/segment/mpsc.lua)
- [`/lua/pipe-line/consumer.lua`](/lua/pipe-line/consumer.lua)
- [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)

## Basic Pattern

Insert `mpsc_handoff` in the pipe where you want a queue boundary.

```lua
local app = pipe-line({ source = "myapp" })
app.pipe = pipe-line.Pipe({
  "timestamper",
  "mpsc_handoff",
  "cloudevent",
})

app:info("async message")
```

## Custom Handoff

```lua
local segment = require("pipe-line.segment")
local handoff = segment.mpsc_handoff({
  strategy = "fork", -- self | clone | fork
})

app.pipe = pipe-line.Pipe({ handoff, "cloudevent" })
```

## Lifecycle

- handoff queue consumers start via segment lifecycle (`ensure_prepared`)
- line lifecycle APIs control orchestration:
  - `line:ensure_prepared()`
  - `line:ensure_stopped()`
  - `line:close()`

## Run Continuation Ownership

`mpsc_handoff` carries continuation runs across a queue boundary.

- continuation is run-owned
- boundary segment transports it; it does not redefine run semantics
- if tracking is needed, continuation state can be stored on `run.continuation`

## Manual Continuation Mode

For manual testing/control, disable auto-start and pop envelopes yourself.

```lua
local app = pipe-line({ autoStartConsumers = false })
local handoff = pipe-line.segment.mpsc_handoff()
app.pipe = pipe-line.Pipe({ handoff, "capture" })

app:log({ message = "manual" })

local envelope = handoff.queue:pop()
local continuation = envelope[pipe-line.segment.HANDOFF_FIELD]
continuation:next()
```

This manual mode demonstrates queue transport only; continuation behavior remains the normal run `:next()` flow.
