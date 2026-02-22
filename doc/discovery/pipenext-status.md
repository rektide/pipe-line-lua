# pipenext-status

Assessment of the new Lua implementation in `lua/termichatter` and its test suites.

## Overview

termichatter-nvim is a structured data-flow pipeline system for Neovim built atop coop.nvim. The implementation uses a layered architecture:

```
Registry (segment library)
    ↓
  Line (pipeline definition, holds pipe + config)
    ↓
  Run (cursor walking the pipe, executing segment)
    ↓
 Output (final destination queue)
```

Key concepts:
- **line**: a pipeline definition holding a pipe, registry, output
- **pipe**: connected sequence of segment with rev/splice/clone capabilities
- **segment**: processing component/handler in a pipe
- **run**: lightweight cursor/context that walks a pipe
- **registry**: repository of known segment types
- **fact**: named capability or state tracked on line/run

## Test Suites Found

| File | Description |
| ---- | ----------- |
| [`tests/termichatter/init_spec.lua`](/tests/termichatter/init_spec.lua) | Tests for main init module |
| [`tests/termichatter/pipe_spec.lua`](/tests/termichatter/pipe_spec.lua) | Tests for pipe module |
| [`tests/termichatter/run_spec.lua`](/tests/termichatter/run_spec.lua) | Tests for run module |
| [`tests/termichatter/line_spec.lua`](/tests/termichatter/line_spec.lua) | Tests for line module (not found) |
| [`tests/termichatter/resolver_spec.lua`](/tests/termichatter/resolver_spec.lua) | Tests for lattice resolver |
| [`tests/termichatter/consumer_spec.lua`](/tests/termichatter/consumer_spec.lua) | Tests for async consumer |
| [`tests/termichatter/pipeline_spec.lua`](/tests/termichatter/pipeline_spec.lua) | Integration tests for full pipeline |
| [`tests/termichatter/integration_spec.lua`](/tests/termichatter/integration_spec.lua) | Integration tests |

## Test Runner

Tests are run via: `nvim -l tests/busted.lua`

---

# journal - initial exploration

Started by examining the project structure:

1. **Lua modules** in `lua/termichatter/`:
   - `init.lua` - main entry point
   - `line.lua` - pipeline definition
   - `pipe.lua` - connected sequence of segments
   - `run.lua` - execution cursor
   - `registry.lua` - segment repository
   - `resolver.lua` - lattice dependency resolver
   - `segment.lua` - built-in segments
   - `consumer.lua` - async consumer
   - `driver.lua` - scheduling
   - `outputter.lua` - output destinations
   - `protocol.lua` - completion protocol
   - `inherit.lua` - metatable utilities

2. **Test files** in `tests/termichatter/`:
   - 8 test spec files found
   - `busted.lua` is the test runner

Reference: [`README.md`](/README.md) for architecture documentation.
