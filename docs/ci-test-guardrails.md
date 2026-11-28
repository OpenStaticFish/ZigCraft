# CI Test Guardrails

## ReleaseSafe Unit Tests

Game and toolchain changes run `zig build test` in both `Debug` and `ReleaseSafe` through the `Build` workflow. `ReleaseSafe` keeps runtime safety checks enabled while exercising optimized code paths that Debug-only CI can miss.

On every PR to `dev` and every `dev` push, Build classifies the full diff with `scripts/ci_changes.py`. Prose and repository automation skip the game jobs. Weston, Lavapipe and Vulkan runner configuration select graphics smoke tests; shader baselines and checker scripts select shader validation. Mixed diffs run the union of applicable checks, and unrecognized inputs select the full game suite. Manual Build dispatches always run the suite for the requested ref.

Changing the Build workflow itself runs the full suite to exercise its commands. Edits limited to runner labels, comments, or YAML formatting still use the lightweight route.

The required `build` and `unit-test` checks still report on every PR. `build` verifies compilation and formatting, including formatter compatibility on shared toolchain changes. `unit-test` verifies the unit matrix, shader validation, and graphics smoke results. Both gates accept skipped work only when the classifier explicitly deselected it. Coverage remains advisory.

Run locally:

```bash
devenv shell zig build -Doptimize=ReleaseSafe test
```

## Coverage

`Coverage` runs independently of `Build` on PRs and pushes to `dev`. Both use the same changed-file classifier: kcov runs for game or toolchain changes and skips prose and routine automation. Changes to the Coverage workflow's commands run kcov without starting game jobs; literal runner-label edits alone skip both. Coverage failures are visible on the `Coverage` run and do not affect the required Build checks. To measure a ref manually, dispatch `Coverage` for that ref.

The workflow uploads the generated report to Codecov and posts a non-blocking comment on same-repository PRs when the coverage artifact is available. The report establishes a baseline before a future blocking threshold is enabled.

Run locally:

```bash
devenv shell --profile unit -- kcov \
  --include-path=src,modules,libs \
  --exclude-path=.zig-cache,zig-cache,assets,docs \
  coverage/kcov \
  zig build test
```

kcov reports line coverage only; branch coverage is not available from this setup.

## Sanitizer Nightly

The `Sanitize` workflow runs nightly and on `workflow_dispatch` with:

```bash
devenv shell zig build -Dsanitize=address test
```

The project is pinned to Zig 0.16.0. That compiler exposes `-fsanitize-c` and `-fsanitize-thread`, but not an LLVM AddressSanitizer build flag through `std.Build`. The repository keeps `-Dsanitize=address` as the CI entrypoint requested by the audit, and currently maps it to Zig's full C undefined-behavior sanitizer support. Failures fail the scheduled workflow check and should be triaged from the uploaded log artifact.

## Vulkan Validation

The integration and world-smoke CI steps run under Lavapipe with `VK_LAYER_KHRONOS_validation`, core validation, and best-practices validation enabled. Integration tests assert that the RHI reports zero validation errors, smoke-test builds exit non-zero if validation errors are observed before shutdown, and the workflow scans both logs for validation-layer error markers as a final fail-on-error gate.
