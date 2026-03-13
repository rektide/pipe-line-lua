# Rename Discovery: nvim-termichatter → pipe-line-lua

Date: 2026-03-13

## Executive Summary

Project rename from **nvim-termichatter** to **pipe-line-lua**. represents a significant work across codebase, documentation, and and infrastructure. This document catalogs the comprehensive scope assessment for all changes required and and provides actionable recommendations for## Scope Assessment

### High Priority Changes (Critical Path, Must change first)

| Category | File | Changes Required | Complexity |
|----------| ---- | ------------------- | ----------- |
| **Core Module** | `lua/termichatter/` directory | Rename entire directory | High |
| **Test Suite** | `tests/termichatter/` directory | Rename entire directory | High |
| **Configuration** | `Cargo.toml` | Update package name | Low |
| **Configuration** | `.luarc.json` | Update workspace paths | Low |
| **Build Config** | `Makefile` | No changes needed | Low |
| **Repository Config** | `.gitignore` | No changes needed | Low |

| **Root Documentation** | `README.md` | Extensive rewrite | High |

### Medium Priority Changes (Post-rename cleanup)

| Category | File Count | Action Required | Complexity |
|---------- | ------------ | --------------------------- | ----------- |
| **Source references** | All `.lua` files | Update require statements | Medium |
| **Test imports** | All test files | Update import paths | Medium |
| **Doc references** | All doc files | Update references | Medium |
| **Internal fields** | Various files | Update field names like `_termichatter_*` | Medium |

### Lower Priority Changes (Optional but recommended)
| Category | File Count | Action Required | Complexity |
| ---------- | ------------ | --------------------------- | ----------- |
| **Benchmark references** | `benches/` directory | Update imports | Low |
| **Test agent files** | `.test-agent/` directory | Update internal references | Low |
| **Dependencies** | `deps/` directory | No changes needed | Low |
| **Vim help** | `doc/termichatter.txt` | Update if exists | Low |

## Documentation Freshness Assessment

### Fresh Documentation (Updated within last month, keep)

| File | Created | Last Modified | Status | Notes |
| ---- | ---- | -------------- | ----------- | ----- |
| `doc/adr/README.md` | 2026-02-26 | 2026-03-08 | ✅ Fresh | Canonical ADR index | Current, active documentation |
| `doc/adr/adr-stop-drain-and-cancel-signal.md` | 2026-02-26 | 2026-03-07 | ✅ Fresh | Canonical ADR | Current, active documentation |
| `doc/adr/adr-transport-policy-interface.md` | 2026-02-26 | 2026-03-08 | ✅ Fresh | Canonical ADR | Current, active documentation |
| `doc/lifecycle.md` | 2026-02-26 | 2026-03-07 | ✅ Fresh | Last update: Mar 2026 | Current, active documentation |
| `doc/segment-authoring.md` | 2026-02-26 | 2026-03-08 | ✅ Fresh | Last update: Mar 2026 | Current, active documentation |
| `doc/segment-instancing.md` | 2026-02-26 | 2026-03-08 | ✅ Fresh | Last update: Mar 2026 | Current, active documentation |
| `doc/async-handoff.md` | 2026-02-26 | 2026-03-07 | ✅ Fresh | Last update: Mar 2026 | Current, active documentation |
| `doc/completion-protocol.md` | 2026-02-26 | 2026-02-26 | ✅ Fresh | Never modified | Current, may need alignment review with ADR work |
| `doc/consumer.md` | 2026-02-07 | 2026-02-25 | ✅ Fresh | Last update: Feb 2026 | Current, active documentation |
| `doc/selecting.md` | 2026-02-26 | 2026-02-26 | ✅ Fresh | Never modified | May need alignment review with ADR work |
| `doc/discovery/adr-async-boundary-segments.md` | 2026-02-25 | 2026-02-25 | ✅ Fresh | Current ADR | Superseded older discovery notes |
| `doc/discovery/re-async.md` | 2026-02-26 | 2026-02-26 | ✅ Fresh | Never modified | Active planning document |

| `doc/discovery/coop2.md` | 2026-02-26 | 2026-03-12 | Archive | Superseded by ADRs | Contains useful historical context |
| `doc/discovery/mpsc-decomp-tasks.md` | 2026-02-26 | 2026-03-12 | Archive | Superseded by ADRs | Contains useful historical context |
| `doc/discovery/mpsc-decomposition.md` | 2026-02-26 | 2026-03-12 | Archive | Superseded by ADRs | Contains useful historical context |
| `doc/discovery/status.md` | 2026-02-23 | 2026-02-25 | Outdated | Earlier status, superseded by later work and ADR docs |
| `doc/discovery/status2.md` | 2026-02-26 | 2026-02-26 | Outdated | Second status update, superseded by ADR docs |

### Outdated Documentation (Consider archiving or deleting)
| File | Created | Last Modified | Reason |
| ---- | -------- | ------------- | ------ |
| `doc/discovery/requirements.md` | 2026-02-04 | 2026-02-04 | Original project vision, very different from current async pipeline architecture |
| `doc/discovery/pipecopy.md` | 2026-02-14 | 2026-02-14 | Earlier implementation planning, superseded by current architecture |
| `doc/discovery/pipeflow/*.md` | 2026-02-14 | 2026-02-25 | TypeScript-based effect system exploration - speculative, may have future reference value |
| `doc/discovery/pipenext-status.md` | 2026-02-21 | 2026-02-25 | Implementation status from earlier phase, superseded by ADR docs |
| `doc/discovery/self-ify.md` | 2026-02-12 | 2026-02-12 | Mode-based implementation notes, superseded by current architecture |
| `doc/discovery/coop-tools.md` | 2026-02-04 | 2026-02-04 | Superseded by ADR work |
| `doc/review/pipecopy-next.md` | 2026-02-20 | 2026-02-20 | Review of earlier implementation attempt |

## Detailed Findings

### 1. Source Code Analysis

#### Lua Module Structure
```
lua/termichatter/
├── consumer.lua
├── coop.lua
├── driver.lua
├── inherit.lua
├── init.lua
├── line.lua
├── log.lua
├── outputter.lua
├── pipe.lua
├── protocol.lua
├── registry.lua
├── resolver.lua
├── run.lua
├── util.lua
├── segment/
    ├── completion.lua
    ├── define/
    │   ├── common.lua
    │   ├── mpsc.lua
    │   ├── safe-task.lua
    │   ├── task.lua
    │   └── transport/
        │       ├── mpsc.lua
        │       └── task.lua
    ├── define.lua
    └── mpsc.lua
```

Total: ~30 files in `lua/termichatter/` and subdirectories

#### Import Pattern Analysis
Current imports use:
require("termichatter.*")
 pattern:
- `require("termichatter")` - main module
- `require("termichatter.line")`
- `require("termichatter.pipe")`
- `require("termichatter.run")`
- `require("termichatter.segment")`
- `require("termichatter.segment.define")`
- `require("termichatter.segment.mpsc")`
- etc.

This pattern appears consistently across all 25+ source files.

#### Test Structure
```
tests/termichatter/
├── consumer_spec.lua
├── init_spec.lua
├── integration_spec.lua
├── line_spec.lua
├── log_spec.lua
├── mpsc_spec.lua
├── outputter_spec.lua
├── pipe_spec.lua
├── pipeline_spec.lua
┞── protocol_spec.lua
├── resolver_spec.lua
├── run_spec.lua
└── stopped_live_spec.lua
```

Total: 14 test files

#### Documentation Structure
```
doc/
├── adr/
│   ├── README.md
│   ├── adr-stop-drain-and-cancel-signal.md
│   └── adr-transport-policy-interface.md
├── discovery/
│   ├── adr-async-boundary-segments.md
│   ├── coop-tools.md
│   ├── coop2.md
│   ├── mpsc-decomp-tasks.md
│   ├── mpsc-decomposition.md
│   ├── pipecopy.md
│   ├── pipeflow/ (13 files)
│   ├── pipenext-status.md
│   ├── re-async.md
│   ├── requirements.md
│   ├── self-ify.md
│   ├── status.md
│   └── status2.md
├── review/
│   └── pipecopy-next.md
├── async-handoff.md
├── completion-protocol.md
├── consumer.md
├── lifecycle.md
├── segment-authoring.md
├── segment-instancing.md
└── selecting.md
```

Total: ~30 documentation files

### 2. Termichatter Reference Analysis

#### Files by Category
| Category | File Count | Est. Lines |
|----------|-------------|-----------|
| Lua source | 25 | ~2,100 |
| Tests | 14 | ~1,400 |
| Documentation | 30 | ~1,700 |
| Config files | 4 | <100 |
| Test agent | 26 | ~2,500 |

#### High-Impact Reference Locations
1. **README.md**: 15 references
2. **lua/termichatter/init.lua**: 20+ references (internal)
3. **Tests**: 150+ references
 all tests clear package cache and re-import
4. **Documentation**: 150+ references across all doc files
5. **Test agent files**: 20+ references in `.test-agent/` directory

### 3. Directory Structure Implications

#### New Structure Proposal
```
lua/pipe-line-lua/
├── consumer.lua
├── coop.lua
├── driver.lua
├── inherit.lua
├── init.lua
├── line.lua
├── log.lua
├── outputter.lua
├── pipe.lua
├── protocol.lua
├── registry.lua
├── resolver.lua
├── run.lua
├── util.lua
└── segment/
    └── [same structure as current]
```

#### Test Directory Structure
```
tests/pipe-line-lua/
└── [same test files, renamed]
```

### 4. Configuration Updates

#### Cargo.toml
```toml
[package]
name = "pipe-line-lua-bench"  # was: termichatter-lua-bench
version = "0.1.0"
edition = "2021"
```

#### .luarc.json
```json
{
  "$schema": "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json",
  "diagnostics": {
    "globals": ["vim"]
  },
  "runtime": {
    "version": "LuaJIT"
  },
  "workspace": {
    "library": [
      "${3rd}/luv/library",
      "/usr/share/nvim/runtime",
      "deps/share/lua/5.1"
    ],
    "checkThirdParty": "Disable"
  }
}
```
No changes needed - paths are relative.

#### .gitignore
No changes needed - no project-specific references.

### 5. Special Considerations

#### Field Names to Review
Some internal fields may reference the old name:
- `_termichatter_line` → `_pipe_line_line` or similar
- `_termichatter_is_instance` → `_pipe_line_is_instance`
- `_termichatter_task_state` → `_pipe_line_task_state`
- `__termichatter_handoff_run` → `__pipe_line_handoff_run`
- `__termichatter_mpsc_continuation` → `__pipe_line_mpsc_continuation`
- `termichatter_protocol` → `pipe_line_protocol`

**Decision needed**: Should these internal field names change? They are implementation details not exposed in public API.

#### Message Type Constants
- `"termichatter.log"` → Consider: `"pipe-line-lua.log"` or keep as-is
- `"termichatter.shutdown"` → Consider: `"pipe-line-lua.shutdown"` or keep as-is

#### vim.help File
- `doc/termichatter.txt` - needs to be renamed and updated

### 6. Naming Recommendations

#### Option A: Full Rename (Recommended)
- GitHub repository: `rektide/pipe-line-lua`
- Lua module: `pipe-line-lua` (or `pipelineline` or `pipelinelua`)
- npm package: `pipe-line-lua`
- Documentation: Full rename throughout

Pros:
- Clean separation from nvim-specific past
- Clear generic Lua library positioning
- Professional naming

Cons:
- Hyphenated Lua module names are awkward (require `require("pipe-line-lua")`)
- May confuse existing users

#### Option B: Shortened Name
- GitHub repository: `rektide/pipeline-lua`
- Lua module: `pipeline` or `pipelua`

Pros:
- Simpler requires: `require("pipeline")`
- Still conveys generic nature

Cons:
- "pipeline" is very generic, may conflict
- Less distinctive

#### Option C: Hybrid
- Repository: `pipe-line-lua`
- Lua module: `pipelua` (no hyphens)

Pros:
- Clean requires: `require("pipelua")`
- Repository name matches user's request

Cons:
- Slight inconsistency between repo and module names

### 7. Implementation Phases

#### Phase 1: Preparation
1. Create backup branch
2. Ensure all tests pass
3. Document current state

#### Phase 2: Directory Rename
1. `git mv lua/termichatter lua/pipelinelua` (or chosen name)
2. `git mv tests/termichatter tests/pipelinelua`
3. Update `.luarc.json` if needed

#### Phase 3: Code Updates
1. Update all `require()` statements
2. Update field names (decide on internal field naming)
3. Update string constants
4. Update comments

#### Phase 4: Documentation
1. Update README.md
2. Update all doc/*.md files
3. Update doc/discovery/*.md files
4. Update ADR documents
5. Update code examples

#### Phase 5: Configuration
1. Update Cargo.toml
2. Update any CI/CD configs
3. Update package metadata

#### Phase 6: Testing
1. Run all tests
2. Fix broken imports
3. Verify documentation examples work

#### Phase 7: Finalization
1. Update repository URL in docs
2. Create migration guide for existing users
3. Commit all changes

### 8. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Breaking existing users | High | High | Provide clear migration guide |
| Missing references | Medium | Medium | Comprehensive grep before/after |
| Test failures | Medium | High | Run tests after each phase |
| Documentation inconsistency | Medium | Low | Careful review process |
| CI/CD breakage | Low | Medium | Check all config files |

### 9. Estimated Effort

| Phase | Estimated Time | Complexity |
|-------|---------------|------------|
| Preparation | 30 min | Low |
| Directory rename | 15 min | Low |
| Code updates | 2-3 hours | Medium |
| Documentation | 3-4 hours | Medium |
| Configuration | 30 min | Low |
| Testing | 1-2 hours | Medium |
| Finalization | 1 hour | Low |
| **Total** | **8-11 hours** | **Medium** |

### 10. Recommendations

#### Immediate Actions
1. **Decide on final module name** - This affects all subsequent work
   - Recommended: `pipelinelua` (no hyphens, clear, matches repo)
   - Alternative: `pipe-line-lua` (exact match, but hyphenated)
   
2. **Create migration checklist** - Detailed list of every file to touch

3. **Choose internal field naming strategy**:
   - Option A: Keep as-is (minimal disruption)
   - Option B: Rename for consistency (more work but cleaner)

#### Documentation Strategy
1. **Keep ADR docs current** - These are fresh and canonical
2. **Archive outdated docs** - Move to `doc/archive/` or mark as deprecated
3. **Consolidate discovery notes** - Consider merging related documents

#### Testing Strategy
1. Run full test suite before starting
2. Run tests after each major phase
3. Keep test coverage intact during rename

### 11. Module Naming Decision Matrix

| Name | Pros | Cons | Verdict |
|------|------|------|---------|
| `pipelinelua` | Clean, no hyphens, distinctive | Longer | ⭐ Recommended |
| `pipe-line-lua` | Exact match to repo | Hyphens in requires | ❌ Not recommended |
| `pipeline` | Short, clear | Too generic, may conflict | ❌ Not recommended |
| `pipelua` | Short, clear | Less descriptive | ⚠️ Acceptable alternative |
| `ppl` | Very short | Cryptic | ❌ Not recommended |

## Appendix A: Complete File List Requiring Updates

### Lua Source Files (25 files)
```
lua/termichatter/consumer.lua
lua/termichatter/coop.lua
lua/termichatter/driver.lua
lua/termichatter/inherit.lua
lua/termichatter/init.lua
lua/termichatter/line.lua
lua/termichatter/log.lua
lua/termichatter/outputter.lua
lua/termichatter/pipe.lua
lua/termichatter/protocol.lua
lua/termichatter/registry.lua
lua/termichatter/resolver.lua
lua/termichatter/run.lua
lua/termichatter/util.lua
lua/termichatter/segment.lua
lua/termichatter/segment/completion.lua
lua/termichatter/segment/define.lua
lua/termichatter/segment/mpsc.lua
lua/termichatter/segment/define/common.lua
lua/termichatter/segment/define/mpsc.lua
lua/termichatter/segment/define/safe-task.lua
lua/termichatter/segment/define/task.lua
lua/termichatter/segment/define/transport.lua
lua/termichatter/segment/define/transport/mpsc.lua
lua/termichatter/segment/define/transport/task.lua
```

### Test Files (14 files)
```
tests/termichatter/consumer_spec.lua
tests/termichatter/init_spec.lua
tests/termichatter/integration_spec.lua
tests/termichatter/line_spec.lua
tests/termichatter/log_spec.lua
tests/termichatter/mpsc_spec.lua
tests/termichatter/outputter_spec.lua
tests/termichatter/pipe_spec.lua
tests/termichatter/pipeline_spec.lua
tests/termichatter/protocol_spec.lua
tests/termichatter/resolver_spec.lua
tests/termichatter/run_spec.lua
tests/termichatter/stopped_live_spec.lua
tests/busted.lua (minor updates)
```

### Documentation Files (30 files)
All doc/*.md files contain references to "termichatter"

### Configuration Files (4 files)
```
Cargo.toml
.luarc.json (no changes needed)
Makefile (no changes needed)
.gitignore (no changes needed)
```

## Appendix B: Grep Commands for Verification

Before rename:
```bash
grep -r "termichatter" --include="*.lua" --include="*.md" --include="*.toml" . | wc -l
```

After rename (to verify completeness):
```bash
grep -r "termichatter" --include="*.lua" --include="*.md" --include="*.toml" .
# Should only find references in comments explaining the old name
```

## Appendix C: Migration Guide Template

```markdown
# Migration Guide: termichatter → pipe-line-lua

## Overview
[Explain the rename and why]

## Breaking Changes

### Module Name
- Old: `require("termichatter")`
- New: `require("pipelinelua")`

### Internal Fields
[List any changed internal field names]

## Migration Steps

1. Update your plugin manager configuration:
   ```lua
   -- lazy.nvim
   {
       "rektide/pipe-line-lua",  -- was: rektide/nvim-termichatter
       dependencies = { "gregorias/coop.nvim" },
   }
   ```

2. Update your code:
   ```lua
   -- Before
   local termichatter = require("termichatter")
   
   -- After
   local pipelinelua = require("pipelinelua")
   ```

[Continue with specific examples]
```
