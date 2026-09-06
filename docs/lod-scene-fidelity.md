# LOD Scene Fidelity

## Status

2026-09-06: Milestone 0 has reproducible generated-world evidence. Milestone 1
has an opt-in, tested near-source prototype, not final visual acceptance or
full-horizon qualification. The existing renderer remains available.

The goal is to preserve the identity of the actual world through progressively
coarser representations, while expanding the horizon within explicit resource
budgets. Larger radii alone are not acceptance criteria.

## Implemented Reference Path

Enable `ZIGCRAFT_LOD_NEAR_SOURCE=1`; unset it or use `0` to retain the existing
source policy. The engine boolean parser does not interpret `off` as false.

- `lod_near_source.zig` scans final chunk blocks into 256 owned column records.
- LOD0/1 use one-block source footprints. Adjacent chunks never round or clamp
  partial contributions onto each other's interior columns.
- Terrain top positions use block boundaries, including Y=256. Known empty
  columns clear old terrain, water, and vegetation.
- Water, trunks/roots/stems, and leaves/mushroom caps have independent measured
  vertical envelopes and actual materials. Leaf-only columns do not invent
  trunks. Canopies above water are retained.
- Top-face lighting is sampled separately for each envelope and reaches near
  vertex metadata. Block light remains scalar, not full RGB lighting parity.
- Bounded, value-owned summaries survive full-detail chunk unloading and
  covered-region cleanup. Generation and remeshing overlay these summaries
  before publishing replacement geometry.
- Source capture uses generation ownership or the runtime's lighting/storage
  lock order. Failed admissions use a bounded value retry queue, not dangling
  chunk pointers. Retirement conservatively rejects older in-flight captures.
- Near geometry culls shared envelope faces and uses bounded unknown-edge skirts
  rather than exposing artificial 16-block cross-sections.

This is deliberately not a complete voxel interval hierarchy. Envelopes fill
internal vertical gaps; terrain remains a ground projection. Cliff material
identities are retained without layer thicknesses, so exposed walls still use
the surface material. Positive-edge samples can remain advisory. Unvisited
terrain still uses the existing procedural summaries.

### Persistence Boundary

Experimental LOD0/1 summaries are memory-only. They are not read from or written
to the old derived cache. Experimental coarse caching is isolated under
`<save>/near-source-v1/lod`; ordinary save blocks and ordinary LOD caches are not
reinterpreted as the new representation.

Retention is bounded by memory admission, a maximum summary count, and distance.
After eviction or restart, a fresh trusted chunk capture is needed. Persistence
of remote edits without full-detail residency is a later milestone, not a
guarantee of this prototype. The procedural origin warmup is not promoted to
authority before persistence lookup.

## Rendering Corrections

These corrections apply independently of the experimental source flag:

1. Expanded terrain and fluid MDI draws now own separate instance and indirect
   buffers for each frame slot. Updating fluid data cannot overwrite bytes used
   by already-recorded terrain draws. Separate descriptors alone were insufficient.
2. Compact indirect draws select terrain/water from the explicit descriptor
   stream, not the reflection-pass flag. Compact water restores the actual
   expanded water pipeline before subsequent ordinary water draws.
3. Compact shaders decode source `0xRRGGBB` in the correct channel order.
4. Expanded atlas averages multiply the original biome tint without normalizing
   its brightness toward white.
5. A no-op upload preserves an already-ready empty mesh.
6. FXAA's intermediate render-pass dependency matches the post-process pipeline's
   creation pass. Explicit validation exposed this preexisting compatibility VUID.

Compact vegetation representation, general water/MSAA qualification, distant
lighting, and atmospheric improvements remain separate work.

## Reproducible Capture

From the repository root, with a working Vulkan/display environment:

```bash
bash scripts/run_lod_fidelity_capture.sh off
bash scripts/run_lod_fidelity_capture.sh on
```

Both runs use offscreen presentation, production Overworld generation, seed
12345, frozen noon, compact off, and the same local reference profile:

| Parameter | Value |
| --- | --- |
| Initial player position | `(896, 84, -1152)` |
| Final player position | `(1024, 106, -1024)` |
| View | NW, yaw `-3*pi/4`, pitch `-10 degrees` |
| Warmup | 16 renderable chunks, at least 500 actual leaf blocks |
| Movement | 180-frame retreat after warmup, no terrain mutations |
| Full-detail radius | 6 chunks |
| LOD radii | `{6, 16, 24, 24, 24}` chunks, 3 active levels |
| Source densities | `{1, 1, 0.25}` for active levels |
| Horizon | 384 blocks |
| Diagnostic LOD memory budget | 1024 MiB |
| Target | LOD1 region `(14, -18)` |

The local profile is not written into user settings. Capture readiness requires
the target's current uploaded revision, visibility/submission evidence, and 180
stable frames. Enabled-mode evidence additionally requires actual block-derived
columns. Logs disclose `local_reference=1` and `qualified=0`.

The CPU site probe found 778 leaves and 244 logs in the initial 16-chunk patch.
Regenerating the surrounding 64 chunks in reverse order preserved their block
hashes. The immediate patch contains no water; a shoreline lies northwest.
This is a forest handoff fixture, not a completed cliff/coast acceptance suite.

### Local Evidence

Successful paired 1920x1080 ReleaseFast captures, after the MDI fix:

- Control: `screenshots/lod-fidelity/run-20260906T020813Z-68954-off/lod-forest.png`
- Near source: `screenshots/lod-fidelity/run-20260906T020933Z-73665-on/lod-forest.png`
- ReleaseSafe validation: `screenshots/lod-fidelity/validation-fixed.png`

These are local, ignored artifacts, not checked-in golden images. The paired
control already includes the independent color and rendering corrections; it
is not an untouched pre-change baseline. Both final images retain foreground
detail; the treatment replaces the oversized synthetic forest in captured
regions with measured birch occupancy. The rectangular missing-terrain gap
disappeared after separating terrain/fluid MDI buffers.

The treatment target contained 4096 block-derived interior columns and 129
advisory border samples, with source and uploaded mesh revisions matching.
These observations demonstrate working source delivery and rendering, not
Distant Horizons-level visual maturity.

## Verification

Commands are wrapped in `devenv shell`; graphics runs have explicit timeouts and
skip presentation.

- Debug and ReleaseSafe `zig build test`: 31/31 build steps succeeded, 627 tests
  across the collected roots, including 244 world-lod tests.
- `zig fmt --check src/ modules/`: passed.
- ReleaseFast offscreen build: passed.
- `zig build test-integration -Dskip-present=true`: 3 tests passed.
- `zig build test-robustness -Dskip-present=true`: passed.
- `zig build phase5-gate`: passed.
- Both local-reference capture wrappers completed with provenance evidence.
- Explicit Khronos-layer ReleaseSafe capture completed with no validation errors
  after the FXAA dependency correction. Layer version: 1.4.321.0.
- Five-second Low stationary benchmark smoke completed: 3456 frames, 691.1 FPS
  average, 1.447 ms average CPU/frame time, 1.099 ms average GPU total, 0.00036 ms
  shadow and 0.894 ms opaque; averages of 560 draw calls, 716544 vertices, and
  113 full-detail chunks. This uses the ordinary source path and is not a
  performance comparison or qualification of the new near-source path.

Logs are under `logs/lod-m01-*`; the benchmark artifact is
`zig-out/lod-m01-benchmark-smoke.json`. Benchmark adapter/driver provenance fields
are `unknown`, so the numbers are local smoke evidence only.

Focused graphics/game-core roots and the existing LOD mesh/renderer test files
are now executable test roots. Previously, cross-module imports did not execute
several of these tests. Stale mock pointers, fixtures, and expectations were
corrected rather than dropping the tests.

This is not a full saved-world RADV/Lavapipe/Phase 5 visual requalification.
Existing compact fallbacks and qualification requirements remain unchanged.

## Next Milestones

### 1. Finish Near-Field Acceptance

Add full-detail reference images at matched poses, multiple tree families,
cliffs, water, and edited terrain. Preserve material run depths and stronger
neighbor boundaries. Replace filled canopy envelopes if silhouette evidence
requires real interval runs. Do not enable the prototype by default yet.

### 2. Fix Resource Recovery and Near Service

Runtime evidence at 256 MiB exposed a permanent refinement lockout: expanded
pool growth exceeds the budget, finer regions are evicted, but pool backing
capacity and CPU shadows remain allocated. Admission stays blocked and radius
hysteresis never recovers. Even the bounded scene retained roughly 403 MiB
after all work drained. Increasing the reference budget isolates visual work;
it does not fix this defect.

Implement growth admission against actual CPU/GPU capacity, fence-safe empty
pool reclamation, and pressure-driven trimming where needed. Reserve service
for the nearby handoff rather than letting horizon fallback occupy all pending
slots. Add a pool-growth/eviction/retirement/readmission regression. Do not hide
real allocations by accounting only live subranges.

### 3. Build the Authoritative Hierarchy

Reduce compatible finer summaries upward with deterministic ownership and
geometric/material error measures. Generate trustworthy summaries for unvisited
territory with bounded work. A fast procedural summary is an optimization that
must match the approved reference, not an independently defined landscape.

### 4. Persist Scene Identity

Track saved-source revisions and reconstruct remote summaries from nonresident
saved chunks. Preserve edits and authoritative emptiness across cache loss,
eviction, reload, and generator changes without keeping full chunks resident.

### 5. Optimize and Qualify the Horizon

Preserve the approved vegetation/material contract in compact streams or reject
unsupported content explicitly. Then extend the horizon, unify atmospheric and
lighting response, and qualify traversal, startup, memory pressure, saves, both
generators, and hardware/software Vulkan paths. Correctness, visual quality,
and performance remain independent acceptance gates.

## Toolchain Note

The RmlUi bridge derivation now takes only `libs/rmlui_bridge` as its source.
Previously every application edit copied the entire checkout and rebuilt the
bridge on shell entry. The corrected dependency built in 1.54 seconds and the
shell evaluated in 5.75 seconds, versus repeated multi-minute setup. No lockfile
or dependency-version changes were required for that correction.
