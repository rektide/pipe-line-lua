# README Rewrite Guide (`pipe-line`)

This guide captures what to use as source material when rewriting [`/README.md`](/README.md) so it reflects the current architecture.

## Primary Sources (Normative)

Use these first. They define current contract and direction.

- ADR index and scope: [`/doc/adr/README.md`](/doc/adr/README.md)
- Transport contract: [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)
- Stop strategy contract: [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)
- Segment contract and async/completion handoff model: [`/doc/segment.md`](/doc/segment.md)
- Run execution and continuation flow: [`/doc/run.md`](/doc/run.md)
- Line lifecycle orchestration and selection: [`/doc/line.md`](/doc/line.md)
- Registry model and emits index usage: [`/doc/registry.md`](/doc/registry.md)

## Secondary Sources (Exploratory / Historical)

These are useful for rationale and alternatives, but should not drive README contract text.

- [`/doc/archive/coop2.md`](/doc/archive/coop2.md)
- [`/doc/archive/mpsc-decomp-tasks.md`](/doc/archive/mpsc-decomp-tasks.md)
- [`/doc/archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md)

## README Content Goals

Keep README short, stable, and contract-focused.

1. What `pipe-line` is (one short paragraph)
2. Core runtime model: Line / Pipe / Segment / Run
3. Segment contract: `handler(run)` plus lifecycle hooks
4. Async model: explicit boundary + run-owned continuation (`run.continuation`)
5. Stop model: `stop_type`, `stop_drain`, `stop_immediate`
6. Quick start (minimal working example)
7. Links to deeper docs

## Contract Language to Preserve

- `handler(run)` is the per-message segment entrypoint.
- `handler_async` is not part of core contract.
- Transport wrappers compose on core segment contract.
- `run.continuation` is the run-owned continuation tracking field.
- `ensure_stopped` follows strategy selected by `stop_type`.

## Key README Citations

At minimum, README should point readers to:

- [`/doc/segment.md`](/doc/segment.md)
- [`/doc/run.md`](/doc/run.md)
- [`/doc/line.md`](/doc/line.md)
- [`/doc/registry.md`](/doc/registry.md)
- [`/doc/adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md)
- [`/doc/adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md)

## Consistency Checklist

Before finalizing README rewrite:

- Use one naming style consistently (`pipe-line` paths/module naming).
- Avoid reintroducing deprecated vocabulary (`dispatch`, `handler_async`, `configure_segment`) as core API.
- Keep examples aligned with current module paths and documented lifecycle hooks.
