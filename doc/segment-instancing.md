# Segment Instancing

This document explains how resolved segment tables become per-line runtime instances.

References:
- [`/lua/termichatter/line.lua`](/lua/termichatter/line.lua)
- [`/lua/termichatter/segment.lua`](/lua/termichatter/segment.lua)

## Why Instancing Exists

Registry entries are often shared prototype tables. Runtime behavior needs per-line state (ids, futures, counters) without mutating shared singletons.

The line runtime resolves segment names into instances and caches those instances per pipe slot.

## Instancing Controls

Line options:

- `auto_id` (default `true`): assign unique `segment.id` when missing.
- `auto_fork` (default `true`): if prototype has `:fork(...)`, use it to create an instance.
- `auto_instance` (default `true`): if no fork path was used, create a thin metatable instance (`__index` -> prototype).

If both `auto_fork=false` and `auto_instance=false`, table prototypes can be used directly.

## Segment Identity

Each runtime segment table should expose:

- `type`: selector and diagnostics identity (non-unique)
- `id`: unique runtime identity per line slot (when `auto_id` is enabled)

There is no separate `name` field requirement; `type` is the selector key.

Segment selection APIs are documented in [`/doc/selecting.md`](/doc/selecting.md).

## Lifecycle Interaction

When a segment instance is materialized/added, `init(context)` may run and can initialize line-bound resources.

If `init` returns an awaitable (future/task) and `seg.stopped` is unset, the return value is stored as `seg.stopped` and later awaited by `line:ensure_stopped()`.

`init` is also the preferred place for per-instance default initialization (for example queue/future/state creation) when those defaults should not be shared across all lines.

## Run-Owned Continuation State

Continuation tracking belongs to the run, not the segment.

If a segment needs per-run continuation bookkeeping, use:

- `run.continuation`

Key continuation entries by runtime segment identity:

- prefer `segment.id`
- fallback `segment.type` when needed

Segment instance state and run continuation state are intentionally separate.
