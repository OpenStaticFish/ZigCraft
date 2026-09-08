# CI Test Guardrails

## ReleaseSafe Unit Tests

Pull requests run `zig build test` in both `Debug` and `ReleaseSafe` through the `Build` workflow. `ReleaseSafe` keeps runtime safety checks enabled while exercising optimized code paths that Debug-only CI can miss.

Run locally:

```bash
devenv shell zig build -Doptimize=ReleaseSafe test
```

## Coverage

The `Coverage` workflow builds/runs the unit suite in a fresh private local cache with `-Doptimize=Debug -Dtest-llvm=true`, then runs kcov directly against every current test ELF (`test` and `<module>-tests`), including direct module roots and their deterministic corpus tests. It merges those runs and validates that the Cobertura report contains nonzero instrumented project lines (`src/`, `modules/`, and project-owned `libs/rmlui_bridge/`). Vendored library coverage is excluded. If test executable naming changes, update `scripts/collect_coverage.sh` alongside the build graph.

Collector, test, merge, and empty-report failures fail collection; there is no successful uninstrumented fallback. Only validated reports are uploaded as `kcov-report`. Codecov uploads run on pushes only and remain non-blocking, but their actual outcome is reported. Same-repository PR comments are published in a separate no-checkout job and report actual collection/artifact outcomes; fork PRs use the run summary and artifacts without write credentials. No threshold or fabricated coverage percentage is claimed.

Run locally:

```bash
timeout --kill-after=30s 28m devenv shell --profile unit -- bash scripts/collect_coverage.sh
```

The optional script argument selects a new report directory (default `coverage/kcov`); collection refuses an existing directory before building and rechecks before merging. `ZIGCRAFT_TEST_JOBS` controls build parallelism and defaults to `2`. Private temporary binaries and reports are retained for diagnosis, not deleted; their path is printed before the build. kcov reports line coverage only; branch coverage is not available from this setup. It requires a runner that permits ptrace and can trace the test ELF/DWARF; incompatibility is a tooling failure, not zero-percent or successful coverage.

The collector traces unmodified private ELF copies using their native interpreter and the Nix runtime library search path. It does not rewrite Zig ELF segments with `patchelf` (which can abort on their native-linker layout); actual loader incompatibilities must fail instrumented execution, not trigger an uninstrumented fallback. Equivalent loaders at different Nix store paths are not rejected merely for having different names. A successful test process or kcov exit code is insufficient: the merged report must contain instrumented lines in both `src/` and `modules/`; bridge-only or partial-scope data is not full-suite coverage. In particular, unsupported DWARF/collector combinations can execute every test while reporting zero lines; this remains coverage unavailable.

The audit A/B verification isolated the missing lines to Zig 0.16.0's default x86_64 Debug backend (`stage2_x86_64`) and kcov 43: the embedded source paths matched the include prefixes, but native-backend reports omitted `src/`. Setting `std.Build.TestOptions.use_llvm = true` produced usable line maps with the same paths and filters. The explicit `-Dtest-llvm` option applies only to direct unit-test executables; leaving it unset preserves Zig's normal backend selection, and it does not change application, benchmark, or integration builds. The collector requests it explicitly rather than weakening validation.

The verified LLVM Debug collection ran all 31 executables (1,917 tests passed) and validated 21,485 hit lines out of 27,431 instrumented project lines. These counts include test code and only source lines emitted into the test ELFs; they are not a percentage of every maintained source line or a branch-coverage claim. The native-backend failure and LLVM success evidence were both preserved.

## Sanitizer Nightly

The `Sanitize` workflow runs nightly and on `workflow_dispatch` with:

```bash
devenv shell zig build -Dsanitize=c test
```

The project is pinned to Zig 0.16.0. This mode sets `std.Build.Module.sanitize_c = .full`, C undefined-behavior sanitization (UBSan), **not LLVM AddressSanitizer**. The canonical build spelling is `c-undefined`; `c` is the supported short alias used in CI. The old `address` alias is deprecated and warns; it never provided ASan. This does not imply memory-error instrumentation of all Zig code or prebuilt C/C++ dependencies. Debug/ReleaseSafe checks and testing allocators provide separate safety signals. Failures fail the scheduled workflow and should be triaged from its log artifact.

## Deterministic Corpus Versus Fuzz Campaign

Tests named `fuzz corpus` run fixed malformed inputs, boundary coordinates, or deterministic pseudo-random samples in ordinary CI. Passing them is regression evidence only. A coverage-guided campaign needs explicitly fuzz-enabled targets, a seed/corpus, a bounded runtime budget, retained crashing inputs, and recorded compiler/runner versions. No scheduled coverage-guided campaign or ASan campaign is claimed by the current workflows. Preserve discovered inputs as regression fixtures rather than deleting diagnostics.

## Shader Freshness

Ordinary builds and tests compare compiled GLSL against tracked runtime SPIR-V without overwriting it. `devenv shell zig build shaders` is the explicit regeneration step; `devenv shell zig build test-shaders` checks freshness, size baselines, and shadow ABI. A stale artifact must fail before regeneration, not be silently repaired by the test under evaluation.

## Vulkan Validation

The integration and world-smoke CI steps run under pinned Lavapipe with `VK_LAYER_KHRONOS_validation`, core validation, and best-practices validation enabled. A bounded present-enabled smoke case additionally exercises Wayland swapchain acquisition/presentation; no-present alone cannot cover it. Integration tests assert that the RHI reports zero validation errors, smoke-test builds exit non-zero if validation errors are observed before shutdown, and log gates reject validation markers, missing/empty logs, and initialization skips. Unsupported local displays must not turn required CI graphics checks into false-green skips.
