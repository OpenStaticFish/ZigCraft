# Release And Promotion Checklist

Use this for `dev` to `main` promotion and before creating a public release or redistributing binaries/assets. CI is evidence, not permission to release.

- [ ] Review the exact promotion/tag commit and its full diff, not only the last feature commit.
- [ ] Confirm build, Debug/ReleaseSafe tests, formatting (`src/ modules/ build.zig`), shader freshness/ABI/size checks, and coverage collection ran on that revision. Build and coverage workflows include `main` and `v*` tags.
- [ ] Confirm no-present and present-enabled Linux/Lavapipe checks actually initialized graphics and passed validation. Record the pinned driver/layer/bootstrap revisions and retained logs.
- [ ] Review deterministic benchmark acceptance (runtime, artifact validation, Vulkan logs) and a fresh non-black visual capture against a reviewed golden. A known invalid/black golden is a blocker, not accepted evidence.
- [ ] Record actual coverage collection and upload outcomes. A missing report is not uploaded coverage; corpus regressions are not fuzz campaigns; C UBSan is not ASan.
- [ ] Inventory every bundled texture, font, model, sound, screenshot, and other third-party asset. Retain provenance, license text, attribution requirements, and evidence that the intended distribution is permitted.
- [ ] Resolve development placeholders, including externally sourced Minecraft-compatible resource-pack textures, by obtaining and documenting applicable permission or replacing them with original/appropriately licensed assets. Do not assume the code's MIT license covers these assets. **This checklist does not resolve their licensing status or grant new rights.**
- [ ] Review generated artifacts and packaging contents for credentials, agent state, developer saves, and unintended data. Never bundle hidden agent caches/auth stores.
- [ ] State supported platforms accurately: Linux/Lavapipe is the correctness gate; Windows/macOS remain manually opted-in build-only experiments until separately validated.
- [ ] Obtain human release approval and record remaining known issues, asset-license evidence, test links, and rollback information.

Do not clean caches, remove media, or retire optional features as an implicit part of release preparation. Such changes require an explicit owner decision and review.
