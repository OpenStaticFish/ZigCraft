# Zig Voxel Engine

A Minecraft-style voxel engine built with [Zig](https://ziglang.org/) (0.14/master), [SDL3](https://wiki.libsdl.org/SDL3/FrontPage), and [OpenGL 3.3](https://www.opengl.org/).

## Features

### Rendering
- **Modern OpenGL 3.3 Core** - Shaders, VAOs, VBOs
- **Floating Origin** - Camera-relative rendering prevents precision loss at large coordinates
- **Reverse-Z Depth Buffer** - Better depth precision at far distances
- **Greedy Meshing** - Optimized chunk mesh generation
- **Frustum Culling** - Camera-relative chunk culling
- **Texture Atlas** - 16x16 tile atlas for block textures
- **Flat Shading** - Per-face normals for clean voxel look

### World Generation
- **Multi-noise Biome System** - 11 biome types based on temperature/humidity
- **Domain Warping** - Natural-looking terrain variation
- **Layered Noise** - Continental, erosion, and detail noise layers
- **Cave Generation** - 3D noise-based cave systems
- **Water Bodies** - Lakes and oceans at sea level

### Engine
- **Multithreaded Chunk Loading** - 4 generation + 3 meshing worker threads
- **Job Prioritization** - Chunks closest to player load first
- **Dynamic Re-prioritization** - Jobs update when player moves
- **Subchunk Rendering** - 16 vertical subchunks per chunk column
- **Solid/Fluid Render Passes** - Proper water transparency

### Controls
| Key | Action |
|-----|--------|
| WASD | Move |
| Space | Fly up |
| Shift | Fly down |
| Mouse | Look around |
| Tab | Toggle mouse capture |
| F | Toggle wireframe |
| T | Toggle textures |
| V | Toggle VSync |
| Esc | Pause/Menu |

## Prerequisites

- [Nix](https://nixos.org/download.html) with `flakes` enabled

## Build & Run

### Development
```bash
nix develop
zig build run
```

### Production Build
```bash
nix build
./result/bin/zig-triangle
```

## Project Structure

```
src/
  engine/
    core/       # Job system, logging, time
    graphics/   # Camera, renderer, shaders, textures
    input/      # Input handling
    math/       # Vec3, Mat4, AABB, Frustum
    ui/         # UI system for menus
  world/
    worldgen/   # Terrain generator, noise functions
    block.zig   # Block types and properties
    chunk.zig   # Chunk data structure
    chunk_mesh.zig  # Greedy meshing
    world.zig   # World manager, chunk loading
  main.zig      # Entry point, game loop
  c.zig         # C bindings (SDL3, GLEW, OpenGL)
```

## Technical Details

### Render Stability
The engine implements industry-standard techniques to prevent terrain shimmering at high altitude and large render distances:

1. **Floating Origin** - Chunk vertices use local coordinates (0-16), world offset applied via model matrix relative to camera position
2. **Reverse-Z Depth** - Near plane maps to z=1, far plane to z=0, with `glDepthFunc(GL_GEQUAL)`
3. **Near Plane** - Set to 0.5 (not 0.1) for better depth precision
4. **Flat Shading** - `flat` interpolation qualifier on normals prevents lighting shimmer

### Chunk System
- Chunk size: 16x256x16 blocks
- 16 subchunks per column (16x16x16 each)
- Render distance configurable in settings
- Chunks unload when player moves away

## License

MIT
