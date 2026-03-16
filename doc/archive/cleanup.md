# Cleanup Audit: Async v5 Migration

> Status: Audit notes
> Date: 2026-03-16
> Context: async v5 rollout (segment-owned aspects: gater/executor)

This document captures code and documentation cleanup identified after async v5 implementation work. This is an audit only; no deletions were applied as part of writing this file.

## Scope

The current runtime has new async v5 modules in place:

- [`/lua/pipe-line/async.lua`](/lua/pipe-line/async.lua)
- [`/lua/pipe-line/errors.lua`](/lua/pipe-line/errors.lua)
- [`/lua/pipe-line/gater/init.lua`](/lua/pipe-line/gater/init.lua)
- [`/lua/pipe-line/gater/inflight.lua`](/lua/pipe-line/gater/inflight.lua)
- [`/lua/pipe-line/gater/none.lua`](/lua/pipe-line/gater/none.lua)
- [`/lua/pipe-line/executor/init.lua`](/lua/pipe-line/executor/init.lua)
- [`/lua/pipe-line/executor/buffered.lua`](/lua/pipe-line/executor/buffered.lua)
- [`/lua/pipe-line/executor/direct.lua`](/lua/pipe-line/executor/direct.lua)

Legacy boundary/transport systems still exist and should be removed.

## Delete Candidates (Runtime)

These files are part of the old explicit-boundary + transport-wrapper model and appear unused by the new path:

- [`/lua/pipe-line/consumer.lua`](/lua/pipe-line/consumer.lua)
- [`/lua/pipe-line/driver.lua`](/lua/pipe-line/driver.lua)
- [`/lua/pipe-line/segment/mpsc.lua`](/lua/pipe-line/segment/mpsc.lua)
- [`/lua/pipe-line/segment/define/mpsc.lua`](/lua/pipe-line/segment/define/mpsc.lua)
- [`/lua/pipe-line/segment/define/task.lua`](/lua/pipe-line/segment/define/task.lua)
- [`/lua/pipe-line/segment/define/safe-task.lua`](/lua/pipe-line/segment/define/safe-task.lua)
- [`/lua/pipe-line/segment/define/transport.lua`](/lua/pipe-line/segment/define/transport.lua)
- [`/lua/pipe-line/segment/define/transport/mpsc.lua`](/lua/pipe-line/segment/define/transport/mpsc.lua)
- [`/lua/pipe-line/segment/define/transport/task.lua`](/lua/pipe-line/segment/define/transport/task.lua)
- [`/lua/pipe-line/segment/define/common.lua`](/lua/pipe-line/segment/define/common.lua)

## In-Place Runtime Cleanup

### `line.lua`

Remove legacy API and references:

- Remove `Line:addHandoff(...)` from [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)
- Remove temporary alias `Line:prepare_segments()` from [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)
- Remove now-unused segment import in [`/lua/pipe-line/line.lua`](/lua/pipe-line/line.lua)

### `segment.lua`

Drop mpsc boundary exports:

- Remove mpsc import and exports from [`/lua/pipe-line/segment.lua`](/lua/pipe-line/segment.lua)
  - `HANDOFF_FIELD`
  - `mpsc_handoff_factory`
  - `mpsc_handoff`
  - `is_mpsc_handoff`

### Optional naming cleanup

In [`/lua/pipe-line/gater/inflight.lua`](/lua/pipe-line/gater/inflight.lua), consolidate stop option naming:

- Keep `gate_stop_type`
- Remove fallback alias `gater_stop_type`

## Tests to Remove or Rewrite

### Delete legacy suites

- [`/tests/pipe-line/consumer_spec.lua`](/tests/pipe-line/consumer_spec.lua)
- [`/tests/pipe-line/mpsc_spec.lua`](/tests/pipe-line/mpsc_spec.lua)

### Rewrite mixed suites

- [`/tests/pipe-line/pipeline_spec.lua`](/tests/pipe-line/pipeline_spec.lua)
  - Remove `mpsc_handoff` path tests
- [`/tests/pipe-line/init_spec.lua`](/tests/pipe-line/init_spec.lua)
  - Remove `pipeline.driver.interval` and `pipeline.driver.rescheduler` tests

### Global stale fixture cleanup

Remove `package.loaded["pipe-line.consumer"]` resets from test setup blocks where present:

- [`/tests/pipe-line/pipeline_spec.lua`](/tests/pipe-line/pipeline_spec.lua)
- [`/tests/pipe-line/mpsc_spec.lua`](/tests/pipe-line/mpsc_spec.lua)
- [`/tests/pipe-line/integration_spec.lua`](/tests/pipe-line/integration_spec.lua)
- [`/tests/pipe-line/init_spec.lua`](/tests/pipe-line/init_spec.lua)
- [`/tests/pipe-line/consumer_spec.lua`](/tests/pipe-line/consumer_spec.lua)
- [`/tests/pipe-line/log_spec.lua`](/tests/pipe-line/log_spec.lua)

## Documentation Cleanup Needed

### README is still old-model

[`/README.md`](/README.md) currently describes explicit `mpsc_handoff`, `auto_start_consumers`, `addHandoff`, `pipe-line.consumer`, and `pipe-line.driver`. It should be rewritten to v5 gate/executor/aspects and AsyncOp semantics.

### Normative docs still reference old architecture

Likely major updates needed:

- [`/doc/segment.md`](/doc/segment.md)
- [`/doc/run.md`](/doc/run.md)
- [`/doc/line.md`](/doc/line.md)
- [`/doc/registry.md`](/doc/registry.md)

### Discovery/ADR documents to archive or mark superseded

- [`/doc/discovery/async3.md`](/doc/discovery/async3.md)
- [`/doc/discovery/async4.md`](/doc/discovery/async4.md)
- [`/doc/discovery/driver.md`](/doc/discovery/driver.md)
- [`/doc/discovery/adr-async-boundary-segments.md`](/doc/discovery/adr-async-boundary-segments.md)
- [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)

Also update references in:

- [`/doc/INDEX.md`](/doc/INDEX.md)
- [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Suggested Cleanup Order

1. Runtime purge: delete legacy transport/consumer/mpsc files and remove old exports/methods.
2. Test sweep: remove legacy suites and rewrite integration tests around AsyncOp + aspects.
3. Docs sweep: update README and normative docs, then archive/supersede old discovery/ADR docs.
4. Final grep sanity pass for: `mpsc_handoff`, `run.continuation`, `pipe-line.consumer`, `pipe-line.driver`, `auto_start_consumers`, `addHandoff`.

## Notes

- This repository is pre-1.0 and compatibility is intentionally not a constraint for this migration.
- Async v5 design reference is [`/doc/discovery/async5.md`](/doc/discovery/async5.md).
