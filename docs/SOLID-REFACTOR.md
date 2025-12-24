# SOLID Refactoring Plan

This document tracks the refactoring effort to improve SOLID compliance in the Zig Voxel Engine.

## Summary

| Principle | Before | Target |
|-----------|--------|--------|
| Single Responsibility | C+ | B+ |
| Open/Closed | B+ | A- |
| Liskov Substitution | B+ | A |
| Interface Segregation | B | B+ |
| Dependency Inversion | C | B+ |

---

## High Priority

### 1. Extract UI from main.zig
**Problem**: `main.zig` contains ~300 lines of UI rendering code (fonts, buttons, text input)

**Files to create**:
- [x] `src/engine/ui/font.zig` - Bitmap font rendering (drawText, drawGlyph, etc.)
- [x] `src/engine/ui/widgets.zig` - Button, text input helpers
- [ ] `src/game/menu.zig` - Menu screen logic

**Status**: Partial (Font/Widgets extracted)

---

### 2. Remove Renderer struct
**Problem**: `Renderer` duplicates RHI functionality with direct OpenGL calls

**Changes**:
- [x] Migrate `Renderer.beginFrame()` callers to use RHI
- [x] Migrate `Renderer.setViewport()` to RHI (add method if needed)
- [x] Migrate `Renderer.setClearColor()` to RHI
- [x] Remove `src/engine/graphics/renderer.zig` (Struct removed, kept helpers)
- [x] Update `main.zig` to remove Renderer usage

**Status**: Completed

---

### 3. Fix World's dual shader dependency
**Problem**: `World.render()` accepts `?*const Shader` which couples it to OpenGL

**Current signature**:
```zig
pub fn render(self: *World, shader: ?*const Shader, view_proj: Mat4, camera_pos: Vec3) void
```

**Target signature**:
```zig
pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3) void
```

**Changes**:
- [x] Remove `shader` parameter from `World.render()`
- [x] Remove `shader` parameter from `World.renderShadowPass()`
- [x] Update all call sites in `main.zig`
- [x] Ensure RHI handles all uniform updates (Implemented setModelMatrix/updateGlobalUniforms in rhi_opengl.zig)

**Status**: Completed

---

### 4. Move embedded shaders to files
**Problem**: ~230 lines of GLSL embedded in `main.zig`

**Changes**:
- [ ] Verify `assets/shaders/terrain.vert` and `terrain.frag` exist and are up-to-date
- [ ] Remove embedded `vertex_shader_src` and `fragment_shader_src` from main.zig
- [ ] Ensure `Shader.initFromFile()` is used consistently

**Status**: Not Started

---

## Medium Priority

### 5. Split World struct
**Problem**: World handles chunk storage, job dispatch, and rendering

**Target structure**:
```
World (facade)
├── ChunkManager - chunk loading/unloading/storage
├── ChunkJobDispatcher - async generation/meshing
└── (rendering stays in World for now, uses RHI)
```

**Status**: Not Started

---

### 6. Implement or remove interfaces.zig
**Problem**: `IUpdatable`, `IRenderable`, `IChunkProvider`, `IMeshBuilder` are defined but never used

**Decision**: Remove unused interfaces, keep as documentation for future extension

**Status**: Not Started

---

### 7. Separate Atmosphere concerns
**Problem**: `Atmosphere` handles time simulation AND sky rendering

**Target**:
- `DayNightCycle` - time of day, sun/moon positions, light intensities
- `SkyRenderer` - sky mesh, shaders, rendering (or use RHI.drawSky)

**Status**: Not Started

---

## Low Priority

### 8. Consider splitting RHI.VTable
**Problem**: 27 methods in single interface

**Potential split**:
- `IRHICore` - lifecycle, buffers, textures, frame management
- `IRHIShadows` - shadow pass methods (optional capability)
- `IRHIUI` - UI quad rendering (optional capability)

**Decision**: Defer - current design works, split only if backends diverge significantly

**Status**: Deferred

---

### 9. Unify Atmosphere rendering
**Problem**: OpenGL path uses direct GL calls, Vulkan uses RHI

**Changes**:
- [ ] Remove `Atmosphere.renderSky()` OpenGL implementation
- [ ] Ensure all paths use `rhi.drawSky()`
- [ ] Remove sky VAO/VBO from Atmosphere

**Status**: Not Started

---

## Progress Log

| Date | Change | Files Modified |
|------|--------|----------------|
| 2024-12-23 | Created refactoring plan | SOLID-REFACTOR.md |
| 2024-12-23 | Extract font rendering to font.zig | src/engine/ui/font.zig, main.zig |

