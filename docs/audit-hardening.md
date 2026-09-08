# Audit Hardening

Implementation and verification record for `bug/audit-hardening`, based on
`origin/dev` at `4d66dfe2`. No feature retirement or release approval is implied.

## Implemented

- Persistent menu launches carry their selected save directory. Diagnostic
  environment overrides do not redirect library worlds.
- Persistence initializes before origin warmup. Saved chunks load before
  generation; corrupt or unreadable saves are not regenerated or overwritten.
- World shutdown joins worker consumers before destroying persistence. Audio
  manager teardown preserves its allocator before freeing the audio system.
- Save acceptance is fallible and bounded. Rejected chunks remain dirty;
  accepted failed snapshots survive eviction and remain retryable. Partial
  failures do not prevent later healthy shutdown batches from being saved.
- Region replacement uses fresh sectors and a recoverable undo journal.
  World metadata and settings use synced temporary-file replacement.
- Meshing reads private snapshots captured under the same synchronization as
  writers. Chunk pins, job tokens, and revision checks protect publication.
- Canceled or failed lighting work remains invalid for persistence. Rebuilds
  retain illumination entering from valid external chunks and rebuild invalid
  dependencies rather than publishing stale lighting.
- Draw batches retain distinct instance and indirect-buffer contents. Bound
  descriptor snapshots are immutable until the owning frame fence retires.
- LPV resizing replaces all grid-dependent resources transactionally. Aborted
  LPV/TAA recordings are invalidated; terminal frame failures quarantine their
  slots instead of recycling possibly pending resources.
- Water sample counts match the main render pass. G-pass rasterization and
  alpha-to-coverage no longer inherit terrain variant settings. TAA defaults,
  output synchronization, and initial resolution state are corrected.
- Vulkan construction unwinds completed ownership stages. Fence, submission,
  and startup errors cannot silently permit frame-slot reuse.
- Settings application has one authoritative mapping shared by startup,
  presets, and individual UI edits.
- Module tests use direct roots and file-relative imports. Named discovery is
  reported explicitly; a filter selecting no named tests fails.
- Ordinary builds validate shader freshness without overwriting tracked
  artifacts. Every runtime shader binary is versioned so fresh clones do not
  depend on ignored local outputs. Regeneration is explicit and fail-fast.
- The unsafe out-of-bounds transfer demo is replaced by a legal guarded
  transfer/readback smoke. Submission error tests call the production boundary.
- Privileged AI review uses trusted-base tooling, tool-free review input, and
  separate publication. Missing screenshots, invalid benchmark artifacts, and
  unusable coverage are no longer reported as successful verification.
- Coverage requests LLVM only for direct unit-test executables. Ordinary
  builds retain their default compiler backend. Native Debug's incomplete kcov
  mapping is not accepted as a coverage baseline.
- Contribution commands, pre-push formatting scope, release requirements,
  sanitizer terminology, and source-size reporting are corrected.
- Removed the unexported Vec4 source and two unused Vulkan forwarding files
  (49 source lines), including their discovery and automation references.

## Verified

Verification was performed on Linux with Zig 0.16.0 through devenv. Graphics
used isolated Weston/pixman, Lavapipe 26.1.4, validation layers 1.4.328, and a
temporary home directory, without visible windows or user-save access.

| Check | Result |
| --- | --- |
| Format and whitespace checks | Passed |
| Debug unit suite | 1,917/1,917 passed |
| ReleaseSafe unit suite | 1,917/1,917 passed |
| Named discovery | 1,890 named tests across 31 roots |
| Empty named filter | Rejected as intended |
| ReleaseFast build | Passed |
| Shader freshness, size, and shadow ABI checks | Passed |
| Offscreen integration | 4/4 passed; zero Vulkan validation errors |
| Guarded transfer/readback smoke | Passed |
| Flat-world screenshot | Captured and inspected |
| Actionlint and ShellCheck | Passed |
| CI verification regressions | 22/22 passed |
| LLVM-backed kcov collection | 31 executables completed and report validated |

The graphics integration covers saved-origin reload, active LPV resizing through
32- and 64-cell grids, MSAA pipeline recreation, real terrain draws, uploads
across frame-slot reuse, replacement during drawing, and early/late quit paths.
Validation uses the application's stderr callback so layer text does not corrupt
Zig's binary test protocol on stdout.

The measured line-coverage result is **21,485 / 27,431 instrumented project lines
(78.32%) across 282 files**. It includes test code and only lines emitted into
the test executables. It is not coverage of every maintained source file, and
kcov's placeholder branch fields are not a branch-coverage measurement.

## Remaining Scope

- Choosing one live menu implementation, removing alternate world generators,
  and retiring diagnostic tools or unreferenced media require explicit scope
  decisions. They were not silently deleted to reduce line counts.
- The larger physical package extraction, gameplay/presentation separation,
  and further interface segregation remain incremental architectural work.
  Import/export repairs and centralized settings policy do not constitute a
  complete SOLID redesign.
- Optional UI dependency trimming needs an explicit supported profile matrix.
  Existing profiles retain their current feature support.
- Region storage is append-only pending compaction. Same-world concurrent
  processes are not supported. Directory-entry power-loss durability is not
  guaranteed without parent-directory syncing.
- A permanently unwritable filesystem cannot make accepted in-memory edits
  durable. Such shutdown failures are reported, not relabeled as successful
  saves; process termination cannot preserve failed in-memory snapshots.
- The transfer smoke does not establish shader out-of-bounds robustness,
  recovery from driver hangs, or physical-GPU performance. Hardware testing,
  longer concurrency stress, and fault injection remain useful release work.
- Live provider review, hosted CI execution, branch-protection settings, and
  release packaging were not exercised by this local verification. Retiring a
  required legacy `ai-merge-gate` check requires repository-owner action.
- Placeholder-asset redistribution rights and replacement artwork remain a
  release requirement; see [the release checklist](release-checklist.md).
