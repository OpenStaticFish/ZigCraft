//! LOD region scheduling and job prioritization.

const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
const LODRegionKey = lod_chunk.LODRegionKey;
const ILODConfig = lod_chunk.ILODConfig;
const Vec3 = @import("engine-math").Vec3;
const engine_core = @import("engine-core");
const JobQueue = engine_core.job_system.JobQueue;
const log = engine_core.log;
const sync = @import("sync");
const lod_gpu = @import("lod_upload_queue.zig");
const ChunkChecker = lod_gpu.ChunkChecker;
const RegionMap = lod_gpu.RegionMap;
const LifecycleQueue = @import("lod_manager_context.zig").LifecycleQueue;
const LifecycleToken = @import("lod_manager_context.zig").LifecycleToken;
const LODScanState = @import("lod_manager_context.zig").LODScanState;
const LOCAL_SERVICE_COLLAR_CHUNKS = @import("lod_manager_context.zig").LOCAL_SERVICE_COLLAR_CHUNKS;
const service = @import("lod_service.zig");

pub const CoverageFn = *const fn (ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool;

pub const SchedulerContext = struct {
    allocator: std.mem.Allocator,
    config: ILODConfig,
    radii: [LODLevel.count]i32,
    active_lod_count: usize,
    regions: *[LODLevel.count]RegionMap,
    gen_queues: *[LODLevel.count]*JobQueue,
    mutex: *sync.RwLock,
    player_cx: i32,
    player_cz: i32,
    scan_states: *[LODLevel.count]LODScanState,
    next_job_token: *u32,
    cleanup_covered_regions: bool,
    coverage_ptr: *anyopaque,
    are_all_chunks_loaded: CoverageFn,
    // Dynamic per-level radius reduction (hysteresis under memory pressure).
    // Applied to all levels EXCEPT the coarsest (horizon is never shrunk).
    radius_reduction: *const [LODLevel.count]i32,
    // When true, queueLODRegions marks chunks queued_for_generation and lets
    // LODManager perform main-thread cache reads before dispatching workers.
    defer_generation_dispatch: bool = false,
    // Shared admission count for queued or in-flight regions. The manager
    // supplies this during normal updates; isolated scheduler tests may omit it.
    pending_regions: ?*usize = null,
    /// Resident-region and conservative logical-memory admission caps.
    resident_region_limit: usize = MAX_LOD_REGIONS,
    logical_memory_limit_bytes: usize = std.math.maxInt(usize),
    logical_memory_bytes: ?*usize = null,
    logical_region_reservation_bytes: usize = 0,
    use_vertical_spans: bool = false,
    /// Persistent bounded priority queue owned by the manager. `null` keeps
    /// isolated scheduler tests and legacy direct-dispatch callers working.
    generation_tokens: ?*LifecycleQueue = null,
    /// Independent service cursors must not disturb the legacy outer scan.
    scan_state_override: ?*LODScanState = null,
    service_lane: ?u3 = null,
    max_admissions: ?usize = null,
    max_scan_steps: usize = MAX_LOD_SCAN_STEPS,
};

pub const ScheduleResult = struct {
    admitted: usize = 0,
    examined: usize = 0,
    pending_blocked: bool = false,
    memory_blocked: bool = false,
    /// One complete bounded window was visited without an eligible candidate.
    exhausted: bool = false,
};

const std = @import("std");

const QueueDiag = struct {
    considered: u64 = 0,
    outside_radius: u64 = 0,
    covered_chunks: u64 = 0,
    existing: u64 = 0,
    candidates: u64 = 0,
    queued: u64 = 0,
};

const LOD0_QUEUE_CANDIDATE_LIMIT: usize = 96;
const LOD1_QUEUE_CANDIDATE_LIMIT: usize = 64;
const HORIZON_QUEUE_CANDIDATE_LIMIT: usize = 64;
const REFINEMENT_QUEUE_CANDIDATE_LIMIT: usize = 48;
/// Hard per-update work budget. Large configured horizons advance through a
/// persistent ring cursor instead of blocking a frame on a full-area scan.
pub const MAX_LOD_SCAN_STEPS: usize = 512;
const MAX_PENDING_LOD_REGIONS = @import("lod_manager_context.zig").MAX_PENDING_LOD_REGIONS;
const MAX_LOD_REGIONS = @import("lod_manager_context.zig").MAX_LOD_REGIONS;

fn regionCoordinateRepresentable(region: i64, scale: i32) bool {
    const min_chunk = region * @as(i64, scale);
    const max_chunk = min_chunk + @as(i64, scale) - 1;
    return min_chunk >= std.math.minInt(i32) and max_chunk <= std.math.maxInt(i32);
}

fn nextRingCoordinate(state: *LODScanState, player_rx: i32, player_rz: i32, region_radius: i64) [2]i64 {
    if (state.next_ring > region_radius) {
        state.next_ring = 0;
        state.ring_index = 0;
    }
    if (state.next_ring == 0) {
        state.next_ring = 1;
        state.ring_index = 0;
        return .{ player_rx, player_rz };
    }

    const ring = state.next_ring;
    const side_length = ring * 2;
    const perimeter_length = side_length * 4;
    const index = state.ring_index;
    const side = @divFloor(index, side_length);
    const offset = @mod(index, side_length);
    const relative = switch (side) {
        0 => [2]i64{ -ring + offset, -ring },
        1 => [2]i64{ ring, -ring + offset },
        2 => [2]i64{ ring - offset, ring },
        else => [2]i64{ -ring, ring - offset },
    };

    state.ring_index += 1;
    if (state.ring_index >= perimeter_length) {
        state.next_ring += 1;
        state.ring_index = 0;
    }
    return .{ @as(i64, player_rx) + relative[0], @as(i64, player_rz) + relative[1] };
}

fn updateScanOrigin(state: *LODScanState, player_rx: i32, player_rz: i32, effective_radius: i32, restart_on_move: bool) void {
    const moved_rx = @as(i64, player_rx) - @as(i64, state.player_rx);
    const moved_rz = @as(i64, player_rz) - @as(i64, state.player_rz);
    if (state.effective_radius != effective_radius) {
        state.* = .{
            .player_rx = player_rx,
            .player_rz = player_rz,
            .effective_radius = effective_radius,
        };
        return;
    }
    if (player_rx == state.player_rx and player_rz == state.player_rz) return;

    state.player_rx = player_rx;
    state.player_rz = player_rz;
    // Preserve refinement progress during ordinary traversal. The coarsest
    // level opts into restarting for every region-origin change so a moving
    // player cannot leave an unvisited hole in the fallback disk.
    if (restart_on_move or @max(@abs(moved_rx), @abs(moved_rz)) > 8) {
        state.next_ring = 0;
        state.ring_index = 0;
        state.last_examined = 0;
    }
}

pub fn priorityRank(lod: LODLevel, active_lod_count: usize) usize {
    const lod_idx: usize = @intFromEnum(lod);
    const coarsest_idx = if (active_lod_count == 0) 0 else active_lod_count - 1;
    return if (lod_idx == coarsest_idx)
        0
    else
        lod_idx + 1;
}

pub fn priorityLevelIndex(order_idx: usize, active_lod_count: usize) usize {
    if (active_lod_count == 0) return 0;
    if (order_idx == 0) return active_lod_count - 1;
    return order_idx - 1;
}

fn lodPriorityBias(lod: LODLevel, active_lod_count: usize) i32 {
    const rank = priorityRank(lod, active_lod_count);
    return @as(i32, @intCast(rank)) << 28;
}

fn maxQueueCandidatesForLOD(lod: LODLevel, active_lod_count: usize) usize {
    const lod_idx: usize = @intFromEnum(lod);
    const coarsest_idx = if (active_lod_count == 0) 0 else active_lod_count - 1;
    if (lod_idx == 0) return LOD0_QUEUE_CANDIDATE_LIMIT;
    if (lod_idx == 1) return LOD1_QUEUE_CANDIDATE_LIMIT;
    if (lod_idx == coarsest_idx) return HORIZON_QUEUE_CANDIDATE_LIMIT;
    return REFINEMENT_QUEUE_CANDIDATE_LIMIT;
}

pub fn priorityWeightForVelocity(velocity: Vec3, chunk_dx: i64, chunk_dz: i64) f32 {
    const speed = @sqrt(velocity.x * velocity.x + velocity.z * velocity.z);
    if (speed < 2.0) return 1.0;

    const cdx: f32 = @floatFromInt(chunk_dx);
    const cdz: f32 = @floatFromInt(chunk_dz);
    const dist = @sqrt(cdx * cdx + cdz * cdz);
    if (dist < 0.001) return 0.5;

    const dir_x = velocity.x / speed;
    const dir_z = velocity.z / speed;
    const dot = (cdx * dir_x + cdz * dir_z) / dist;
    return 1.0 - dot * 0.5;
}

pub fn encodePriority(lod: LODLevel, chunk_dx: i64, chunk_dz: i64, velocity: Vec3, active_lod_count: usize) i32 {
    const dx: f64 = @floatFromInt(chunk_dx);
    const dz: f64 = @floatFromInt(chunk_dz);
    const weighted = (dx * dx + dz * dz) * @as(f64, priorityWeightForVelocity(velocity, chunk_dx, chunk_dz));
    const priority: i32 = @intFromFloat(@min(weighted, @as(f64, @floatFromInt(@as(i32, 0x0FFFFFFF)))));
    return (priority & 0x0FFFFFFF) | lodPriorityBias(lod, active_lod_count);
}

/// Queue LOD regions that need generation.
pub fn queueLODRegions(ctx: SchedulerContext, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    _ = try queueLODRegionsBounded(ctx, lod, velocity, chunk_checker, checker_ctx);
}

pub fn queueLODRegionsBounded(ctx: SchedulerContext, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !ScheduleResult {
    var result: ScheduleResult = .{};
    if (ctx.max_admissions == 0 or ctx.max_scan_steps == 0) return result;
    // Do not rescan thousands of horizon candidates while the bounded
    // lifecycle pipeline cannot admit another region.
    ctx.mutex.lockShared();
    if (ctx.pending_regions) |pending| {
        if (pending.* >= MAX_PENDING_LOD_REGIONS) {
            ctx.mutex.unlockShared();
            result.pending_blocked = true;
            return result;
        }
    }
    ctx.mutex.unlockShared();

    const radii = ctx.radii;
    const idx: u32 = @intFromEnum(lod);
    // Apply dynamic radius reduction (hysteresis) to every level except the
    // coarsest horizon band, which must keep filling regardless of pressure.
    const is_coarsest = (idx + 1 >= LODLevel.count) or (@as(usize, idx + 1) >= ctx.active_lod_count);
    const radius = if (is_coarsest) @max(0, radii[idx]) else @max(0, radii[idx] - ctx.radius_reduction[idx]);
    const local_radius = @min(radius, @max(0, ctx.config.getChunkRenderRadius()) +| LOCAL_SERVICE_COLLAR_CHUNKS);
    const lane: ?service.Class = if (ctx.service_lane) |value| blk: {
        std.debug.assert(value < service.CLASS_COUNT);
        break :blk @enumFromInt(value);
    } else null;
    const local_scan = if (lane) |class| switch (class) {
        .local_fallback, .near0, .near1 => true,
        .horizon, .refinement => false,
    } else false;
    if (lane) |class| {
        const valid_level = switch (class) {
            .local_fallback, .horizon => is_coarsest,
            .near0 => lod == .lod0,
            .near1 => lod == .lod1,
            .refinement => !is_coarsest,
        };
        if (!valid_level) return .{ .exhausted = true };
    }
    const scan_radius = if (local_scan) local_radius else radius;

    const scale: i32 = @intCast(lod.chunksPerSide());
    const region_radius = @divFloor(@as(i64, scan_radius), @as(i64, scale)) + 1;
    const window_side: u64 = @intCast(region_radius * 2 + 1);
    const scan_limit: usize = @intCast(@min(ctx.max_scan_steps, MAX_LOD_SCAN_STEPS, window_side * window_side));

    const player_rx = @divFloor(ctx.player_cx, scale);
    const player_rz = @divFloor(ctx.player_cz, scale);

    const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);
    var diag = QueueDiag{};
    const active_lod_count = ctx.active_lod_count;

    // All LOD jobs go to the highest LOD queue. Encode the actual LOD in priority bits.
    const queue = ctx.gen_queues[LODLevel.count - 1];
    const lod_idx: u3 = @intFromEnum(lod);

    // Keep only the bounded best candidates while walking the horizon. This
    // avoids allocating/sorting an entry for every potential region.
    const Candidate = struct {
        key: LODRegionKey,
        encoded_priority: i32,
        scan_state_before: LODScanState,
    };
    const max_candidates = @min(maxQueueCandidatesForLOD(lod, active_lod_count), ctx.max_admissions orelse std.math.maxInt(usize));
    var candidates = std.ArrayListUnmanaged(Candidate).empty;
    defer candidates.deinit(ctx.allocator);

    // Existing active regions must not consume the bounded candidate window.
    // A persistent concentric-ring cursor guarantees bounded frame work while
    // eventually visiting every coordinate in the configured horizon.
    ctx.mutex.lock();
    const candidate_storage = &ctx.regions[@intFromEnum(lod)];
    const state = ctx.scan_state_override orelse &ctx.scan_states[@intFromEnum(lod)];
    updateScanOrigin(state, player_rx, player_rz, scan_radius, is_coarsest or local_scan);
    if (state.next_ring > region_radius) {
        state.next_ring = 0;
        state.ring_index = 0;
    }

    var examined: usize = 0;
    while (examined < scan_limit and candidates.items.len < max_candidates) : (examined += 1) {
        const scan_state_before = state.*;
        const coordinate = nextRingCoordinate(state, player_rx, player_rz, region_radius);
        const rx = coordinate[0];
        const rz = coordinate[1];
        diag.considered += 1;
        if (!regionCoordinateRepresentable(rx, scale) or !regionCoordinateRepresentable(rz, scale)) continue;
        const key = LODRegionKey{ .rx = @intCast(rx), .rz = @intCast(rz), .lod = lod };
        const chunk_bounds = key.chunkBounds();
        if (!chunk_bounds.intersectsRadius(ctx.player_cx, ctx.player_cz, radius)) {
            diag.outside_radius += 1;
            continue;
        }
        if (lane) |class| {
            const intersects_local = chunk_bounds.intersectsRadius(ctx.player_cx, ctx.player_cz, local_radius);
            const in_window = switch (class) {
                .local_fallback, .near0, .near1 => intersects_local,
                .horizon => !intersects_local,
                .refinement => if (idx < 2) !intersects_local else true,
            };
            if (!in_window) continue;
        }

        var duplicate = false;
        for (candidates.items) |candidate| {
            if (candidate.key.eql(key)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        if (candidate_storage.get(key)) |chunk| {
            diag.existing += 1;
            if (chunk.getState() != .missing or chunk.isPinned()) continue;
        }

        if (ctx.cleanup_covered_regions) {
            if (chunk_checker) |checker| {
                const temp_chunk = LODChunk.init(key.rx, key.rz, lod);
                if (ctx.are_all_chunks_loaded(ctx.coverage_ptr, temp_chunk.worldBounds(), checker, checker_ctx.?)) {
                    diag.covered_chunks += 1;
                    continue;
                }
            }
        }

        const center_cx = @as(i64, key.rx) * @as(i64, scale) + @divFloor(scale, 2);
        const center_cz = @as(i64, key.rz) * @as(i64, scale) + @divFloor(scale, 2);
        const distance_priority = encodePriority(lod, center_cx - @as(i64, ctx.player_cx), center_cz - @as(i64, ctx.player_cz), velocity, active_lod_count);
        const candidate = Candidate{
            .key = key,
            .encoded_priority = distance_priority,
            .scan_state_before = scan_state_before,
        };
        candidates.append(ctx.allocator, candidate) catch |err| {
            state.* = if (candidates.items.len > 0) candidates.items[0].scan_state_before else scan_state_before;
            ctx.mutex.unlock();
            return err;
        };
        diag.candidates += 1;
    }
    state.last_examined = examined;
    result.examined = examined;
    result.exhausted = examined == window_side * window_side and candidates.items.len == 0;
    ctx.mutex.unlock();

    var queued_count: usize = 0;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    defer state.last_examined = result.examined;

    const storage = &ctx.regions[@intFromEnum(lod)];
    var resident_regions: usize = 0;
    for (ctx.regions) |region_map| resident_regions += region_map.count();
    for (candidates.items) |cand| {
        // Candidate discovery advances the persistent scan cursor. If bounded
        // admission cannot accept this coordinate, rewind to it so the next
        // update resumes at the first actual coverage hole instead of skipping
        // the remainder of a ring and producing directional strips.
        if (queued_count >= max_candidates) {
            state.* = cand.scan_state_before;
            break;
        }
        if (ctx.pending_regions) |pending| {
            if (pending.* >= MAX_PENDING_LOD_REGIONS) {
                state.* = cand.scan_state_before;
                result.pending_blocked = true;
                break;
            }
        }

        const existing = storage.get(cand.key);
        // A missing, unpinned region has no `unusedCpuBuildReservation` in
        // manager accounting. Re-admitting it must acquire exactly one fresh
        // allowance just like a newly allocated region.
        const needs_admission_reservation = existing == null or
            (existing.?.getState() == .missing and !existing.?.isPinned());
        if (existing == null and resident_regions >= ctx.resident_region_limit) {
            state.* = cand.scan_state_before;
            result.memory_blocked = true;
            break;
        }
        if (needs_admission_reservation) if (ctx.logical_memory_bytes) |logical| {
            const reservation = ctx.logical_region_reservation_bytes;
            if (reservation > ctx.logical_memory_limit_bytes -| logical.*) {
                state.* = cand.scan_state_before;
                result.memory_blocked = true;
                break;
            }
        };
        // A cancelled worker keeps the region pinned until it observes its
        // cancellation signal. Do not reset that signal by dispatching a new
        // generation for the same region concurrently.
        const needs_queue = if (existing) |chunk| chunk.getState() == .missing and !chunk.isPinned() else true;
        if (!needs_queue) continue;

        errdefer state.* = cand.scan_state_before;

        const chunk = if (existing) |c| c else blk: {
            const c = try ctx.allocator.create(LODChunk);
            errdefer ctx.allocator.destroy(c);
            c.* = LODChunk.init(cand.key.rx, cand.key.rz, lod);
            try storage.put(cand.key, c);
            resident_regions += 1;
            if (ctx.logical_memory_bytes) |logical| {
                logical.* = std.math.add(usize, logical.*, ctx.logical_region_reservation_bytes) catch std.math.maxInt(usize);
            }
            break :blk c;
        };

        const previous_token = chunk.job_token;
        const previous_priority = chunk.job_priority;
        const previous_preserve = chunk.preserve_job_priority;
        const previous_lane = chunk.service_lane;
        const previous_cancel = chunk.cancellationRequested();
        var accepted = false;
        defer if (!accepted) {
            state.* = cand.scan_state_before;
            if (existing == null) {
                _ = storage.remove(cand.key);
                resident_regions -= 1;
                if (ctx.logical_memory_bytes) |logical| logical.* -= ctx.logical_region_reservation_bytes;
                chunk.deinit(ctx.allocator);
                ctx.allocator.destroy(chunk);
            } else {
                chunk.setState(.missing);
                chunk.job_token = previous_token;
                chunk.job_priority = previous_priority;
                chunk.preserve_job_priority = previous_preserve;
                chunk.service_lane = previous_lane;
                chunk.cancel_requested.store(previous_cancel, .release);
            }
        };

        chunk.job_token = ctx.next_job_token.*;
        chunk.service_lane = ctx.service_lane orelse 4;
        chunk.job_priority = cand.encoded_priority;
        chunk.preserve_job_priority = false;
        if (ctx.defer_generation_dispatch) {
            chunk.setState(.queued_for_generation);
            if (ctx.generation_tokens) |tokens| {
                _ = tokens.push(ctx.allocator, .{
                    .key = cand.key,
                    .job_token = chunk.job_token,
                    .source_revision = chunk.source_revision,
                    .priority = cand.encoded_priority,
                    .stage = .generation,
                    .service_lane = chunk.service_lane,
                }) catch |err| {
                    if (err == error.LifecycleQueueFull) {
                        result.pending_blocked = true;
                        break;
                    }
                    return err;
                };
                accepted = true;
            } else {
                // Legacy deferred callers use map reconciliation as their queue.
                accepted = ctx.service_lane == null;
            }
        } else {
            chunk.resetCancellation();
            chunk.setState(.generating);
            accepted = try queue.tryPush(.{
                .type = .chunk_generation,
                .service_lane = chunk.service_lane,
                .dist_sq = cand.encoded_priority,
                .data = .{
                    .chunk = .{
                        .x = chunk.region_x,
                        .z = chunk.region_z,
                        .job_token = chunk.job_token,
                        .lod_level = lod_idx,
                        .coord_scale = scale,
                        .lod_radius = radii[idx],
                        .use_vertical_spans = ctx.use_vertical_spans,
                    },
                },
            });
        }
        if (!accepted) {
            result.pending_blocked = true;
            break;
        }
        if (existing != null and needs_admission_reservation) if (ctx.logical_memory_bytes) |logical| {
            logical.* = std.math.add(usize, logical.*, ctx.logical_region_reservation_bytes) catch std.math.maxInt(usize);
        };
        ctx.next_job_token.* +%= 1;
        diag.queued += 1;
        queued_count += 1;
        result.admitted += 1;
        if (ctx.pending_regions) |pending| pending.* += 1;
    }

    if (diag_enabled) {
        const S = struct {
            var counter: [LODLevel.count]u64 = .{0} ** LODLevel.count;
        };
        const diag_lod_idx = @intFromEnum(lod);
        S.counter[diag_lod_idx] += 1;
        if (S.counter[diag_lod_idx] % 120 == 1) {
            log.log.info("LOD_QUEUE_DIAG lod={} radius={} scale={} considered={} outside={} covered={} existing={} candidates={} queued={} player_chunk=({}, {})", .{
                diag_lod_idx,
                radius,
                scale,
                diag.considered,
                diag.outside_radius,
                diag.covered_chunks,
                diag.existing,
                diag.candidates,
                diag.queued,
                ctx.player_cx,
                ctx.player_cz,
            });
        }
    }
    return result;
}

test "LOD scheduling seeds horizon before detailed refinements" {
    try std.testing.expect(lodPriorityBias(.lod4, LODLevel.count) < lodPriorityBias(.lod0, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod0, LODLevel.count) < lodPriorityBias(.lod1, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod1, LODLevel.count) < lodPriorityBias(.lod2, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod2, LODLevel.count) < lodPriorityBias(.lod3, LODLevel.count));

    try std.testing.expect(lodPriorityBias(.lod3, 4) < lodPriorityBias(.lod0, 4));
    try std.testing.expect(lodPriorityBias(.lod0, 4) < lodPriorityBias(.lod1, 4));

    try std.testing.expectEqual(@as(usize, 4), priorityLevelIndex(0, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 0), priorityLevelIndex(1, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 1), priorityLevelIndex(2, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 2), priorityLevelIndex(3, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 3), priorityLevelIndex(4, LODLevel.count));
}

test "LOD scheduling preserves ring progress during ordinary movement" {
    var state = LODScanState{
        .player_rx = 12,
        .player_rz = -4,
        .effective_radius = 1024,
        .next_ring = 9,
        .ring_index = 17,
        .last_examined = MAX_LOD_SCAN_STEPS,
    };

    updateScanOrigin(&state, 13, -4, 1024, false);

    try std.testing.expectEqual(@as(i32, 13), state.player_rx);
    try std.testing.expectEqual(@as(i32, -4), state.player_rz);
    try std.testing.expectEqual(@as(i64, 9), state.next_ring);
    try std.testing.expectEqual(@as(i64, 17), state.ring_index);
    try std.testing.expectEqual(MAX_LOD_SCAN_STEPS, state.last_examined);

    updateScanOrigin(&state, 30, -4, 1024, false);
    try std.testing.expectEqual(@as(i64, 0), state.next_ring);
    try std.testing.expectEqual(@as(i64, 0), state.ring_index);
    try std.testing.expectEqual(@as(usize, 0), state.last_examined);

    state = .{ .player_rx = 12, .player_rz = -4, .effective_radius = 1024, .next_ring = 9, .ring_index = 17 };
    updateScanOrigin(&state, 13, -4, 1024, true);
    try std.testing.expectEqual(@as(i64, 0), state.next_ring);
    try std.testing.expectEqual(@as(i64, 0), state.ring_index);
}

test "LOD scheduling caps resident regions and logical admission memory" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 2,
        .radii = .{ 5, 12, 24, 48, 96 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var scan_states = [_]LODScanState{LODScanState{}} ** LODLevel.count;
    var pending_regions: usize = 0;
    var logical_memory_bytes: usize = 0;
    const reservation_bytes: usize = 1024;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };

    try queueLODRegions(.{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .scan_states = &scan_states,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
        .pending_regions = &pending_regions,
        .resident_region_limit = 1,
        .logical_memory_limit_bytes = reservation_bytes,
        .logical_memory_bytes = &logical_memory_bytes,
        .logical_region_reservation_bytes = reservation_bytes,
    }, .lod0, Vec3.zero, null, null);

    const queue = queue_ptrs[LODLevel.count - 1];
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(queue.count(), pending_regions);
    try std.testing.expectEqual(reservation_bytes, logical_memory_bytes);
    const job = queue.pop().?;
    try std.testing.expectEqual(engine_core.job_system.JobType.chunk_generation, job.type);
    try std.testing.expectEqual(@as(u3, 0), job.data.chunk.lod_level);

    const key = LODRegionKey{ .rx = job.data.chunk.x, .rz = job.data.chunk.z, .lod = .lod0 };
    const chunk = regions[0].get(key).?;
    try std.testing.expectEqual(lod_chunk.LODState.generating, chunk.state);
}

test "LOD scheduling fills nearby horizon fallback before distant regions" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 16,
        .radii = .{ 4096, 8192, 16_384, 32_768, 131_072 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var scan_states = [_]LODScanState{LODScanState{}} ** LODLevel.count;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };
    const ctx = SchedulerContext{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .scan_states = &scan_states,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
    };

    try queueLODRegions(ctx, .lod0, Vec3.zero, null, null);
    try queueLODRegions(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expect(scan_states[@intFromEnum(LODLevel.lod0)].last_examined <= MAX_LOD_SCAN_STEPS);
    try std.testing.expect(scan_states[@intFromEnum(LODLevel.lod4)].last_examined <= MAX_LOD_SCAN_STEPS);

    const queue = queue_ptrs[LODLevel.count - 1];
    const total = queue.count();
    try std.testing.expectEqual(LOD0_QUEUE_CANDIDATE_LIMIT + HORIZON_QUEUE_CANDIDATE_LIMIT, total);

    // A cold cache must not keep admitting work once the global pipeline is
    // full; completed regions free capacity on subsequent manager updates.
    var pending_regions = MAX_PENDING_LOD_REGIONS;
    var capped_ctx = ctx;
    capped_ctx.pending_regions = &pending_regions;
    try queueLODRegions(capped_ctx, .lod1, Vec3.zero, null, null);
    try std.testing.expectEqual(total, queue.count());

    const first_job = queue.pop().?;
    try std.testing.expectEqual(@intFromEnum(LODLevel.lod4), first_job.data.chunk.lod_level);

    var lod0_count: usize = 0;
    var horizon_count: usize = 1;
    var max_horizon_dist_sq: i64 = 0;
    const recordHorizonDistance = struct {
        fn record(max_dist_sq: *i64, job: engine_core.job_system.Job) void {
            const scale: i32 = @intCast(LODLevel.lod4.chunksPerSide());
            const center_x: i64 = job.data.chunk.x * scale + @divFloor(scale, 2);
            const center_z: i64 = job.data.chunk.z * scale + @divFloor(scale, 2);
            max_dist_sq.* = @max(max_dist_sq.*, center_x * center_x + center_z * center_z);
        }
    }.record;
    recordHorizonDistance(&max_horizon_dist_sq, first_job);
    var i: usize = 1;
    while (i < total) : (i += 1) {
        const job = queue.pop().?;
        if (job.data.chunk.lod_level == @intFromEnum(LODLevel.lod0)) lod0_count += 1;
        if (job.data.chunk.lod_level == @intFromEnum(LODLevel.lod4)) {
            horizon_count += 1;
            recordHorizonDistance(&max_horizon_dist_sq, job);
        }
    }

    try std.testing.expectEqual(LOD0_QUEUE_CANDIDATE_LIMIT, lod0_count);
    try std.testing.expectEqual(HORIZON_QUEUE_CANDIDATE_LIMIT, horizon_count);
    // Coarsest fallback advances concentrically. A cold start must not spend
    // its bounded admission budget on disconnected outer-horizon islands.
    const nearby_limit_chunks: i64 = 6 * @as(i64, @intCast(LODLevel.lod4.chunksPerSide()));
    try std.testing.expect(max_horizon_dist_sq <= nearby_limit_chunks * nearby_limit_chunks);
}

test "LOD scheduling does not skip horizon coordinates with one admission slot" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 16,
        .radii = .{ 64, 128, 256, 384, 512 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var pending_regions: usize = MAX_PENDING_LOD_REGIONS - 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var scan_states = [_]LODScanState{LODScanState{}} ** LODLevel.count;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };
    const ctx = SchedulerContext{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .scan_states = &scan_states,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
        .pending_regions = &pending_regions,
    };

    // Repeatedly free exactly one pipeline slot. The scheduler must resume at
    // the first unadmitted coordinate rather than advancing 64 candidates and
    // leaving a directionally biased set of holes behind.
    for (0..HORIZON_QUEUE_CANDIDATE_LIMIT) |_| {
        try queueLODRegions(ctx, .lod4, Vec3.zero, null, null);
        try std.testing.expectEqual(@as(usize, 1), queue_ptrs[LODLevel.count - 1].count());
        _ = queue_ptrs[LODLevel.count - 1].pop().?;
        pending_regions = MAX_PENDING_LOD_REGIONS - 1;
    }

    try std.testing.expectEqual(HORIZON_QUEUE_CANDIDATE_LIMIT, regions[@intFromEnum(LODLevel.lod4)].count());
    var z: i32 = -3;
    while (z <= 3) : (z += 1) {
        var x: i32 = -3;
        while (x <= 3) : (x += 1) {
            try std.testing.expect(regions[@intFromEnum(LODLevel.lod4)].contains(.{ .rx = x, .rz = z, .lod = .lod4 }));
        }
    }
    var iter = regions[@intFromEnum(LODLevel.lod4)].keyIterator();
    while (iter.next()) |key| {
        try std.testing.expect(@max(@abs(key.rx), @abs(key.rz)) <= 4);
    }
}

test "LOD scheduling biases priorities toward movement direction" {
    const velocity = Vec3.init(10, 0, 0);
    const ahead = encodePriority(.lod2, 10, 0, velocity, LODLevel.count) & 0x0FFFFFFF;
    const behind = encodePriority(.lod2, -10, 0, velocity, LODLevel.count) & 0x0FFFFFFF;
    const stationary_ahead = encodePriority(.lod2, 10, 0, Vec3.zero, LODLevel.count) & 0x0FFFFFFF;
    const stationary_behind = encodePriority(.lod2, -10, 0, Vec3.zero, LODLevel.count) & 0x0FFFFFFF;

    try std.testing.expect(ahead < behind);
    try std.testing.expectEqual(stationary_ahead, stationary_behind);
}

const BoundedFixture = struct {
    allocator: std.mem.Allocator,
    regions: [LODLevel.count]RegionMap,
    queue: JobQueue,
    queue_ptrs: [LODLevel.count]*JobQueue = undefined,
    config: LODConfig = .{ .chunk_render_radius = 0, .radii = .{ 4096, 8192, 16_384, 32_768, 131_072 } },
    mutex: sync.RwLock = .{},
    scan_states: [LODLevel.count]LODScanState = @splat(.{}),
    local_state: LODScanState = .{},
    reduction: [LODLevel.count]i32 = @splat(0),
    next_token: u32 = 1,
    pending: usize = 0,
    logical: usize = 0,
    covered: bool = false,
    tokens: LifecycleQueue = .{},

    fn init(allocator: std.mem.Allocator) BoundedFixture {
        var self = BoundedFixture{ .allocator = allocator, .regions = undefined, .queue = JobQueue.init(allocator) };
        for (&self.regions) |*map| map.* = RegionMap.init(allocator);
        return self;
    }

    fn deinit(self: *BoundedFixture) void {
        self.tokens.deinit(self.allocator);
        self.queue.deinit();
        for (&self.regions) |*map| {
            var it = map.valueIterator();
            while (it.next()) |chunk| {
                chunk.*.deinit(self.allocator);
                self.allocator.destroy(chunk.*);
            }
            map.deinit();
        }
    }

    fn coverage(ptr: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
        const self: *BoundedFixture = @ptrCast(@alignCast(ptr));
        return self.covered;
    }

    fn checker(_: i32, _: i32, _: *anyopaque) bool {
        return true;
    }

    fn context(self: *BoundedFixture, lane: service.Class) SchedulerContext {
        self.queue_ptrs = @splat(&self.queue);
        return .{
            .allocator = self.allocator,
            .config = self.config.interface(),
            .radii = self.config.radii,
            .active_lod_count = LODLevel.count,
            .regions = &self.regions,
            .gen_queues = &self.queue_ptrs,
            .mutex = &self.mutex,
            .player_cx = -1,
            .player_cz = -1,
            .scan_states = &self.scan_states,
            .scan_state_override = &self.local_state,
            .next_job_token = &self.next_token,
            .cleanup_covered_regions = false,
            .coverage_ptr = self,
            .are_all_chunks_loaded = coverage,
            .radius_reduction = &self.reduction,
            .pending_regions = &self.pending,
            .logical_memory_bytes = &self.logical,
            .logical_region_reservation_bytes = 1024,
            .service_lane = @intFromEnum(lane),
        };
    }
};

test "bounded LOD service windows partition footprints and honor memory shrink" {
    const cases = .{
        .{ service.Class.local_fallback, LODLevel.lod4, true },
        .{ service.Class.near0, LODLevel.lod0, true },
        .{ service.Class.near1, LODLevel.lod1, true },
        .{ service.Class.horizon, LODLevel.lod4, false },
        .{ service.Class.refinement, LODLevel.lod0, false },
        .{ service.Class.refinement, LODLevel.lod1, false },
    };
    inline for (cases) |case| {
        var f = BoundedFixture.init(std.testing.allocator);
        defer f.deinit();
        const result = try queueLODRegionsBounded(f.context(case[0]), case[1], Vec3.zero, null, null);
        try std.testing.expect(result.admitted > 0);
        try std.testing.expectEqual(result.admitted, f.queue.count());
        var it = f.regions[@intFromEnum(case[1])].valueIterator();
        while (it.next()) |chunk| {
            try std.testing.expectEqual(case[2], chunk.*.key().chunkBounds().intersectsRadius(-1, -1, 4));
            try std.testing.expectEqual(@intFromEnum(case[0]), chunk.*.service_lane);
        }
        try std.testing.expectEqual(@as(i32, -1), f.scan_states[@intFromEnum(case[1])].effective_radius);
        if (case[2]) try std.testing.expectEqual(@as(i32, 4), f.local_state.effective_radius);
    }

    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    f.config.chunk_render_radius = 128;
    f.reduction[0] = f.config.radii[0] - 2;
    const result = try queueLODRegionsBounded(f.context(.near0), .lod0, Vec3.zero, null, null);
    try std.testing.expect(result.admitted > 0);
    try std.testing.expectEqual(@as(i32, 2), f.local_state.effective_radius);
    var it = f.regions[0].keyIterator();
    while (it.next()) |key| try std.testing.expect(key.chunkBounds().intersectsRadius(-1, -1, 2));
    const excluded = try queueLODRegionsBounded(f.context(.refinement), .lod4, Vec3.zero, null, null);
    try std.testing.expect(excluded.exhausted);
    try std.testing.expectEqual(@as(usize, 0), excluded.admitted);
}

test "bounded LOD scan respects grants coverage and one complete small window" {
    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    f.covered = true;
    var ctx = f.context(.local_fallback);
    ctx.cleanup_covered_regions = true;
    ctx.max_scan_steps = 2;
    const partial = try queueLODRegionsBounded(ctx, .lod4, Vec3.zero, BoundedFixture.checker, &f);
    try std.testing.expectEqual(@as(usize, 2), partial.examined);
    try std.testing.expect(!partial.exhausted);
    ctx.max_scan_steps = MAX_LOD_SCAN_STEPS;
    const full = try queueLODRegionsBounded(ctx, .lod4, Vec3.zero, BoundedFixture.checker, &f);
    const scale = LODLevel.lod4.chunksPerSide();
    const side = (4 / scale + 1) * 2 + 1;
    try std.testing.expectEqual(@as(usize, side * side), full.examined);
    try std.testing.expectEqual(full.examined, f.local_state.last_examined);
    try std.testing.expect(full.exhausted);
    try std.testing.expectEqual(@as(usize, 0), f.queue.count());
    ctx.max_admissions = 0;
    const no_grant = try queueLODRegionsBounded(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expectEqual(@as(usize, 0), no_grant.examined);
    try std.testing.expect(!no_grant.exhausted);
}

test "bounded LOD one slot discovers every negative local footprint and revisits holes" {
    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    var ctx = f.context(.near1);
    var exhausted = false;
    for (0..128) |_| {
        f.pending = MAX_PENDING_LOD_REGIONS - 1;
        const result = try queueLODRegionsBounded(ctx, .lod1, Vec3.zero, null, null);
        try std.testing.expect(result.admitted <= 1);
        try std.testing.expectEqual(result.admitted, f.queue.count());
        if (result.admitted != 0) {
            const job = f.queue.pop().?;
            try std.testing.expectEqual(@intFromEnum(service.Class.near1), job.service_lane);
        }
        if (result.exhausted) {
            exhausted = true;
            break;
        }
    }
    try std.testing.expect(exhausted);
    var z: i32 = -6;
    while (z <= 4) : (z += 1) {
        var x: i32 = -6;
        while (x <= 4) : (x += 1) {
            const key = LODRegionKey{ .rx = x, .rz = z, .lod = .lod1 };
            try std.testing.expectEqual(key.chunkBounds().intersectsRadius(-1, -1, 4), f.regions[1].contains(key));
        }
    }
    // The inclusive negative edge is eligible even when its region center is outside.
    const hole = LODRegionKey.fromChunkCoords(-5, -1, .lod1);
    f.regions[1].get(hole).?.setState(.missing);
    f.pending = 0;
    ctx.max_scan_steps = 2;
    ctx.max_admissions = 1;
    var rediscovered = false;
    for (0..128) |_| {
        const result = try queueLODRegionsBounded(ctx, .lod1, Vec3.zero, null, null);
        try std.testing.expect(result.examined <= 2);
        if (result.admitted == 1) {
            const job = f.queue.pop().?;
            try std.testing.expectEqual(hole.rx, job.data.chunk.x);
            try std.testing.expectEqual(hole.rz, job.data.chunk.z);
            rediscovered = true;
            break;
        }
    }
    try std.testing.expect(rediscovered);
}

test "bounded LOD memory and pending denial preserve first unadmitted candidate" {
    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    var ctx = f.context(.near0);
    ctx.max_admissions = 1;
    ctx.logical_memory_limit_bytes = 1023;
    const denied = try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null);
    try std.testing.expect(denied.memory_blocked and !denied.exhausted);
    try std.testing.expectEqual(@as(usize, 0), denied.admitted);
    try std.testing.expectEqual(@as(usize, 0), f.regions[0].count());
    try std.testing.expectEqual(@as(usize, 0), f.logical);
    try std.testing.expectEqual(@as(i64, 0), f.local_state.next_ring);
    ctx.logical_memory_limit_bytes = 1024;
    ctx.resident_region_limit = 0;
    try std.testing.expect((try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null)).memory_blocked);
    ctx.resident_region_limit = 1;
    f.pending = MAX_PENDING_LOD_REGIONS;
    const pending = try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null);
    try std.testing.expect(pending.pending_blocked);
    try std.testing.expectEqual(@as(usize, 0), pending.examined);
    f.pending = 0;
    const admitted = try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null);
    try std.testing.expectEqual(@as(usize, 1), admitted.admitted);
    const first = LODRegionKey.fromChunkCoords(-1, -1, .lod0);
    try std.testing.expect(f.regions[0].contains(first));
    try std.testing.expectEqual(@as(usize, 1024), f.logical);
}

test "bounded LOD paused and stopped queues roll back new and existing chunks" {
    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    var ctx = f.context(.near0);
    ctx.max_admissions = 1;
    f.queue.setPaused(true);
    const paused = try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null);
    try std.testing.expect(paused.pending_blocked);
    try std.testing.expectEqual(@as(usize, 0), paused.admitted);
    try std.testing.expectEqual(@as(usize, 0), f.regions[0].count());
    try std.testing.expectEqual(@as(usize, 0), f.logical);
    try std.testing.expectEqual(@as(u32, 1), f.next_token);
    try std.testing.expectEqual(@as(i64, 0), f.local_state.next_ring);

    const key = LODRegionKey.fromChunkCoords(-1, -1, .lod0);
    const chunk = try f.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    f.regions[0].put(key, chunk) catch |err| {
        f.allocator.destroy(chunk);
        return err;
    };
    chunk.job_token = 37;
    chunk.job_priority = 123;
    chunk.preserve_job_priority = true;
    chunk.service_lane = 4;
    chunk.requestCancellation();
    f.queue.stop();
    const stopped = try queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null);
    try std.testing.expect(stopped.pending_blocked);
    try std.testing.expectEqual(@as(usize, 0), stopped.admitted);
    try std.testing.expectEqual(@as(usize, 1), f.regions[0].count());
    try std.testing.expectEqual(lod_chunk.LODState.missing, chunk.getState());
    try std.testing.expectEqual(@as(u32, 37), chunk.job_token);
    try std.testing.expectEqual(@as(i32, 123), chunk.job_priority);
    try std.testing.expectEqual(@as(u3, 4), chunk.service_lane);
    try std.testing.expect(chunk.preserve_job_priority and chunk.cancellationRequested());
    try std.testing.expectEqual(@as(usize, 0), f.pending);
}

test "bounded LOD allocation failures roll back discovery map reservations and submissions" {
    inline for (.{ false, true }) |deferred| {
        var failures: usize = 0;
        var successes: usize = 0;
        for (0..8) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            var f = BoundedFixture.init(failing.allocator());
            defer f.deinit();
            var ctx = f.context(.near0);
            ctx.max_admissions = 1;
            ctx.defer_generation_dispatch = deferred;
            ctx.generation_tokens = if (deferred) &f.tokens else null;
            const result = queueLODRegionsBounded(ctx, .lod0, Vec3.zero, null, null) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                try std.testing.expectEqual(@as(usize, 0), f.regions[0].count());
                try std.testing.expectEqual(@as(usize, 0), f.logical);
                try std.testing.expectEqual(@as(usize, 0), f.pending);
                try std.testing.expectEqual(@as(u32, 1), f.next_token);
                try std.testing.expectEqual(@as(i64, 0), f.local_state.next_ring);
                try std.testing.expectEqual(@as(usize, 0), f.queue.count() + f.tokens.count());
                continue;
            };
            successes += 1;
            try std.testing.expectEqual(@as(usize, 1), result.admitted);
            try std.testing.expectEqual(@as(usize, 1), f.queue.count() + f.tokens.count());
        }
        try std.testing.expect(failures >= 4);
        try std.testing.expect(successes > 0);
    }
}

test "bounded LOD lifecycle capacity rejection rewinds before durable lane admission" {
    var f = BoundedFixture.init(std.testing.allocator);
    defer f.deinit();
    var ctx = f.context(.local_fallback);
    ctx.max_admissions = 1;
    ctx.defer_generation_dispatch = true;
    ctx.generation_tokens = &f.tokens;
    f.tokens.capacity = 0;
    f.tokens.overflow_capacity = 0;
    const rejected = try queueLODRegionsBounded(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expect(rejected.pending_blocked);
    try std.testing.expectEqual(@as(usize, 0), rejected.admitted);
    try std.testing.expectEqual(@as(usize, 0), f.regions[4].count());
    try std.testing.expectEqual(@as(usize, 0), f.logical);
    try std.testing.expectEqual(@as(usize, 0), f.pending);
    try std.testing.expectEqual(@as(u32, 1), f.next_token);
    try std.testing.expectEqual(@as(i64, 0), f.local_state.next_ring);
    f.tokens.capacity = 1;
    const result = try queueLODRegionsBounded(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expectEqual(@as(usize, 1), result.admitted);
    try std.testing.expectEqual(@as(usize, 0), f.queue.count());
    try std.testing.expectEqual(@as(usize, 1), f.tokens.count());
    const token = f.tokens.pop().?;
    const chunk = f.regions[4].get(token.key).?;
    try std.testing.expectEqual(lod_chunk.LODState.queued_for_generation, chunk.getState());
    try std.testing.expectEqual(@as(u3, 0), token.service_lane);
    try std.testing.expectEqual(token.service_lane, chunk.service_lane);
    try std.testing.expect(token.matches(chunk));
    try std.testing.expectEqual(@as(usize, 1024), f.logical);
}
