<div align="center">

```
 /$$$$$$$$ /$$$$$$  /$$$$$$   /$$$$$$  /$$$$$$$   /$$$$$$  /$$$$$$$$ /$$$$$$$$
|_____ $$ |_  $$_/ /$$__  $$ /$$__  $$| $$__  $$ /$$__  $$| $$_____/|__  $$__/
     /$$/   | $$  | $$  \__/| $$  \__/| $$  \ $$| $$  \ $$| $$         | $$   
    /$$/    | $$  | $$ /$$$$| $$      | $$$$$$$/| $$$$$$$$| $$$$$      | $$   
   /$$/     | $$  | $$|_  $$| $$      | $$__  $$| $$__  $$| $$__/      | $$   
  /$$/      | $$  | $$  \ $$| $$    $$| $$  \ $$| $$  | $$| $$         | $$   
 /$$$$$$$$ /$$$$$$|  $$$$$$/|  $$$$$$/| $$  | $$| $$  | $$| $$         | $$   
|________/|______/ \______/  \______/ |__/  |__/|__/  |__/|__/         |__/   
```

  <img src="assets/screenshots/distant-lod-landscape.png" alt="Historical ZigCraft terrain landscape screenshot" width="100%" />

  # ⚡ ZigCraft ⚡

  [![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig)](https://ziglang.org/)
  [![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
  [![Build Status](https://github.com/OpenStaticFish/ZigCraft/actions/workflows/build.yml/badge.svg)](https://github.com/OpenStaticFish/ZigCraft/actions)

  A high-performance Minecraft-style voxel engine built with **Zig**, **SDL3**, and a modern **Vulkan** graphics pipeline.
</div>

---

## 🚀 Overview

**ZigCraft** is a technical exploration of high-performance voxel rendering techniques, developed primarily as an AI-assisted solo project. It features a custom-built graphics abstraction layer, advanced terrain generation, and a multithreaded job system to handle massive world streaming with zero hitching.

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
- **Greedy Meshing**: Optimized vertex data generation for maximum throughput.

### 🛠️ Engine Core
- **Multithreaded Pipeline**: Dedicated worker pools for generation (4 threads) and meshing (3 threads).
- **Job Prioritization**: Proximity-based task scheduling ensures immediate loading of local chunks.
- **Comprehensive Testing**: Unit tests covering math, worldgen, and core engine modules.
- **Refined App Lifecycle**: Modular architecture with extracted systems for rendering, input, and world management.

### 📊 Performance

Optimized for high chunk render distances with greedy meshing, job-based multithreading, and a Vulkan RHI backend. Build with `-Doptimize=ReleaseFast` for best results.

## ⌨️ Controls

| Key | Action |
|-----|--------|
| **WASD** | Movement |
| **Space / Shift** | Jump / Crouch (Fly Up / Down) |
| **Left Ctrl** | Sprint |
| **Mouse** | Look |
| **Left Click / Right Click** | Mine Block / Place Block |
| **Tab** | Toggle Mouse Capture / Menu |
| **I** | Open Inventory |
| **1-9** | Select Hotbar Slot |
| **F / T** | Toggle Wireframe / Textures |
| **V** | Toggle VSync |
| **U / K** | Toggle Shadow Debug / Cycle Cascades |
| **M** | Toggle World Map |
| **N** | Freeze / Unfreeze Time |
| **F2** | Toggle FPS Counter |
| **F3** | Toggle Creative Mode |
| **F5** | Toggle Block Info |
| **Esc** | Menu / Pause |

> **Note**: Time of day can be set via the inventory screen (buttons for DAWN, NOON, DUSK, NIGHT).

## 🏗️ Build & Run

This project uses **devenv** (Nix-based) for a reproducible development environment.

### 🛠️ Development Setup

After cloning or creating a new worktree, run the setup script to enable git hooks:

```bash
./scripts/setup-hooks.sh
```

This configures a pre-push hook that runs:
- `zig fmt --check src/ modules/ build.zig` - formatting check
- `zig build test` - full test suite

To bypass in emergencies: `git push --no-verify`

### 🎮 Running the Game
- **Run**: `devenv shell zig build run`
- **Release build**: `devenv shell zig build run -Doptimize=ReleaseFast`

### Debug Build Flags

- **Smoke test**: `devenv shell zig build run -Dsmoke-test`
- **Headless / no present**: `devenv shell zig build run -Dskip-present`
- **Headless benchmark**: `devenv shell zig build benchmark -Dbenchmark-preset=low -Dbenchmark-duration=60 -Dbenchmark-output=benchmark-low.json`
- **Auto-open a world**: `devenv shell zig build run -Dauto-world=normal`
- **Open on monitor**: `devenv shell zig build run -Dmonitor-index=1`
- **Open on Hyprland monitor**: `devenv shell zig build run -Dmonitor-name=DP-2`
- **Force XWayland monitor placement**: `devenv shell zig build run -Dmonitor-index=1 -Dwindow-video-driver=x11`
- **Background window launch**: `devenv shell zig build run -Dmonitor-name=DP-2 -Dwindow-video-driver=x11 -Dwindow-no-focus`
- **Startup diagnostic**: `devenv shell zig build run -Dauto-world=normal -Dstartup-diagnostic-seconds=5 -Dskip-present`
- **Worldgen climate snapshot JSON**: `devenv shell zig build worldgen-climate-snapshot -- --seed 42 --origin-x -256 --origin-z -256 --width 128 --depth 128 --step 4 --output zig-out/climate-42.json`
- **Worldgen climate heatmap**: `devenv shell zig build worldgen-climate-snapshot -- --format ppm --field temperature --output zig-out/temperature-42.ppm`
- **Chunk-only debug mode**: `devenv shell zig build run -Dchunk-debug-mode -Dauto-world=normal`
- **Shadow/cave lighting capture**: `./scripts/capture_shadow_test.sh screenshots/shadow-test.png`

`-Dchunk-debug-mode` strips the overworld down to basic chunks for isolation work:
- water generation/rendering off by default
- caves off by default
- decorations/features off by default

Re-enable individual systems with `-Dchunk-debug-enable=` using a comma-separated list:
- `water`
- `watergen`
- `waterrender`
- `caves`
- `decorations`

Examples:

```bash
# Water plus cave generation
devenv shell zig build run -Dchunk-debug-mode -Dchunk-debug-enable=water,caves -Dauto-world=normal

# Headless startup comparison after 5 seconds
devenv shell zig build run -Dchunk-debug-mode -Dchunk-debug-enable=water,caves -Dauto-world=normal -Dstartup-diagnostic-seconds=5 -Dskip-present
```

The shadow/cave lighting capture launches a deterministic low-block test scene, applies a small shadow-focused graphics preset, waits 5 seconds after the target is ready, captures a PNG, and exits. It defaults to a `dug-cave` variant that matches a player-dug dirt/grass cave mouth. Use `ZIGCRAFT_SHADOW_TEST_VARIANT=bend ./scripts/capture_shadow_test.sh screenshots/shadow-bend.png` to check the older bend/deep-black regression. Override the wait with `ZIGCRAFT_SCREENSHOT_DELAY_SECONDS=8 ./scripts/capture_shadow_test.sh screenshots/shadow-test.png`. Screenshot paths are restricted to image extensions from `image/png`, `image/jpeg`, `image/gif`, and `image/webp`; the built-in encoder currently writes PNG.

### 🧪 Running Tests
- **All Tests**: `devenv shell zig build test`
- **Single Test**: `devenv shell zig build test -- --test-filter "Test Name"`
- **Single Test Alternative**: `devenv shell zig build test -Dtest-filter="Test Name"`
- **Test inventory**: `devenv shell zig build test-discovery` (runs direct roots and prints named tests)
- **Shader checks only**: `devenv shell zig build test-shaders` (does not rewrite tracked SPIR-V)

The fuzz-named corpus tests in the ordinary suite are deterministic regression tests, not an ongoing fuzz campaign. The nightly `-Dsanitize=c` mode enables C undefined-behavior sanitization, **not AddressSanitizer**. See [CI test guardrails](docs/ci-test-guardrails.md) for scope and limitations.

## 📂 Project Structure

- `modules/engine-*`: Core engine packages (RHI, graphics, math, UI, input, jobs, ECS, audio).
- `modules/world-core`: Blocks, chunks, coordinates, lighting, and shared world types.
- `modules/world-worldgen`: Generator facade and registry; `modules/worldgen-*` own shared generation code and individual terrain generators.
- `modules/world-meshing`: Chunk storage, mesh generation, GPU block buffers, and meshing helpers.
- `modules/world-runtime`: World facade, streaming, mutation, rendering, and GPU meshing runtime.
- `modules/world-persistence`: Level data, chunk serialization, region files, and save manager.
- `modules/game-core`: Session, player, inventory, settings, and benchmark logic.
- `modules/game-ui`: Screens, menus, and settings UI.
- `src/game/`: Application wiring and lifecycle orchestration; `src/main.zig` is the executable entry point.
- `assets/`: GLSL shaders and textures.
- `scripts/`: CI verification, benchmarks, asset processing, and reporting tools.
- `libs/`: Vendored dependencies (zig-math, zig-noise, stb) and the project-owned RmlUi C ABI bridge.


## 🛠️ Texture Pipeline

### Temporary Asset Notice

Some textures in `assets/textures/default/` are temporary development placeholders imported from external Minecraft-compatible resource packs, including Classic Faithful 64x Jappa, while the engine art pipeline is being built out. They are included only to make local development and visual iteration easier, and should be replaced with original or clearly licensed project assets before any public release or redistribution.

ZigCraft does not claim ownership of third-party placeholder textures. Keep attribution and licensing requirements with any external resource pack assets you use. The repository's code license does not establish redistribution rights for these placeholders; the [release checklist](docs/release-checklist.md) requires a separate asset/license review. This remains unresolved until supported by evidence.

The engine supports HD texture packs with full PBR maps. To standardize high-resolution source imagery (4k JPEGs, EXRs) into engine-ready 512px PNGs, use the provided helper script:

```bash
# Standardize an entire pack
./scripts/process_textures.sh assets/textures/pbr-test 512
```

The script automatically handles resizing and naming conventions for `_diff`, `_nor_gl`, `_rough`, and `_disp` maps.

## 🤝 Contributing

This is primarily a solo, AI-assisted project. Contributions are welcome but the scope and direction are tightly focused. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow.

### Quick Start for Contributors

```bash
# Clone and setup
git clone https://github.com/OpenStaticFish/ZigCraft.git
cd ZigCraft
./scripts/setup-hooks.sh

# Enter dev environment and run tests
devenv shell zig build test
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

### devenv Build Failures
Preserve the failing log and pinned `devenv.lock` first. Check tool versions and the selected profile before changing dependencies. `devenv update` is an intentional dependency upgrade, not a routine repair command. Cache deletion is not required for diagnosis; use `./scripts/codebase_report.sh` to report tracked source metrics separately from local cache/build footprint without cleaning anything.

### Vulkan Driver Issues
- **Linux**: Ensure `vulkan-loader` and GPU drivers are installed
- **NVIDIA**: Proprietary drivers recommended for best performance
- **Verify**: Run `vulkaninfo` to check Vulkan support

### Shader Validation Errors
Ordinary builds and `zig build test` validate tracked SPIR-V without rewriting it. After intentionally changing GLSL, regenerate the runtime artifacts explicitly and then validate:
```bash
devenv shell zig build shaders
devenv shell zig build test-shaders
```

If shader sizes intentionally change, update `docs/shaders/spirv-sizes.json` with `./scripts/update_spirv_baseline.sh` and review the baseline diff. Do not regenerate first when investigating stale-artifact failures: preserve the failing evidence.

### Performance Issues
- Try `zig build run -Doptimize=ReleaseFast` for optimized builds
- Reduce render distance in-game: Press `Esc` → Graphics → Render Distance
- Disable VSync if FPS is capped at 60

## 🌟 Community

|  |  |
|----------|----------|
| **Discussions** | [GitHub Discussions](https://github.com/OpenStaticFish/ZigCraft/discussions) |
| **Issues** | [GitHub Issues](https://github.com/OpenStaticFish/ZigCraft/issues) |
| **Security** | [Security Policy](SECURITY.md) |
| **License** | [MIT License](LICENSE) |

---

<div align="center">

**[⬆ Back to Top](#-zigcraft-)**

Built by [OpenStaticFish](https://github.com/OpenStaticFish)

</div>

## ⚖️ License

MIT License - see [LICENSE](LICENSE) for details.
