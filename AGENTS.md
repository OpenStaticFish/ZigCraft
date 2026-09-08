# ZigCraft Agent Guide

## Toolchain and commands

- Use Zig 0.16.0 through devenv. Wrap every Zig build/test/format command in `devenv shell`; CI uses the narrower `--profile unit` and `--profile graphics` profiles.
- Build/run:
  ```bash
  devenv shell zig build
  devenv shell zig build run
  devenv shell zig build -Doptimize=ReleaseFast
  ```
- Format source, modules, and the build definition:
  ```bash
  devenv shell zig fmt src/ modules/ build.zig
  devenv shell zig fmt --check src/ modules/ build.zig
  ```
- `zig build test` is the broad suite: direct application/module test roots, deterministic fuzz corpus regressions, shader freshness/size checks, and shadow ABI checks. It is not a coverage-guided fuzz campaign. `zig build test-discovery` runs roots and prints named-test inventory; empty discovery fails.
  ```bash
  devenv shell zig build test
  devenv shell zig build test -Dtest-filter="name"
  # Equivalent runtime-filter form:
  devenv shell zig build test -- --test-filter "name"
  ```
- Graphics/runtime verification is separate:
  ```bash
  devenv shell zig build test-integration -Dskip-present=true
  devenv shell zig build test-robustness
  ```
- `-Dskip-present=true` only suppresses presentation; SDL/Vulkan initialization still needs a display/compositor and driver. Use the repo skills `headless-crash-test`, `headless-screenshot`, `headless-benchmark`, or `headless-graphics-verification`, and always bound game/graphics commands with a timeout.
- For deterministic startup checks, combine `-Dskip-present`, `-Dauto-world=<normal|overworld|overworld-v2|flat|test>`, and `-Dstartup-diagnostic-seconds=N`. `-Dchunk-debug-mode` disables water, caves, and decorations; selectively restore `water,watergen,waterrender,caves,decorations` with `-Dchunk-debug-enable=`.

## Benchmarks and generated artifacts

- The benchmark harness is a separate build step; do not pass benchmark presets to ordinary `run` and assume benchmarking is active:
  ```bash
  devenv shell zig build benchmark -Doptimize=ReleaseFast \
    -Dbenchmark-preset=low -Dbenchmark-scenario=traversal \
    -Dbenchmark-duration=60 -Dbenchmark-output=zig-out/benchmark-low.json
  ```
  Scenarios are `stationary`, `traversal`, `rapid-turn`, and `teleport-eviction`. Prefer the `headless-benchmark` skill for bounded runs.
- Focused CPU-only tools: `devenv shell zig build worldgen-report` and `devenv shell zig build worldgen-climate-snapshot`. Pass climate snapshot arguments after `--`, e.g. `devenv shell zig build worldgen-climate-snapshot -- --seed 42 ...`.
- Ordinary builds/tests validate tracked `*.spv` files without rewriting them. After intentional GLSL edits, run `devenv shell zig build shaders` to regenerate runtime SPIR-V, then `devenv shell zig build test-shaders`. After intentional shader-size changes, run `./scripts/update_spirv_baseline.sh`; `docs/shaders/spirv-sizes.json` and shadow runtime SPIR-V parity are test-enforced. Preserve stale-artifact evidence before regenerating during diagnosis.
- New/changed textures go through `./scripts/process_textures.sh <pack> 512`; preserve licensing/attribution for placeholder assets.

## Architecture boundaries

- `src/main.zig` and `src/game/app.zig` wire the executable. Reusable session/player/settings/benchmark logic belongs in `modules/game-core`; screens belong in `modules/game-ui`.
- `engine-rhi` owns rendering contracts and opaque handles; `engine-graphics` owns the Vulkan backend, render passes, resources, and pipelines. Vulkan is currently the only backend, so interface changes usually require both the RHI vtable/contracts and Vulkan implementation.
- `world-core` owns shared block/chunk/coordinate types; world generation is split across `world-worldgen-*` packages; `world-meshing` owns chunk mesh/storage; `world-runtime` coordinates streaming, lighting, GPU meshing, mutation, and rendering; `world-persistence` owns saves/regions.
- Never call RHI/SDL from worker jobs. Pin chunks while background jobs hold them and synchronize shared mesh/chunk state with the project mutex abstraction.
- Convert global coordinates with `worldToChunk`/`worldToLocal` from `world-core`; chunk coordinates are floor-divided, so ad-hoc truncating division is wrong for negative positions.
- GPU-shared structs and shader blocks are ABI contracts. Use explicit layouts (`extern`/packed as appropriate), assert sizes/offsets, and update CPU, GLSL, descriptors, and backend bindings together.

## Graphics hazards

- Dedicated transfer queues cannot upload exclusive graphics buffers safely with semaphore synchronization alone; queue-family release/acquire ownership transfers are required. Until implemented, keep these uploads on the graphics family.
- A descriptor set update affects all previously recorded commands that bind that set when execution happens. Terrain/water or direct/indirect streams that need different buffers require immutable/per-layer descriptor sets, not sequential updates to one set.

## Verification and CI

- Match verification to the change, but graphics/RHI/shader/runtime work normally requires: format check, `zig build test`, ReleaseFast build, integration/robustness as relevant, and the appropriate headless graphics skill. CI additionally runs Debug and ReleaseSafe tests and Lavapipe/Weston integration smoke tests.
- Install the repo pre-push hook with `./scripts/setup-hooks.sh`. Its intended format scope is `src/ modules/ build.zig`; it still omits ReleaseSafe and graphics jobs, so do not treat it as CI parity.
- Nightly `-Dsanitize=c` enables C undefined-behavior sanitization, not ASan. Coverage collection must fail on collector failure or zero project lines; never substitute a passing uninstrumented run or an invented percentage.
- Coverage uses `scripts/collect_coverage.sh`, which explicitly selects `-Dtest-llvm=true` for direct unit-test executables: Zig 0.16 native Debug line mappings are incomplete in kcov 43. Ordinary builds/tests retain their default backend unless that option is requested.
- The PR AI review is static and advisory: trusted-base tooling only, no PR execution or agent tools, no provider secrets for fork reviews, and separate publication. Do not restore broad hidden agent-state artifacts or model-authorized auto-merge. See `docs/ci-review-security.md`.
- Before promotion or redistribution, complete `docs/release-checklist.md`; placeholder-asset licensing remains an explicit review requirement.

## Git workflow

- Branch from and target PRs to `dev`; do not push directly to `dev` unless explicitly requested. Branch prefixes are `feature/`, `bug/`, `hotfix/`, and `ci/`.
- PR titles and commits use conventional types: `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `chore`, `perf`, `build`, `style`, or `revert`.
- Every non-merge PR commit needs a DCO trailer; create commits with `git commit -s`.
