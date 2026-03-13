# Documentation Index

## Normative — Contracts and Guides

These define the current architecture. Read these to understand pipe-line.

- [`segment-authoring.md`](/doc/segment-authoring.md) — Segment contract: `handler(run)`, lifecycle hooks, return semantics, protocol pass-through via `define()`
- [`segment-instancing.md`](/doc/segment-instancing.md) — How registry prototypes become per-line runtime instances; `auto_fork`/`auto_instance`/`auto_id`; continuation ownership
- [`selecting.md`](/doc/selecting.md) — `line:select_segments()` and `line:stopped_live()` for runtime segment queries
- [`lifecycle.md`](/doc/lifecycle.md) — Line lifecycle orchestration: `ensure_prepared`, `ensure_stopped`, `close`, hook context shape, strategy-specific stop
- [`async-handoff.md`](/doc/async-handoff.md) — Explicit async boundaries via `mpsc_handoff`; custom handoff; manual continuation mode
- [`completion-protocol.md`](/doc/completion-protocol.md) — Completion control runs, state accounting, completion segment stop behavior

## Architecture Decision Records

- [`adr/README.md`](/doc/adr/README.md) — ADR index
- [`adr/adr-transport-policy-interface.md`](/doc/adr/adr-transport-policy-interface.md) — Transport wrappers compose on core `handler(run)` contract; removes `handler_async`/`configure_segment`
- [`adr/adr-stop-drain-and-cancel-signal.md`](/doc/adr/adr-stop-drain-and-cancel-signal.md) — Strategy-specific stop futures and verbs (`stop_drain`, `stop_immediate`). Proposed; not yet fully implemented.

## Discovery — Active Explorations

Working notes for in-progress design and audit work. May inform future normative docs.

- [`discovery/doc-fixes.md`](/doc/discovery/doc-fixes.md) — Audit of all doc files against current code; tracked discrepancies and recommendations
- [`discovery/readme-pipe-line.md`](/doc/discovery/readme-pipe-line.md) — Guide used for README rewrite: source material, content goals, contract language
- [`discovery/adr-async-boundary-segments.md`](/doc/discovery/adr-async-boundary-segments.md) — Exploratory notes on async boundary segment decomposition
- [`discovery/re-async.md`](/doc/discovery/re-async.md) — Async model re-examination notes
- [`discovery/rename.md`](/doc/discovery/rename.md) — Naming and rename considerations

## Archive — Superseded

Historical documents. These reflect earlier designs and are preserved for rationale context only.

- [`archive/consumer.md`](/doc/archive/consumer.md) — Old consumer API (`create`, `createPipeline`, `withDriver`); fully superseded by run-centric handoff model
- [`archive/mpsc-decomposition.md`](/doc/archive/mpsc-decomposition.md) — mpsc decomposition design exploration
- [`archive/mpsc-decomp-tasks.md`](/doc/archive/mpsc-decomp-tasks.md) — Task breakdown for mpsc decomposition
- [`archive/coop2.md`](/doc/archive/coop2.md) — coop.nvim integration notes
- [`archive/coop-tools.md`](/doc/archive/coop-tools.md) — coop utility exploration
- [`archive/requirements.md`](/doc/archive/requirements.md) — Early requirements
- [`archive/pipecopy.md`](/doc/archive/pipecopy.md), [`archive/pipecopy-next.md`](/doc/archive/pipecopy-next.md) — Pipe copy design iterations
- [`archive/pipenext-status.md`](/doc/archive/pipenext-status.md), [`archive/status.md`](/doc/archive/status.md), [`archive/status2.md`](/doc/archive/status2.md) — Historical status snapshots
- [`archive/self-ify.md`](/doc/archive/self-ify.md) — Self-ification refactor notes
- [`archive/pipeflow/`](/doc/archive/pipeflow/) — Earlier pipeflow design artifacts

## Other

- [`termichatter.txt`](/doc/termichatter.txt) — Neovim help file (vimdoc)
