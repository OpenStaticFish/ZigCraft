import unittest

from ci_changes import classify


class ChangeRoutingTests(unittest.TestCase):
    def assert_jobs(self, paths, *expected, full=False):
        decision = classify(paths, full=full)
        self.assertEqual({job for job, selected in decision.items() if selected}, set(expected))

    def test_docs_and_automation_do_not_allocate_game_runners(self):
        self.assert_jobs(["README.md", "docs/benchmarks/README.md", "docs/assets/budget.json"])
        self.assert_jobs([".github/workflows/build.yml", "scripts/opencode_review.sh"])

    def test_graphics_runner_changes_only_exercise_graphics(self):
        self.assert_jobs([".github/actions/start-weston/action.yml", "README.md"], "graphics")

    def test_shader_baseline_and_checker_use_standalone_validation(self):
        self.assert_jobs(["docs/shaders/spirv-sizes.json", "scripts/check_shadow_abi.sh"], "shaders")

    def test_mixed_changes_preserve_full_suite_without_duplicate_shader_job(self):
        self.assert_jobs(["docs/guide.md", "modules/example.zig", "docs/shaders/spirv-sizes.json"],
                         "fmt", "game", "graphics")

    def test_toolchain_shaders_and_unknown_inputs_select_full_game_checks(self):
        for path in ("devenv.lock", "assets/shaders/vulkan/sky.frag", "scripts/new-check.sh",
                     "docs/future-fixture.bin"):
            with self.subTest(path=path):
                self.assert_jobs([path], "game", "graphics")

    def test_manual_run_is_full_even_without_a_diff(self):
        self.assert_jobs([], "fmt", "game", "graphics", full=True)


if __name__ == "__main__":
    unittest.main()
