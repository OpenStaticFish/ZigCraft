<div align="center">

```
 ________  __    _______   ______   ______    ______   ________  ________ 
|        \|  \  /       \ /      \ /      \  /      \ |        \|        \
 \$$$$$$$$ \$$ |  $$$$$$$|  $$$$$$|  $$$$$$\|  $$$$$$\| $$$$$$$$ \$$$$$$$$
    /  $$ |  \ | $$  | $$| $$   $$| $$   \$$| $$__| $$| $$__       | $$   
   /  $$  | $$ | $$  | $$| $$     | $$      | $$    $$| $$  \      | $$   
  /  $$   | $$ | $$  | $$| $$   __| $$   __ | $$$$$$$$| $$$$$      | $$   
 /  $$___ | $$ | $$__/ $$| $$__/  | $$__/  \| $$  | $$| $$         | $$   
|  $$    \| $$ | $$    $$ \$$    $$\$$    $$| $$  | $$| $$         | $$   
 \$$$$$$$$ \$$  \$$$$$$$   \$$$$$$  \$$$$$$  \$$   \$$ \$$          \$$   
```

  <img src="https://github.com/OpenStaticFish/ZigCraft/raw/main/assets/screenshots/hero.png" alt="ZigCraft Hero" width="100%" />

  # ⚡ ZigCraft ⚡

  [![Zig](https://img.shields.io/badge/Zig-0.14.0--dev-orange.svg?logo=zig)](https://ziglang.org/)
  [![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
  [![Build Status](https://github.com/MichaelFisher1997/ZigCraft/actions/workflows/build.yml/badge.svg)](https://github.com/MichaelFisher1997/ZigCraft/actions)
  [![Tests](https://img.shields.io/badge/Tests-58%20Passed-success.svg)](src/tests.zig)

  A high-performance Minecraft-style voxel engine built with **Zig**, **SDL3**, and a modern **Vulkan** graphics pipeline.
</div>

---

## 💻 System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| **OS** | Linux (NixOS), Windows (WSL2) | Linux (NixOS) |
| **GPU** | Vulkan 1.2, 4GB VRAM | Vulkan 1.3, 8GB+ VRAM |
| **RAM** | 8 GB | 16 GB |
| **Storage** | 2 GB | 4 GB SSD |
| **Build Tools** | Nix package manager | Nix (latest) |

> **Note**: All builds require Nix for reproducible dependency management (SDL3, Vulkan, glslang).

---

## 🚀 Overview

**ZigCraft** is a technical exploration of high-performance voxel rendering techniques. It features a custom-built graphics abstraction layer, advanced terrain generation, and a multithreaded job system to handle massive world streaming with zero hitching.

## ✨ Key Features

### 🎨 Rendering Architecture
- **Vulkan RHI**: Modern, explicit graphics API with persistent UBO mapping for high performance.
- **PBR Rendering**: Physically Based Rendering with Cook-Torrance BRDF for realistic materials.
- **Cascaded Shadow Maps (CSM)**: 3 cascades with configurable PCF sampling (4-16 samples).
- **Atmospheric Scattering**: Physically-based day/night cycle with dynamic fog and sky rendering.
- **Advanced Graphics Menu**: Real-time control over shadow quality, PBR, resolution scaling, and MSAA.
- **Floating Origin & Reverse-Z**: Industry-standard techniques to eliminate precision jitter and Z-fighting at scale.
- **Greedy Meshing**: Optimized chunk generation reducing draw call overhead and triangle counts.

### 🌍 World Generation
- **Biomes & Climate**: Multi-noise system based on temperature and humidity (11+ biomes).
- **Infinite Terrain**: Seed-based, deterministic generation with domain warping and 3D caves.
- **Volumetric Clouds**: Procedural, shadowed cloud layers that integrate with the atmosphere.
- **Level of Detail (LOD)**: Hierarchical LOD system enabling 100+ chunk render distances using simplified terrain meshes and specialized rendering.
- **Greedy Meshing**: Optimized vertex data generation for maximum throughput.

### 🛠️ Engine Core
- **Multithreaded Pipeline**: Dedicated worker pools for generation (4 threads) and meshing (3 threads).
- **Job Prioritization**: Proximity-based task scheduling ensures immediate loading of local chunks.
- **Comprehensive Testing**: 58+ unit tests covering math, worldgen, and core engine modules.
- **Refined App Lifecycle**: Modular architecture with extracted systems for rendering, input, and world management.

### 📊 Performance Benchmarks
| Render Distance | FPS (ReleaseFast) | GPU Used |
|-----------------|-------------------|----------|
| 32 chunks | 120+ | RTX 3060 |
| 64 chunks | 90+ | RTX 3060 |
| 128 chunks | 60+ | RTX 3060 |

*Benchmarks measured on RTX 3060 @ 1080p with HIGH quality preset*

## 🖼️ Screenshots

| PBR Materials | Cascaded Shadows | Biomes |
|---------------|------------------|---------|
| ![PBR](https://github.com/OpenStaticFish/ZigCraft/raw/main/assets/screenshots/hero.png) | ![Shadows](https://github.com/OpenStaticFish/ZigCraft/raw/main/assets/screenshots/hero.png) | ![Biomes](https://github.com/OpenStaticFish/ZigCraft/raw/main/assets/screenshots/hero.png) |

*More screenshots coming soon!*

## ⌨️ Controls

| Key | Action |
|-----|--------|
| **WASD** | Movement |
| **Space / Shift** | Fly Up / Down |
| **Mouse** | Look |
| **Tab** | Toggle Mouse Capture |
| **F / T** | Toggle Wireframe / Textures |
| **V / C** | Toggle VSync / Clouds |
| **U / M** | Toggle Shadow Debug / World Map |
| **1-4** | Set Time (Midnight → Sunset) |
| **N** | Freeze / Unfreeze Time |
| **Esc** | Menu |

## 🏗️ Build & Run

This project uses **Nix** for a reproducible development environment.

### 🛠️ Development Setup

After cloning or creating a new worktree, run the setup script to enable git hooks:

```bash
./scripts/setup-hooks.sh
```

This configures a pre-push hook that runs:
- `zig fmt --check src/` - formatting check
- `zig build test` - full test suite

To bypass in emergencies: `git push --no-verify`

### 🎮 Running the Game
- **Run**: `nix develop --command zig build run`
- **Release build**: `nix develop --command zig build run -Doptimize=ReleaseFast`

### 🧪 Running Tests
- **All Tests**: `nix develop --command zig build test`
- **Single Test**: `nix develop --command zig build test -- --test-filter "Test Name"`

## 📂 Project Structure

- `src/engine/`: Core engine components (RHI, Math, UI, Input, Jobs).
- `src/world/`: Voxel-specific logic (Greedy Meshing, World Manager, Chunks).
- `src/world/worldgen/`: Procedural terrain, noise, and biome systems.
- `assets/`: GLSL shaders and textures.
- `scripts/`: Helper scripts for asset processing.
- `libs/`: (Planned) Extracted standalone math and noise libraries.

## 🗺️ Roadmap

- [ ] **Data-driven block registry** - Decouple block behavior from `BlockType` enum
- [ ] **Segregated render context interface** - Split fat `IRenderContext` into focused traits
- [ ] **RHI subsystem decoupling** - Break monolithic RHI into `ResourceManager`, `RenderCommandQueue`, etc.
- [ ] **Dynamic texture atlas loading** - Support custom texture packs without code changes
- [ ] **VRAM optimization** - Texture streaming and compression
- [ ] **Modding API** - Expose hooks for gameplay mods

See [SOLID_ISSUES.md](SOLID_ISSUES.md) for detailed architectural improvements planned.

## 🛠️ Texture Pipeline

The engine supports HD texture packs with full PBR maps. To standardize high-resolution source imagery (4k JPEGs, EXRs) into engine-ready 512px PNGs, use the provided helper script:

```bash
# Standardize an entire pack
./scripts/process_textures.sh assets/textures/pbr-test 512
```

The script automatically handles resizing and naming conventions for `_diff`, `_nor_gl`, `_rough`, and `_disp` maps.

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow.

### Quick Start for Contributors

```bash
# Clone and setup
git clone https://github.com/OpenStaticFish/ZigCraft.git
cd ZigCraft
./scripts/setup-hooks.sh

# Enter dev environment and run tests
nix develop --command zig build test
```

### Branch Workflow

```
main (production)
  └─ dev (staging)
      ├─ feature/*    # New features
      ├─ bug/*        # Non-critical fixes
      ├─ hotfix/*     # Critical fixes
      └─ ci/*         # CI/workflow changes
```

All PRs target the `dev` branch. Use our PR templates (`feature.md`, `bug.md`, `hotfix.md`, `ci.md`) for best practices.

## 🔧 Troubleshooting

### Nix Build Failures
```bash
# Clean build artifacts
rm -rf zig-out/ .zig-cache/

# Update Nix channels (if using older Nix)
nix-channel --update
```

### Vulkan Driver Issues
- **Linux**: Ensure `vulkan-loader` and GPU drivers are installed
- **NVIDIA**: Proprietary drivers recommended for best performance
- **Verify**: Run `vulkaninfo` to check Vulkan support

### Shader Validation Errors
Shaders are validated during `zig build test`. If glslang fails:
```bash
# Install glslang via Nix
nix develop  # glslang is included in the dev shell
```

### Performance Issues
- Try `zig build run -Doptimize=ReleaseFast` for optimized builds
- Reduce render distance in-game: Press `Esc` → Graphics → Render Distance
- Disable VSync if FPS is capped at 60

## 🌟 Community

|  |  |
|----------|----------|
| **Discussions** | [GitHub Discussions](https://github.com/OpenStaticFish/ZigCraft/discussions) |
| **Issues** | [GitHub Issues](https://github.com/OpenStaticFish/ZigCraft/issues) |
| **License** | [MIT License](LICENSE) |

---

<div align="center">

**[⬆ Back to Top](#-zigcraft-)**

Built with ❤️ by the OpenStaticFish community

</div>

## ⚖️ License

MIT License - see [LICENSE](LICENSE) for details.
