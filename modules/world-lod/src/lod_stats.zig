//! LOD system statistics and aggregation helpers.

const std = @import("std");
const MonotonicTimer = @import("engine-core").time.MonotonicTimer;
const lod_types = @import("lod_types.zig");
const LODLevel = lod_types.LODLevel;
const LODState = lod_types.LODState;

/// Device-wide waits are never an ordinary streaming operation. Keep their
/// shutdown accounting separate so runtime streaming telemetry cannot be
/// made to look healthy by including teardown-only synchronization.
pub const LODWaitIdleReason = enum(u8) {
    streaming,
    shutdown,
};

/// Read-only LOD profiling data. Durations are cumulative CPU timings; memory
/// fields are current known allocations rather than GPU-driver measurements.
pub const LODProfilingSnapshot = struct {
    enabled: bool = false,
    update_ms: f64 = 0,
    scheduling_ms: f64 = 0,
    /// Cumulative dedicated cache-worker CPU/I/O time. This is intentionally
    /// not update-thread blocking time; frame work only queues and drains.
    cache_ms: f64 = 0,
    generation_dispatch_ms: f64 = 0,
    state_transition_ms: f64 = 0,
    upload_prep_ms: f64 = 0,
    upload_submission_ms: f64 = 0,
    visibility_ms: f64 = 0,
    coverage_ms: f64 = 0,
    eviction_ms: f64 = 0,
    worker_generation_ms: f64 = 0,
    worker_mesh_construction_ms: f64 = 0,
    /// Successful LOD3/LOD4 expanded CPU mesh builds performed by workers.
    worker_far_expanded_mesh_construction_ms: f64 = 0,
    /// Successful LOD3/LOD4 compact tile encodes performed by workers.
    worker_compact_encode_ms: f64 = 0,
    manager_lock_wait_ms: f64 = 0,
    manager_lock_hold_ms: f64 = 0,
    upload_bytes: u64 = 0,
    /// Successful LOD3/LOD4 representation uploads. These deliberately omit
    /// near pooled geometry and failed/retried submissions.
    far_expanded_upload_bytes: u64 = 0,
    compact_upload_bytes: u64 = 0,
    pending_cpu_upload_bytes: u64 = 0,
    /// Upload-budget deferrals plus RHI upload-pressure errors.
    staging_pressure_count: u64 = 0,
    visible_count: u64 = 0,
    rejected_count: u64 = 0,
    coverage_count: u64 = 0,
    /// Per-LOD visibility projection telemetry. These counters are cumulative
    /// and count a region once, even when terrain and water are both drawn.
    visibility_levels: [LODLevel.count]LODVisibilityLevelSnapshot = [_]LODVisibilityLevelSnapshot{.{}} ** LODLevel.count,
    /// Current known GPU allocation bytes retained by meshes awaiting destruction.
    deferred_deletion_bytes: u64 = 0,
    deferred_deletion_cpu_bytes: u64 = 0,
    pool_gpu_capacity_bytes: u64 = 0,
    pool_gpu_retired_bytes: u64 = 0,
    direct_gpu_retired_bytes: u64 = 0,
    pool_gpu_allocated_bytes: u64 = 0,
    pool_gpu_slack_bytes: u64 = 0,
    pool_cpu_shadow_bytes: u64 = 0,
    compact_pool_capacity_bytes: u64 = 0,
    compact_pool_allocated_bytes: u64 = 0,
    compact_pool_free_bytes: u64 = 0,
    compact_pool_retired_bytes: u64 = 0,
    direct_mesh_gpu_bytes: u64 = 0,
    known_memory_bytes: u64 = 0,
    wait_idle_count: u64 = 0,
    wait_idle_ms: f64 = 0,
    wait_idle_shutdown_count: u64 = 0,
    wait_idle_shutdown_ms: f64 = 0,
    /// Compact LOD lifecycle diagnostics. These are cumulative and let
    /// production evidence distinguish selection from runtime fallback.
    compact_selected: u64 = 0,
    compact_build_rejected: u64 = 0,
    compact_upload_failures: u64 = 0,
    compact_draw_unavailable: u64 = 0,
    compact_draw_failures: u64 = 0,
    /// Confirmed compact direct draws plus successfully emitted compact GPU
    /// indirect streams. This is evidence of submission, not allocation.
    compact_submissions: u64 = 0,
    compact_recoveries: u64 = 0,
    compact_disabled: u64 = 0,
    /// GPU-culling telemetry is renderer-owned and deliberately persistent:
    /// manager/UI frame-stat resets must not erase benchmark evidence.
    gpu_culling_requested: bool = false,
    gpu_culling_threshold: u32 = 0,
    gpu_culling_candidate_count: u32 = 0,
    gpu_culling_candidate_count_max: u32 = 0,
    gpu_culling_draw_submissions: u64 = 0,
    gpu_culling_overflows: u32 = 0,
    gpu_culling_validation_mismatches: u32 = 0,
    gpu_culling_validation_generation: u64 = 0,
    gpu_culling_validation_completed_generation: u64 = 0,
    gpu_culling_validation_completed_count: u64 = 0,
};

pub const LODVisibilityLevelSnapshot = struct {
    candidates: u64 = 0,
    accepted: u64 = 0,
    rejected_no_draw: u64 = 0,
    rejected_not_ready: u64 = 0,
    rejected_missing_region: u64 = 0,
    rejected_not_renderable: u64 = 0,
    rejected_finer_coverage: u64 = 0,
    rejected_range: u64 = 0,
    rejected_frustum: u64 = 0,
    rejected_chunk_coverage: u64 = 0,
    coverage_checks: u64 = 0,
};

const LODVisibilityLevelCounters = struct {
    candidates: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_no_draw: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_not_ready: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_missing_region: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_not_renderable: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_finer_coverage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_range: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_frustum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_chunk_coverage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coverage_checks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn add(self: *LODVisibilityLevelCounters, value: LODVisibilityLevelSnapshot) void {
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            const amount = @field(value, field.name);
            if (amount != 0) _ = @field(self, field.name).fetchAdd(amount, .monotonic);
        }
    }

    fn reset(self: *LODVisibilityLevelCounters) void {
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            @field(self, field.name).store(0, .monotonic);
        }
    }

    fn snapshot(self: *const LODVisibilityLevelCounters) LODVisibilityLevelSnapshot {
        var result = LODVisibilityLevelSnapshot{};
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            @field(result, field.name) = @field(self, field.name).load(.monotonic);
        }
        return result;
    }
};

/// Thread-safe backing store for an `LODProfilingSnapshot`.
///
/// Profiling is enabled once when an LOD manager is initialized. All timing
/// methods return before touching a clock when disabled, while worker updates
/// use atomics so they never race snapshot collection on the update thread.
pub const LODProfilingCollector = struct {
    const AtomicU64 = std.atomic.Value(u64);

    pub const TimerKind = enum {
        update,
        scheduling,
        cache,
        generation_dispatch,
        state_transition,
        upload_prep,
        upload_submission,
        visibility,
        coverage,
        eviction,
        worker_generation,
        worker_mesh_construction,
        worker_far_expanded_mesh_construction,
        worker_compact_encode,
        manager_lock_wait,
        manager_lock_hold,
        wait_idle,
    };

    enabled: bool = false,
    update_ns: AtomicU64 = AtomicU64.init(0),
    scheduling_ns: AtomicU64 = AtomicU64.init(0),
    cache_ns: AtomicU64 = AtomicU64.init(0),
    generation_dispatch_ns: AtomicU64 = AtomicU64.init(0),
    state_transition_ns: AtomicU64 = AtomicU64.init(0),
    upload_prep_ns: AtomicU64 = AtomicU64.init(0),
    upload_submission_ns: AtomicU64 = AtomicU64.init(0),
    visibility_ns: AtomicU64 = AtomicU64.init(0),
    coverage_ns: AtomicU64 = AtomicU64.init(0),
    eviction_ns: AtomicU64 = AtomicU64.init(0),
    worker_generation_ns: AtomicU64 = AtomicU64.init(0),
    worker_mesh_construction_ns: AtomicU64 = AtomicU64.init(0),
    worker_far_expanded_mesh_construction_ns: AtomicU64 = AtomicU64.init(0),
    worker_compact_encode_ns: AtomicU64 = AtomicU64.init(0),
    manager_lock_wait_ns: AtomicU64 = AtomicU64.init(0),
    manager_lock_hold_ns: AtomicU64 = AtomicU64.init(0),
    wait_idle_ns: AtomicU64 = AtomicU64.init(0),
    upload_bytes: AtomicU64 = AtomicU64.init(0),
    far_expanded_upload_bytes: AtomicU64 = AtomicU64.init(0),
    compact_upload_bytes: AtomicU64 = AtomicU64.init(0),
    pending_cpu_upload_bytes: AtomicU64 = AtomicU64.init(0),
    staging_pressure_count: AtomicU64 = AtomicU64.init(0),
    visible_count: AtomicU64 = AtomicU64.init(0),
    rejected_count: AtomicU64 = AtomicU64.init(0),
    coverage_count: AtomicU64 = AtomicU64.init(0),
    visibility_levels: [LODLevel.count]LODVisibilityLevelCounters = [_]LODVisibilityLevelCounters{.{}} ** LODLevel.count,
    deferred_deletion_bytes: AtomicU64 = AtomicU64.init(0),
    deferred_deletion_cpu_bytes: AtomicU64 = AtomicU64.init(0),
    pool_gpu_capacity_bytes: AtomicU64 = AtomicU64.init(0),
    pool_gpu_retired_bytes: AtomicU64 = AtomicU64.init(0),
    direct_gpu_retired_bytes: AtomicU64 = AtomicU64.init(0),
    pool_gpu_allocated_bytes: AtomicU64 = AtomicU64.init(0),
    pool_gpu_slack_bytes: AtomicU64 = AtomicU64.init(0),
    pool_cpu_shadow_bytes: AtomicU64 = AtomicU64.init(0),
    compact_pool_capacity_bytes: AtomicU64 = AtomicU64.init(0),
    compact_pool_allocated_bytes: AtomicU64 = AtomicU64.init(0),
    compact_pool_free_bytes: AtomicU64 = AtomicU64.init(0),
    compact_pool_retired_bytes: AtomicU64 = AtomicU64.init(0),
    direct_mesh_gpu_bytes: AtomicU64 = AtomicU64.init(0),
    known_memory_bytes: AtomicU64 = AtomicU64.init(0),
    wait_idle_count: AtomicU64 = AtomicU64.init(0),
    wait_idle_shutdown_count: AtomicU64 = AtomicU64.init(0),
    wait_idle_shutdown_ns: AtomicU64 = AtomicU64.init(0),
    compact_selected: AtomicU64 = AtomicU64.init(0),
    compact_build_rejected: AtomicU64 = AtomicU64.init(0),
    compact_upload_failures: AtomicU64 = AtomicU64.init(0),
    compact_draw_unavailable: AtomicU64 = AtomicU64.init(0),
    compact_draw_failures: AtomicU64 = AtomicU64.init(0),
    compact_submissions: AtomicU64 = AtomicU64.init(0),
    compact_recoveries: AtomicU64 = AtomicU64.init(0),
    compact_disabled: AtomicU64 = AtomicU64.init(0),
    gpu_culling_requested: AtomicU64 = AtomicU64.init(0),
    gpu_culling_threshold: AtomicU64 = AtomicU64.init(0),
    gpu_culling_candidate_count: AtomicU64 = AtomicU64.init(0),
    gpu_culling_candidate_count_max: AtomicU64 = AtomicU64.init(0),
    gpu_culling_draw_submissions: AtomicU64 = AtomicU64.init(0),
    gpu_culling_overflows: AtomicU64 = AtomicU64.init(0),
    gpu_culling_validation_mismatches: AtomicU64 = AtomicU64.init(0),
    gpu_culling_validation_generation: AtomicU64 = AtomicU64.init(0),
    gpu_culling_validation_completed_generation: AtomicU64 = AtomicU64.init(0),
    gpu_culling_validation_completed_count: AtomicU64 = AtomicU64.init(0),

    pub fn init(enabled: bool) LODProfilingCollector {
        return .{ .enabled = enabled };
    }

    pub fn begin(self: *const LODProfilingCollector) ?MonotonicTimer {
        if (!self.enabled) return null;
        return MonotonicTimer.start();
    }

    pub fn end(self: *LODProfilingCollector, kind: TimerKind, timer: ?MonotonicTimer) void {
        const elapsed = timer orelse return;
        _ = self.counterFor(kind).fetchAdd(elapsed.read(), .monotonic);
    }

    pub fn add(self: *LODProfilingCollector, counter: *AtomicU64, value: u64) void {
        if (!self.enabled or value == 0) return;
        _ = counter.fetchAdd(value, .monotonic);
    }

    pub fn addUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.upload_bytes, @intCast(bytes));
    }

    pub fn addFarExpandedUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.far_expanded_upload_bytes, @intCast(bytes));
    }

    pub fn addCompactUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.compact_upload_bytes, @intCast(bytes));
    }

    pub fn setPendingCpuUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled) return;
        self.pending_cpu_upload_bytes.store(@intCast(bytes), .monotonic);
    }

    pub fn setRetiredPoolGpuBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled) return;
        self.pool_gpu_retired_bytes.store(@intCast(bytes), .monotonic);
    }

    pub fn setRetiredDirectGpuBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled) return;
        self.direct_gpu_retired_bytes.store(@intCast(bytes), .monotonic);
    }

    pub fn setMemoryAccounting(self: *LODProfilingCollector, pool_gpu_capacity: usize, pool_gpu_allocated: usize, pool_gpu_slack: usize, pool_cpu_shadow: usize, compact_pool_capacity: usize, compact_pool_allocated: usize, compact_pool_free: usize, compact_pool_retired: usize, direct_mesh_gpu: usize, known_memory: usize) void {
        if (!self.enabled) return;
        self.pool_gpu_capacity_bytes.store(@intCast(pool_gpu_capacity), .monotonic);
        self.pool_gpu_allocated_bytes.store(@intCast(pool_gpu_allocated), .monotonic);
        self.pool_gpu_slack_bytes.store(@intCast(pool_gpu_slack), .monotonic);
        self.pool_cpu_shadow_bytes.store(@intCast(pool_cpu_shadow), .monotonic);
        self.compact_pool_capacity_bytes.store(@intCast(compact_pool_capacity), .monotonic);
        self.compact_pool_allocated_bytes.store(@intCast(compact_pool_allocated), .monotonic);
        self.compact_pool_free_bytes.store(@intCast(compact_pool_free), .monotonic);
        self.compact_pool_retired_bytes.store(@intCast(compact_pool_retired), .monotonic);
        self.direct_mesh_gpu_bytes.store(@intCast(direct_mesh_gpu), .monotonic);
        self.known_memory_bytes.store(@intCast(known_memory), .monotonic);
    }

    pub fn addStagingPressure(self: *LODProfilingCollector) void {
        self.add(&self.staging_pressure_count, 1);
    }

    pub fn addVisible(self: *LODProfilingCollector) void {
        self.add(&self.visible_count, 1);
    }

    pub fn addCompactSelected(self: *LODProfilingCollector) void {
        self.add(&self.compact_selected, 1);
    }

    pub fn addCompactBuildRejected(self: *LODProfilingCollector) void {
        self.add(&self.compact_build_rejected, 1);
    }

    pub fn addCompactUploadFailure(self: *LODProfilingCollector) void {
        self.add(&self.compact_upload_failures, 1);
    }

    pub fn addCompactDrawUnavailable(self: *LODProfilingCollector) void {
        self.add(&self.compact_draw_unavailable, 1);
    }

    pub fn addCompactDrawFailure(self: *LODProfilingCollector) void {
        self.add(&self.compact_draw_failures, 1);
    }

    pub fn addCompactSubmission(self: *LODProfilingCollector) void {
        self.add(&self.compact_submissions, 1);
    }

    pub fn addCompactRecovery(self: *LODProfilingCollector) void {
        self.add(&self.compact_recoveries, 1);
    }

    pub fn addCompactDisabled(self: *LODProfilingCollector) void {
        self.add(&self.compact_disabled, 1);
    }

    pub fn setGpuCullingConfiguration(self: *LODProfilingCollector, requested: bool, threshold: usize) void {
        if (!self.enabled) return;
        self.gpu_culling_requested.store(@intFromBool(requested), .monotonic);
        self.gpu_culling_threshold.store(@min(threshold, std.math.maxInt(u32)), .monotonic);
    }

    /// Records the projection once per prepared frame, before terrain and water
    /// consume the same candidate stream.
    pub fn setGpuCullingCandidateCount(self: *LODProfilingCollector, count: usize) void {
        if (!self.enabled) return;
        const value: u64 = @min(count, std.math.maxInt(u32));
        self.gpu_culling_candidate_count.store(value, .monotonic);
        var observed = self.gpu_culling_candidate_count_max.load(.monotonic);
        while (observed < value) {
            observed = self.gpu_culling_candidate_count_max.cmpxchgWeak(observed, value, .monotonic, .monotonic) orelse break;
        }
    }

    /// Counts one successful GPU frame submission, rather than one terrain and
    /// one water stream, so paired layers cannot inflate benchmark evidence.
    pub fn addGpuCullingSubmission(self: *LODProfilingCollector) void {
        self.add(&self.gpu_culling_draw_submissions, 1);
    }

    pub fn setGpuCullingDiagnostics(self: *LODProfilingCollector, overflows: u32, mismatches: u32, generation: u64, completed_generation: u64, completed_count: u64) void {
        if (!self.enabled) return;
        self.gpu_culling_overflows.store(overflows, .monotonic);
        self.gpu_culling_validation_mismatches.store(mismatches, .monotonic);
        self.gpu_culling_validation_generation.store(generation, .monotonic);
        self.gpu_culling_validation_completed_generation.store(completed_generation, .monotonic);
        self.gpu_culling_validation_completed_count.store(completed_count, .monotonic);
    }

    pub fn addRejected(self: *LODProfilingCollector) void {
        self.add(&self.rejected_count, 1);
    }

    pub fn addCoverage(self: *LODProfilingCollector) void {
        self.add(&self.coverage_count, 1);
    }

    pub fn addVisibilityLevel(self: *LODProfilingCollector, lod: LODLevel, value: LODVisibilityLevelSnapshot) void {
        if (!self.enabled) return;
        self.visibility_levels[@intFromEnum(lod)].add(value);
    }

    pub fn addDeferredDeletionBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.deferred_deletion_bytes, @intCast(bytes));
    }

    pub fn removeDeferredDeletionBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled or bytes == 0) return;
        _ = self.deferred_deletion_bytes.fetchSub(@intCast(bytes), .monotonic);
    }

    pub fn addDeferredDeletionCpuBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.deferred_deletion_cpu_bytes, @intCast(bytes));
    }

    pub fn removeDeferredDeletionCpuBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled or bytes == 0) return;
        _ = self.deferred_deletion_cpu_bytes.fetchSub(@intCast(bytes), .monotonic);
    }

    /// Compatibility helper for a runtime/streaming wait with no measured
    /// duration. New call sites should use `recordWaitIdle`.
    pub fn addWaitIdle(self: *LODProfilingCollector) void {
        self.add(&self.wait_idle_count, 1);
    }

    pub fn recordWaitIdle(self: *LODProfilingCollector, reason: LODWaitIdleReason, timer: ?MonotonicTimer) void {
        if (!self.enabled) return;
        const elapsed = timer orelse return;
        switch (reason) {
            .streaming => {
                _ = self.wait_idle_count.fetchAdd(1, .monotonic);
                _ = self.wait_idle_ns.fetchAdd(elapsed.read(), .monotonic);
            },
            .shutdown => {
                _ = self.wait_idle_shutdown_count.fetchAdd(1, .monotonic);
                _ = self.wait_idle_shutdown_ns.fetchAdd(elapsed.read(), .monotonic);
            },
        }
    }

    /// Resets cumulative profiling counters. Concurrent worker completion may
    /// land immediately before or after this reset, but snapshots are always
    /// race-free and never contain torn values.
    pub fn reset(self: *LODProfilingCollector) void {
        self.pool_gpu_retired_bytes.store(0, .monotonic);
        self.direct_gpu_retired_bytes.store(0, .monotonic);
        inline for (.{
            &self.update_ns,                                &self.scheduling_ns,                     &self.cache_ns,
            &self.generation_dispatch_ns,                   &self.state_transition_ns,               &self.upload_prep_ns,
            &self.upload_submission_ns,                     &self.visibility_ns,                     &self.coverage_ns,
            &self.eviction_ns,                              &self.worker_generation_ns,              &self.worker_mesh_construction_ns,
            &self.worker_far_expanded_mesh_construction_ns, &self.worker_compact_encode_ns,          &self.manager_lock_wait_ns,
            &self.manager_lock_hold_ns,                     &self.wait_idle_ns,                      &self.upload_bytes,
            &self.far_expanded_upload_bytes,                &self.compact_upload_bytes,              &self.pending_cpu_upload_bytes,
            &self.staging_pressure_count,                   &self.visible_count,                     &self.rejected_count,
            &self.coverage_count,                           &self.deferred_deletion_bytes,           &self.deferred_deletion_cpu_bytes,
            &self.pool_gpu_capacity_bytes,                  &self.pool_gpu_allocated_bytes,          &self.pool_gpu_slack_bytes,
            &self.pool_cpu_shadow_bytes,                    &self.compact_pool_capacity_bytes,       &self.compact_pool_allocated_bytes,
            &self.compact_pool_free_bytes,                  &self.compact_pool_retired_bytes,        &self.direct_mesh_gpu_bytes,
            &self.known_memory_bytes,                       &self.wait_idle_count,                   &self.wait_idle_shutdown_count,
            &self.wait_idle_shutdown_ns,                    &self.compact_selected,                  &self.compact_build_rejected,
            &self.compact_upload_failures,                  &self.compact_draw_unavailable,          &self.compact_draw_failures,
            &self.compact_submissions,                      &self.compact_recoveries,                &self.compact_disabled,
            &self.gpu_culling_requested,                    &self.gpu_culling_threshold,             &self.gpu_culling_candidate_count,
            &self.gpu_culling_candidate_count_max,          &self.gpu_culling_draw_submissions,      &self.gpu_culling_overflows,
            &self.gpu_culling_validation_mismatches,        &self.gpu_culling_validation_generation, &self.gpu_culling_validation_completed_generation,
            &self.gpu_culling_validation_completed_count,
        }) |counter| counter.store(0, .monotonic);
        for (&self.visibility_levels) |*level| level.reset();
    }

    pub fn snapshot(self: *const LODProfilingCollector) LODProfilingSnapshot {
        return .{
            .enabled = self.enabled,
            .update_ms = nsToMs(self.update_ns.load(.monotonic)),
            .scheduling_ms = nsToMs(self.scheduling_ns.load(.monotonic)),
            .cache_ms = nsToMs(self.cache_ns.load(.monotonic)),
            .generation_dispatch_ms = nsToMs(self.generation_dispatch_ns.load(.monotonic)),
            .state_transition_ms = nsToMs(self.state_transition_ns.load(.monotonic)),
            .upload_prep_ms = nsToMs(self.upload_prep_ns.load(.monotonic)),
            .upload_submission_ms = nsToMs(self.upload_submission_ns.load(.monotonic)),
            .visibility_ms = nsToMs(self.visibility_ns.load(.monotonic)),
            .coverage_ms = nsToMs(self.coverage_ns.load(.monotonic)),
            .eviction_ms = nsToMs(self.eviction_ns.load(.monotonic)),
            .worker_generation_ms = nsToMs(self.worker_generation_ns.load(.monotonic)),
            .worker_mesh_construction_ms = nsToMs(self.worker_mesh_construction_ns.load(.monotonic)),
            .worker_far_expanded_mesh_construction_ms = nsToMs(self.worker_far_expanded_mesh_construction_ns.load(.monotonic)),
            .worker_compact_encode_ms = nsToMs(self.worker_compact_encode_ns.load(.monotonic)),
            .manager_lock_wait_ms = nsToMs(self.manager_lock_wait_ns.load(.monotonic)),
            .manager_lock_hold_ms = nsToMs(self.manager_lock_hold_ns.load(.monotonic)),
            .upload_bytes = self.upload_bytes.load(.monotonic),
            .far_expanded_upload_bytes = self.far_expanded_upload_bytes.load(.monotonic),
            .compact_upload_bytes = self.compact_upload_bytes.load(.monotonic),
            .pending_cpu_upload_bytes = self.pending_cpu_upload_bytes.load(.monotonic),
            .staging_pressure_count = self.staging_pressure_count.load(.monotonic),
            .visible_count = self.visible_count.load(.monotonic),
            .rejected_count = self.rejected_count.load(.monotonic),
            .coverage_count = self.coverage_count.load(.monotonic),
            .visibility_levels = blk: {
                var levels: [LODLevel.count]LODVisibilityLevelSnapshot = undefined;
                for (&levels, 0..) |*level, index| level.* = self.visibility_levels[index].snapshot();
                break :blk levels;
            },
            .deferred_deletion_bytes = self.deferred_deletion_bytes.load(.monotonic),
            .deferred_deletion_cpu_bytes = self.deferred_deletion_cpu_bytes.load(.monotonic),
            .pool_gpu_capacity_bytes = self.pool_gpu_capacity_bytes.load(.monotonic),
            .pool_gpu_retired_bytes = self.pool_gpu_retired_bytes.load(.monotonic),
            .direct_gpu_retired_bytes = self.direct_gpu_retired_bytes.load(.monotonic),
            .pool_gpu_allocated_bytes = self.pool_gpu_allocated_bytes.load(.monotonic),
            .pool_gpu_slack_bytes = self.pool_gpu_slack_bytes.load(.monotonic),
            .pool_cpu_shadow_bytes = self.pool_cpu_shadow_bytes.load(.monotonic),
            .compact_pool_capacity_bytes = self.compact_pool_capacity_bytes.load(.monotonic),
            .compact_pool_allocated_bytes = self.compact_pool_allocated_bytes.load(.monotonic),
            .compact_pool_free_bytes = self.compact_pool_free_bytes.load(.monotonic),
            .compact_pool_retired_bytes = self.compact_pool_retired_bytes.load(.monotonic),
            .direct_mesh_gpu_bytes = self.direct_mesh_gpu_bytes.load(.monotonic),
            .known_memory_bytes = self.known_memory_bytes.load(.monotonic),
            .wait_idle_count = self.wait_idle_count.load(.monotonic),
            .wait_idle_ms = nsToMs(self.wait_idle_ns.load(.monotonic)),
            .wait_idle_shutdown_count = self.wait_idle_shutdown_count.load(.monotonic),
            .wait_idle_shutdown_ms = nsToMs(self.wait_idle_shutdown_ns.load(.monotonic)),
            .compact_selected = self.compact_selected.load(.monotonic),
            .compact_build_rejected = self.compact_build_rejected.load(.monotonic),
            .compact_upload_failures = self.compact_upload_failures.load(.monotonic),
            .compact_draw_unavailable = self.compact_draw_unavailable.load(.monotonic),
            .compact_draw_failures = self.compact_draw_failures.load(.monotonic),
            .compact_submissions = self.compact_submissions.load(.monotonic),
            .compact_recoveries = self.compact_recoveries.load(.monotonic),
            .compact_disabled = self.compact_disabled.load(.monotonic),
            .gpu_culling_requested = self.gpu_culling_requested.load(.monotonic) != 0,
            .gpu_culling_threshold = @intCast(self.gpu_culling_threshold.load(.monotonic)),
            .gpu_culling_candidate_count = @intCast(self.gpu_culling_candidate_count.load(.monotonic)),
            .gpu_culling_candidate_count_max = @intCast(self.gpu_culling_candidate_count_max.load(.monotonic)),
            .gpu_culling_draw_submissions = self.gpu_culling_draw_submissions.load(.monotonic),
            .gpu_culling_overflows = @intCast(self.gpu_culling_overflows.load(.monotonic)),
            .gpu_culling_validation_mismatches = @intCast(self.gpu_culling_validation_mismatches.load(.monotonic)),
            .gpu_culling_validation_generation = self.gpu_culling_validation_generation.load(.monotonic),
            .gpu_culling_validation_completed_generation = self.gpu_culling_validation_completed_generation.load(.monotonic),
            .gpu_culling_validation_completed_count = self.gpu_culling_validation_completed_count.load(.monotonic),
        };
    }

    fn counterFor(self: *LODProfilingCollector, kind: TimerKind) *AtomicU64 {
        return switch (kind) {
            .update => &self.update_ns,
            .scheduling => &self.scheduling_ns,
            .cache => &self.cache_ns,
            .generation_dispatch => &self.generation_dispatch_ns,
            .state_transition => &self.state_transition_ns,
            .upload_prep => &self.upload_prep_ns,
            .upload_submission => &self.upload_submission_ns,
            .visibility => &self.visibility_ns,
            .coverage => &self.coverage_ns,
            .eviction => &self.eviction_ns,
            .worker_generation => &self.worker_generation_ns,
            .worker_mesh_construction => &self.worker_mesh_construction_ns,
            .worker_far_expanded_mesh_construction => &self.worker_far_expanded_mesh_construction_ns,
            .worker_compact_encode => &self.worker_compact_encode_ns,
            .manager_lock_wait => &self.manager_lock_wait_ns,
            .manager_lock_hold => &self.manager_lock_hold_ns,
            .wait_idle => &self.wait_idle_ns,
        };
    }
};

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

/// Statistics for LOD system monitoring.
pub const LODStats = struct {
    /// Lifetime progress by admission lane, independent of per-frame resets.
    service: @import("lod_service.zig").Snapshot = .{},
    /// Cumulative opt-in CPU, upload, and pressure telemetry snapshot.
    profiling: LODProfilingSnapshot = .{},
    loaded: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generating: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generated: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    meshing: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_ready: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    uploading: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,

    memory_used_mb: u32 = 0,
    /// Exact known LOD CPU/GPU allocation total. `memory_used_mb` is retained
    /// for compatibility and is this value rounded down to MiB.
    memory_used_bytes: u64 = 0,
    pool_gpu_capacity_bytes: u64 = 0,
    pool_gpu_retired_bytes: u64 = 0,
    direct_gpu_retired_bytes: u64 = 0,
    pool_gpu_allocated_bytes: u64 = 0,
    pool_gpu_slack_bytes: u64 = 0,
    pool_cpu_shadow_bytes: u64 = 0,
    compact_pool_capacity_bytes: u64 = 0,
    compact_pool_allocated_bytes: u64 = 0,
    compact_pool_free_bytes: u64 = 0,
    compact_pool_retired_bytes: u64 = 0,
    direct_mesh_gpu_bytes: u64 = 0,
    source_data_cpu_bytes: u64 = 0,
    resident_region_count: u64 = 0,
    /// Unused capacity reserved for the canonical immutable-source cache. The
    /// cache can fill asynchronously while a region is building, so admission
    /// must reserve its configured capacity rather than only sampling bytes.
    source_cache_reservation_bytes: u64 = 0,
    logical_admission_reservation_bytes: u64 = 0,
    logical_admission_bytes: u64 = 0,
    pending_cpu_upload_bytes: u64 = 0,
    deferred_deletion_gpu_bytes: u64 = 0,
    deferred_deletion_cpu_bytes: u64 = 0,
    mesh_count: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_vertices: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    gen_queue_depth: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    upload_queue_depth: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    /// On-disk LOD source store counters. cache_* below are retained as
    /// compatibility aliases for existing diagnostics consumers.
    store_hits: u32 = 0,
    store_misses: u32 = 0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    evictions: u32 = 0,
    drawn: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    instances: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    fluid_drawn: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    fluid_instances: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    /// Candidate counts submitted to device-local LOD compute streams. These
    /// deliberately do not require a same-frame readback of compacted counts.
    gpu_terrain_candidates: u32 = 0,
    gpu_fluid_candidates: u32 = 0,
    gpu_culling_requested: bool = false,
    gpu_culling_threshold: u32 = 0,
    gpu_culling_candidate_count: u32 = 0,
    gpu_culling_draw_submissions: u32 = 0,
    gpu_culling_overflows: u32 = 0,
    gpu_culling_validation_mismatches: u32 = 0,
    gpu_culling_validation_generation: u64 = 0,
    gpu_culling_validation_completed_generation: u64 = 0,
    gpu_culling_validation_completed_count: u64 = 0,
    ingestion_backlog: u32 = 0,
    upgrades_pending: u32 = 0,
    downgrades_pending: u32 = 0,
    upload_failures: u32 = 0,
    /// Lifecycle tokens accepted into bounded overflow heaps. These are
    /// observable pressure counters; overflow tokens are still immediately
    /// prioritized for consumption rather than being dropped.
    generation_token_overflows: u64 = 0,
    transition_token_overflows: u64 = 0,
    fade_token_overflows: u64 = 0,
    /// Worker and queued jobs invalidated before stale results could publish.
    cancelled_jobs: u32 = 0,

    pub fn totalLoaded(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.loaded) |count| total += count;
        return total;
    }

    pub fn totalGenerating(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.generating) |count| total += count;
        return total;
    }

    pub fn reset(self: *LODStats) void {
        self.profiling = .{};
        self.loaded = [_]u32{0} ** LODLevel.count;
        self.generating = [_]u32{0} ** LODLevel.count;
        self.generated = [_]u32{0} ** LODLevel.count;
        self.meshing = [_]u32{0} ** LODLevel.count;
        self.mesh_ready = [_]u32{0} ** LODLevel.count;
        self.uploading = [_]u32{0} ** LODLevel.count;
        self.memory_used_mb = 0;
        self.memory_used_bytes = 0;
        self.pool_gpu_capacity_bytes = 0;
        self.pool_gpu_retired_bytes = 0;
        self.direct_gpu_retired_bytes = 0;
        self.pool_gpu_allocated_bytes = 0;
        self.pool_gpu_slack_bytes = 0;
        self.pool_cpu_shadow_bytes = 0;
        self.compact_pool_capacity_bytes = 0;
        self.compact_pool_allocated_bytes = 0;
        self.compact_pool_free_bytes = 0;
        self.compact_pool_retired_bytes = 0;
        self.direct_mesh_gpu_bytes = 0;
        self.source_data_cpu_bytes = 0;
        self.resident_region_count = 0;
        self.source_cache_reservation_bytes = 0;
        self.logical_admission_reservation_bytes = 0;
        self.logical_admission_bytes = 0;
        self.pending_cpu_upload_bytes = 0;
        self.deferred_deletion_gpu_bytes = 0;
        self.deferred_deletion_cpu_bytes = 0;
        self.mesh_count = [_]u32{0} ** LODLevel.count;
        self.mesh_vertices = [_]u32{0} ** LODLevel.count;
        self.gen_queue_depth = [_]u32{0} ** LODLevel.count;
        self.upload_queue_depth = [_]u32{0} ** LODLevel.count;
        self.drawn = [_]u32{0} ** LODLevel.count;
        self.instances = [_]u32{0} ** LODLevel.count;
        self.fluid_drawn = [_]u32{0} ** LODLevel.count;
        self.fluid_instances = [_]u32{0} ** LODLevel.count;
        self.gpu_terrain_candidates = 0;
        self.gpu_fluid_candidates = 0;
        self.gpu_culling_requested = false;
        self.gpu_culling_threshold = 0;
        self.gpu_culling_candidate_count = 0;
        self.gpu_culling_draw_submissions = 0;
        self.gpu_culling_overflows = 0;
        self.gpu_culling_validation_mismatches = 0;
        self.gpu_culling_validation_generation = 0;
        self.gpu_culling_validation_completed_generation = 0;
        self.gpu_culling_validation_completed_count = 0;
        self.upgrades_pending = 0;
        self.downgrades_pending = 0;
        self.upload_failures = 0;
        self.generation_token_overflows = 0;
        self.transition_token_overflows = 0;
        self.fade_token_overflows = 0;
        self.ingestion_backlog = 0;
        self.cancelled_jobs = 0;
    }

    pub fn recordState(self: *LODStats, lod_idx: usize, state: LODState) void {
        switch (state) {
            .renderable => self.loaded[lod_idx] += 1,
            .generating => self.generating[lod_idx] += 1,
            .generated => self.generated[lod_idx] += 1,
            .meshing => self.meshing[lod_idx] += 1,
            .mesh_ready => self.mesh_ready[lod_idx] += 1,
            .uploading => self.uploading[lod_idx] += 1,
            else => {},
        }
    }

    pub fn addMemory(self: *LODStats, bytes: usize) void {
        self.memory_used_bytes += @intCast(bytes);
        self.memory_used_mb = @intCast(self.memory_used_bytes / (1024 * 1024));
    }

    pub fn cacheHitRate(self: *const LODStats) f32 {
        const total = self.store_hits + self.store_misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.store_hits)) / @as(f32, @floatFromInt(total));
    }
};

test "LODStats reports cache hit rate" {
    var stats = LODStats{};
    try std.testing.expectEqual(@as(f32, 0.0), stats.cacheHitRate());

    stats.store_hits = 3;
    stats.store_misses = 1;
    try std.testing.expectEqual(@as(f32, 0.75), stats.cacheHitRate());
}

test "LOD profiling collector snapshots and resets cumulative counters" {
    var collector = LODProfilingCollector.init(true);
    collector.addUploadBytes(128);
    collector.addFarExpandedUploadBytes(96);
    collector.addCompactUploadBytes(32);
    collector.setPendingCpuUploadBytes(64);
    collector.addVisible();
    collector.addRejected();
    collector.addCoverage();
    collector.addCompactSubmission();
    collector.addVisibilityLevel(.lod1, .{ .candidates = 3, .accepted = 1, .rejected_frustum = 1, .coverage_checks = 1 });
    collector.addDeferredDeletionBytes(32);
    collector.addDeferredDeletionCpuBytes(16);
    collector.setMemoryAccounting(256, 192, 64, 256, 1024, 320, 704, 0, 128, 1664);
    collector.addWaitIdle();
    collector.setGpuCullingConfiguration(true, 128);
    collector.setGpuCullingCandidateCount(1024);
    collector.setGpuCullingCandidateCount(512);
    collector.addGpuCullingSubmission();
    collector.setGpuCullingDiagnostics(2, 3, 9, 8, 7);

    const snapshot = collector.snapshot();
    try std.testing.expect(snapshot.enabled);
    try std.testing.expectEqual(@as(u64, 128), snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 96), snapshot.far_expanded_upload_bytes);
    try std.testing.expectEqual(@as(u64, 32), snapshot.compact_upload_bytes);
    try std.testing.expectEqual(@as(u64, 64), snapshot.pending_cpu_upload_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.visible_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.coverage_count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.visibility_levels[1].candidates);
    try std.testing.expectEqual(@as(u64, 1), snapshot.visibility_levels[1].rejected_frustum);
    try std.testing.expectEqual(@as(u64, 32), snapshot.deferred_deletion_bytes);
    try std.testing.expectEqual(@as(u64, 16), snapshot.deferred_deletion_cpu_bytes);
    try std.testing.expectEqual(@as(u64, 256), snapshot.pool_gpu_capacity_bytes);
    try std.testing.expectEqual(@as(u64, 192), snapshot.pool_gpu_allocated_bytes);
    try std.testing.expectEqual(@as(u64, 64), snapshot.pool_gpu_slack_bytes);
    try std.testing.expectEqual(@as(u64, 256), snapshot.pool_cpu_shadow_bytes);
    try std.testing.expectEqual(@as(u64, 1024), snapshot.compact_pool_capacity_bytes);
    try std.testing.expectEqual(@as(u64, 320), snapshot.compact_pool_allocated_bytes);
    try std.testing.expectEqual(@as(u64, 704), snapshot.compact_pool_free_bytes);
    try std.testing.expectEqual(@as(u64, 128), snapshot.direct_mesh_gpu_bytes);
    try std.testing.expectEqual(@as(u64, 1664), snapshot.known_memory_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.wait_idle_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.compact_submissions);
    try std.testing.expect(snapshot.gpu_culling_requested);
    try std.testing.expectEqual(@as(u32, 128), snapshot.gpu_culling_threshold);
    try std.testing.expectEqual(@as(u32, 512), snapshot.gpu_culling_candidate_count);
    try std.testing.expectEqual(@as(u32, 1024), snapshot.gpu_culling_candidate_count_max);
    try std.testing.expectEqual(@as(u64, 1), snapshot.gpu_culling_draw_submissions);
    try std.testing.expectEqual(@as(u32, 2), snapshot.gpu_culling_overflows);
    try std.testing.expectEqual(@as(u32, 3), snapshot.gpu_culling_validation_mismatches);

    collector.reset();
    const reset_snapshot = collector.snapshot();
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.far_expanded_upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.visible_count);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.deferred_deletion_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.pool_gpu_capacity_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.visibility_levels[1].candidates);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.compact_submissions);
    try std.testing.expect(!reset_snapshot.gpu_culling_requested);
    try std.testing.expectEqual(@as(u32, 0), reset_snapshot.gpu_culling_candidate_count_max);
}

test "per-frame LOD stats reset cannot erase collector GPU-culling evidence" {
    var collector = LODProfilingCollector.init(true);
    collector.setGpuCullingConfiguration(true, 128);
    collector.setGpuCullingCandidateCount(1024);
    collector.addGpuCullingSubmission();

    var frame_stats = LODStats{};
    frame_stats.gpu_culling_requested = true;
    frame_stats.gpu_culling_candidate_count = 1024;
    frame_stats.reset();

    const snapshot = collector.snapshot();
    try std.testing.expect(snapshot.gpu_culling_requested);
    try std.testing.expectEqual(@as(u32, 1024), snapshot.gpu_culling_candidate_count_max);
    try std.testing.expectEqual(@as(u64, 1), snapshot.gpu_culling_draw_submissions);
}

test "disabled LOD profiling collector does not accumulate samples" {
    var collector = LODProfilingCollector.init(false);
    const timer = collector.begin();
    collector.end(.update, timer);
    collector.addUploadBytes(256);
    collector.addVisible();

    const snapshot = collector.snapshot();
    try std.testing.expect(!snapshot.enabled);
    try std.testing.expectEqual(@as(f64, 0), snapshot.update_ms);
    try std.testing.expectEqual(@as(u64, 0), snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), snapshot.visible_count);
}
