# Platform CI

`.github/workflows/build.yml` runs Linux/Lavapipe as the canonical correctness gate: formatting, debug/release-safe unit tests, shader validation, integration smoke, and world smoke.

The Windows and macOS jobs are build-only and manual opt-in in this first iteration. They are kept in the workflow behind the `enable_platform_builds` dispatch input so the dependency setup and artifact paths are ready for stabilization without blocking PRs on non-Linux runner drift.

Known limitations:

- Windows is manual build-only until SDL/Vulkan library discovery and a stable headless Vulkan smoke path are available on GitHub-hosted Windows runners.
- macOS uses MoltenVK plus the Vulkan loader and is manual build-only until a repeatable headless smoke test is defined for GitHub-hosted macOS runners.
- Optional ImGui linkage remains covered by Linux CI; non-Linux build-only legs disable it until cimgui package availability is standardized there.
- Linux/Lavapipe remains the required correctness signal for tests and validation logs.

Linux CI includes both offscreen/no-present checks and a bounded present-enabled smoke run under Weston. A valid Wayland socket and working Lavapipe initialization are prerequisites, not reasons to silently skip. The graphics gate rejects missing logs and initialization-skip messages as well as Vulkan validation errors.

Lavapipe, validation layers, ImageMagick visual comparison, and the devenv bootstrap CLI use the explicit nixpkgs revision recorded in their workflow/actions, not the floating `nixpkgs` registry. Application libraries remain pinned independently by `devenv.yaml`/`devenv.lock`. Updating either pin requires runtime verification; a cache miss is not justification to float the driver. Windows/macOS bootstrap packages are still experimental and are not claimed to share this Linux reproducibility guarantee.

## Optional UI Dependencies

The default, unit, and graphics devenv profiles currently retain cimgui and RmlUi/bridge dependencies so explicit `-Dimgui` and `-Drmlui` builds continue to work. Disabling a build flag does not remove those libraries from the Nix shell closure; `unit` is leaner in developer/graphics tooling, not a UI-free environment. No dependency or feature is retired by this audit.

A genuinely smaller shell needs an explicit opt-in profile that removes UI packages from packages, runtime library paths, and artifact rpaths together, paired with `-Dimgui=false -Drmlui=false` verification and clear missing-feature diagnostics. That profile/feature-policy decision is deferred rather than silently changing existing profile behavior. Default full UI support must remain available.
