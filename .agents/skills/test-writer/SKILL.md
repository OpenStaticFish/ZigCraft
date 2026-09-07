---
name: test-writer
description: Write unit tests for ZigCraft modules. Covers test patterns, codebase conventions, build commands, Vulkan-without-GPU strategies, and PR formatting.
---

## Role

You are a senior Zig systems programmer writing unit tests for a voxel engine.

## Codebase Context

ZigCraft is a high-performance Minecraft-style voxel engine built with:
- **Zig 0.16+** with strict memory management (explicit allocators, defer/errdefer)
- **SDL3** for windowing and input
- **Vulkan** for rendering (only backend, via RHI abstraction)
- **devenv** for reproducible builds (`devenv shell zig build`)
- **GLSL shaders** validated via glslangValidator
- **Custom job system** for multithreaded world generation and meshing

### Build Commands

| Command | Purpose |
|---|---|
| `devenv shell zig build test` | Unit tests + shader validation |
| `devenv shell zig fmt src/ modules/` | Format code |
| `devenv shell zig build test -- --test-filter "test name"` | Verify a specific new test is discovered and runnable |
| `devenv shell zig build test-integration` | Integration smoke tests for game/graphics/runtime-adjacent changes |
| `devenv shell zig build -Doptimize=ReleaseFast` | Release build |

### Project Structure (testing-relevant)

```
modules/
  engine-core/      # job_system, ring_buffer, time, log, window
  engine-graphics/  # render system, shaders, textures, camera, shadows, vulkan/
  engine-rhi/       # RHI contracts, resource manager, render settings, culling
  engine-input/     # input handling
  engine-math/      # Vec3, Mat4, AABB, Frustum
  engine-ui/        # immediate-mode UI, fonts, widgets
  engine-ecs/       # entity component system
  world-core/       # chunk, block, block_registry, coordinates, lighting
  world-worldgen/   # terrain generation, biomes, caves, decorations
  world-meshing/    # chunk_storage, chunk_mesh, meshing/, GPU block buffers
  world-runtime/    # world facade, streaming, renderer, mutation, GPU mesher
  world-persistence/# level data, region files, save manager
src/
  game/             # player, screen, inventory, settings/, input_mapper, session
  tests.zig     # Test registry — all test files MUST be registered here
```

### Code Style for Tests

- `const std = @import("std"); const testing = std.testing;`
- Import the package under test by module name, or with a same-package relative import for nearby files
- Use `std.testing` assertions: `expectEqual`, `expectApproxEqAbs`, `expect`, `expectError`
- Descriptive test names: `test "ModuleName.functionName edge case description"`
- Accept `std.mem.Allocator` if allocation is needed; use `testing.allocator`
- Use `defer`/`errdefer` for cleanup

### Non-Vacuous Test Requirement

Every test must exercise production code or validate a real production invariant. A good test would fail if the production behavior named in the test regresses.

Valid tests include:

- Calling a production function with inputs that exercise a success path, edge case, or error path
- Initializing a production type and invoking its real methods or helper functions
- Verifying a documented GPU/shared-memory layout invariant with `@sizeOf`, `@alignOf`, `@offsetOf`, or `@bitSizeOf`
- Testing error mapping, handle validation, state transitions, or deterministic output through the real implementation
- Using mocks or stubs only to satisfy dependencies while still calling the production function under test

Invalid tests include:

- Reimplementing production branches in local variables and asserting the copied result
- Checking local booleans, counters, or branch order without invoking the production code being named
- Assigning a Vulkan/C struct field in the test and asserting the field contains the assigned value
- Asserting constants equal themselves or testing that Vulkan/C bindings work
- Using `try testing.expect(true)` as a placeholder assertion
- Returning early from a test as the success condition instead of asserting observable production behavior
- Adding duplicate tests with different names but no new production behavior coverage

If a path cannot be tested without a real GPU/window and cannot be reached through an existing mockable helper, skip it. Document the remaining gap in the PR body rather than adding a filler test.

## Where to Write Tests

- Create or extend `*_tests.zig` files **alongside** the source files (same directory)
- Example: tests for `modules/engine-graphics/src/vulkan/swapchain.zig` go in `modules/engine-graphics/src/vulkan/swapchain_tests.zig`
- After creating a new test file, register it in `src/tests.zig`:
  ```zig
  _ = @import("engine-graphics").vulkan.swapchain_tests;
  ```
  Prefer importing the owning module root from `src/tests.zig`.

## What to Test — Priorities

### Quality Gate

Every new test must protect real production behavior. A reviewer should be able to point to the function, method, layout, encoding, state transition, or error path that would regress if the implementation changed.

Acceptable tests do at least one of the following:
- Call a real production function/method and assert externally observable behavior
- Exercise a real production error path with `expectError`
- Validate a real packed/extern layout, field offset, alignment, bit encoding, or serialized format
- Prove deterministic behavior for production code with fixed inputs
- Verify state transitions on a production type without reaching GPU/window APIs

Forbidden tests:
- Tests that only assign a local variable or struct field and assert the assigned value
- Tests that only prove Zig, `std.ArrayListUnmanaged`, atomics, enums, or C constants work
- Tautologies such as `FOO == FOO`
- Tests named after a production function that never call that function
- Tests that copy production branch logic into local booleans instead of exercising production code
- Helpers that simulate the behavior under test rather than invoking the real function
- Tests for private functions from another file unless an existing valid test import pattern already exposes them
- Tests that document behavior production code does not implement
- Bulk low-value test dumps; keep each run to 3-8 focused tests
- Duplicate tests that already exist nearby

### For ALL modules
1. **Untested public functions** — Any `pub fn` with no corresponding test
2. **Error paths** — Functions returning `!T` or `RhiError!T` with no error branch tests
3. **Edge cases** — Zero values, max values, negative values, empty inputs, boundary conditions
4. **State transitions** — Init -> use -> deinit cycles, state machine correctness
5. **Determinism** — Same inputs produce same outputs across multiple calls
6. **Invariants** — Properties that should always hold (e.g., `normalize(v).length() == 1.0`)

### For graphics/vulkan modules
1. **Vulkan error code mapping** — Every `VkResult` error code must map to the correct Zig error via `checkVk`. Unmapped codes return `error.Unknown`.
2. **GPU crash paths** — Device loss, surface loss, out-of-memory produce the right errors without panicking.
3. **Resource handle validation** — Invalid handles (0, max u32), null pointers, double-destroy, use-after-destroy.
4. **Buffer/Texture lifecycle** — Create/destroy ordering, deletion queue, MAX_FRAMES_IN_FLIGHT double-buffering.
5. **RhiError propagation** — Every function that can return `RhiError` should have at least one error path test.
6. **Synchronization safety** — Fence/semaphore patterns, command buffer lifecycle, frame-in-flight tracking.
7. **Struct layout** — `packed struct` alignment, `extern struct` field offsets, GPU data layout.
8. **Pipeline state** — Shader compilation error handling, pipeline creation failure recovery.

For Vulkan orchestration code, do not copy the orchestration condition into the test and assert the copied condition. Either call the real orchestration helper with a mock/partial context, test a smaller real helper used by the orchestration path, or leave the path as a documented gap.

### For world-core/world-worldgen modules
1. **Chunk boundary conditions** — Negative coordinates, coordinate transforms, edge-of-world
2. **Determinism** — Same seed always produces identical output
3. **Noise range guarantees** — Output stays within documented bounds
4. **Biome selection** — Climate parameter edge cases, transition rules

### For engine/core modules
1. **Job system** — Work distribution, edge cases with 0 or 1 jobs
2. **Ring buffer** — Full/empty boundary, wrap-around, capacity edge cases
3. **Time** — Precision, overflow at large values, delta time calculations

## How to Test Vulkan Code Without a GPU

Many Vulkan types are opaque pointers that can be `null` in tests:

1. **Test pure logic**: Functions not calling Vulkan APIs directly (e.g., `checkVk`, struct constructors, validation, math).
2. **Partial struct initialization**: Initialize structs with `null` Vulkan handles and test non-Vulkan fields, but do not call methods that could reach Vulkan APIs.
3. **Mock interfaces**: Follow `modules/engine-graphics/src/rhi_tests.zig` patterns — create mock structs with function pointers.
4. **Error mapping tests**: Call `checkVk` with specific `VkResult` constants.
5. **Struct layout tests**: Verify `@sizeOf`, `@offsetOf`, `@bitSizeOf` for GPU-facing structs.
6. **State machine tests**: Test state transitions only when the inputs return before any Vulkan call.

Do not call real Vulkan APIs with null or fake handles. If a function could reach `vkCreate*`, `vkDestroy*`, queue submit, presentation, or device wait calls, do not test it without an existing safe mock/stub.

Pure-logic tests must still call real production logic. Do not recreate a production `if` expression, selection rule, or state-machine transition inside the test body unless the assertion is also tied to a production function or production type invariant.

### Example Patterns

```zig
// Error mapping test
test "checkVk maps VK_ERROR_OUT_OF_DATE_KHR" {
    const checkVk = @import("vulkan_device.zig").checkVk;
    try testing.expectError(error.OutOfDate, checkVk(c.VK_ERROR_OUT_OF_DATE_KHR));
}

// Partial struct test
test "VulkanDevice fault count tracking" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .fault_count = 0,
    };
    try testing.expectEqual(@as(u32, 0), device.fault_count);
}

// Mock-based test
test "ResourceManager rejects invalid handle" {
    var manager = ResourceManager{ ... };
    try testing.expectError(error.ResourceNotFound, manager.getBuffer(0));
}
```

## Git Workflow

You are running inside the opencode GitHub Action. The infrastructure auto-creates a branch and handles push + PR creation after you finish.

**CRITICAL: Stay on the current branch. Do NOT create a new branch. Do NOT push. Do NOT run `gh pr create`.**

1. Write your test files
2. Register new test files in `src/tests.zig`
3. Format: `devenv shell zig fmt src/ modules/`
4. Run tests: `devenv shell zig build test` — ALL tests must pass, not just yours
5. Run at least one new test by filter: `devenv shell zig build test -- --test-filter "<new test name>"`
6. Self-review the diff and remove any fake, tautological, misleading, or unsafe test before committing
7. Count actual added `test "..."` declarations from your diff and keep the run within 3-8 total new tests
8. Commit your changes with message: `test: add {area} tests for {module}`

The infrastructure will push the branch and create the PR automatically.

## Constraints

- Only write tests for logic testable WITHOUT a real GPU/window. Use mocks, stubs, or test pure logic only.
- Do NOT modify any non-test source files. Only add or modify test files (and `src/tests.zig` for registration).
- Tests MUST pass before committing. This is non-negotiable.
- A filtered run for at least one newly added test MUST pass before committing.
- The new tests MUST be semantically analyzed and executed by `zig build test`; do not rely on registrations that hide test blocks from the test runner.
- Format before commit: `devenv shell zig fmt src/ modules/`.
- 3-8 tests per run across the whole PR, not per file. Quality over quantity.
- If the module has no testable logic, stop without committing and note limitations.
- Skip if nothing to test — do not create trivial tests just to create a PR.
- For game, graphics, windowing-adjacent, or runtime initialization tests, run `devenv shell zig build test-integration` when feasible and report if it was not feasible.

## Stop Conditions

Stop without committing if any of these are true:
- `zig build test` fails
- A newly added test cannot be run by `--test-filter`
- Tests require a real GPU, Vulkan device, SDL window, network, wall-clock timing, or nondeterministic scheduler behavior
- Tests only check local assignments, copied branch logic, C constants, or standard library behavior
- Tests require modifying production code only to expose private internals
- The diff changes non-test production files except necessary test registration exports/imports

## Required Self-Review Before Commit

Before committing, inspect the diff and remove or rewrite any test where the answer to any of these questions is "no":

- Does the test call production code or validate a real production layout/type invariant?
- Would this test fail if the production behavior described by the test name were broken?
- Is the test asserting behavior beyond values created only inside the test body?
- Is the test materially different from existing tests in the same file?

Also verify the PR summary counts actual added `test "..."` declarations from the diff. Do not estimate test counts from intent.

## PR Body Template

The PR body should follow this format:

```
## Module
`{module}` (automated test coverage)

## Summary
1-2 sentences describing what areas are now tested.

## Tests Added
- `test "descriptive name"` — What it verifies
- `test "descriptive name"` — What it verifies

## Testing Gaps Remaining
- Functions or paths that still need tests and why

## Verification
- [x] `devenv shell zig fmt src/ modules/` passes
- [x] `devenv shell zig build test` passes (all tests, not just new ones)
- [x] `devenv shell zig build test -- --test-filter "..."` passes for a newly added test
- [x] No non-test source files were modified
```
