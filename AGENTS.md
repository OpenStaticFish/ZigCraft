# ZigCraft Agent Guidelines

This document provides essential instructions for agentic coding agents operating in this Zig voxel engine repository.

## Development Environment & Commands

The project uses Nix for dependency management. **All build and test commands MUST be wrapped in `nix develop --command`** to ensure dependencies (SDL3, Vulkan, glslang) are available.

### Build & Run
```bash
# Build
nix develop --command zig build

# Run
nix develop --command zig build run

# Release build
nix develop --command zig build -Doptimize=ReleaseFast

# Clean build artifacts
rm -rf zig-out/ .zig-cache/
```

### Testing
```bash
# Run all unit tests (also validates Vulkan shaders)
nix develop --command zig build test

# Run a single test by name filter
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

## Code Style & Conventions

### Naming Conventions
- **Types/Structs/Enums**: `PascalCase` (`RenderSystem`, `BufferHandle`, `BlockType`)
- **Functions/Variables**: `snake_case` (`init_renderer`, `mesh_queue`, `chunk_x`)
- **Constants/Globals**: `SCREAMING_SNAKE_CASE` (`MAX_CHUNKS`, `CHUNK_SIZE_X`)
- **Files**: `snake_case.zig`

### Import Order & Style
```zig
// 1. Standard library
const std = @import("std");
const Allocator = std.mem.Allocator;

// 2. C imports (always via c.zig)
const c = @import("../c.zig").c;

// 3. Local modules (relative paths within subsystem)
const Vec3 = @import("../math/vec3.zig").Vec3;
const log = @import("../engine/core/log.zig");
```

### Memory Management
- Functions allocating heap memory MUST accept `std.mem.Allocator`
- Use `defer`/`errdefer` for cleanup immediately after allocation
- Prefer `std.ArrayListUnmanaged` in structs that store the allocator elsewhere
- Use `extern struct` for GPU-shared data layouts (e.g., `Vertex`)
- Use `chunk.pin()`/`chunk.unpin()` when passing chunks to background jobs

### Error Handling
- Propagate errors with `try`; define subsystem-specific error sets (`RhiError`)
- Log errors via `src/engine/core/log.zig`: `log.log.err("msg: {}", .{err})`
- Use `//!` for module-level docs, `///` for public API documentation

### Type Patterns
- GPU resource handles are opaque `u32` (`BufferHandle`, `TextureHandle`, `ShaderHandle`)
- Packed data uses `packed struct` (e.g., `PackedLight` for sky/block light)
- Chunk coordinates: `i32`; local block coordinates: `u32` (0-15 for X/Z, 0-255 for Y)

---

## Coordinate Systems

- **World**: Global (x, y, z) in blocks/meters
- **Chunk**: `(chunk_x, chunk_z)` via `@divFloor(world, 16)`
- **Local**: (x, y, z) within a chunk
- Use `worldToChunk()` and `worldToLocal()` from `src/world/chunk.zig`

---

## Architectural Patterns

### Render Hardware Interface (RHI)
- All rendering uses the `RHI` interface in `src/engine/graphics/rhi.zig`
- Vulkan is the primary and only supported backend implementation in `rhi_vulkan.zig`
- Extend functionality by updating `RHI.VTable` and the backend implementation

### Job System & Concurrency
- Use `JobSystem` for heavy tasks (world gen, meshing, lighting)
- **Never call RHI or windowing from worker threads**
- Synchronize shared state with `std.Thread.Mutex`

### UI System
- Immediate-mode API: `UISystem.drawRect()`, `UISystem.drawText()`
- Widgets in `src/engine/ui/widgets.zig`

---

## Common Implementation Tasks

### Adding a New Block Type
1. Add entry to `BlockType` enum in `src/world/block.zig`
2. Register properties (`isSolid`, `isTransparent`, `getLightEmission`, `getColor`)
3. Add textures to `src/engine/graphics/texture_atlas.zig`
4. Update `src/world/chunk_mesh.zig` for special face/transparency logic

### Modifying Shaders
1. GLSL sources in `assets/shaders/` (Vulkan shaders in `vulkan/` subdirectory)
2. Vulkan SPIR-V validated during `zig build test` via `glslangValidator`
3. Uniform names must match exactly between shader source and RHI backends

### Adding Unit Tests
- Add tests to `src/tests.zig`
- Use `std.testing` assertions: `expectEqual`, `expectApproxEqAbs`, `expect`
- Test naming: descriptive, e.g., `test "Vec3 normalize"`

---

## Agent Best Practices

### Verification Checklist
- [ ] Run `zig build test` to verify unit tests and shader validation
- [ ] Check `zig build -Doptimize=ReleaseFast` for performance-critical changes
- [ ] Run `zig fmt src/` before committing

### Code Quality
- Write self-documenting code; use comments only to explain *why*
- Follow Zig idioms: `init`/`deinit` pairs, explicit allocators, error unions
- Add test cases for new utility, math, or worldgen logic
- For graphics changes, run the app and verify visually

### Performance Considerations
- Chunk mesh building runs on worker threads; avoid allocations in hot paths
- Use packed structs for large arrays (e.g., light data)
- Profile before optimizing; use `ReleaseFast` for benchmarks
