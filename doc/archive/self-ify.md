# Self-ify: Method Syntax Refactoring

## Background

Lua's colon `:` syntax is called **method syntax** - syntactic sugar that automatically passes the object as the first `self` parameter.

```lua
-- These are equivalent:
obj:method(arg)
obj.method(obj, arg)

-- For definitions:
function M:info(msg)      -- equivalent to:
function M.info(self, msg)
```

## Recent Change

The log priority methods (`error`, `warn`, `info`, `debug`, `trace`) in `pipeline.lua` were converted from factory-generated functions to direct method definitions:

```lua
-- Before: runtime attachment via attachLogMethods()
local function makeLogMethod(priority, level, self)
    return function(msg) ... end
end
M.attachLogMethods = function(module)
    for name, level in pairs(M.priorities) do
        module[name] = makeLogMethod(name, level, module)
    end
end

-- After: direct method definitions
function M:error(msg)
    return logWithPriority(self, msg, "error", 1)
end
```

Benefits:
- Methods defined once on `M`
- No runtime attachment needed
- Works with metatable inheritance (`__index`) - child pipelines inherit naturally

## Candidates for Conversion

### pipeline.lua

| Function | Current Signature | Convert? | Notes |
|----------|------------------|----------|-------|
| `M.addProcessor` | `function(self, name, handler, position, withQueue)` | **Yes** | Instance method, returns self for chaining |
| `M.startConsumers` | `function(self)` | **Yes** | Operates on pipeline instance |
| `M.stopConsumers` | `function(self)` | **Yes** | Operates on pipeline instance |
| `M.makePipeline` | `function(self, config)` | **Maybe** | Already handles dual calling conventions |
| `M.log` | `function(msg, self)` | **No** | `self` is second param, optional |

### registry.lua

| Function | Current Signature | Convert? | Notes |
|----------|------------------|----------|-------|
| `R.resolve` | `function(name, context)` | **No** | Static utility, no `self` |

### consumer.lua

The object returned by `M.create()` has methods defined inline in a table literal:

```lua
return {
    process = function(self, msg) ... end,
    start = function(self) ... end,
    spawn = function(self) ... end,
    stop = function(self) ... end,
    isRunning = function(self) ... end,
    addHandler = function(self, handler) ... end,
}
```

Table literal definitions don't support colon syntax directly. These are already correct; conversion would require structural changes (e.g., defining methods separately or using a class pattern).

## Recommended Changes

### High-value conversions

```lua
-- pipeline.lua: addProcessor
-- Before:
M.addProcessor = function(self, name, handler, position, withQueue)

-- After:
function M:addProcessor(name, handler, position, withQueue)
```

```lua
-- pipeline.lua: startConsumers
-- Before:
M.startConsumers = function(self)

-- After:
function M:startConsumers()
```

```lua
-- pipeline.lua: stopConsumers
-- Before:
M.stopConsumers = function(self)

-- After:
function M:stopConsumers()
```

### Deferred: makePipeline

`makePipeline` explicitly handles both call styles:

```lua
M.makePipeline = function(self, config)
    -- Handle both M.makePipeline(config) and M:makePipeline(config)
    if self == M or type(self) ~= "table" or (not self.pipeline and not getmetatable(self)) then
        config = self
        self = M
    end
```

Converting to method syntax would still work but the dual-mode detection would remain. Consider whether this flexibility is still needed.

## Non-candidates

### M.log

`self` is the **second** parameter and optional:

```lua
M.log = function(msg, self)
    self = self or M
```

Method syntax requires `self` as first param. This pattern is intentional - `M.log(msg)` works without context.

### Registry resolve

Static utility operating on global `R`:

```lua
R.resolve = function(name, context)
    if R[name] then return R[name] end
```

No instance semantics.

### Consumer object methods

Defined inline in table literals. Would require extracting to a prototype pattern to use colon definition syntax. Current form is idiomatic for Lua "objects".
