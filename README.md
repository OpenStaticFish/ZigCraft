# Zig Voxel Engine

A Minecraft-style voxel engine built with [Zig](https://ziglang.org/) (0.14/master), [SDL3](https://wiki.libsdl.org/SDL3/FrontPage), and supporting both **OpenGL 3.3** and **Vulkan**.

## Features

### Rendering
- **Render Hardware Interface (RHI)** - Abstraction layer supporting multiple backends
- **OpenGL Backend** - Feature-complete legacy backend (OpenGL 3.3/4.6)
- **Vulkan Backend** - High-performance backend (Work In Progress)
- **Floating Origin** - Camera-relative rendering prevents precision loss at large coordinates
- **Reverse-Z Depth Buffer** - Better depth precision at far distances
- **Greedy Meshing** - Optimized chunk mesh generation
- **Cascaded Shadow Maps (CSM)** - High-quality shadows with 3 cascades
- **Atmospheric Scattering** - Physically-based day/night cycle with fog and sun/moon rendering
- **Volumetric Clouds** - Procedural cloud layer with shadows

### World Generation
- **Multi-noise Biome System** - 11 biome types based on temperature/humidity
- **Domain Warping** - Natural-looking terrain variation
- **Layered Noise** - Continental, erosion, and detail noise layers
- **Cave Generation** - 3D noise-based cave systems
- **Water Bodies** - Lakes and oceans at sea level

### Engine
- **Multithreaded Chunk Loading** - 4 generation + 3 meshing worker threads
- **Job Prioritization** - Chunks closest to player load first
- **Async Asset Loading** - Shaders loaded from external files
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
| C | Toggle Clouds |
| U | Toggle Shadow Debug |
| M | Toggle World Map |
| 1-4 | Set Time (Midnight/Sunrise/Noon/Sunset) |
| N | Freeze/Unfreeze Time |
| Esc | Pause/Menu |

## Prerequisites

- [Nix](https://nixos.org/download.html) with `flakes` enabled

## Build & Run

### Development (OpenGL Default)
```bash
nix develop
zig build run
```

### Run with Vulkan Backend
```bash
nix develop
zig build run -- --backend vulkan
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
    graphics/   # RHI, Camera, renderer, shaders, textures
      rhi.zig          # Render Hardware Interface definition
      rhi_opengl.zig   # OpenGL backend implementation
      rhi_vulkan.zig   # Vulkan backend implementation
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
  c.zig         # C bindings (SDL3, GLEW, OpenGL, Vulkan)
assets/
  shaders/      # GLSL shaders (terrain.vert, terrain.frag)
```

## Technical Details

### Render Architecture (RHI)
The engine uses a **Render Hardware Interface (RHI)** to decouple game logic from the graphics API:
1. **Frontend**: The `World` and `ChunkMesh` systems generate backend-agnostic vertex data.
2. **Transfer Queue**: Meshing threads request uploads via `RHI.createBuffer` and `RHI.uploadBuffer`, allowing the backend to manage bandwidth and transfer queues (e.g., using a dedicated transfer thread in Vulkan).
3. **Backend**: `rhi_opengl.zig` or `rhi_vulkan.zig` consumes these commands to render the frame.

### Render Stability
The engine implements industry-standard techniques to prevent terrain shimmering:
1. **Floating Origin** - Chunk vertices use local coordinates (0-16), world offset applied via model matrix.
2. **Reverse-Z Depth** - Near plane maps to z=1, far plane to z=0, with `glDepthFunc(GL_GEQUAL)`.
3. **Flat Shading** - `flat` interpolation qualifier on normals prevents lighting shimmer.

## License

MIT
