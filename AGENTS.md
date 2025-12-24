# ZigCraft Agent Guidelines

This document provides essential instructions for agentic coding agents operating in the ZigCraft repository.

## Development Environment & Commands

The project uses Nix for dependency management and the Zig build system.

### Build & Run
- **Build**: `nix develop --command zig build`
- **Run (Default/OpenGL)**: `nix develop --command zig build run`
- **Run (Vulkan)**: `nix develop --command zig build run -- --backend vulkan`
- **Release Build**: `nix develop --command zig build -Doptimize=ReleaseFast`
- **Clean**: `rm -rf zig-out/ .zig-cache/`
- **Note on CI**: In GitHub Actions, the environment is pre-configured with Nix. You can run `zig build`, `nix build`, etc., directly without the `nix develop --command` prefix.

### Testing
- **Run All Tests**: `nix develop --command zig build test`
- **Single Test**: `nix develop --command zig build test -- --test-filter "Test Name"`
  - *Note*: Tests are primarily defined in `src/tests.zig` and cover math, worldgen, and engine core.

### Linting & Formatting
- **Format Code**: `nix develop --command zig fmt src/`
  - **Requirement**: Always run `zig fmt` on modified files before committing.
- **Check Interpretation**: `nix develop --command zig build check` (used for fast type-checking during development)

---

## Project Structure

- **src/engine/**: Core engine systems.
  - **core/**: Interfaces, job system, logging, window management.
  - **graphics/**: RHI implementations (Vulkan/OpenGL), camera, shaders, textures.
  - **input/**: Input handling.
  - **math/**: 3D math (vectors, matrices, frustums).
  - **ui/**: Immediate-mode UI system and widgets.
- **src/world/**: Voxel world logic.
  - **worldgen/**: Biomes, noise, cave generation, region management.
- **src/game/**: Main application logic, state management, and menus.
- **src/c.zig**: Centralized C header imports.

---

## Code Style & Conventions

### Naming Conventions
- **Types/Structs/Enums**: `PascalCase` (e.g., `RenderSystem`, `BufferHandle`).
- **Functions/Variables**: `snake_case` (e.g., `init_renderer`, `mesh_queue`).
- **Constants/Global Variables**: `SCREAMING_SNAKE_CASE` (e.g., `MAX_CHUNKS`, `CHUNK_SIZE`).
- **Files**: `snake_case.zig`.

### Imports & Dependencies
- **Order**: `std` first, then C imports/external libs, then local modules.
- **Relative Paths**: Always use relative paths for local modules within the same subsystem.
- **C Imports**: Use `src/c.zig` which centralizes external library headers (SDL3, GLEW, OpenGL, Vulkan).
- **Example**:
  ```zig
  const std = @import("std");
  const c = @import("../c.zig").c;
  const rhi = @import("rhi.zig");
  ```

### Error Handling
- **Propagation**: Use Zig's `try` for most error propagation.
- **Explicit Errors**: Define explicit error sets for subsystems (e.g., `RhiError` in `rhi.zig`).
- **Avoid Unreachable**: Only use `catch unreachable` if the condition is truly impossible or in test code.
- **Context**: When catching errors for logging, use `log.log.err("message: {}", .{err})`.

### Memory Management
- **Explicit Allocators**: Functions that perform heap allocation MUST accept an `Allocator` as an argument.
- **Lifetime Management**: Use `defer` or `errdefer` immediately after an allocation to ensure cleanup.
- **Ownership**: Document which struct owns an allocated resource. Structs should typically have a `deinit()` method if they own resources.
- **ArrayLists**: Use `std.ArrayList` for dynamic arrays, and prefer `ArrayListUnmanaged` if the allocator is stored externally.

---

## Architectural Patterns

### Render Hardware Interface (RHI)
- **Abstraction**: All rendering logic MUST be backend-agnostic and use the `RHI` interface defined in `src/engine/graphics/rhi.zig`.
- **Implementation**: New rendering features must be implemented in both `rhi_opengl.zig` and `rhi_vulkan.zig`.
- **Resources**: GPU resources (buffers, textures, shaders) are handled via opaque handles (e.g., `BufferHandle`).
- **VTable Extension**: When adding new functionality to the RHI, update the `VTable` struct in `rhi.zig` and implement the corresponding functions in all backends.

### Job System
- **Concurrency**: Use the `JobSystem` (`src/engine/core/job_system.zig`) for any computation taking more than a few milliseconds.
- **Current Jobs**: World generation, chunk meshing, and map updates.
- **Safety**: Do not access `RHI` or windowing functions from worker threads. Synchronize access to shared state using `std.Thread.Mutex`.

### UI System
- **Immediate Mode**: The UI system (`src/engine/ui/ui_system.zig`) uses an immediate-mode style API for drawing primitives and widgets.
- **Layout**: Use `Rect` for positioning and `Color` for styling.
- **Widgets**: Reusable components like buttons and text inputs are located in `src/engine/ui/widgets.zig`.

### World Generation
- **Noise**: Seed-based noise generation is handled in `src/world/worldgen/noise.zig`.
- **Biomes**: Biome-specific logic and parameters are in `src/world/worldgen/biome.zig`.
- **Isolation**: World generation must remain decoupled from rendering. It produces `Block` data which is then consumed by the meshing system.
- **Performance**: Use `@as(f32, @floatFromInt(value))` and other explicit casts for clarity in math-heavy code.

---

## Common Implementation Tasks

### Adding a New Block Type
1. Define the block in `src/world/block.zig` (add to `BlockType` enum).
2. Register block properties (solid, transparent, light level).
3. Update `src/engine/graphics/texture_atlas.zig` if new textures are needed.
4. Ensure `src/world/chunk_mesh.zig` correctly handles the new block's faces.

### Adding a UI Widget
1. Create a new function in `src/engine/ui/widgets.zig`.
2. Use `UISystem` methods (`drawRect`, `drawText`) for rendering.
3. Handle mouse input using `Input` state passed from the menu context.
4. Integrate the widget into `src/game/menus.zig`.

---

## Agent-Specific Best Practices

### Proactiveness
- **Cross-Backend Compatibility**: When modifying the renderer, verify that changes do not break either OpenGL or Vulkan backends.
- **Build Verification**: If a change affects `build.zig` or linked libraries, verify the build succeeds for all optimization modes (`Debug`, `ReleaseFast`, `ReleaseSafe`).

### Verification & Testing
- **Self-Verification**: After any logic change, run relevant tests using the `--test-filter`.
- **Visual Check**: If UI or rendering was touched, start the application and verify the main menu and a test world load correctly.
- **Logging**: Use the engine's logging system (`src/engine/core/log.zig`) for debug information instead of `std.debug.print` in production code.

### Documentation
- **Doc Comments**: Use `///` for public struct fields and functions. These are used by Zig's autogenerated documentation.
- **Module Responsibility**: Use `//!` at the top of files to describe the file's purpose and its role in the engine.
- **Clarity**: Favor clear, self-documenting code over complex comments.
