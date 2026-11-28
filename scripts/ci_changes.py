"""Select Build jobs from a NUL-delimited git diff --no-renames --name-only."""

import os
import sys
from fnmatch import fnmatchcase


# Only known non-game inputs can opt out. A new dependency or directory gets
# the full game suite until it has been classified explicitly.
REPO_ONLY = (
    "docs/*.md",
    "docs/assets/budget.json", "docs/benchmarks/*.json", "docs/visual-test/golden/*",
    ".github/workflows/*", ".github/actions/load-prompt/*", ".github/prompts/*",
    ".github/opencode/*", ".github/PULL_REQUEST_TEMPLATE/*", ".github/*.md",
    ".github/actionlint.yaml", ".github/CODEOWNERS", ".github/dependabot.yml",
    ".github/issue-labeler.json", ".github/labeler.yml", ".agents/*", ".opencode/*",
    ".githooks/*", ".commitlintrc.json", ".gitignore", ".markdownlint-cli2.jsonc",
    ".prettierignore", ".prettierrc", ".semgrepignore", ".shellcheckrc",
    "bun.lock", "package.json", "opencode.json", "LICENSE",
    "scripts/opencode_*", "scripts/test_opencode_*", "scripts/benchmark_baseline.py",
    "scripts/compare_benchmarks.sh", "scripts/run_benchmark.sh", "scripts/validate_benchmark_artifact.sh",
    "scripts/*generated_tests.sh", "scripts/authorize_source_task.sh",
    "scripts/capture_*.sh", "scripts/check_asset_budget.sh",
    "scripts/check_existing_test_prs.sh", "scripts/ci_changes.py",
    "scripts/test_ci_changes.py", "scripts/test_build_gates.rb", "scripts/codebase_report.sh",
    "scripts/compare_visual_golden.sh", "scripts/configure*git_identity.sh",
    "scripts/ensure_label.sh", "scripts/github_actions_common.sh",
    "scripts/process_textures.sh", "scripts/select_*_module.sh",
    "scripts/setup-hooks.sh", "scripts/stale_branch_cleanup.sh",
    "scripts/validate_generated_zig.sh",
)
SHADER_INPUTS = {
    "docs/shaders/spirv-sizes.json", "scripts/check_spirv_sizes.sh",
    "scripts/update_spirv_baseline.sh", "scripts/check_shadow_abi.sh",
}
COMMITTED_SHADOW_INPUTS = {
    "assets/shaders/vulkan/sky.frag", "assets/shaders/vulkan/sky.frag.spv",
    "assets/shaders/vulkan/terrain.frag", "assets/shaders/vulkan/terrain.frag.spv",
}
GRAPHICS_INPUTS = (
    ".github/actions/start-weston/", ".github/actions/stop-weston/",
    ".github/actions/setup-lavapipe/", ".github/vulkan/",
)
TOOLCHAIN_CONFIG = {"devenv.nix", "devenv.yaml", "devenv.lock"}
TOOLCHAIN_ACTIONS = (".github/actions/setup-devenv/", ".github/actions/setup-zig-cache/")


def classify(paths, full=False):
    game = fmt = graphics = full
    shaders = full
    for path in paths:
        if path in TOOLCHAIN_CONFIG or path.startswith(TOOLCHAIN_ACTIONS):
            game = fmt = True
        elif path in SHADER_INPUTS:
            shaders = True
        elif path.startswith(GRAPHICS_INPUTS):
            graphics = True
        elif "/" not in path and path.endswith(".md"):
            continue
        elif not any(fnmatchcase(path, pattern) for pattern in REPO_ONLY):
            game = True
            fmt |= path.endswith(".zig")
        # Compare the two shipped shadow binaries before any build regenerates them.
        if path in COMMITTED_SHADOW_INPUTS:
            shaders = True
    return dict(game=game, fmt=fmt, graphics=graphics or game, shaders=shaders)


if __name__ == "__main__":
    paths = os.fsdecode(sys.stdin.buffer.read()).split("\0")
    for job, selected in classify(filter(None, paths), full=sys.argv[1:] == ["--all"]).items():
        print(f"{job}={str(selected).lower()}")
