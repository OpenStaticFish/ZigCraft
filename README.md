<div align="center">
  <img src="assets/screenshots/hero.png" alt="ZigCraft Hero" width="100%" />

  # ⚡ ZigCraft ⚡

  [![Zig](https://img.shields.io/badge/Zig-0.14.0--dev-orange.svg?logo=zig)](https://ziglang.org/)
  [![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
  [![Build Status](https://github.com/MichaelFisher1997/ZigCraft/actions/workflows/build.yml/badge.svg)](https://github.com/MichaelFisher1997/ZigCraft/actions)
  [![Tests](https://img.shields.io/badge/Tests-58%20Passed-success.svg)](src/tests.zig)

  A high-performance Minecraft-style voxel engine built with **Zig**, **SDL3**, and a modern **Vulkan** graphics pipeline.
</div>

---

## 🚀 Overview

**ZigCraft** is a technical exploration of high-performance voxel rendering techniques. It features a custom-built graphics abstraction layer, advanced terrain generation, and a multithreaded job system to handle massive world streaming with zero hitching.

## ✨ Key Features

### 🎨 Rendering Architecture
- **Vulkan RHI**: Modern, explicit graphics API for high performance and low CPU overhead.
- **Cascaded Shadow Maps (CSM)**: 3 cascades for high-fidelity shadows across long distances.
- **Atmospheric Scattering**: Physically-based day/night cycle with dynamic fog and sky rendering.
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
- `libs/`: (Planned) Extracted standalone math and noise libraries.

## ⚖️ License

MIT License - see [LICENSE](LICENSE) for details.
