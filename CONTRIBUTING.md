# Contributing to ZigCraft

Thank you for your interest in contributing to ZigCraft! This is primarily a solo, AI-assisted project, but well-scoped contributions are welcome. This document covers the development workflow, coding conventions, and how to get started.

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
- Nix package manager (installed via [NixOS](https://nixos.org/) or [Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer)) — required by devenv
- [devenv](https://devenv.sh/getting-started/) (`nix profile add nixpkgs#devenv`)
- [direnv](https://direnv.net/) (optional; auto-activates the shell on `cd`)
- Git

### First-Time Setup
```bash
# Clone repository
git clone https://github.com/OpenStaticFish/ZigCraft.git
cd ZigCraft

# Enter dev environment
devenv shell

# Build and run tests
zig build test
```

---

## Development Environment

The project uses devenv (Nix-based) for reproducible builds. All commands must be run with `devenv shell`.

### Build & Run
```bash
# Build
devenv shell zig build

# Run
devenv shell zig build run

# Release build (optimized)
devenv shell zig build -Doptimize=ReleaseFast

```

### Testing
```bash
# Run all unit tests (also validates Vulkan shaders)
devenv shell zig build test

# Run a specific test
devenv shell zig build test -- --test-filter "Vec3 addition"

# Integration test (requires a display/compositor and Vulkan driver)
timeout --kill-after=30s 10m devenv shell zig build test-integration
```

### Linting & Formatting
```bash
# Format code
devenv shell zig fmt src/ modules/ build.zig

# Check formatting without edits
devenv shell zig fmt --check src/ modules/ build.zig

# Compile the application; there is no `zig build check` step
devenv shell zig build
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
| `feature/*` | New features, enhancements | `feature -> dev -> main` | `feature/terrain-improvements` |
| `bug/*` | Non-critical bugs | `bug -> dev -> main` | `bug/rendering-artifact` |
| `hotfix/*` | Critical bugs (crashes, data loss) | `hotfix -> dev -> main` | `hotfix/crash-on-load` |
| `ci/*` | CI/workflow changes | `ci -> dev -> main` | `ci/update-runner` |
| `dev` | Staging/integration | All PRs target dev | - |
| `main` | Production | `dev -> main` promotions | - |

### Branch Naming Guidelines
- Use **kebab-case** for branch names
- Be descriptive: `feature/terrain-improvements`, `bug/chunk-leak`, `hotfix/save-corruption`
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

Follow the coding conventions in [Code Style](#code-style) below. The [AGENTS.md](AGENTS.md) file contains detailed internal guidelines used by AI coding agents and may also be a useful reference.

```bash
# Format your code before committing
devenv shell zig fmt src/ modules/ build.zig

# Run tests
devenv shell zig build test
```

### 3. Commit Changes

Use conventional commits for clear commit messages and PR titles. Allowed types are `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`, `perf`, `build`, `style`, and `revert`.

```
feat: add terrain generation improvements
fix: resolve chunk mesh memory leak
ci: update runner configuration for faster builds
refactor: extract lighting calculation to separate module
test: add unit tests for Vec3 operations
docs: update CONTRIBUTING.md with workflow changes
```

### Developer Certificate of Origin (DCO)

Every PR commit must include a `Signed-off-by` trailer certifying the Developer Certificate of Origin. Create signed-off commits with `git commit -s`:

```bash
git commit -s -m "fix: resolve chunk mesh memory leak"
```

If a commit is already created, amend it with `git commit --amend -s` before pushing. The DCO check validates the trailer on every PR commit.

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

Promotion PRs to `main`, pushes to `dev`/`main`, and `v*` tags run build and coverage workflows. Workflow success is not release authorization: complete the [release checklist](docs/release-checklist.md), including unresolved placeholder-asset redistribution rights, before publishing binaries or asset bundles.

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

// 3. Project modules by package name
const Vec3 = @import("engine-math").Vec3;
const log = @import("engine-core").log;
```

### Memory Management
- Functions allocating heap memory MUST accept `std.mem.Allocator`
- Use `defer`/`errdefer` for cleanup immediately after allocation
- Prefer `std.ArrayListUnmanaged` in structs that store the allocator elsewhere

### Error Handling
- Propagate errors with `try`; define subsystem-specific error sets
- Log errors: `log.log.err("msg: {}", .{err})`
- Use `//!` for module-level docs, `///` for public API docs

For full coding guidelines, see [AGENTS.md](AGENTS.md) (internal AI agent reference, contains detailed conventions).

---

## Testing

### Before Committing
```bash
# Format code
devenv shell zig fmt src/ modules/ build.zig

# Run all tests
devenv shell zig build test
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
1. Add entry to `BlockType` enum in `modules/world-core/src/block.zig`
2. Register properties (`isSolid`, `isTransparent`, `getLightEmission`, `getColor`)
3. Add textures to `modules/engine-graphics/src/texture_atlas.zig`
4. Standardize PBR textures: `./scripts/process_textures.sh`
5. Update `modules/world-meshing/src/chunk_mesh.zig` for special face/transparency logic

Keep the block catalog under the current `u8` capacity policy documented in [`docs/roadmap/block-id-capacity.md`](docs/roadmap/block-id-capacity.md). Open or update a follow-up issue before adding large block families that would push the catalog toward the documented threshold.

### Modifying Shaders
1. GLSL sources in `assets/shaders/` (Vulkan shaders in `vulkan/` subdirectory)
2. Run `devenv shell zig build shaders` to explicitly regenerate tracked SPIR-V after intentional edits
3. Ordinary builds and `devenv shell zig build test-shaders` validate freshness, sizes, and shadow ABI without modifying tracked artifacts
4. Update intentional size changes with `./scripts/update_spirv_baseline.sh` and review the generated diff
5. GPU layouts, descriptors, and bindings must agree between shader sources and RHI backends

### Adding Unit Tests
Add tests beside their owning module's code and include them from its file-relative `test_root.zig`; application wiring tests belong in `src/tests.zig`. Inspect `devenv shell zig build test-discovery` to verify the compiler discovers named tests. Use `std.testing` assertions:
- `expectEqual` - exact value comparison
- `expectApproxEqAbs` - floating point comparison
- `expect` - boolean/boolean expressions

Fuzz-named corpus tests in the normal suite are deterministic regressions, not coverage-guided campaigns. Nightly `-Dsanitize=c` uses C UBSan, not ASan or universal Zig memory-error instrumentation. See [CI test guardrails](docs/ci-test-guardrails.md).

---

## Project Structure

```
modules/
  engine-*          # Engine packages for core, graphics, RHI, math, input, UI, ECS, audio
  world-core/       # Blocks, chunks, coordinates, and light packing
  world-worldgen/   # Generator facade and registry
  worldgen-*/       # Shared generation code and individual generator implementations
  world-meshing/    # Chunk storage, chunk mesh generation, GPU block buffers
  world-runtime/    # World facade, streamer, renderer, mutation, GPU meshing runtime
  world-persistence/# Level data, region files, chunk serialization, save manager
  game-core/        # Session, player, inventory, settings, benchmarks
  game-ui/          # Screens, menus, settings UI
src/
  game/             # Application wiring and lifecycle orchestration
  c.zig             # Central C interop (@cImport)
  main.zig          # Entry point
  tests.zig         # Application test root; module tests have their own direct roots
libs/               # Vendored dependencies and the project-owned RmlUi bridge
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
