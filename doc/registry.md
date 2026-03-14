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

Registry is responsible for:

- storing segment definitions by name
- resolving name -> definition with parent-chain fallback
- maintaining local `emits_index` metadata incrementally
- providing effective merged emits index across parent chain
- supporting hierarchical registry composition via `derive()`

## Data Model

Core fields:

- `type = "registry"`
- `segment` (name -> handler/segment table)
- `emits_index` (fact -> entries[])
- `_emits_by_name` (name -> emitted facts snapshot)
- `rev` (local revision counter)
- emits index cache fields (`_emits_index_cache*`)

## Resolution Semantics

`registry:resolve(name)` behavior:

1. non-string values are returned unchanged
2. check `self.segment[name]`
3. check `self[name]`
4. recurse into parent registry (if derived)
5. return `nil` if unresolved

This makes it safe to pass direct function/table segment references through resolver paths.

## Registering Segments

`registry:register(name, handler)` updates both storage and metadata indexes.

On register:

1. increment `rev`
2. invalidate effective emits cache
3. remove prior emits index entries for same name (if any)
4. store new handler in `segment[name]`
5. if handler has `emits`, add index entries for each emitted fact

Each emits entry stores:

- `name`
- `wants`
- `emits`
- `handler`

This makes dependency metadata immediately queryable without full registry rescans.

## Effective Emits Index (`get_emits_index`)

`registry:get_emits_index()` returns merged view of:

- parent effective emits index
- local `emits_index`

Caching rules:

- cache valid when local `rev` unchanged and parent effective index identity unchanged
- otherwise recompute merged result and refresh cache

This keeps repeated resolver queries cheap while preserving correctness across updates.

## Derivation and Parent Chains

`registry:derive(config?)` creates a child registry with:

- fresh local `segment` map
- fresh local `emits_index`
- independent local `rev`
- metatable `__index` fallback to parent registry

Effects:

- child can override names without mutating parent
- unresolved names naturally fall through parent
- child effective emits index includes both parent and child contributions

## How Line Uses Registry

`line:resolve_segment(name)` resolves in this order:

1. line/local inherited field lookup
2. registry `resolve(name)`

This allows both:

- ad-hoc line-local segment overrides
- standard registry-managed segment lookup

After resolution, line may materialize factories and instantiate table segments per line settings.

## How Resolver Uses Registry Metadata

Resolver-oriented segment metadata:

- `wants`: required facts
- `emits`: produced facts

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

- keep segment names stable and explicit
- include `wants`/`emits` when resolver participation matters
- prefer deriving registries for scope-local overrides instead of mutating global registry
- treat `rev` and emits index caches as implementation details (do not couple external behavior to cache internals)

## Relationship to Other Core Components

- **Segment** definitions are registered in registry. See [`/doc/segment.md`](/doc/segment.md).
- **Line** resolves named pipe entries through registry. See [`/doc/line.md`](/doc/line.md).
- **Run** executes resolved handlers downstream. See [`/doc/run.md`](/doc/run.md).
