# Contributing to ZigCraft

Thank you for your interest in contributing to ZigCraft! This document covers the development workflow, coding conventions, and how to get started.

---

## Table of Contents
- [Quick Start](#quick-start)
- [Development Environment](#development-environment)
- [Branching Strategy](#branching-strategy)
- [Workflow](#workflow)
- [PR Templates](#pr-templates)
- [Code Style](#code-style)
- [Testing](#testing)
- [Common Tasks](#common-tasks)

---

## Quick Start

### Prerequisites
- Nix package manager (installed via [NixOS](https://nixos.org/) or [Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer))
- Git

### First-Time Setup
```bash
# Clone repository
git clone https://github.com/OpenStaticFish/ZigCraft.git
cd ZigCraft

# Enter dev environment
nix develop

# Build and run tests
zig build test
```

---

## Development Environment

The project uses Nix for reproducible builds. All commands must be run with `nix develop --command`.

### Build & Run
```bash
# Build
nix develop --command zig build

# Run
nix develop --command zig build run

# Release build (optimized)
nix develop --command zig build -Doptimize=ReleaseFast

# Clean build artifacts
rm -rf zig-out/ .zig-cache/
```

### Testing
```bash
# Run all unit tests (also validates Vulkan shaders)
nix develop --command zig build test

# Run a specific test
nix develop --command zig build test -- --test-filter "Vec3 addition"

# Integration test (window init smoke test)
nix develop --command zig build test-integration
```

### Linting & Formatting
```bash
# Format code
nix develop --command zig fmt src/

# Fast type-check (no full compilation)
nix develop --command zig build check
```

### Asset Processing
```bash
# Process PBR textures (Standardize 4k sources to 512px PNGs)
./scripts/process_textures.sh assets/textures/<pack_name> 512
```

---

## Branching Strategy

```
main        <- Production-ready code
 |
dev         <- Staging branch for integrated features
 |
 +- feature/*  <- New features
 +- bug/*      <- Non-critical bug fixes
 +- hotfix/*   <- Critical bug fixes (crashes, data loss)
 +- ci/*       <- CI/workflow changes
```

### Branch Types

| Branch Type | Purpose | Merge Flow | Examples |
|-------------|---------|-------------|----------|
| `feature/*` | New features, enhancements | `feature -> dev -> main` | `feature/lod-system` |
| `bug/*` | Non-critical bugs | `bug -> dev -> main` | `bug/rendering-artifact` |
| `hotfix/*` | Critical bugs (crashes, data loss) | `hotfix -> dev -> main` | `hotfix/crash-on-load` |
| `ci/*` | CI/workflow changes | `ci -> dev -> main` | `ci/update-runner` |
| `dev` | Staging/integration | All PRs target dev | - |
| `main` | Production | `dev -> main` promotions | - |

### Branch Naming Guidelines
- Use **kebab-case** for branch names
- Be descriptive: `feature/lod-system`, `bug/chunk-leak`, `hotfix/save-corruption`
- No strict format required (issue numbers optional)
- CI branches: `ci/` prefix for `.github/` changes

---

## Workflow

### 1. Start a New Feature or Bug Fix

```bash
# Always branch from dev
git checkout dev
git pull origin dev

# Create your branch
git checkout -b feature/your-feature-name
# or
git checkout -b bug/your-bug-fix
# or
git checkout -b hotfix/critical-fix
# or
git checkout -b ci/workflow-change
```

### 2. Make Changes

Follow the coding conventions in [AGENTS.md](AGENTS.md) and [Code Style](#code-style) below.

```bash
# Format your code before committing
nix develop --command zig fmt src/

# Run tests
nix develop --command zig build test
```

### 3. Commit Changes

Use conventional commits for clear commit messages:

```
feat: add LOD system for distant terrain
fix: resolve chunk mesh memory leak
hotfix: prevent crash on save file corruption
ci: update runner configuration for faster builds
refactor: extract lighting calculation to separate module
test: add unit tests for Vec3 operations
docs: update CONTRIBUTING.md with workflow changes
```

### 4. Push & Create PR

```bash
# Push your branch
git push origin feature/your-feature-name
```

- Open a PR on GitHub
- Select the appropriate template (feature, bug, hotfix, ci)
- **Base branch: `dev`** (all PRs should target `dev`)
- Mark as **[Draft]** if work-in-progress

### 5. Review & Merge

- Wait for CI checks to pass: `build`, `unit-test`, `integration-test`, `opencode`
- Address review feedback
- Once approved, merge using **Squash and merge**
- Delete your branch after merging

### 6. Promote to Main (for maintainers)

When `dev` has stable features ready for production:

```bash
# Create PR from dev -> main
git checkout main
git pull origin main
git checkout -b promote/dev-to-main-$(date +%Y%m%d)
git push origin promote/dev-to-main-$(date +%Y%m%d)
```

- Create a PR with base `main`, compare `dev`
- Verify all CI checks pass
- Merge after final review

---

## PR Templates

We have 4 PR templates to help standardize contributions:

- **feature.md** - New features and enhancements
- **bug.md** - Non-critical bug fixes
- **hotfix.md** - Critical issues requiring immediate attention
- **ci.md** - Workflow and CI changes

Each template includes:
- Type classification
- Related issue links
- Checklist of requirements
- Testing steps

---

## Code Style

### Naming Conventions
- **Types/Structs/Enums**: `PascalCase` (`RenderSystem`, `BufferHandle`)
- **Functions/Variables**: `snake_case` (`init_renderer`, `mesh_queue`)
- **Constants/Globals**: `SCREAMING_SNAKE_CASE` (`MAX_CHUNKS`)
- **Files**: `snake_case.zig`

### Import Order
```zig
// 1. Standard library
const std = @import("std");
const Allocator = std.mem.Allocator;

// 2. C imports (always via c.zig)
const c = @import("../c.zig").c;

// 3. Local modules (relative paths)
const Vec3 = @import("../math/vec3.zig").Vec3;
const log = @import("../engine/core/log.zig");
```

### Memory Management
- Functions allocating heap memory MUST accept `std.mem.Allocator`
- Use `defer`/`errdefer` for cleanup immediately after allocation
- Prefer `std.ArrayListUnmanaged` in structs that store the allocator elsewhere

### Error Handling
- Propagate errors with `try`; define subsystem-specific error sets
- Log errors: `log.log.err("msg: {}", .{err})`
- Use `//!` for module-level docs, `///` for public API docs

For full coding guidelines, see [AGENTS.md](AGENTS.md).

---

## Testing

### Before Committing
```bash
# Format code
nix develop --command zig fmt src/

# Run all tests
nix develop --command zig build test
```

### Test Coverage
- Add unit tests for new utility, math, or worldgen logic
- Use descriptive test names: `test "Vec3 normalize"`
- Test error paths and edge cases

### Graphics Testing
For rendering changes:
- Run the app and verify visually
- Test multiple graphics presets (LOW, MEDIUM, HIGH, ULTRA)
- Check for regressions in shadows, lighting, fog

---

## Common Tasks

### Adding a New Block Type
1. Add entry to `BlockType` enum in `src/world/block.zig`
2. Register properties (`isSolid`, `isTransparent`, `getLightEmission`, `getColor`)
3. Add textures to `src/engine/graphics/texture_atlas.zig`
4. Standardize PBR textures: `./scripts/process_textures.sh`
5. Update `src/world/chunk_mesh.zig` for special face/transparency logic

### Modifying Shaders
1. GLSL sources in `assets/shaders/` (Vulkan shaders in `vulkan/` subdirectory)
2. Vulkan SPIR-V validated during `zig build test` via `glslangValidator`
3. Uniform names must match exactly between shader source and RHI backends

### Adding Unit Tests
Add tests to `src/tests.zig` using `std.testing` assertions:
- `expectEqual` - exact value comparison
- `expectApproxEqAbs` - floating point comparison
- `expect` - boolean/boolean expressions

---

## Project Structure

```
src/
  engine/           # Core engine systems
    core/           # Window, time, logging, job system
    graphics/       # RHI, shaders, textures, camera, shadows
    input/          # Input handling
    math/           # Vec3, Mat4, AABB, Frustum
    ui/             # Immediate-mode UI, fonts, widgets
  world/            # Voxel world logic
    worldgen/       # Terrain generation, biomes, caves
    block.zig       # Block types and properties
    chunk.zig       # Chunk data structure (16x256x16)
    chunk_mesh.zig  # Mesh generation from chunks
    world.zig       # World management
  game/             # Application logic, state, menus
  c.zig             # Central C interop (@cImport)
  main.zig          # Entry point
  tests.zig         # Unit test suite
libs/               # Local dependencies (zig-math, zig-noise)
assets/shaders/     # GLSL shaders (vulkan/ contains SPIR-V)
```

---

## Getting Help

- 📖 [Issues](https://github.com/OpenStaticFish/ZigCraft/issues) - Report bugs or request features
- 💬 [Discussions](https://github.com/OpenStaticFish/ZigCraft/discussions) - Ask questions
- 📚 [AGENTS.md](AGENTS.md) - Agent coding guidelines

---

## License

By contributing, you agree that your contributions will be licensed under the project's license.
