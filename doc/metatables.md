# Metatables in pipe-line

Metatables are the connective tissue of pipe-line. Nearly every relationship in the system — runs reading from lines, child lines inheriting from parents, segment instances delegating to prototypes, registries inheriting from parent registries — is expressed through Lua's `__index` metatable mechanism. Understanding these chains is essential to understanding how data flows through the system without being explicitly copied everywhere.

References:

- [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)
- [`/lua/pipe-line/run.lua`](/lua/pipe-line/run.lua)
- [`/lua/pipe-line/registry.lua`](/lua/pipe-line/registry.lua)
- [`/lua/pipe-line/pipe.lua`](/lua/pipe-line/pipe.lua)
- [`/lua/pipe-line/inherit.lua`](/lua/pipe-line/inherit.lua)
- [`/lua/pipe-line/init.lua`](/lua/pipe-line/init.lua)

## Why Metatables Matter Here

pipe-line is designed around cheap derivation. A child line doesn't copy its parent's pipe, output queue, registry, or config — it just points at the parent via `__index` and reads through. A run doesn't copy the line's fields — it reads through to them. A cloned run doesn't copy the parent run's fields — it reads through to those too.

This means:

- **Child lines are free.** `app:child("auth")` creates a table with one field (`source = "auth"`) and a metatable pointer. Everything else — pipe, output, filter, registry — is inherited.
- **Runs are free.** A run is a small table with `input`, `pos`, `line`, and a metatable. `run.filter` resolves through the metatable to `line.filter` without anyone having to pass it.
- **Segments read from runs reads from lines.** When a segment handler reads `run.source`, it traverses: run → line → parent line → ... until it finds a `source` field. No plumbing, no argument passing.
- **Ownership is opt-in.** When you need isolation, `rawset` a field on the child to shadow the parent. Until then, you share for free.

The design trades predictability for efficiency: you need to understand that `self.foo` might come from three levels up the chain, and that `rawget(self, "foo")` is how you ask "does *this specific table* own `foo`?"

## All Metatable Chains

| Object | `__index` target | Lookup order | Source |
|--------|-----------------|--------------|--------|
| **Line instance** | `LINE_MT.__index` (function) | Own fields → `Line` methods → `parent` line (recursive) | [`line.lua:669`](/lua/pipe-line/line.lua) |
| **Line constructor** | `__call` → `new_line(config)` | — | [`line.lua:678`](/lua/pipe-line/line.lua) |
| **Run instance** | `__index` function | Own fields → `Run` methods → `line[k]` | [`run.lua:280`](/lua/pipe-line/run.lua) |
| **Cloned run** | `__index` function | Own fields → `Run` methods → parent run's `rawget` fields → `parent_run.line[k]` | [`run.lua:229`](/lua/pipe-line/run.lua) |
| **Run constructor** | `__call` → `Run.new(line, config)` | — | [`run.lua:295`](/lua/pipe-line/run.lua) |
| **Run-local fact table** | `__index` → `line.fact` | Own fact fields → line's fact table | [`run.lua:173`](/lua/pipe-line/run.lua) |
| **Segment instance** | `__index` → prototype table | Own fields → registry prototype | [`line.lua:100`](/lua/pipe-line/line.lua) |
| **Pipe instance** | `PIPE_MT.__index = Pipe` | Array entries + own fields → `Pipe` methods | [`pipe.lua:56`](/lua/pipe-line/pipe.lua) |
| **Pipe constructor** | `__call` → `M.new(entry)` | — | [`pipe.lua:59`](/lua/pipe-line/pipe.lua) |
| **Registry (global)** | `__call` → `M:derive(config)` | — | [`registry.lua:179`](/lua/pipe-line/registry.lua) |
| **Registry (derived)** | `__index` → parent registry | Own segment/emits → parent segment/emits | [`inherit.lua:13`](/lua/pipe-line/inherit.lua) via [`registry.lua:164`](/lua/pipe-line/registry.lua) |
| **Multi-parent child** | `__index` function | Own fields → each parent in left-to-right order | [`inherit.lua:23`](/lua/pipe-line/inherit.lua) |
| **Module entry point** | `__call` → creates Line with default registry | — | [`init.lua:51`](/lua/pipe-line/init.lua) |

## The Line Chain

When you create `app:child("auth"):child("jwt")`, you get three tables connected by metatables:

```
jwt (instance)
  source = "jwt"
  ↓ LINE_MT.__index
Line methods (log, info, run, child, fork, ...)
  ↓ not found? check parent
auth (instance)
  source = "auth"
  ↓ LINE_MT.__index
Line methods
  ↓ not found? check parent
app (instance)
  source = "myapp"
  pipe = Pipe{...}
  output = MpscQueue
  registry = ...
  fact = {}
  ↓ LINE_MT.__index
Line methods
  ↓ no parent
nil
```

`jwt.pipe` resolves to `app.pipe`. `jwt.output` resolves to `app.output`. `jwt.source` resolves to `"jwt"` — its own local field. `jwt:full_source()` walks `rawget` up the parent chain to build `"myapp:auth:jwt"`.

The `LINE_MT.__index` function is not a simple table lookup — it's a two-phase function ([`line.lua:178`](/lua/pipe-line/line.lua)):

```lua
function LINE_MT.__index(self, key)
    local method = Line[key]        -- 1. check prototype methods
    if method ~= nil then return method end

    local parent = rawget(self, "parent")  -- 2. delegate to parent
    if parent then return parent[key] end

    return nil
end
```

This means Line methods always win over parent data fields. A child line can't accidentally shadow `line:run()` with a parent's `run` data field.

### Child vs Fork

`line:child()` creates a thin line that inherits everything. `line:fork()` creates a child and then gives it its own `pipe` (cloned), `output` (new queue), and `fact` (shallow copy). The metatable chain is the same — fork just pre-populates owned fields so they shadow the parent.

```lua
-- child: reads pipe/output/fact from parent via __index
local child = app:child("thin")

-- fork: owns pipe/output/fact, other fields still read through
local forked = app:fork("independent")
```

## The Run Chain

A run's metatable is a function that checks `Run` methods first, then falls through to the line:

```lua
setmetatable(run, { __index = function(_, k)
    local method = Run[k]       -- 1. Run prototype methods
    if method ~= nil then return method end
    return line[k]              -- 2. line fields (which may chain to parent lines)
end })
```

This is what makes `run.filter`, `run.source`, `run.registry`, and every other line field available to segments without any explicit passing. A segment handler receives `run` and can read anything from the line — or from the line's parent, or grandparent — transparently.

### Cloned Run Chain

`run:clone(new_input)` creates a child run with a three-level `__index`:

```lua
setmetatable(child, { __index = function(_, k)
    local method = Run[k]                  -- 1. Run methods
    if method ~= nil then return method end

    local from_parent = rawget(parent_run, k)  -- 2. parent run's owned fields
    if from_parent ~= nil then return from_parent end

    return parent_run.line[k]              -- 3. line (and its parent chain)
end })
```

This means a cloned run inherits any owned fields from its parent run — like a custom `pipe` or `fact` that the parent took ownership of — before falling through to the line. A run that called `own("pipe")` passes that owned pipe to its clones automatically.

### Run-Local Fact

`run:set_fact("name")` lazily creates a per-run fact table with an `__index` to `line.fact`:

```lua
own = setmetatable({}, { __index = line_fact })
rawset(self, "fact", own)
own[name] = value
```

After this, `run.fact.name` reads from the run's own table, but `run.fact.time` (if not set locally) reads through to the line's fact table. This is a micro-inheritance chain within the larger run→line chain.

`run:own("fact")` collapses this into a plain table by snapshotting all visible facts — breaking the `__index` link permanently.

## The Segment Instance Chain

Registry prototypes are shared across all lines. When a line resolves a segment name, it creates a per-line instance via `__index`:

```lua
instance = setmetatable({}, { __index = prototype })
instance._pipe_line_line = line
instance._pipe_line_is_instance = true
```

The instance starts empty. It inherits `handler`, `wants`, `emits`, `init`, `ensure_prepared`, `ensure_stopped`, and everything else from the prototype. Per-instance state (set during `init` or at runtime) lives on the instance table and shadows the prototype.

If the prototype has a `fork()` method and `auto_fork` is enabled, the line calls `prototype:fork()` instead — giving the segment control over how its instance is created. If `fork()` returns a new table, that table is used directly (after identity assignment). If it returns the prototype itself, the thin metatable instance is used as fallback.

## The Registry Chain

`registry:derive()` creates a child registry via `inherit.derive`, which sets `__index` to the parent:

```lua
child = setmetatable({
    type = "registry",
    segment = {},         -- own segment table (empty)
    emits_index = {},     -- own emits index (empty)
    rev = 0,
    _emits_by_name = {},
}, { __index = parent_registry })
```

Resolution walks the chain explicitly — `registry:resolve(name)` checks `self.segment`, then `rawget(self, name)`, then calls `parent:resolve(name)` if a parent exists ([`registry.lua:43`](/lua/pipe-line/registry.lua)). The `emits_index` has its own merging logic via `get_emits_index()` that combines parent and child indexes with caching ([`registry.lua:118`](/lua/pipe-line/registry.lua)).

## The `inherit` Module

[`/lua/pipe-line/inherit.lua`](/lua/pipe-line/inherit.lua) provides the generic utilities that several of the above chains are built on:

- **`derive(parent, child)`** — sets `child.__index = parent`. Used by registry derivation.
- **`derive_multi(parents, child)`** — sets `child.__index` to a function that searches parents left-to-right. Available for multi-parent composition.
- **`walk_field(obj, field)`** — walks `__index` tables (not functions) looking for a `rawget` match. Used by `line:resolve_segment()` to find segment definitions scoped to specific lines.
- **`walk_predicate(obj, predicate)`** — same walk, but calls a predicate at each level. Cycle-safe.
- **`get_parent(obj)`** — returns the full parent chain as an array.

## Ownership via `rawget` / `rawset`

The metatable chains make field access transparent, but sometimes you need to know *where* a value lives:

- **`rawget(self, key)`** — "does this specific table own this field?" Used extensively in line construction, segment instancing, and run cloning to distinguish owned vs inherited values.
- **`rawset(self, key, value)`** — "set this field on this specific table, shadowing whatever the metatable would return." Used by `run:own()`, `run:set_fact()`, and `line:addSegment()`.

The pattern is: read through metatables by default (cheap, shared), `rawset` when you need local ownership (isolation), `rawget` when you need to distinguish local from inherited (decisions).

## When Chains Break

Ownership operations intentionally break metatable chains:

| Operation | What it breaks | Why |
|-----------|---------------|-----|
| `run:own("pipe")` | Run stops reading line's pipe | Run needs to splice without affecting the line |
| `run:own("fact")` | Run stops reading line's fact | Run needs a snapshot, not a live view |
| `run:fork(el)` | Owns pipe + fact | Full independence for detached processing |
| `line:fork()` | Child owns pipe, output, fact | Independent pipeline with shared config |

After ownership, the field is a plain table on the object — no `__index`, no delegation. The chain above that point still works (a forked run's clone still reads through to the forked run's owned pipe), but the link to the original line is severed for that specific field.
