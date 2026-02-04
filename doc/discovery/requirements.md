# Requirements

## Background

Termichatter is an Neovim plugin providing a buffered asynchronous logging system. It enables structured logging with configurable latency, multiple buffer support, and Cloud Events-compliant message enrichment.

## Initial Prompt

Create termichatter: an nvim plugin that is a buffered async logger. Termichatter supports multiple buffers of log data. These are immediately timestamped on ingress/queue time. An async loop runs to flush messages to disk in a structured log system. Messages are extended with Cloud Event fields by a pipeline processor, before being batch spun to disk. Latency is configurable. Loggers ought be instantiated by clients with a module name, for npm debug like ability to filter/turn different loggers on off and to different levels. Priority is converted to a number at ingress, from "error", "log" "info" "warn" "debug". coop.nvim is used for all async and file system work.

## Requirements

### Core Functionality

- [REQ-001] Provide a buffered asynchronous logging system for Neovim plugins
- [REQ-002] Support multiple independent log buffers that can be managed concurrently
- [REQ-003] Assign timestamps to log messages immediately at ingress/queue time
- [REQ-004] Maintain an asynchronous processing loop that flushes messages to disk
- [REQ-005] Write logs to a structured log system on disk (e.g., JSONL or similar structured format)

### Message Processing Pipeline

- [REQ-006] Implement a pipeline processor that extends messages with Cloud Events fields before writing to disk
- [REQ-007] Batch messages before writing to disk (configurable batch size or time-based batching)
- [REQ-008] Cloud Events extension should include at minimum:
  - `specversion`: Cloud Events spec version
  - `type`: Event type identifier
  - `source`: Source of the event (likely the module name)
  - `id`: Unique event identifier
  - `time`: Event timestamp
  - `data`: The original log message payload

### Logger Instantiation and Filtering

- [REQ-009] Allow clients to instantiate loggers with a module name (string identifier)
- [REQ-010] Provide npm debug-like ability to filter loggers by module name
- [REQ-011] Support enabling/disabling individual loggers or groups of loggers
- [REQ-012] Support setting different log levels per logger:
  - `error` (highest priority)
  - `warn`
  - `log`
  - `info`
  - `debug` (lowest priority)
- [REQ-013] Convert priority levels to numeric values at ingress for efficient filtering and comparison

### Configuration

- [REQ-014] Make latency (time before flush) configurable
- [REQ-015] Provide configuration for batch size thresholds
- [REQ-016] Allow configuration of output log location
- [REQ-017] Support runtime configuration updates (where safe to do so)

### Async and File System Operations

- [REQ-018] Use coop.nvim for all asynchronous operations
- [REQ-019] Use coop.nvim for all file system operations
- [REQ-020] Ensure thread-safe operations when managing multiple buffers

### Integration and API

- [REQ-021] Provide a clean Lua API for plugin integration
- [REQ-022] Support TypeScript/JavaScript consumers (if applicable given coop.nvim context)
- [REQ-023] Provide methods for:
  - Creating loggers
  - Writing log messages at different levels
  - Flushing buffers explicitly (synchronous or async option)
  - Checking logger status
  - Configuring global and per-logger settings

### Performance and Reliability

- [REQ-024] Ensure minimal impact on Neovim's main thread responsiveness
- [REQ-025] Handle disk write failures gracefully (queue retention, retry logic)
- [REQ-026] Prevent memory leaks in buffer management
- [REQ-027] Provide graceful shutdown/cleanup on Neovim exit

### Testing

- [REQ-028] Include unit tests for core logging functionality
- [REQ-029] Include integration tests with coop.nvim
- [REQ-030] Test concurrent buffer operations
- [REQ-031] Test Cloud Events message extension

## Non-Functional Requirements

- [NFR-001] Code should be well-documented with clear API references
- [NFR-002] Follow existing code style conventions in the project
- [NFR-003] Ensure type safety where TypeScript is used
- [NFR-004] Maintain compatibility with Neovim 0.9+ (or as appropriate)
- [NFR-005] Keep dependencies minimal and well-justified

## Open Questions

- [OQ-001] What is the preferred structured log format (JSONL, NDJSON, other)?
- [OQ-002] Should log files be rotated (size-based or time-based)?
- [OQ-003] What is the default latency and batch size?
- [OQ-004] How should configuration be specified (Lua table, environment variables, config file)?
- [OQ-005] Should there be a way to subscribe to log messages in real-time (for debugging plugins)?
