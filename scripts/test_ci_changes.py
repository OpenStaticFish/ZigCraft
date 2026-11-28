import unittest

from ci_changes import classify


class ChangeRoutingTests(unittest.TestCase):
    def assert_jobs(self, paths, *expected, full=False):
        decision = classify(paths, full=full)
        self.assertEqual({job for job, selected in decision.items() if selected}, set(expected))

    def test_docs_and_automation_do_not_allocate_game_runners(self):
        self.assert_jobs(["README.md", "docs/benchmarks/README.md", "docs/assets/budget.json"])
        self.assert_jobs([".github/workflows/repo-automation.yml", "scripts/opencode_review.sh"])
        self.assert_jobs([".github/actions/load-prompt/action.yml"])
        self.assert_jobs(["scripts/run_benchmark.sh", "scripts/benchmark_baseline.py",
                          "scripts/compare_benchmarks.sh", "scripts/validate_benchmark_artifact.sh"])

    def test_graphics_runner_changes_only_exercise_graphics(self):
        self.assert_jobs([".github/actions/start-weston/action.yml", "README.md"], "graphics")

    def test_shader_baseline_and_checker_use_standalone_validation(self):
        self.assert_jobs(["docs/shaders/spirv-sizes.json", "scripts/check_shadow_abi.sh"], "shaders")

    def test_mixed_changes_keep_clean_checkout_shader_validation(self):
        self.assert_jobs(["docs/guide.md", "modules/example.zig", "docs/shaders/spirv-sizes.json"],
                         "fmt", "game", "graphics", "shaders")

    def test_committed_shadow_binaries_and_sources_select_both_checks(self):
        for shader in ("sky", "terrain"):
            for suffix in (".frag", ".frag.spv"):
                path = f"assets/shaders/vulkan/{shader}{suffix}"
                with self.subTest(path=path):
                    self.assert_jobs([path], "game", "graphics", "shaders")

    def test_toolchain_changes_include_clean_checkout_shader_check(self):
        for path in ("devenv.nix", "devenv.yaml", "devenv.lock",
                     ".github/actions/setup-devenv/action.yml",
                     ".github/actions/setup-zig-cache/action.yml"):
            with self.subTest(path=path):
                self.assert_jobs([path], "fmt", "game", "graphics", "shaders")

    def test_shaders_and_unknown_inputs_select_full_game_checks(self):
        for path in (".github/actions/new-action/action.yml",
                     "assets/shaders/vulkan/water.frag", "scripts/new-check.sh",
                     "scripts/new-benchmark-check.sh", "docs/future-fixture.bin"):
            with self.subTest(path=path):
                self.assert_jobs([path], "game", "graphics")

    def test_manual_run_is_full_even_without_a_diff(self):
        self.assert_jobs([], "fmt", "game", "graphics", "shaders", full=True)


if __name__ == "__main__":
    unittest.main()
