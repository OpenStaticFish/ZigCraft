const std = @import("std");
const Self = @import("lod_manager.zig").LODManager;
const fs = @import("fs");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const ILODConfig = lod_chunk.ILODConfig;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Vertex = @import("engine-rhi").Vertex;
const engine_core = @import("engine-core");
const log = engine_core.log;
const JobSystem = engine_core.job_system;
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const lod_tile = @import("lod_tile.zig");
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const ChunkChecker = lod_gpu.ChunkChecker;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
const lod_service = @import("lod_service.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const TextureAtlas = @import("engine-assets").TextureAtlas;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODStats = @import("lod_stats.zig").LODStats;
const manager_ctx = @import("lod_manager_context.zig");
const ChunkCoordKey = manager_ctx.ChunkCoordKey;
const ChunkCoordKeyContext = manager_ctx.ChunkCoordKeyContext;
const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);
const ChunkResolver = manager_ctx.ChunkResolver;
const PendingIngestion = manager_ctx.PendingIngestion;
const PlayerChunkPos = manager_ctx.PlayerChunkPos;
const GenerationCandidate = manager_ctx.GenerationCandidate;
const LifecycleStage = manager_ctx.LifecycleStage;
const LifecycleToken = manager_ctx.LifecycleToken;
const MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE = manager_ctx.MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE;
const LIFECYCLE_RECONCILIATION_INTERVAL = manager_ctx.LIFECYCLE_RECONCILIATION_INTERVAL;
const MAX_CACHE_LOADS_PER_UPDATE = manager_ctx.MAX_CACHE_LOADS_PER_UPDATE;
const MAX_MEMORY_EVICTIONS_PER_UPDATE = manager_ctx.MAX_MEMORY_EVICTIONS_PER_UPDATE;
const MAX_MESH_DELETIONS_PER_SWEEP = manager_ctx.MAX_MESH_DELETIONS_PER_SWEEP;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = manager_ctx.DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const LOGICAL_LOD_REGION_RESERVATION_BYTES = manager_ctx.LOGICAL_LOD_REGION_RESERVATION_BYTES;
const LOD_UPLOAD_BUDGET_ENV = manager_ctx.LOD_UPLOAD_BUDGET_ENV;
const LOD_UPDATE_DIVISOR = manager_ctx.LOD_UPDATE_DIVISOR;
const DELETION_SWEEP_SECONDS = manager_ctx.DELETION_SWEEP_SECONDS;
const CHUNK_COVERAGE_PADDING = manager_ctx.CHUNK_COVERAGE_PADDING;
const MIN_LOD_WORKERS = manager_ctx.MIN_LOD_WORKERS;
const MAX_LOD_WORKERS = manager_ctx.MAX_LOD_WORKERS;
const MAX_PENDING_INGESTIONS = manager_ctx.MAX_PENDING_INGESTIONS;
const PENDING_INGESTION_TTL = manager_ctx.PENDING_INGESTION_TTL;
const EDIT_FLUSH_COOLDOWN = manager_ctx.EDIT_FLUSH_COOLDOWN;
const LOD_FRAME_DT_APPROX = manager_ctx.LOD_FRAME_DT_APPROX;
const lodUploadBudgetBytes = manager_ctx.lodUploadBudgetBytes;
const wouldExceedUploadBudget = manager_ctx.wouldExceedUploadBudget;
const isUploadPressureError = manager_ctx.isUploadPressureError;

const scene = world_core.lod_scene;
const scene_builder = @import("lod_scene_builder.zig");
const BudgetAllocator = @import("lod_budget_allocator.zig").BudgetAllocator;
const BACKGROUND_RETRY_TICKS = 180;

/// Only worker-owned replacement data is mutable. The lifetime pin survives the
/// queue, worker and pending upload; cleanup never takes the manager mutex.
pub const CanonicalRefresh = struct {
    manager: *Self,
    key: LODRegionKey,
    token: u32,
    region: *LODChunk,
    density: f32,
    quota: *BudgetAllocator,
    background: bool,
    data: ?LODSimplifiedData = null,
    mesh: ?*LODMesh = null,
    bytes: usize = BudgetAllocator.admission_bytes,

    fn accountBytes(work: *CanonicalRefresh, bytes: usize) void {
        if (bytes >= work.bytes) {
            _ = work.manager.canonical_refresh_bytes.fetchAdd(bytes - work.bytes, .acq_rel);
        } else {
            _ = work.manager.canonical_refresh_bytes.fetchSub(work.bytes - bytes, .acq_rel);
        }
        work.bytes = bytes;
    }

    fn release(work: *CanonicalRefresh, retry: bool) void {
        const self = work.manager;
        if (work.data) |*data| data.deinit();
        if (work.mesh) |mesh| {
            // This path is CPU-only. Uploaded replacements are detached or
            // destroyed on the main thread before releasing the context.
            const build = mesh.takePendingCpuBuild();
            if (build.vertices) |vertices| mesh.allocator.free(vertices);
            mesh.releasePendingCompactTile();
            mesh.releaseAllocatorOwner();
            self.allocator.destroy(mesh);
        }
        if (retry) work.region.canonical_refresh_requested.store(true, .release);
        work.region.refresh_in_flight.store(false, .release);
        work.region.unpin();
        _ = self.canonical_refresh_bytes.fetchSub(work.bytes, .acq_rel);
        _ = self.canonical_refresh_count.fetchSub(1, .acq_rel);
        if (work.background) _ = self.canonical_background_refresh_count.fetchSub(1, .acq_rel);
        work.quota.release();
        self.allocator.destroy(work);
    }

    fn cleanup(ptr: *anyopaque) void {
        const work: *CanonicalRefresh = @ptrCast(@alignCast(ptr));
        work.release(true);
    }

    fn publish(work: *CanonicalRefresh) void {
        const self = work.manager;
        self.canonical_completion_mutex.lock();
        defer self.canonical_completion_mutex.unlock();
        for (&self.canonical_completions) |*slot| if (slot.* == null) {
            slot.* = work;
            return;
        };
        unreachable; // Count includes queued, active, and completed contexts.
    }

    fn process(ptr: *anyopaque) void {
        const work: *CanonicalRefresh = @ptrCast(@alignCast(ptr));
        const self = work.manager;
        // Failures also reach main so retry delay is written under its lock.
        defer work.publish();
        defer {
            work.accountBytes(work.quota.snapshot().used + @sizeOf(BudgetAllocator) + @sizeOf(CanonicalRefresh) + if (work.mesh != null) @as(usize, @sizeOf(LODMesh)) else 0);
        }
        if (self.job_dispatcher.stop_flag.load(.acquire) or work.region.cancellationRequested()) return;
        self.service_counters.record(.started, work.region.service_lane);
        work.data = LODSimplifiedData.initWithSampleDensity(work.quota.allocator(), work.key.lod, work.density) catch return;
        const data = &work.data.?;
        self.generator.generateHeightmapOnly(data, work.key.rx, work.key.rz, work.key.lod, &work.region.cancel_requested);
        attachCanonicalGrid(self, data, work.key, &work.region.cancel_requested) catch return;
        const mesh = initCanonicalMesh(self, work.key.lod, work.quota) catch return;
        mesh.buildFromSceneGrid(data.scene_grid.?, self.atlas) catch {
            const build = mesh.takePendingCpuBuild();
            if (build.vertices) |vertices| mesh.allocator.free(vertices);
            mesh.releaseAllocatorOwner();
            self.allocator.destroy(mesh);
            return;
        };
        work.mesh = mesh;
    }
};

fn initCanonicalMesh(self: *Self, level: LODLevel, quota: *BudgetAllocator) !*LODMesh {
    const mesh = try self.allocator.create(LODMesh);
    mesh.* = LODMesh.init(quota.allocator(), level);
    quota.retain();
    mesh.allocator_owner = .{ .ptr = quota, .release_fn = BudgetAllocator.releaseOwner, .parent_allocator = self.allocator };
    return mesh;
}

pub fn attachCanonicalGrid(self: *Self, data: *LODSimplifiedData, key: LODRegionKey, cancel: ?*const std.atomic.Value(bool)) !void {
    const source = self.source_hierarchy orelse return;
    const size = world_core.regionSizeBlocks(key.lod);
    const origin_x = try std.math.mul(i32, key.rx, @intCast(size));
    const origin_z = try std.math.mul(i32, key.rz, @intCast(size));
    const allocator = data.allocator;
    const grid = try allocator.create(scene.SceneGrid);
    errdefer allocator.destroy(grid);
    grid.* = try scene_builder.build(allocator, data, origin_x, origin_z, size, source.provider(), @intFromEnum(key.lod) <= 1, cancel);
    if (data.scene_grid) |old| {
        old.deinit();
        allocator.destroy(old);
    }
    data.scene_grid = grid;
    // Legacy samples are diagnostics/bounds only, not canonical mesh inputs.
    for (0..data.width) |z| for (0..data.width) |x| {
        const gx: i32 = @intCast(x);
        const gz: i32 = @intCast(z);
        const index = z * data.width + x;
        const info = grid.columnInfo(gx, gz);
        data.heightmap[index] = 0;
        data.top_blocks[index] = .air;
        for (grid.column(gx, gz)) |span| {
            if (span.max_y >= data.heightmap[index]) {
                data.heightmap[index] = span.max_y;
                data.top_blocks[index] = span.block;
                data.biomes[index] = span.biome;
            }
        }
        data.provenance[index] = if (info.known_area == info.total_area) .chunk_derived else .worldgen;
    };
}

/// Each changed chunk can intersect at most nine region-plus-halo footprints
/// per level. No block-coordinate or resident-map sweep on the normal path.
pub fn invalidateCanonicalChunk(self: *Self, cx: i32, cz: i32) void {
    for (0..LODLevel.count) |level| {
        const lod: LODLevel = @enumFromInt(level);
        const key = LODRegionKey.fromChunkCoords(cx, cz, lod);
        for (0..3) |z| for (0..3) |x| {
            const rx = std.math.add(i32, key.rx, @as(i32, @intCast(x)) - 1) catch continue;
            const rz = std.math.add(i32, key.rz, @as(i32, @intCast(z)) - 1) catch continue;
            if (self.regions[level].get(.{ .rx = rx, .rz = rz, .lod = lod })) |region|
                region.canonical_refresh_requested.store(true, .release);
        };
    }
}

pub fn drainCanonicalChanges(self: *Self) void {
    const source = self.source_hierarchy orelse return;
    var changes: std.ArrayListUnmanaged(@import("lod_source_hierarchy.zig").ChunkCoord) = .empty;
    defer changes.deinit(self.allocator);
    const all = source.drainChanges(&changes, 32) catch return;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (all) {
        for (&self.regions) |*regions| {
            var it = regions.valueIterator();
            while (it.next()) |region| region.*.canonical_refresh_requested.store(true, .release);
        }
    } else for (changes.items) |coord| invalidateCanonicalChunk(self, coord.cx, coord.cz);
}

pub fn queueCanonicalRefreshes(self: *Self) void {
    if (!self.usesCanonicalSource() or self.job_dispatcher.stop_flag.load(.acquire)) return;
    self.updateStats();
    self.mutex.lock();
    defer self.mutex.unlock();
    const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
    // A retained refresh is optional for a background tile but urgent for a
    // local/near tile whose current source is stale. Walk lanes first so the
    // bounded replacement slots cannot let horizon refreshes starve near work.
    for (0..lod_service.CLASS_COUNT) |lane_index| {
        const service_lane: u3 = @intCast(lane_index);
        for (0..LODLevel.count) |_| {
            const level = self.canonical_refresh_level;
            self.canonical_refresh_level = (level + 1) % LODLevel.count;
            var it = self.regions[level].iterator();
            while (it.next()) |entry| {
                if (self.canonical_refresh_count.load(.acquire) >= 8) return;
                const region = entry.value_ptr.*;
                if (region.getState() != .renderable or region.isPinned() or
                    !region.canonical_refresh_requested.load(.acquire) or region.refresh_in_flight.load(.acquire) or
                    self.update_tick < region.canonical_retry_tick or region.service_lane != service_lane) continue;
                const background = region.service_lane >= @intFromEnum(lod_service.Class.horizon);
                if (background and self.canonical_background_refresh_count.load(.acquire) >= 4) continue;
                if (budget != 0 and BudgetAllocator.admission_bytes > lod_service.memoryLimitWithNearUsage(region.service_lane, budget, self.memory_governor.near_exclusive_bytes) -| self.memory_governor.logical_admission_bytes) {
                    // Only urgent lanes may reclaim space for a CPU build. A
                    // horizon/refinement refresh remains parked rather than
                    // evicting protected near terrain for soft-reserve capacity.
                    if (!background and BudgetAllocator.admission_bytes <= budget) {
                        self.memory_governor.requestAdmissionRecovery(region.service_lane, BudgetAllocator.admission_bytes);
                        self.memory_governor.pressure_pending = true;
                    }
                    continue;
                }
                const work = self.allocator.create(CanonicalRefresh) catch return;
                const quota = BudgetAllocator.init(self.allocator, BudgetAllocator.default_quota_bytes) catch {
                    self.allocator.destroy(work);
                    return;
                };
                work.* = .{ .manager = self, .key = entry.key_ptr.*, .token = region.job_token, .region = region, .density = self.sourceSampleDensity(entry.key_ptr.lod), .quota = quota, .background = background };
                region.pin();
                region.resetCancellation();
                region.refresh_in_flight.store(true, .release);
                region.canonical_refresh_requested.store(false, .release);
                region.canonical_retry_tick = self.update_tick +| 30;
                _ = self.canonical_refresh_count.fetchAdd(1, .acq_rel);
                if (background) _ = self.canonical_background_refresh_count.fetchAdd(1, .acq_rel);
                _ = self.canonical_refresh_bytes.fetchAdd(work.bytes, .acq_rel);
                const accepted = self.job_dispatcher.queues[LODLevel.count - 1].tryPush(.{
                    .type = .generic,
                    .priority = region.job_priority,
                    .service_lane = region.service_lane,
                    .data = .{ .generic = .{ .context = work, .process_fn = CanonicalRefresh.process, .cleanup_fn = CanonicalRefresh.cleanup } },
                }) catch false;
                if (!accepted) {
                    work.release(true);
                    return;
                }
                self.memory_governor.logical_admission_bytes +|= BudgetAllocator.admission_bytes;
                self.service_counters.record(.dispatched, region.service_lane);
            }
        }
    }
}

/// Drain the completion mutex before taking Self.mutex, including retries.
/// A failed GPU attempt leaves the independent replacement and old map intact.
pub fn drainCanonicalRefreshes(self: *Self, shutdown: bool) void {
    self.canonical_required_upload_bytes = 0;
    self.canonical_completion_mutex.lock();
    const completions = self.canonical_completions;
    self.canonical_completions = @splat(null);
    self.canonical_completion_mutex.unlock();
    var attempts: usize = 0;
    for (completions) |slot| {
        const work = slot orelse continue;
        if (shutdown) {
            if (work.mesh) |mesh| {
                self.gpu_bridge.destroy(mesh);
                mesh.releaseAllocatorOwner();
                self.allocator.destroy(mesh);
                work.mesh = null;
            }
            work.release(false);
            continue;
        }
        self.updateStats();
        self.mutex.lock();
        const region = self.regions[@intFromEnum(work.key.lod)].get(work.key);
        const mesh_slot = self.meshes[@intFromEnum(work.key.lod)].getPtr(work.key);
        const player = self.loadPlayerChunkPos();
        const in_range = @intFromEnum(work.key.lod) < lod_chunk.activeLODCount(self.config) and work.key.chunkBounds().intersectsRadius(player.cx, player.cz, self.config.getRadii()[@intFromEnum(work.key.lod)]);
        const valid = region == work.region and work.region.job_token == work.token and work.region.getState() == .renderable and mesh_slot != null and in_range;
        const current_epoch = if (work.region.data == .simplified) if (work.region.data.simplified.scene_grid) |grid| grid.source_epoch else 0 else 0;
        const stale = if (work.data) |data| if (data.scene_grid) |grid| grid.source_epoch < current_epoch else true else true;
        const lost_coverage = if (work.region.data == .simplified and work.data != null) if (work.region.data.simplified.scene_grid) |old| if (work.data.?.scene_grid) |new| !preservesKnownCoverage(old, new) else true else false else false;
        if (!valid or stale or lost_coverage or work.mesh == null or work.region.cancellationRequested()) {
            work.region.canonical_retry_tick = self.update_tick +| (if (work.background) @as(u32, BACKGROUND_RETRY_TICKS) else 30);
            if (work.mesh) |mesh| {
                self.gpu_bridge.destroy(mesh);
                mesh.releaseAllocatorOwner();
                self.allocator.destroy(mesh);
                work.mesh = null;
            }
            work.release(valid);
            self.mutex.unlock();
            continue;
        }
        const mesh = work.mesh.?;
        const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
        const available = if (budget == 0) std.math.maxInt(usize) else lod_service.memoryLimitWithNearUsage(work.region.service_lane, budget, self.memory_governor.near_exclusive_bytes) -| self.memory_governor.logical_admission_bytes;
        self.gpu_bridge.prepareUpload(mesh, available);
        const cost = self.gpu_bridge.uploadMemoryCost(mesh);
        const staging = self.gpu_bridge.uploadCost(mesh).total();
        const blocked = cost > available or attempts >= @min(self.config.getMaxUploadsPerFrame(), 2) or self.canonical_upload_failed or
            (self.canonical_upload_attempted and staging > self.memory_governor.maintenance_staging_bytes);
        if (blocked) {
            if (cost > available) {
                self.memory_governor.pressure_pending = true;
                // Near replacements may request eviction headroom, but coarse
                // refreshes must not spend the near-service reserve.
                if (work.region.service_lane < @intFromEnum(lod_service.Class.horizon) and cost <= budget) {
                    const previous = self.canonical_required_upload_bytes;
                    self.canonical_required_upload_bytes = if (previous == 0) cost else @min(previous, cost);
                }
                if (work.background) {
                    work.region.canonical_retry_tick = self.update_tick +| BACKGROUND_RETRY_TICKS;
                    self.gpu_bridge.destroy(mesh);
                    mesh.releaseAllocatorOwner();
                    self.allocator.destroy(mesh);
                    work.mesh = null;
                    work.release(true);
                    self.mutex.unlock();
                    continue;
                }
            }
            self.mutex.unlock();
            work.publish();
            continue;
        }
        self.mesh_disposal.queue.ensureUnusedCapacity(self.allocator, 1) catch {
            self.mutex.unlock();
            work.publish();
            continue;
        };
        attempts += 1;
        self.canonical_upload_attempted = true;
        self.memory_governor.maintenance_staging_bytes -|= staging;
        self.gpu_bridge.upload(mesh) catch {
            self.memory_governor.maintenance_staging_bytes = 0;
            self.canonical_upload_failed = true;
            // A failed backend may retain newly allocated backing. Include it
            // until successful publication or main-thread disposal.
            const memory = mesh.memorySnapshot();
            const bytes = @sizeOf(BudgetAllocator) + @sizeOf(CanonicalRefresh) + @sizeOf(LODMesh) + work.quota.snapshot().used + if (memory.pooled) @as(usize, 0) else memory.capacity_bytes;
            work.accountBytes(bytes);
            self.stats.upload_failures +|= 1;
            self.memory_governor.pressure_pending = true;
            self.mutex.unlock();
            work.publish();
            continue;
        };
        if (!mesh.isCoverageReady()) {
            // Unknown empty output is not proof that old terrain disappeared.
            // Rebuild after source progress instead of publishing a hole.
            self.gpu_bridge.destroy(mesh);
            mesh.releaseAllocatorOwner();
            self.allocator.destroy(mesh);
            work.mesh = null;
            work.region.canonical_retry_tick = self.update_tick +| 30;
            work.release(true);
            self.mutex.unlock();
            continue;
        }
        const was_ready = self.regionContributesGeometry(work.key, work.region);
        const old_mesh = mesh_slot.?.*;
        mesh_slot.?.* = mesh;
        var old_data = work.region.data;
        work.region.data = .{ .simplified = work.data.? };
        work.region.canonical_allocator = work.quota;
        work.data = null;
        work.mesh = null;
        work.region.bumpSourceRevision();
        mesh.setSourceIdentity(work.token, work.region.source_revision);
        work.region.updateHeightBoundsFromData();
        const ready = self.regionContributesGeometry(work.key, work.region);
        if (ready != was_ready) self.adjustParentReadyChildren(work.key, if (ready) 1 else -1);
        self.queueMeshDeletion(old_mesh);
        switch (old_data) {
            .simplified => |*data| data.deinit(),
            else => {},
        }
        self.enqueueFade(work.key, work.region);
        self.service_counters.record(.renderable, work.region.service_lane);
        work.release(false);
        self.mutex.unlock();
    }
}

/// Epoch advancement cannot turn an authoritative cell back into an estimate.
/// Include the halo: losing measured neighbors can also expose guessed faces.
pub fn preservesKnownCoverage(old: *const scene.SceneGrid, new: *const scene.SceneGrid) bool {
    if (old.origin_x != new.origin_x or old.origin_z != new.origin_z or old.width != new.width or old.cell_size != new.cell_size or old.columns.len != new.columns.len) return false;
    for (old.columns, new.columns) |previous, next| {
        if (previous.known_area == 0) continue;
        if (next.known_area < previous.known_area or next.total_area != previous.total_area) return false;
    }
    // Equal area can hide losing chunk A and gaining B in a coarse cell. Both
    // lists are sorted (cz, cx); manual old grids without identities retain the
    // count checks above, while production grids require every old input pin.
    var index: usize = 0;
    for (old.known_chunks.items) |previous| {
        while (index < new.known_chunks.items.len) : (index += 1) {
            const next = new.known_chunks.items[index];
            if (next.cz > previous.cz or (next.cz == previous.cz and next.cx >= previous.cx)) break;
        }
        if (index == new.known_chunks.items.len or !std.meta.eql(previous, new.known_chunks.items[index])) return false;
        index += 1;
    }
    return true;
}

pub fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    return lod_scheduler.queueLODRegions(schedulerContext(self, lod, null), lod, velocity, chunk_checker, checker_ctx);
}

pub fn queueLODService(self: *Self, lod: LODLevel, lane: u3, scan_state: *manager_ctx.LODScanState, max_scan_steps: usize, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !lod_scheduler.ScheduleResult {
    var ctx = schedulerContext(self, lod, lane);
    ctx.scan_state_override = scan_state;
    ctx.max_admissions = 1;
    ctx.max_scan_steps = @min(max_scan_steps, 128);
    // The service classifier reads config.getChunkRenderRadius(): this is the
    // configured full-detail collar, never the active startup render radius.
    const result = try lod_scheduler.queueLODRegionsBounded(ctx, lod, velocity, chunk_checker, checker_ctx);
    if (result.memory_blocked and lane < @intFromEnum(lod_service.Class.horizon)) {
        const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
        const reservation = BudgetAllocator.admission_bytes;
        if (budget != 0 and reservation <= budget) {
            self.memory_governor.requestAdmissionRecovery(lane, reservation);
            self.memory_governor.pressure_pending = true;
        }
    }
    return result;
}

fn schedulerContext(self: *Self, lod: LODLevel, lane: ?u3) lod_scheduler.SchedulerContext {
    // Canonical source cache capacity exists before the first region is
    // admitted. Refresh it here, at the admission boundary, rather than only
    // after cold-start work has already reserved region quotas.
    if (self.usesCanonicalSource()) self.updateStats();
    const player = self.loadPlayerChunkPos();
    self.mutex.lock();
    const radii = self.config.getRadii();
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    const use_vertical_spans = self.sourceRequiresSpans(lod);
    const memory_budget_bytes = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
    self.mutex.unlock();

    const Coverage = struct {
        fn areAllLoaded(ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
            const mgr: *Self = @ptrCast(@alignCast(ptr));
            return mgr.areAllChunksLoaded(bounds, checker, ctx);
        }
    };
    return .{
        .allocator = self.allocator,
        .config = self.config,
        .radii = radii,
        .active_lod_count = active_lod_count,
        .regions = &self.regions,
        .gen_queues = &self.job_dispatcher.queues,
        .mutex = &self.mutex,
        .player_cx = player.cx,
        .player_cz = player.cz,
        .scan_states = &self.scan_states,
        .next_job_token = &self.job_dispatcher.next_token,
        .cleanup_covered_regions = self.cleanup_covered_regions,
        .coverage_ptr = self,
        .are_all_chunks_loaded = Coverage.areAllLoaded,
        .radius_reduction = &self.memory_governor.radius_shrink_chunks,
        // Route every region through the bounded admission path, whether or
        // not persistent LOD caching is enabled.
        .defer_generation_dispatch = true,
        .pending_regions = &self.pending_region_count,
        // Distance is not bounded by a fixed region count. The logical-memory
        // reservation below provides the actual resource-based backpressure.
        .resident_region_limit = std.math.maxInt(usize),
        // Legacy unclassified scheduling retains the full hard budget.
        .logical_memory_limit_bytes = lod_service.memoryLimitWithNearUsage(lane orelse @intFromEnum(lod_service.Class.near0), memory_budget_bytes, self.memory_governor.near_exclusive_bytes),
        .service_lane = lane,
        .logical_memory_bytes = &self.memory_governor.logical_admission_bytes,
        .logical_region_reservation_bytes = if (self.usesCanonicalSource()) BudgetAllocator.admission_bytes else if (memory_budget_bytes == 0) 0 else @min(memory_budget_bytes, LOGICAL_LOD_REGION_RESERVATION_BYTES),
        .use_vertical_spans = use_vertical_spans,
        .generation_tokens = &self.generation_tokens,
    };
}

pub fn processQueuedGenerations(self: *Self, velocity: Vec3) !void {
    const cache_path = self.cacheDirPathSnapshot();
    defer if (cache_path) |path| self.allocator.free(path);
    var cache_reads: usize = 0;
    var processed: usize = 0;
    while (processed < MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE) : (processed += 1) {
        const token = self.generation_tokens.pop() orelse break;
        const candidate = generationCandidateFromToken(self, token, velocity) orelse continue;
        if (cache_path) |path| {
            if (!self.usesNearSource(candidate.key.lod) and cache_reads < MAX_CACHE_LOADS_PER_UPDATE) {
                cache_reads += 1;
                self.mutex.lock();
                if (candidate.chunk.getState() == .queued_for_generation and candidate.chunk.job_token == candidate.job_token and candidate.chunk.source_revision == token.source_revision and !candidate.chunk.cache_read_queued) {
                    candidate.chunk.cache_read_queued = true;
                    const accepted = self.cache_io.enqueueRead(path, candidate.key, self.cacheKey(candidate.key), candidate.job_token) catch false;
                    if (accepted) {
                        self.mutex.unlock();
                        continue;
                    }
                    candidate.chunk.cache_read_queued = false;
                }
                self.mutex.unlock();
            }
        }

        if (!(try dispatchGenerationCandidate(self, candidate))) break;
    }
}

pub fn dispatchCacheMiss(self: *Self, key: LODRegionKey, token: u32) void {
    const lod_idx = @intFromEnum(key.lod);
    self.mutex.lock();
    const chunk = self.regions[lod_idx].get(key) orelse {
        self.mutex.unlock();
        return;
    };
    if (chunk.getState() != .queued_for_generation or chunk.job_token != token) {
        self.mutex.unlock();
        return;
    }
    const scale: i32 = @intCast(key.lod.chunksPerSide());
    const candidate = GenerationCandidate{
        .key = key,
        .chunk = chunk,
        .encoded_priority = chunk.job_priority,
        .level = @intCast(lod_idx),
        .coord_scale = scale,
        .job_token = token,
        .lod_radius = self.config.getRadii()[lod_idx],
        .want_spans = self.sourceRequiresSpans(key.lod),
    };
    self.mutex.unlock();
    _ = dispatchGenerationCandidate(self, candidate) catch |err| {
        log.log.warn("Failed to dispatch cache-miss LOD{} generation ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
        return;
    };
}

fn generationCandidateFromToken(self: *Self, token: LifecycleToken, velocity: Vec3) ?GenerationCandidate {
    _ = velocity;
    if (token.stage != .generation) return null;
    const lod_idx = @intFromEnum(token.key.lod);
    self.mutex.lock();
    defer self.mutex.unlock();
    const chunk = self.regions[lod_idx].get(token.key) orelse return null;
    if (chunk.getState() != .queued_for_generation or !token.matches(chunk)) return null;
    const scale: i32 = @intCast(token.key.lod.chunksPerSide());
    return .{
        .key = token.key,
        .chunk = chunk,
        .encoded_priority = chunk.job_priority,
        .level = @intCast(lod_idx),
        .coord_scale = scale,
        .job_token = token.job_token,
        .lod_radius = self.config.getRadii()[lod_idx],
        .want_spans = self.sourceRequiresSpans(token.key.lod),
    };
}

fn dispatchGenerationCandidate(self: *Self, candidate: GenerationCandidate) !bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (candidate.chunk.getState() != .queued_for_generation or candidate.chunk.job_token != candidate.job_token or candidate.chunk.cache_read_queued) {
        return true;
    }
    candidate.chunk.resetCancellation();
    candidate.chunk.setState(.generating);

    const dispatch_timer = self.profiling.begin();
    defer self.profiling.end(.generation_dispatch, dispatch_timer);
    const accepted = self.job_dispatcher.queues[LODLevel.count - 1].tryPush(.{
        .type = .chunk_generation,
        .dist_sq = candidate.encoded_priority,
        .service_lane = candidate.chunk.service_lane,
        .data = .{ .chunk = .{
            .x = candidate.chunk.region_x,
            .z = candidate.chunk.region_z,
            .job_token = candidate.job_token,
            .lod_level = candidate.level,
            .coord_scale = candidate.coord_scale,
            .preserve_priority = candidate.chunk.preserve_job_priority,
            .lod_radius = candidate.lod_radius,
            .use_vertical_spans = candidate.want_spans,
        } },
    }) catch |err| {
        candidate.chunk.setState(.queued_for_generation);
        self.enqueueTransition(candidate.key, candidate.chunk, .generation);
        return err;
    };
    if (!accepted) {
        candidate.chunk.setState(.queued_for_generation);
        self.enqueueTransition(candidate.key, candidate.chunk, .generation);
        return false;
    }
    self.service_counters.record(.dispatched, candidate.chunk.service_lane);
    return true;
}

/// Process state transitions (generated -> meshing -> ready)
pub fn processStateTransitions(self: *Self, velocity: Vec3) !void {
    _ = velocity;
    var processed: usize = 0;
    while (processed < MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE) : (processed += 1) {
        const token = self.transition_tokens.pop() orelse break;
        const lod_idx = @intFromEnum(token.key.lod);
        // Transition and enqueue atomically with respect to workers. A worker
        // may pop immediately, but cannot inspect the chunk until this short
        // manager critical section publishes the matching state.
        self.mutex.lock();
        const chunk = self.regions[lod_idx].get(token.key) orelse {
            self.mutex.unlock();
            continue;
        };
        if (!token.matches(chunk)) {
            self.mutex.unlock();
            continue;
        }
        if (chunk.isPinned()) {
            self.enqueueTransition(token.key, chunk, token.stage);
            self.mutex.unlock();
            continue;
        }
        if (token.stage == .upload) {
            if (chunk.getState() != .mesh_ready) {
                self.mutex.unlock();
                continue;
            }
            if (self.meshes[lod_idx].get(token.key)) |mesh| patchCompactAprons(self, lod_idx, token.key, mesh);
            chunk.setState(.uploading);
            self.upload_queues[lod_idx].push(chunk) catch |err| {
                chunk.setState(.mesh_ready);
                self.enqueueTransition(token.key, chunk, .upload);
                self.mutex.unlock();
                return err;
            };
            self.mutex.unlock();
            continue;
        }
        if (token.stage != .mesh or chunk.getState() != .generated) {
            self.mutex.unlock();
            continue;
        }
        const scale: i32 = @intCast(token.key.lod.chunksPerSide());
        // Captures may have arrived after generation/cache publication. Apply
        // once more before any worker can observe the first mesh input.
        _ = self.overlayNearSourcesLocked(chunk);
        chunk.setState(.meshing);
        chunk.resetCancellation();
        const accepted = self.job_dispatcher.queues[LODLevel.count - 1].tryPush(.{
            .type = .chunk_meshing,
            .dist_sq = token.priority,
            .service_lane = chunk.service_lane,
            .data = .{
                .chunk = .{
                    .x = chunk.region_x,
                    .z = chunk.region_z,
                    .job_token = token.job_token,
                    .lod_level = @intCast(lod_idx),
                    .coord_scale = scale,
                    .preserve_priority = chunk.preserve_job_priority,
                    .lod_radius = self.config.getRadii()[lod_idx],
                },
            },
        }) catch |err| {
            if (chunk.getState() == .meshing and chunk.job_token == token.job_token) {
                chunk.setState(.generated);
                self.enqueueTransition(token.key, chunk, .mesh);
            }
            self.mutex.unlock();
            return err;
        };
        if (!accepted) {
            chunk.setState(.generated);
            self.enqueueTransition(token.key, chunk, .mesh);
            self.mutex.unlock();
            break;
        }
        self.service_counters.record(.dispatched, chunk.service_lane);
        // Never let a worker invoke RHI or release a live pooled range. Once
        // the replacement job is guaranteed to be queued, detach the previous
        // representation and retire it through the normal frame-delayed
        // disposal queue. The worker will create a fresh mesh object.
        if (self.meshes[lod_idx].fetchRemove(token.key)) |old_mesh| {
            self.queueMeshDeletion(old_mesh.value);
        }
        self.mutex.unlock();
    }
    if (self.update_tick % LIFECYCLE_RECONCILIATION_INTERVAL == 0) reconcileLifecycleTokens(self);
}

/// Explicit, infrequent fallback for queue overflow or legacy state changes.
/// Normal work is entirely token-driven; this sweep is intentionally the only
/// resident-map lifecycle scan and is observable in code/reports.
fn reconcileLifecycleTokens(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (&self.regions) |*regions| {
        var it = regions.iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.transition_frames_remaining > 0) self.enqueueFade(entry.key_ptr.*, chunk);
            const stage: LifecycleStage = switch (chunk.getState()) {
                .queued_for_generation => .generation,
                .generated => .mesh,
                .mesh_ready => .upload,
                else => continue,
            };
            const token = LifecycleToken{
                .key = entry.key_ptr.*,
                .job_token = chunk.job_token,
                .source_revision = chunk.source_revision,
                .priority = chunk.job_priority,
                .stage = stage,
                .service_lane = chunk.service_lane,
            };
            if (stage == .generation) {
                _ = self.generation_tokens.push(self.allocator, token) catch false;
            } else {
                _ = self.transition_tokens.push(self.allocator, token) catch false;
            }
        }
    }
}

pub fn enqueueTransition(self: *Self, key: LODRegionKey, chunk: *const LODChunk, stage: LifecycleStage) void {
    const token = LifecycleToken{
        .key = key,
        .job_token = chunk.job_token,
        .source_revision = chunk.source_revision,
        .priority = chunk.job_priority,
        .stage = stage,
        .service_lane = chunk.service_lane,
    };
    if (stage == .generation) {
        _ = self.generation_tokens.push(self.allocator, token) catch false;
    } else {
        _ = self.transition_tokens.push(self.allocator, token) catch false;
    }
}

pub fn enqueueFade(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
    if (chunk.transition_frames_remaining == 0) return;
    _ = self.fade_tokens.push(self.allocator, .{
        .key = key,
        .job_token = chunk.job_token,
        .source_revision = chunk.source_revision,
        .priority = 0,
        .stage = .fade,
    }) catch false;
}

fn patchCompactAprons(self: *Self, lod_index: usize, key: LODRegionKey, mesh: *LODMesh) void {
    const neighbors = [_]struct { dx: i32, dz: i32, edge: lod_tile.TileEdge }{
        .{ .dx = -1, .dz = 0, .edge = .west },
        .{ .dx = 1, .dz = 0, .edge = .east },
        .{ .dx = 0, .dz = -1, .edge = .north },
        .{ .dx = 0, .dz = 1, .edge = .south },
    };
    for (neighbors) |neighbor| {
        const neighbor_key = LODRegionKey{ .rx = key.rx + neighbor.dx, .rz = key.rz + neighbor.dz, .lod = key.lod };
        const neighbor_mesh = self.meshes[lod_index].get(neighbor_key) orelse continue;
        _ = mesh.patchCompactNeighbor(neighbor.edge, neighbor_mesh);
    }
}

pub fn getOrCreateMesh(self: *Self, key: LODRegionKey) !*LODMesh {
    self.mutex.lock();
    defer self.mutex.unlock();

    const lod_idx = @intFromEnum(key.lod);
    if (lod_idx >= LODLevel.count) return error.InvalidLODLevel;

    const meshes = &self.meshes[lod_idx];

    if (meshes.get(key)) |mesh| {
        return mesh;
    }

    const mesh = if (self.usesCanonicalSource()) canonical: {
        const chunk = self.regions[lod_idx].get(key) orelse return error.InvalidState;
        break :canonical try initCanonicalMesh(self, key.lod, chunk.canonical_allocator orelse return error.InvalidState);
    } else legacy: {
        const mesh = try self.allocator.create(LODMesh);
        mesh.* = LODMesh.init(self.allocator, key.lod);
        break :legacy mesh;
    };
    errdefer {
        mesh.releaseAllocatorOwner();
        self.allocator.destroy(mesh);
    }
    try meshes.put(key, mesh);
    return mesh;
}

/// Build mesh for an LOD chunk (called after generation completes)
pub fn buildMeshForChunk(self: *Self, chunk: *LODChunk) !void {
    // A meshing worker pins its chunk while it owns the immutable source data.
    // Ingestion defers writes to .meshing chunks and eviction skips pinned
    // chunks, so retaining the manager lock through mesh construction is both
    // unnecessary and a substantial source of contention.
    std.debug.assert(chunk.isPinned());
    std.debug.assert(chunk.getState() == .meshing);

    const key = LODRegionKey{
        .rx = chunk.region_x,
        .rz = chunk.region_z,
        .lod = chunk.lodLevel(),
    };

    const mesh = try self.getOrCreateMesh(key);
    mesh.setSourceIdentity(chunk.job_token, chunk.source_revision);

    switch (chunk.data) {
        .simplified => |*data| {
            const bounds = chunk.worldBounds();
            if (data.scene_grid) |grid| {
                try mesh.buildFromSceneGrid(grid, self.atlas);
                return;
            }
            if (self.usesNearSource(chunk.lodLevel())) {
                try mesh.buildFromNearSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
                return;
            }
            // Compact tiles carry water samples too. Unsupported mixed-shore
            // topology is rejected by `buildCompactTile` and immediately uses
            // the maintained expanded CPU fallback.
            if (shouldUseCompactTiles(self, chunk)) {
                self.profiling.addCompactSelected();
                mesh.buildCompactTile(data) catch |err| switch (err) {
                    error.UnsupportedSourceFeatures => {
                        self.profiling.addCompactBuildRejected();
                        const support = @import("lod_tile.zig").CompactLODTile.support(data, chunk.lodLevel());
                        log.log.warn("LOD{} compact build rejected for ({}, {}): {s}", .{ @intFromEnum(chunk.lodLevel()), chunk.region_x, chunk.region_z, @tagName(support) });
                        if (engine_core.envFlag("ZIGCRAFT_LOD_COMPACT_DIAG", false)) {
                            std.debug.print("LOD_COMPACT: event=build_rejected lod={} region=({}, {}) reason={s}\n", .{ @intFromEnum(chunk.lodLevel()), chunk.region_x, chunk.region_z, @tagName(support) });
                        }
                    },
                    else => {
                        self.profiling.addCompactBuildRejected();
                        return err;
                    },
                };
                if (mesh.isCompact()) {
                    return;
                }
            }
            switch (self.effectiveMeshPath(chunk.lodLevel())) {
                .heightfield => try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas),
                .column_spans => try mesh.buildFromColumnSpans(data, bounds.min_x, bounds.min_z, self.atlas),
                .qem => {
                    const lod = chunk.lodLevel();
                    const horizontal_detail = self.config.getHorizontalDetail(lod);
                    const detail_target = horizontal_detail * horizontal_detail;
                    const target = @max(self.config.getQEMTarget(lod), detail_target);
                    if (target == 0) {
                        try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
                    } else {
                        try mesh.buildFromSimplifiedDataWithQEM(data, bounds.min_x, bounds.min_z, target, self.config.getQEMMinInputTriangles(), self.atlas);
                    }
                },
            }
        },
        .full => {
            // LOD0 meshes handled by World, not LODManager
        },
        .empty => {
            // No data to build mesh from
        },
    }
}

/// Converts an unrenderable compact upload to the established CPU heightfield
/// route. The upload task pins `chunk`, so its simplified source is stable for
/// this synchronous recovery and can immediately be requeued without a hole.
///
/// CPU construction happens before compact retirement. If allocation fails,
/// the existing compact samples remain renderable and retryable. On success,
/// detach the new CPU payload across `destroy`: the bridge clears pending
/// vertices and the production compact pool clears all compact draw counts.
pub fn fallbackCompactMeshToCpu(self: *Self, mesh: *LODMesh, chunk: *LODChunk) !void {
    std.debug.assert(mesh.isCompact());
    switch (chunk.data) {
        .simplified => |*data| {
            const bounds = chunk.worldBounds();
            try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
        },
        else => return error.InvalidState,
    }
    var cpu_build = mesh.takePendingCpuBuild();

    self.gpu_bridge.destroy(mesh);
    // Lightweight test bridges may only release their own handle. Make the
    // transition deterministic in both cases without touching cpu_build.
    mesh.clearRetiredState();
    mesh.restorePendingCpuBuild(&cpu_build);
}

fn shouldUseCompactTiles(self: *Self, chunk: *const LODChunk) bool {
    if (self.usesCanonicalSource()) return false;
    if (chunk.compact_disabled) return false;
    if (!self.config.getCompactTilesEnabled()) return false;
    const lod = chunk.lodLevel();
    if (lod != .lod3 and lod != .lod4) return false;
    const mode = engine_core.getenv("ZIGCRAFT_LOD_COMPACT") orelse "auto";
    if (std.ascii.eqlIgnoreCase(mode, "off")) return false;
    // Auto requires the immutable descriptor snapshots used by compact
    // terrain/water GPU-culling streams, not only vertex-pulling support.
    if (std.ascii.eqlIgnoreCase(mode, "auto")) return self.gpu_bridge.supportsCompactGpuCulling();
    if (std.ascii.eqlIgnoreCase(mode, "force")) return self.gpu_bridge.supportsCompact();
    return false;
}

pub fn effectiveMeshPath(self: *Self, lod: LODLevel) lod_chunk.LODMeshPath {
    // Far bands stay as high-resolution stepped block columns. LOD2 keeps
    // the richer span path so mid-distance cliffs/trees remain voxel-like
    // without turning the terrain into a smooth polygon surface.
    if (@intFromEnum(lod) >= @intFromEnum(LODLevel.lod3)) return .heightfield;
    if (lod == LODConfig.coarsestLOD()) return .heightfield;
    if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_QEM", false)) return .qem;
    if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_SPANS", false)) return .column_spans;
    return self.config.getMeshPath();
}

/// Worker pool callback for LOD tasks (generation and meshing)
pub fn processLODJob(ctx: *anyopaque, job: Job) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const lod_level: LODLevel = @enumFromInt(job.data.chunk.lod_level);
    const key = LODRegionKey{
        .rx = job.data.chunk.x,
        .rz = job.data.chunk.z,
        .lod = lod_level,
    };

    const lod_idx = @intFromEnum(lod_level);

    // Phase 1: Acquire lock, validate job, pin chunk
    self.mutex.lock();
    const storage = &self.regions[lod_idx];

    const chunk = storage.get(key) orelse {
        self.mutex.unlock();
        return;
    };

    // Reject invalidated work before any state reconciliation. A stale queued
    // job must never demote a newer job for the same region.
    if (chunk.job_token != job.data.chunk.job_token) {
        self.mutex.unlock();
        return;
    }

    // Stale job check (too far from player)
    const player = self.loadPlayerChunkPos();
    const radius = job.data.chunk.lod_radius;
    const use_vertical_spans = self.usesNearSource(lod_level) or job.data.chunk.use_vertical_spans;
    const job_key = LODRegionKey{
        .rx = job.data.chunk.x,
        .rz = job.data.chunk.z,
        .lod = lod_level,
    };

    if (!job_key.chunkBounds().intersectsRadius(player.cx, player.cz, radius)) {
        if (chunk.getState() == .generating or chunk.getState() == .meshing) {
            if (self.pending_region_count > 0) self.pending_region_count -= 1;
            chunk.setState(.missing);
        }
        self.mutex.unlock();
        return;
    }

    // Check state and capture job type before releasing lock
    const current_state = chunk.getState();
    const job_type = job.type;

    // Validate state matches expected for job type
    const valid_state = switch (job_type) {
        .chunk_generation => current_state == .generating,
        .chunk_meshing => current_state == .meshing,
        else => false,
    };

    if (!valid_state) {
        self.mutex.unlock();
        return;
    }

    // Check if we need to generate data (while still holding lock)
    const needs_data_init = (job_type == .chunk_generation and chunk.data != .simplified);

    // Pin chunk during operation (prevents unload)
    chunk.pin();
    self.service_counters.record(.started, chunk.service_lane);
    self.mutex.unlock();

    // Phase 2: Do expensive work without lock
    var success = false;
    var new_state: LODState = .missing;
    // Only a job that publishes its representation may contribute far-path
    // evidence; stale and retried work is intentionally excluded below.
    const far_representation_timer = self.profiling.begin();

    switch (job_type) {
        .chunk_generation => {
            const generation_timer = self.profiling.begin();
            defer self.profiling.end(.worker_generation, generation_timer);
            // Initialize simplified data if needed
            if (needs_data_init) {
                const quota: ?*BudgetAllocator = if (self.usesCanonicalSource()) BudgetAllocator.init(self.allocator, BudgetAllocator.default_quota_bytes) catch {
                    self.mutex.lock();
                    if (chunk.job_token == job.data.chunk.job_token) {
                        if (self.pending_region_count > 0) self.pending_region_count -= 1;
                        chunk.setState(.missing);
                    }
                    chunk.unpin();
                    self.mutex.unlock();
                    return;
                } else null;
                defer if (quota) |owner| owner.release();
                const data_allocator = if (quota) |owner| owner.allocator() else self.allocator;
                var data = if (use_vertical_spans)
                    LODSimplifiedData.initWithVerticalSpansSampleDensity(data_allocator, lod_level, self.sourceSampleDensity(lod_level)) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) {
                            if (self.pending_region_count > 0) self.pending_region_count -= 1;
                            chunk.setState(new_state);
                        }
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    }
                else
                    LODSimplifiedData.initWithSampleDensity(data_allocator, lod_level, self.sourceSampleDensity(lod_level)) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) {
                            if (self.pending_region_count > 0) self.pending_region_count -= 1;
                            chunk.setState(new_state);
                        }
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    };

                // Generate heightmap data (expensive, done without lock).
                // Pass the region cancellation signal so pause and teleport
                // can interrupt a multi-second coarse-LOD generation loop.
                // Teardown sets both the manager flag and every region signal.
                self.generator.generateHeightmapOnly(&data, chunk.region_x, chunk.region_z, lod_level, &chunk.cancel_requested);
                if (self.usesCanonicalSource()) {
                    attachCanonicalGrid(self, &data, key, &chunk.cancel_requested) catch |err| {
                        // Retain an explicitly provisional fallback, never mark
                        // unavailable/corrupt block sources as known coverage.
                        if (err != error.Cancelled) log.log.warn("Canonical LOD{} source unavailable ({}, {}): {}; keeping provisional fallback", .{ @intFromEnum(lod_level), key.rx, key.rz, err });
                        chunk.canonical_refresh_requested.store(true, .release);
                    };
                }

                // A parent can contribute only when its grid spacing exactly
                // matches this child. This preserves seam samples and avoids
                // copying a different coarse footprint into refinement data.
                self.mutex.lock();
                if (if (self.usesCanonicalSource() or self.usesNearSource(lod_level)) null else key.parentKey()) |parent_key| {
                    if (self.regions[@intFromEnum(parent_key.lod)].get(parent_key)) |parent| switch (parent.data) {
                        .simplified => |*parent_data| {
                            const child_x: u1 = @intCast(@mod(chunk.region_x, 2));
                            const child_z: u1 = @intCast(@mod(chunk.region_z, 2));
                            _ = data.reuseAlignedParentSamples(parent_data, child_x, child_z);
                        },
                        else => {},
                    };
                }
                self.mutex.unlock();

                // If generation was aborted, discard the partial data
                // and leave the chunk in .missing so it re-generates later.
                if (self.job_dispatcher.stop_flag.load(.acquire) or chunk.cancellationRequested()) {
                    data.deinit();
                    new_state = .missing;
                    self.mutex.lock();
                    if (chunk.job_token == job.data.chunk.job_token) {
                        if (self.pending_region_count > 0) self.pending_region_count -= 1;
                        chunk.setState(new_state);
                    }
                    chunk.unpin();
                    self.mutex.unlock();
                    return;
                }

                // Acquire lock to update chunk data. A cache read or forced
                // save-time edit may have published source while this worker
                // was generating. Never let stale worldgen replace that newer
                // authoritative snapshot.
                self.mutex.lock();
                if (chunk.data == .simplified) {
                    data.deinit();
                } else {
                    chunk.data = .{ .simplified = data };
                    chunk.canonical_allocator = quota;
                    _ = self.overlayNearSourcesLocked(chunk);
                    chunk.updateHeightBoundsFromData();
                    chunk.markSourceDirty();
                }
                self.mutex.unlock();
            }
            success = true;
            new_state = .generated;
        },
        .chunk_meshing => {
            const mesh_timer = self.profiling.begin();
            defer self.profiling.end(.worker_mesh_construction, mesh_timer);
            // Build mesh (expensive, done without lock)
            // Note: buildMeshForChunk -> getOrCreateMesh acquires its own lock
            self.buildMeshForChunk(chunk) catch |err| {
                log.log.errWithTrace("Failed to build LOD{} async mesh: {}", .{ @intFromEnum(lod_level), err });
                new_state = .generated; // Retry later
                self.mutex.lock();
                if (chunk.job_token == job.data.chunk.job_token) {
                    chunk.setState(new_state);
                    self.enqueueTransition(key, chunk, .mesh);
                }
                chunk.unpin();
                self.mutex.unlock();
                return;
            };
            success = true;
            new_state = .mesh_ready;
        },
        else => unreachable,
    }

    // Phase 3: Acquire lock briefly to update state
    self.mutex.lock();
    if (success and chunk.job_token == job.data.chunk.job_token) {
        chunk.setState(new_state);
        if (new_state == .mesh_ready and (lod_level == .lod3 or lod_level == .lod4)) {
            const mesh = self.meshes[lod_idx].get(key) orelse unreachable;
            self.profiling.end(if (mesh.isCompact()) .worker_compact_encode else .worker_far_expanded_mesh_construction, far_representation_timer);
        }
        if (new_state == .generated) self.enqueueTransition(key, chunk, .mesh);
        if (new_state == .mesh_ready) self.enqueueTransition(key, chunk, .upload);
    }
    chunk.unpin();
    self.mutex.unlock();
}

test "LODManager rejected service dispatch retains retries and counts only validated work" {
    const allocator = std.testing.allocator;
    var config = LODConfig{};
    var manager = try Self.initCacheTestManager(allocator, "");
    defer manager.cache_io.deinit();
    defer manager.ingestion_queue.deinit(allocator);
    defer manager.generation_tokens.deinit(allocator);
    defer manager.transition_tokens.deinit(allocator);
    manager.config = config.interface();
    manager.update_tick = 1;
    var queue = JobQueue.init(allocator);
    defer queue.deinit();
    var live_queue = JobQueue.init(allocator);
    defer live_queue.deinit();
    const service = @import("lod_service.zig");
    queue.enableServiceLanes(&service.WHEEL);
    live_queue.enableServiceLanes(&service.WHEEL);
    manager.job_dispatcher = .{ .queues = @splat(&queue) };
    manager.generation_tokens.enableServiceLanes(&service.WHEEL);
    manager.transition_tokens.enableServiceLanes(&service.WHEEL);
    for (&manager.regions) |*regions| regions.* = RegionMap.init(allocator);
    for (&manager.meshes) |*meshes| meshes.* = MeshMap.init(allocator);
    defer {
        for (&manager.regions) |*regions| regions.deinit();
        for (&manager.meshes) |*meshes| meshes.deinit();
    }
    var chunk = LODChunk.init(0, 0, .lod0);
    defer chunk.deinit(allocator);
    chunk.job_token = 1;
    chunk.service_lane = @intFromEnum(service.Class.near0);
    chunk.setState(.queued_for_generation);
    // Existing source avoids generator calls when exercising the real worker.
    chunk.data = .{ .simplified = try LODSimplifiedData.init(allocator, .lod0) };
    try manager.regions[0].put(chunk.key(), &chunk);
    manager.pending_region_count = 1;
    manager.enqueueTransition(chunk.key(), &chunk, .generation);

    queue.setPaused(true);
    try manager.processQueuedGenerations(Vec3.zero);
    queue.setPaused(false);
    queue.stop();
    try manager.processQueuedGenerations(Vec3.zero);
    try std.testing.expectEqual(LODState.queued_for_generation, chunk.getState());
    try std.testing.expectEqual(@as(usize, 1), manager.generation_tokens.count());
    try std.testing.expectEqual(@as(usize, 1), manager.pending_region_count);
    try std.testing.expect(!chunk.isPinned());
    try std.testing.expectEqual(@as(u64, 0), manager.service_counters.snapshot().dispatched[chunk.service_lane]);

    manager.job_dispatcher.queues = @splat(&live_queue);
    try manager.processQueuedGenerations(Vec3.zero);
    const job = live_queue.tryPop().?;
    try std.testing.expectEqual(chunk.service_lane, job.service_lane);
    try std.testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().dispatched[chunk.service_lane]);
    var stale_job = job;
    stale_job.data.chunk.job_token = 0;
    processLODJob(&manager, stale_job);
    try std.testing.expectEqual(@as(u64, 0), manager.service_counters.snapshot().started[chunk.service_lane]);
    processLODJob(&manager, job);
    try std.testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().started[chunk.service_lane]);
    try std.testing.expectEqual(LODState.generated, chunk.getState());
    try std.testing.expect(!chunk.isPinned());

    live_queue.setPaused(true);
    try manager.processStateTransitions(Vec3.zero);
    try std.testing.expectEqual(LODState.generated, chunk.getState());
    try std.testing.expectEqual(@as(usize, 1), manager.transition_tokens.count());
    try std.testing.expectEqual(@as(usize, 1), manager.pending_region_count);
    try std.testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().dispatched[chunk.service_lane]);
    live_queue.setPaused(false);
    try manager.processStateTransitions(Vec3.zero);
    try std.testing.expectEqual(LODState.meshing, chunk.getState());
    try std.testing.expectEqual(chunk.service_lane, live_queue.tryPop().?.service_lane);
    try std.testing.expectEqual(@as(u64, 2), manager.service_counters.snapshot().dispatched[chunk.service_lane]);
    try std.testing.expect(!chunk.isPinned());
}
