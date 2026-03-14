# Registry

`Registry` is the segment definition repository in pipe-line. It resolves named segments, supports inheritance through derivation, and maintains dependency metadata indexes used by resolver flows.

If `Segment` defines behavior and `Line` orchestrates execution, `Registry` provides the addressable catalog they depend on.

## Reference Materials

| Area | Source | Why it matters |
|------|--------|----------------|
| Registry implementation | [`/lua/pipe-line/registry.lua`](/lua/pipe-line/registry.lua) | Canonical resolve/register/derive behavior and emits index caching |
| Inheritance helper | [`/lua/pipe-line/inherit.lua`](/lua/pipe-line/inherit.lua) | Underpins registry derivation and parent chain lookup |
| Line segment resolution | [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua) | Shows how runtime pipe entries are resolved via registry |
| Built-in segment definitions | [`/lua/pipe-line/segment.lua`](/lua/pipe-line/segment.lua) | Typical segment metadata shape registered in registry |
| Resolver implementation | [`/lua/pipe-line/resolver.lua`](/lua/pipe-line/resolver.lua) | Uses emits metadata index to inject dependency-satisfying segments |
| Metatable behavior | [`/doc/metatables.md`](/doc/metatables.md) | Explains table inheritance model used by derived registries |

## Core Responsibilities

| Responsibility | Description |
|----------------|-------------|
| definition storage | stores segment definitions by name |
| resolution | resolves `name -> definition` with parent fallback |
| metadata indexing | maintains local `emits_index` incrementally |
| effective index composition | provides merged emits index across parent chain |
| hierarchy support | supports derived registries via `derive()` |

## Data Model

| Field | Purpose |
|-------|---------|
| `type = "registry"` | identity marker |
| `segment` | name -> handler/segment table map |
| `emits_index` | local fact -> entries[] index |
| `_emits_by_name` | tracks emitted facts for each registered name |
| `rev` | local revision counter |
| `_emits_index_cache*` | effective index cache and cache invalidation state |

## Resolution Semantics

`registry:resolve(name)` behavior:

| Step | Resolution rule |
|------|-----------------|
| 1 | non-string values are returned unchanged |
| 2 | check `self.segment[name]` |
| 3 | check `self[name]` |
| 4 | recurse into parent registry if present |
| 5 | return `nil` if unresolved |

This makes it safe to pass direct function/table segment references through resolver paths.

## Registering Segments

`registry:register(name, handler)` updates both storage and metadata indexes.

On register:

| Step | Register action |
|------|-----------------|
| 1 | increment `rev` |
| 2 | invalidate effective emits cache |
| 3 | remove prior emits entries for same name |
| 4 | store new handler in `segment[name]` |
| 5 | add new emits entries for each emitted fact |

Each emits entry stores:

| Entry field | Meaning |
|-------------|---------|
| `name` | registered segment name |
| `wants` | required facts |
| `emits` | provided facts |
| `handler` | segment definition payload |

This makes dependency metadata immediately queryable without full registry rescans.

## Effective Emits Index (`get_emits_index`)

`registry:get_emits_index()` returns merged view of:

| Merge source | Contribution |
|--------------|--------------|
| parent effective index | inherited candidates |
| local `emits_index` | local candidates and overrides |

Caching rules:

| Cache condition | Behavior |
|-----------------|----------|
| local `rev` unchanged and parent index identity unchanged | reuse cached merged index |
| any change in local rev or parent identity | recompute merged index and refresh cache |

This keeps repeated resolver queries cheap while preserving correctness across updates.

## Derivation and Parent Chains

`registry:derive(config?)` creates a child registry with:

| Child field | Initial state |
|-------------|---------------|
| `segment` | fresh local map |
| `emits_index` | fresh local index |
| `rev` | independent local revision |
| `__index` | parent registry fallback |

Effects:

| Derived behavior | Result |
|------------------|--------|
| local override | child can replace names without mutating parent |
| unresolved lookup | falls through to parent registry |
| metadata composition | effective emits index includes parent and child entries |

```mermaid
flowchart TB
    subgraph child[Child Registry]
        childseg[segment[name]]
        childidx[emits_index]
        childcache[get_emits_index cache]
    end

    subgraph parent[Parent Registry]
        parentseg[parent segment[name]]
        parentidx[parent emits_index]
    end

    line[line:resolve_segment(name)] --> childseg
    childseg -->|miss| parentseg
    childidx --> childcache
    parentidx --> childcache
    childcache --> resolver[resolver candidates by fact]
```

## How Line Uses Registry

`line:resolve_segment(name)` resolves in this order:

| Order | Resolution path |
|-------|-----------------|
| 1 | line/local inherited field lookup |
| 2 | registry `resolve(name)` |

This allows both:

| Pattern | Capability |
|---------|------------|
| line-local override | ad-hoc behavior injection on specific line trees |
| registry-managed lookup | reusable named segment catalog |

After resolution, line may materialize factories and instantiate table segments per line settings.

## How Resolver Uses Registry Metadata

Resolver-oriented segment metadata:

| Metadata field | Resolver meaning |
|----------------|------------------|
| `wants` | required facts |
| `emits` | provided facts |

Registry emits index maps fact names to candidate providers, enabling dependency-guided segment insertion.

Without this index, resolver would need repeated full registry scans.

## Practical Patterns

### Registering a simple segment

```lua
registry:register("tagger", function(run)
  run.input.tagged = true
  return run.input
end)
```

### Registering metadata-rich segment

```lua
registry:register("validator", {
  type = "validator",
  wants = { "time" },
  emits = { "validated" },
  handler = function(run)
    run.input.validated = true
    return run.input
  end,
})
```

### Derived registry overlay

```lua
local child = registry:derive()
child:register("local_enricher", my_segment)

-- resolves local first, then parent
local seg = child:resolve("timestamper")
```

## Operational Guidance

| Guidance | Reason |
|----------|--------|
| keep names stable and explicit | improves readability and reliable resolution |
| include `wants`/`emits` where resolver participation matters | enables dependency-aware insertion |
| prefer derived registries for local overrides | avoids global mutation coupling |
| treat `rev`/cache fields as internals | avoid coupling behavior to cache implementation details |

## Relationship to Other Core Components

| Component | Relationship to Registry |
|-----------|--------------------------|
| [`/doc/segment.md`](/doc/segment.md) | definitions are registered in registry |
| [`/doc/line.md`](/doc/line.md) | line resolves named pipe entries through registry |
| [`/doc/run.md`](/doc/run.md) | run executes handlers resolved through line/registry path |
