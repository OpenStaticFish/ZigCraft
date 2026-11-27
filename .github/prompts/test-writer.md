Load the `test-writer` skill first. It contains the repository testing patterns, module layout, and ZigCraft workflow rules. The stricter instructions below override any weaker guidance in the skill.

## YOUR TASK

Write 3-8 high-quality unit tests for `$MODULE`, targeting `$DEFAULT_BRANCH`.

Quality is more important than quantity. If you cannot identify at least 3 meaningful tests that exercise real production behavior, STOP without committing and explain why in your final message.

`3-8` means the total number of new `test "..."` declarations in the entire PR, not per file.

## TEST QUALITY — CRITICAL

Every added test must be non-vacuous: it must call production code or validate a real production type/layout invariant. A test should fail if the production behavior named by the test regresses.

Do NOT add tests that only:

- Recreate production logic in local variables and assert the copied result
- Check local booleans, counters, or branches without calling the production function under test
- Assign fields in a Vulkan/C struct and assert the same assigned values
- Assert constants equal themselves or verify C/Vulkan bindings rather than ZigCraft behavior
- Use `try testing.expect(true)` or return early as the success condition

For Vulkan code without a real GPU/window, prefer real pure functions, mockable context helpers, handle validation, error mapping, state fields initialized from production types, or layout invariants. If a path cannot be tested without reimplementing it locally, skip it and document the gap instead of adding a filler test.

## FILES TO SCAN

Read these source files to find untested code:

$SCAN_PATHS

Also read existing nearby `*_tests.zig` files and the owning module `root.zig`/test registration pattern before writing tests.

## HARD STOP CONDITIONS

Do not commit if any of these are true:

1. `devenv shell zig build test` fails.
2. The new test file is not actually discovered by `zig build test`.
3. A newly added test cannot be run by name with `devenv shell zig build test -- --test-filter "<new test name>"`.
4. Any test depends on a real GPU, real Vulkan device, SDL window, display server, network, wall-clock timing, or nondeterministic scheduler behavior.
5. Any test calls Vulkan destroy/create/submit functions with null or fake handles unless the production function guarantees it returns before the Vulkan call.
6. The tests require modifying production code only to make private implementation details public.
7. The diff modifies non-test source files, except for necessary test registration exports/imports in module roots or `src/tests.zig`.
8. You added trivial, fake, tautological, or misleading tests as defined below.

If a stop condition is hit, revert only your own uncommitted changes, leave the repository without a new commit, and explain the blocker.

## TEST QUALITY BAR

Every new test must satisfy at least one of these:

1. Calls a real production function/method and asserts externally observable behavior.
2. Exercises a real error path from production code with `expectError` or equivalent.
3. Validates a real data invariant, serialization format, packed/extern layout, field offset, alignment, or bit-level encoding used by production code.
4. Proves deterministic behavior for a production generator/transform using fixed inputs.
5. Verifies state transitions on a real production type without invoking GPU/window APIs.

Prefer tests that would fail if the implementation were accidentally changed. A reviewer should be able to point to the production behavior each test protects.

## FORBIDDEN TEST PATTERNS

Do not write or keep tests that match any of these patterns:

1. Tests that only assign a local variable or struct field and assert the assigned value.
2. Tests that only prove Zig, `std.ArrayListUnmanaged`, atomics, enums, or C constants work.
3. Tests that check a constant against itself, e.g. `FOO == FOO`.
4. Tests named after a production function that never call that function.
5. Tests that copy or mirror production branch logic with local booleans instead of exercising production code.
6. Helpers that simulate the behavior under test rather than invoking the real function.
7. Tests for private functions from another file unless the existing code already exposes that behavior through a valid test-only import pattern.
8. Tests that document behavior the production code does not actually implement.
9. Bulk test dumps. Do not add dozens of tests in one run just because many cases are easy to enumerate.
10. Duplicate tests that already exist in nearby test files.

Examples of bad tests to avoid:

```zig
test "VkSubmitInfo wait semaphore count can be 2" {
    var info = c.VkSubmitInfo{ .waitSemaphoreCount = 2, ... };
    try testing.expectEqual(@as(u32, 2), info.waitSemaphoreCount);
}

test "beginFrame returns InvalidState" {
    const frame_in_progress = true;
    if (frame_in_progress) return error.InvalidState;
}
```

## VULKAN AND GRAPHICS TESTS

Only test Vulkan/graphics code without a GPU by using safe units:

1. Pure mapping functions such as `checkVk`.
2. Public validation helpers that do not call Vulkan.
3. Struct layout, packed data, offsets, alignment, and bit encoding.
4. State transitions that return before any Vulkan call with null handles.
5. Existing mock interfaces already used in the repository.

Do not call real Vulkan APIs with fake handles. If a function could reach a Vulkan API call, do not test it unless you can prove the test input takes an early return before that call.

## REGISTRATION REQUIREMENTS

1. Add or extend `*_tests.zig` alongside the source under test.
2. Follow the existing module export pattern if new test files need to be exported from a module `root.zig`.
3. Register new tests in `src/tests.zig` using the existing style.
4. Confirm the tests are semantically analyzed and executed, not just reachable through a `pub const` that hides test blocks from the test runner.

## REQUIRED SELF-REVIEW BEFORE COMMIT

Before committing, inspect your own diff and remove any test that would likely be flagged by `.github/prompts/pr-review.md` for these reasons:

1. It does not call the method/function named in the test.
2. It provides false confidence by testing local logic instead of production logic.
3. It is tautological or only checks C/Zig/std constants.
4. It uses null/fake Vulkan handles unsafely.
5. It claims to test behavior that is not implemented.
6. It changes production files unnecessarily.
7. It adds excessive low-value coverage instead of a small number of meaningful tests.

If review would reasonably return `MERGE WITH FIXES` or `DO NOT MERGE`, fix the tests before committing.

## VERIFICATION COMMANDS

Run all commands through devenv.

1. Format: `devenv shell zig fmt src/ modules/`
2. Run all unit tests: `devenv shell zig build test`
3. Run at least one newly added test by exact or narrow filter: `devenv shell zig build test -- --test-filter "<new test name>"`
4. For tests touching game, graphics, windowing-adjacent, or runtime initialization code, also run: `devenv shell zig build test-integration`

If `test-integration` is not feasible in the GitHub Action environment, do not guess. State the exact reason in the final message, but still require `zig build test` and the filtered test to pass before commit.

## GIT WORKFLOW - CRITICAL

You are running inside the opencode GitHub Action. The infrastructure auto-creates a branch and handles `git push` and PR creation after you finish.

STAY ON THE CURRENT BRANCH. Do NOT create a new branch. Do NOT run `git checkout -b`. Do NOT push. Do NOT run `gh pr create`. The infrastructure does all of that for you.

Workflow:

1. Write only meaningful tests and necessary test registration changes.
2. Run the required verification commands.
3. Self-review the diff against the quality bar above.
4. Commit only if all required checks pass and the tests are review-grade.
5. Use commit message: `test: add {area} tests for $MODULE`
6. STOP. Do not push or create a PR.

## FINAL MESSAGE

In your final response, include:

1. Tests added and the production behavior each protects.
2. Verification commands run and whether they passed.
3. Confirmation that no non-test production files were modified except necessary registration.
4. Any remaining testing gaps and why they were not safe to cover.
