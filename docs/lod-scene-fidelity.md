# LOD Scene Fidelity

## Status

**2026-09-07, current:** the canonical scene hierarchy is implemented behind
`ZIGCRAFT_LOD_CANONICAL=1`. Its default remains **false**. It is an opt-in
development path, not the shipping default or a completed feature. When
enabled, it supersedes the older near-source path for that manager; the
existing renderer remains available.

The historical near-envelope prototype and its 2026-09-06 evidence remain
below for provenance. They are not evidence for the canonical hierarchy.

The goal is to preserve the identity of the actual world through progressively
coarser representations, while expanding the horizon within explicit resource
budgets. Larger radii alone are not acceptance criteria.

## Current Canonical Hierarchy

### Source and Reduction Contract

- A canonical source is a value-owned `ChunkSummary`: 256 columns, each a
  run-length encoded vertical sequence of non-air blocks. Each run retains its
  `[min_y, max_y)` interval, exact block material, and top and bottom packed
  lighting; each column retains its biome. Air gaps are represented by gaps
  between runs, rather than filled envelopes.
- The summary is validated as an ordered, non-overlapping partition before use.
  It preserves strata, roofs/overhang gaps, water, leaf-only crowns, and known
  empty columns at chunk resolution. It is not a single heightfield.
- `SceneBuilder` takes immutable source snapshots over the final region
  footprint plus a one-cell halo. It reduces source columns directly into a
  `SceneGrid`; it does not successively reduce already-lossy scene spans.
  Integer per-Y/material/class counts, coverage, biome counts, centroids, and
  top/bottom light moments make compatible reductions associative and
  independent of source insertion order, including negative coordinates.
- The grid records known area separately from total area. Fully known air is
  authoritative coverage, while missing coverage is explicitly provisional.
  A newer provisional result cannot replace known air or partial canonical
  coverage; an old mesh stays live through worker or upload failure.

Exact coverage is obtained from live chunks, strict saved reads, or bounded
full-chunk generation. Until that work completes, missing or unvisited territory
uses the established procedural/heightfield fallback and is marked approximate;
the fallback is not promoted to canonical authority. This means
coarse/provisional visual differences remain expected outside covered source
footprints.

### Saved-World Authority and Persistence

Saved block regions are authoritative over generated observations. A strict
saved-source read precedes generation: a read error never falls through to the
procedural generator, and generation is allowed only after block absence is
confirmed. Revisions, fingerprints, capture-start epochs, and immutable leases
fence delayed live, saved, and background work. Eviction releases payloads but
does not turn stale observations into authority.

The derived RLE sidecar is persisted separately from block regions. A saved
summary whose sidecar write is cancelled, rejected, or races a newer save keeps
a bounded persistence obligation; a fresh strict reread/revalidation retries
the sidecar rather than writing the stale queued snapshot. Corrupt or missing
sidecars repair from unchanged saved blocks. Corrupt block payloads are strict
errors and are never overwritten by sidecar repair.

### Materials, Lighting, and Seams

Canonical scene meshing carries opaque, trunk, canopy, water, and plant spans with
their actual block materials, biome tint inputs, and separately reduced top and
bottom lighting. It retains layered depths and detached geometry rather than
using the former terrain/canopy envelopes. Canonical geometry uses the expanded
CPU path: compact v1 explicitly rejects canonical scene sources, so it cannot
silently flatten them.

Exact cross and tall-cross plants retain each stored root, their species atlas,
and their one- or two-block height. Coarse plant bands use bounded one-block-wide
representatives, not billboards stretched across a coarse cell. Plant vertex
colors follow the LOD atlas-average-times-tint contract; otherwise the shader's
detail reconstruction would amplify their brightness. Atlas-backed cutouts
retain alpha testing after RGB texture detail fades.

Greedy merging is constrained by span/material/light/coverage compatibility.
The halo distinguishes known air, unknown cells, and partial geometry; shared
surfaces are emitted by deterministic half-open ownership, with the inward
vertical-boundary rule retaining an owner's exposed face. Unknown edges use the
appropriate conservative handoff instead of claiming a neighbor's geometry.
Ready descendants subtract only their owned footprints from fallback parents,
including known-empty children and descendants below missing intermediate
levels. Cached nonempty children outside the frame's distance selection do not
erase their parent. Detail coverage is revalidated each projection, rather than
assuming a previously complete disk cannot lose a chunk.
The latest intentional shader baseline change carries the ownership varyings
and alpha handling needed by these expanded canonical draws. It is not a
compact-v1 qualification.

### CPU/GPU Budgeting and Fairness

Canonical refresh work has bounded outstanding/completion queues, per-region
retry ticks, and a quota allocator that charges CPU allocation and reallocation
overlap until the mesh releases its owner. Source-cache work reserves bounded
scratch space and limits background work; completed CPU payload allowance is
released before GPU admission. Failed refreshes retain the previous valid
geometry and retry rather than publishing a partial replacement.

The pre-existing memory governor continues to charge active GPU pools, CPU
shadows, retired GPU backing, source CPU data, pending work, and replacement
peaks. Its weighted service wheel gives local fallback, near LOD0/1, horizon,
and refinement lanes bounded opportunities; the horizon/refinement soft limit
reserves headroom for local/near work while the hard cap applies to every lane.
Background admission credits only the portion of that reserve already consumed
by exclusively owned near allocations. Shared pools and source-cache capacity
are not credited. Canonical cache capacity is reserved before first admission;
failed/missing work must reacquire its CPU allowance. Bounded CPU and upload
recovery requests can reclaim eligible outer work without discarding protected
near coverage merely to satisfy a background soft limit.
These are LOD-adapter accounting figures, **not** a reservation for all worker
allocations or a measurement of total application RSS.

### Current Evidence and Limits

- `logs/lod-canonical-tests-verified.log`: Debug and ReleaseSafe tests, each
  37/37 build steps succeeded. The later ownership-distance regression also
  passes the full Debug suite in `logs/lod-ownership-full-v8.log`.
- `logs/lod-canonical-final-checks.log`: final ReleaseSafe tests (37/37),
  ReleaseFast offscreen build, and integration/robustness/policy gates (26/26).
- `logs/lod-canonical-service-verified.log`: the unchanged 256 MiB,
  256-chunk configured-horizon service capture passes with `overlap_seen=1`,
  current 4096/4096 target coverage, and 180 stable frames. The Khronos layer
  was explicitly requested; no validation errors or runtime error markers
  occurred. Artifact:
  `screenshots/lod-fidelity/run-20260907T015850Z-841808-on-service/lod-forest.png`.
- The preceding successful `logs/lod-canonical-horizon-v3.log` recorded 61
  horizon-lane renderable publications, final accounted usage 210,758,856 bytes,
  logical admission 244,355,674 bytes, and no pending uploads. Its sampled
  logical maximum was exactly 268,435,456 bytes, the 256 MiB limit. These are
  sampled adapter figures, not a total-process or unsampled peak guarantee.
- Earlier local 256 MiB captures reached target readiness, but their cold-start
  logical reservations exceeded the cap. They are not memory qualification for
  the current admission fix. Earlier service runs correctly failed because
  horizon publications remained blocked despite a ready forest target.
- `logs/lod-canonical-saved-v4.log`: intact reload and summary-cache-loss
  repair both preserved all 113 original chunks. The run removed 2,385 derived
  summaries, then repaired from saved blocks; it rendered nine required saved
  features with the target source nonresident. The inspected local image root
  is `screenshots/canonical-saved/run-20260906T235609Z-317753-uDCwEa`.
- `logs/lod-canonical-saved-validation-v2.log`: repeated intact and cache-loss
  repair with the Khronos layer requested; all original block contents were
  preserved, sidecars reconstructed, and target sources remained nonresident.
  Artifact root:
  `screenshots/canonical-saved/run-20260907T004929Z-552197-s2wA2h`.
- `bash scripts/run_canonical_saved_capture.sh --self-test`: eight CPU-only
  tests plus evidence-parser checks. The harness validates all original saved
  block arrays, not only nine feature probes. Valid lighting changes and added
  chunks are allowed; malformed payloads, invalid biomes, missing original
  chunks, or changed original blocks fail. Raw region snapshots are retained.

The service result proves concurrent near/horizon progress, not that every
coordinate in the configured horizon is populated. Every capture still reports
`qualified=0`. No default-shipping
qualification, full RADV/Lavapipe matrix, or full Phase 5 visual qualification
has been completed.

Explicit fidelity limits remain: glass, ice, and lava are not faithfully
pass-routed, slab/stair spans are not exact construction meshes, and
coarse/provisional areas visibly differ from full detail. One intermediate
validation run (`logs/lod-canonical-horizon-final.log`) reached readiness but
was correctly rejected for repeated LOD3 CPU-quota allocation failures.
The subsequent verified run passed; complex refinement saturation and repeatable
visual quality still need broader qualification. The canonical hierarchy is
not a claim of full feature completion.

## Historical: Near-Source Envelope Prototype (2026-09-06)

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

## Historical: Near-Source Reproducible Capture

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

## Historical: Near-Source Verification

Commands are wrapped in `devenv shell`; graphics runs have explicit timeouts and
skip presentation.

- Debug and ReleaseSafe `zig build test`: 31/31 build steps succeeded, 627 tests
  at the first checkpoint. After resource recovery, both modes pass 650 tests,
  including 264 world-lod tests.
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

## Historical: Near-Source Resource Recovery

The renderer now reports fence-retired expanded GPU backing separately from
active pool capacity and CPU shadows. Upload admission checks additional peak
allocation before staging's oversized-task exception can apply. Pool planning,
staging estimates, and execution share a single replacement decision.

- Replacements are fully migrated before publishing new mesh locations. Failure
  retains the pending payload and valid previous draw state, including offsets
  changed by a successful pool relocation before a later payload failure.
- Retired backing remains charged until a strictly newer completion of its
  actual backend frame slot. World update announces that epoch before uploads
  or deletions, not only when drawing later in the frame.
- Empty pools can release their shadows/backing when range retirement and free
  coverage prove safety. Nonempty pools can shrink through a budgeted replacement.
- Maintenance runs before projection/compute preparation, at most once per frame,
  even without GPU culling. It never relocates between terrain and water draws.
- Reclaimed shadows first pay any existing budget deficit. Only remaining
  headroom can fund a trim; GPU debt is not treated as already freed memory.
- Memory-denied uploads remain retryable and request enough recovery headroom
  for one achievable replacement, even when current usage is below the cap.
- Eviction prefers unfinished distant refinements with a renderable parent.
  Raw upload-queue pointers are removed before freeing their chunks; pending
  CPU payloads are released immediately and GPU storage remains deferred.
- Reduced radii exclude evicted footprints. Re-expansion requires two continuous
  seconds of settled, unchanged logical usage below 80%, preventing rapid
  eviction/regeneration churn while jobs and retirements remain outstanding.

Reproduce the lower-budget capture without changing ordinary presets:

```bash
ZIGCRAFT_LOD_FIDELITY_MEMORY_MB=256 bash scripts/run_lod_fidelity_capture.sh on
```

The override is limited to `lod-forest`: valid integers clamp to 64-4096 MiB;
invalid or absent values retain the 1024 MiB reference default. Both requested
and effective budgets are logged. Readiness, pose, horizon, and source authority
requirements are unchanged.

### Recovery Evidence

| Run | Result |
| --- | --- |
| Original 256 MiB implementation | Retained roughly 403 MiB after work drained; target missing |
| Admission-only iteration | Below-cap upload headroom stall, then excessive eviction churn; rejected |
| Final ReleaseFast 256 MiB run | Target rendered; 133454113 accounted bytes (127.3 MiB), no pending uploads or retired backing |
| Final ReleaseSafe validation run | Target remained ready through the longer capture; 131699606 accounted bytes (125.6 MiB), no pending uploads or retired backing |

Artifacts:

- `screenshots/lod-fidelity/run-20260906T140230Z-2349687-on/lod-forest.png`
- `screenshots/lod-fidelity/recovery-validation-256.png`
- `logs/lod-recovery-256-v3.log`
- `logs/lod-recovery-validation-256.log`

The target still contains all 4096 measured interior columns. The low-budget
run intentionally retains fewer distant refinements than the 1 GiB reference;
it is not equal-quality or full-horizon performance qualification. The
ReleaseSafe run used explicit Khronos validation and a 20-second screenshot
delay, completed without validation errors, and ended with all local work
queues drained. Sampled known usage stayed below the configured budget; this
is not a measurement of every transient allocation or total application RSS.

After the recovery changes, Debug/ReleaseSafe tests, ReleaseFast build,
integration, robustness, Phase 5 policy gate, and whole-tree formatting passed.
The regressions include the complete real-pool grow/evict/retire/reclaim/trim/
readmit cycle with three levels and a nonempty coarsest fallback.

A new ordinary-source Low stationary five-second smoke completed with 3893
frames, 778.4 average FPS, 1.285 ms average CPU/frame time, 1.389/1.458 ms p95/p99
frame times, and 0.931 ms average GPU total (0.00036 ms shadow, 0.724 ms opaque).
It averaged 506 draw calls, 716544 vertices, and 113 full-detail chunks. Artifact:
`zig-out/lod-recovery-benchmark-smoke.json`. Different retained LOD coverage and
unknown adapter provenance prevent treating this as an equal-quality speedup.

Remaining accounting limits are explicit: worker allocation concurrency and
allocations outside the LOD resource adapters do not have a strict global peak
reservation contract. The RHI's void destruction callback is assumed to accept retirement;
backend deletion-queue OOM behavior is not qualified by these tests. Admission
refresh currently scans known allocations after upload attempts; incremental
accounting is a future optimization, not a reason to undercount retained memory.

## Historical: Near-Source Service Scheduling

LOD admission, generation/mesh lifecycle queues, worker dequeue, and uploads now
use persistent weighted service turns. This policy applies to LOD scheduling;
the block-derived source experiment remains separately opt-in. Ordinary engine
job queues retain their existing priority behavior unless explicitly enabled.

| Lane | Purpose | Turns Per Wheel |
| --- | --- | --- |
| Local fallback | Coarsest footprints near the detailed area | 1 |
| Near0 | Nearby LOD0 refinement | 1 |
| Near1 | Nearby LOD1 refinement | 1 |
| Horizon | Remaining concentric coarsest expansion | 2 |
| Refinement | Other levels and distant portions of LOD0/1 | 1 |

The wheel is `{local, near0, horizon, near1, refinement, horizon}`. Empty lanes
yield. Full pending/token capacity does not consume the next admission turn.
The local window intersects inclusive region footprints with configured detail
radius plus four chunks, clamped to each level's pressure-reduced radius. It
uses independent scan cursors, so a large horizon or large outer near-level
radius cannot delay local discovery until an outer scan wraps. This is the
configured detail boundary, not the smaller temporary startup radius.

Admission remains bounded to 64 successes and 512 examined coordinates per
class per heavy update, with shared pending and logical-memory caps. Worker and
lifecycle queues use queue-owned FIFO tickets within each enabled lane. Uploads
also rotate levels within a lane; a stream of small LOD0 uploads cannot hide an
older LOD3 refinement indefinitely. An oversized staging candidate that yields
can receive one owed opportunity on the next call, after key/token/revision and
memory revalidation. That exception never overrides backing-memory admission.

### Resource Service

Scheduling fairness alone did not preserve the runtime target: distant
allocations could still consume its headroom. Horizon and ordinary-refinement
lanes now use a 75% soft memory limit, reserving the remaining quarter for local
fallback and near lanes. The unchanged full hard cap applies to everyone.
Zero-growth uploads may drain pending CPU data above the soft limit.

Background uploads parked solely at this soft limit do not prevent nearby
radius recovery. Their memory remains fully charged; active jobs, hard denials,
retirements, inconsistent counts, and the existing cooldown still block recovery.

A fresh unpooled near mesh may choose the existing dedicated-buffer route if
its own rounded allocation fits but a shared-pool replacement peak does not.
This choice is sticky for retries, never converts a live pooled range, and is
planned before both hard/soft checks. Normal uploads remain pooled. Dedicated
LOD buffers now have retirement tracking too: failed temporary uploads,
replacements, and destruction retain GPU debt until the actual frame-slot fence
completes. Active buffers remain mesh-accounted, without double-counting.

`LODStats.service` exposes lifetime admissions, accepted dispatches, validated
worker starts, and renderable publications per lane. Publications include
remeshes and empty results; they are not counts of unique visible regions.
Capture evidence separately verifies the target's current drawable geometry.

### Service Evidence

```bash
ZIGCRAFT_LOD_FIDELITY_HORIZON_CHUNKS=256 \
ZIGCRAFT_LOD_FIDELITY_MEMORY_MB=256 \
  bash scripts/run_lod_fidelity_capture.sh on
```

The existing forest pose, natural warmup, retreat, and target remain unchanged.
Valid horizon overrides from 64 through 512 chunks select five-level service
mode; missing or invalid overrides retain the 24-chunk local reference. Service
mode defaults to 256 MiB rather than the local reference's 1 GiB. Logs and the
wrapper verify effective values and retain `qualified=0`.

The 256-chunk (4096-block) horizon run at 256 MiB passed the target gate and
latched progress from both near lanes while horizon work remained pending, with
positive horizon progress as well. A longer ReleaseSafe run with explicit
Khronos validation and a 20-second screenshot delay also passed without
validation errors. Its final target retained all 4096 measured interior columns;
accounted LOD memory was 228111064 bytes (about 217.5 MiB). At that snapshot,
131 horizon-lane regions were renderable and 26 horizon uploads remained pending.
Those parked uploads are resource backpressure, not a fully loaded horizon.

Local artifacts:

- `screenshots/lod-fidelity/run-20260906T162031Z-2840984-on/lod-forest.png`
- `screenshots/lod-fidelity/service-validation-256.png`
- `logs/lod-service-horizon-fallback.log`
- `logs/lod-service-validation.log`

Deterministic tests execute the real scheduler, lifecycle queues, job dequeue,
generation/meshing callbacks, and mock upload completion. Under the test's
bounded workload (two jobs and one upload per simulated tick), both near bands
and horizon work become renderable within 256 ticks, including fresh demand
after saturation and movement to negative coordinates. Separate regressions
cover one-slot token backpressure, cross-level upload starvation, owed staging,
memory reserves, and dedicated retirement debt.

Final Debug and ReleaseSafe runs each pass 707 tests, including 309 world-lod
tests, with 31/31 build steps. ReleaseFast build, integration, robustness, Phase 5
policy gate, and formatting also pass. The local 256 MiB capture remains valid.

An ordinary Low-preset, original-source traversal smoke completed for ten seconds
at 1920x1080: 18659 frames, reported average 1865.9 FPS, 0.536 ms CPU/frame,
1.255/1.497 ms p95/p99 frame times, and 0.359 ms average GPU total (0.000195 ms
shadow, 0.250 ms opaque). It averaged 256.8 draw calls, 764464 vertices, and about
113 full-detail chunks. Artifact: `zig-out/lod-service-benchmark-traversal.json`.
This output contains zero-GPU timing samples and unknown adapter provenance;
it is smoke evidence, not a reliable speedup or equal-quality comparison.

The service contract is bounded opportunities for eligible, feasible work, not
a millisecond deadline or unconditional per-region completion guarantee. Finite
discovery, non-preemptive jobs, resource feasibility, retries, and cancellation
still matter. Lanes describe admission-time locality. Worker allocation peaks
and the entire requested horizon are not qualified by this capture, and the
soft reserve may deliberately halt distant expansion to protect near work.

## Historical Roadmap (superseded by the canonical work above)

### 1. Finish Near-Field Acceptance

Add full-detail reference images at matched poses, multiple tree families,
cliffs, water, and edited terrain. Preserve material run depths and stronger
neighbor boundaries. Replace filled canopy envelopes if silhouette evidence
requires real interval runs. Do not enable the prototype by default yet.

### 2. Qualify Near Service at Scale

Pool recovery and end-to-end service lanes are implemented and locally verified
above. Qualify longer traversal, repeated budget changes, compact/GPU-culling
paths, and saved-world reloads. Preserve accurate capacity/debt accounting while
reducing the cost of reconciliation and extending peak reservations to workers
and other allocation paths.

### 3. Build the Authoritative Hierarchy

The RLE canonical hierarchy now supplies the direct reduction and deterministic
ownership portion of this item. Trustworthy unvisited-territory authority and
visual qualification remain open; a procedural summary is still only an
optimization, not an independently defined landscape.

### 4. Persist Scene Identity

Saved-source revisions, nonresident reconstruction, cache-loss repair, and
authoritative emptiness are implemented for the bounded canonical path. Broader
shipping qualification across saves, generators, and runtime conditions remains
open.

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
