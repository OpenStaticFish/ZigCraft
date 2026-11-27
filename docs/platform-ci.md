# Platform CI

For the private model provider, Tailscale setup and workflow switches, see [OpenCode CI](opencode-ci.md).

`.github/workflows/build.yml` runs Linux/Lavapipe as the canonical correctness gate: formatting, debug/release-safe unit tests, shader validation, integration smoke, and world smoke.

The Windows and macOS jobs are build-only and manual opt-in in this first iteration. They are kept in the workflow behind the `enable_platform_builds` dispatch input so the dependency setup and artifact paths are ready for stabilization without blocking PRs on non-Linux runner drift.

Known limitations:

- Windows is manual build-only until SDL/Vulkan library discovery and a stable headless Vulkan smoke path are available on GitHub-hosted Windows runners.
- macOS uses MoltenVK plus the Vulkan loader and is manual build-only until a repeatable headless smoke test is defined for GitHub-hosted macOS runners.
- Optional ImGui linkage remains covered by Linux CI; non-Linux build-only legs disable it until cimgui package availability is standardized there.
- Linux/Lavapipe remains the required correctness signal for tests and validation logs.
