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
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const ChunkChecker = lod_gpu.ChunkChecker;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
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
const MAX_CACHE_LOADS_PER_UPDATE = manager_ctx.MAX_CACHE_LOADS_PER_UPDATE;
const MAX_MEMORY_EVICTIONS_PER_UPDATE = manager_ctx.MAX_MEMORY_EVICTIONS_PER_UPDATE;
const MAX_MESH_DELETIONS_PER_SWEEP = manager_ctx.MAX_MESH_DELETIONS_PER_SWEEP;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = manager_ctx.DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const LOD_UPLOAD_BUDGET_ENV = manager_ctx.LOD_UPLOAD_BUDGET_ENV;
const LOD_UPDATE_DIVISOR = manager_ctx.LOD_UPDATE_DIVISOR;
const DELETION_SWEEP_SECONDS = manager_ctx.DELETION_SWEEP_SECONDS;
const CHUNK_COVERAGE_PADDING = manager_ctx.CHUNK_COVERAGE_PADDING;
const MIN_LOD_WORKERS = manager_ctx.MIN_LOD_WORKERS;
const MAX_LOD_WORKERS = manager_ctx.MAX_LOD_WORKERS;
const MAX_PENDING_INGESTIONS = manager_ctx.MAX_PENDING_INGESTIONS;
const EDIT_FLUSH_COOLDOWN = manager_ctx.EDIT_FLUSH_COOLDOWN;
const LOD_FRAME_DT_APPROX = manager_ctx.LOD_FRAME_DT_APPROX;
const lodUploadBudgetBytes = manager_ctx.lodUploadBudgetBytes;
const wouldExceedUploadBudget = manager_ctx.wouldExceedUploadBudget;
const isUploadPressureError = manager_ctx.isUploadPressureError;

pub fn setChunkResolver(self: *Self, resolver: ChunkResolver) void {
    self.ingestion_queue.mutex.lock();
    defer self.ingestion_queue.mutex.unlock();
    self.ingestion_queue.chunk_resolver = resolver;
}

/// Ingest a real chunk into every LOD level whose region contains it. The
/// chunk is downsampled into each region's source data with the given
/// provenance; higher provenance always wins. Regions that are missing or
/// currently in-flight are recorded as pending and replayed from
/// `update()`. Safe to call from the generation worker thread; the caller
/// must pin the chunk and synchronize block mutations for the call.
pub fn ingestChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
    if (self.captureNearChunk(chunk, if (provenance == .edited) .edited else .generated)) |capture| {
        if (!self.submitNearChunk(cx, cz, capture)) self.deferNearChunk(cx, cz, capture);
    }
    ingestCoarseChunk(self, cx, cz, chunk, provenance);
}

pub fn ingestCoarseChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
    const mask = activeIngestionMask(self) & (if (self.near_source_enabled) @as(u8, 0xfc) else @as(u8, 0xff));
    const pending_mask = applyIngestionToRegionsMask(self, cx, cz, chunk, provenance, mask);
    if (pending_mask != 0) {
        self.ingestion_queue.mutex.lock();
        const recorded = self.recordPendingLocked(cx, cz, provenance, pending_mask);
        if (!recorded and provenance == .edited) {
            // Preserve discoverability for persistence invalidation when the
            // bounded pending queue is saturated entirely by edited work.
            self.ingestion_queue.edit_dirty.put(.{ .cx = cx, .cz = cz }, {}) catch {};
        }
        self.ingestion_queue.mutex.unlock();
    }
}

/// Record a deferred ingestion without a chunk pointer. The chunk is
/// resolved later via `chunk_resolver` from `update()`. Used for chunk
/// loads that happen before their LOD region exists.
pub fn requestIngestion(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance) void {
    self.ingestion_queue.mutex.lock();
    defer self.ingestion_queue.mutex.unlock();
    const recorded = self.recordPendingLocked(cx, cz, provenance, activeIngestionMask(self));
    if (!recorded and provenance == .edited) {
        self.ingestion_queue.edit_dirty.put(.{ .cx = cx, .cz = cz }, {}) catch {};
    }
}

/// Notify the LOD system that a block edit affected chunk (cx, cz).
/// Coalesced on a short cooldown and re-ingested with the `edited`
/// provenance so distant terrain reflects player changes after teleport.
pub fn markChunkEdited(self: *Self, cx: i32, cz: i32) void {
    // Runtime calls this on the main thread after releasing mutation locks.
    // Retain near edits immediately; debounce only the existing coarse work.
    if (self.near_source_enabled) _ = self.captureResolvedNearChunk(cx, cz, .edited);
    self.ingestion_queue.mutex.lock();
    defer self.ingestion_queue.mutex.unlock();
    self.ingestion_queue.edit_dirty.put(.{ .cx = cx, .cz = cz }, {}) catch |err| {
        log.log.warn("Failed to track edited chunk for LOD ingestion ({}, {}): {}", .{ cx, cz, err });
    };
}

/// Consumes any queued edit work for a chunk that is about to leave full-detail
/// storage, then applies its final authoritative snapshot to every currently
/// available LOD region. Deferred entries are removed because their resolver
/// would become invalid as soon as the caller completes the unload.
pub fn flushEditedChunkForUnload(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, retain_pending: bool) u8 {
    var requested_mask: u8 = 0;
    self.ingestion_queue.mutex.lock();
    if (self.ingestion_queue.edit_dirty.remove(.{ .cx = cx, .cz = cz })) {
        requested_mask = activeIngestionMask(self);
    }

    var index: usize = 0;
    while (index < self.ingestion_queue.pending_ingestions.items.len) {
        const pending = self.ingestion_queue.pending_ingestions.items[index];
        if (pending.cx == cx and pending.cz == cz and pending.provenance == .edited) {
            requested_mask |= pending.pending_levels;
            _ = self.ingestion_queue.pending_ingestions.orderedRemove(index);
            continue;
        }
        index += 1;
    }
    self.ingestion_queue.mutex.unlock();

    if (self.near_source_enabled and requested_mask != 0) {
        if (self.captureResolvedNearChunk(cx, cz, .edited)) requested_mask &= 0xfc;
    }
    if (requested_mask == 0) return 0;
    const pending_mask = applyIngestionToRegionsMask(self, cx, cz, chunk, .edited, requested_mask);
    if (pending_mask != 0 and retain_pending) {
        self.ingestion_queue.mutex.lock();
        const recorded = self.recordPendingLocked(cx, cz, .edited, pending_mask);
        if (!recorded) {
            self.ingestion_queue.edit_dirty.put(.{ .cx = cx, .cz = cz }, {}) catch {};
        }
        self.ingestion_queue.mutex.unlock();
    }
    return pending_mask;
}

/// Apply one chunk's contribution to every LOD region that already has
/// source data and is not in-flight. Returns a bitmask of LOD levels that
/// could not be applied (region missing, not yet generated, or meshing)
/// so the caller can record them as pending.
pub fn applyIngestionToRegions(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) u8 {
    var mask = activeIngestionMask(self);
    if (self.captureNearChunk(chunk, if (provenance == .edited) .edited else .generated)) |capture| {
        if (self.submitNearChunk(cx, cz, capture)) mask &= 0xfc;
    }
    return applyIngestionToRegionsMask(self, cx, cz, chunk, provenance, mask);
}

fn applyIngestionToRegionsMask(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance, requested_mask: u8) u8 {
    var pending_mask: u8 = if (self.near_source_enabled) requested_mask & 3 else 0;
    const active = lod_chunk.activeLODCount(self.config);

    self.mutex.lock();
    defer self.mutex.unlock();

    var i: usize = if (self.near_source_enabled) 2 else 1;
    while (i < active) : (i += 1) {
        const level_mask = @as(u8, 1) << @intCast(i);
        if (requested_mask & level_mask == 0) continue;
        const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
        const key = LODRegionKey.fromChunkCoords(cx, cz, lod);
        const lod_chunk_ptr = self.regions[i].get(key) orelse {
            pending_mask |= level_mask;
            continue;
        };
        switch (lod_chunk_ptr.data) {
            .simplified => |*data| {
                // Defer if a mesh/generation/upload job is mid-flight for
                // this region: writing source data concurrently with a
                // mesh job reading it (under the shared lock) would race.
                if (lod_chunk_ptr.isPinned() or
                    lod_chunk_ptr.getState() == .generating or
                    lod_chunk_ptr.getState() == .meshing or
                    lod_chunk_ptr.getState() == .uploading)
                {
                    pending_mask |= level_mask;
                    continue;
                }
                const region_size: i32 = @intCast(world_core.regionSizeBlocks(lod));
                const min_x: i32 = lod_chunk_ptr.region_x * region_size;
                const min_z: i32 = lod_chunk_ptr.region_z * region_size;
                const written = lod_ingest.downsampleChunkIntoRegion(chunk, cx, cz, data, min_x, min_z, region_size, provenance);
                if (written == 0) continue;
                lod_chunk_ptr.markSourceDirty();
                lod_chunk_ptr.updateHeightBoundsFromData();
                // Force a remesh of already-rendered regions so the new
                // chunk-derived data becomes visible.
                self.demoteRegionForRemesh(key, lod_chunk_ptr);
            },
            else => {
                // Region exists but has no source data yet (not generated).
                pending_mask |= level_mask;
            },
        }
    }
    return pending_mask;
}

fn activeIngestionMask(self: *Self) u8 {
    var mask: u8 = 0;
    const active = lod_chunk.activeLODCount(self.config);
    var i: usize = if (self.near_source_enabled) 0 else 1;
    while (i < active) : (i += 1) mask |= @as(u8, 1) << @intCast(i);
    return mask;
}

/// Assumes `ingestion_mutex` held. Coalesces by coordinate, keeping the
/// most authoritative provenance and the union of pending level bits.
/// Deferred work is deliberately durable: a player edit can outlive many
/// unload/reload or teleport cycles before its source chunk becomes resident.
pub fn recordPendingLocked(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8) bool {
    for (self.ingestion_queue.pending_ingestions.items) |*entry| {
        if (entry.cx == cx and entry.cz == cz) {
            entry.pending_levels |= mask;
            entry.ttl = 0;
            if (provenance.canOverwrite(entry.provenance)) entry.provenance = provenance;
            return true;
        }
    }
    if (!makePendingRoomLocked(self, cx, cz, provenance)) return false;
    self.ingestion_queue.pending_ingestions.append(self.allocator, .{
        .cx = cx,
        .cz = cz,
        .provenance = provenance,
        .pending_levels = mask,
        .ttl = 0,
    }) catch |err| {
        log.log.warn("Failed to defer LOD ingestion for chunk ({}, {}): {}", .{ cx, cz, err });
        return false;
    };
    return true;
}

/// Re-record a pending entry from outside the lock. Coalesces with any
/// existing entry for the coordinate without allowing retry pressure to age
/// out player-edit provenance.
pub fn rerecordPending(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8, ttl: u16) void {
    self.ingestion_queue.mutex.lock();
    defer self.ingestion_queue.mutex.unlock();
    for (self.ingestion_queue.pending_ingestions.items) |*entry| {
        if (entry.cx == cx and entry.cz == cz) {
            entry.pending_levels |= mask;
            _ = ttl;
            entry.ttl = 0;
            if (provenance.canOverwrite(entry.provenance)) entry.provenance = provenance;
            return;
        }
    }
    if (!makePendingRoomLocked(self, cx, cz, provenance)) return;
    self.ingestion_queue.pending_ingestions.append(self.allocator, .{
        .cx = cx,
        .cz = cz,
        .provenance = provenance,
        .pending_levels = mask,
        .ttl = 0,
    }) catch |err| {
        log.log.warn("Failed to requeue deferred LOD ingestion for chunk ({}, {}): {}", .{ cx, cz, err });
    };
}

/// Remove only entries that have no remaining target levels. Deferred source
/// updates must not expire just because their chunks remain unloaded.
/// Assumes `ingestion_mutex` held.
pub fn decayPendingLocked(self: *Self) void {
    var write: usize = 0;
    for (self.ingestion_queue.pending_ingestions.items) |entry| {
        if (entry.pending_levels != 0) {
            self.ingestion_queue.pending_ingestions.items[write] = entry;
            write += 1;
        }
    }
    self.ingestion_queue.pending_ingestions.shrinkRetainingCapacity(write);
}

/// Replay deferred ingestions: snapshot all pending under the ingestion
/// lock, resolve each chunk, and re-apply. Unresolved or still-in-flight
/// levels remain queued until they apply or manager teardown.
pub fn drainPendingIngestions(self: *Self) void {
    drainPendingIngestionsWithLimit(self, self.ingestion_queue.drain_per_frame);
}

/// Makes one immediate attempt to apply every currently deferred ingestion.
/// Requests that still cannot resolve or target in-flight regions remain
/// queued for later updates.
pub fn drainPendingIngestionsNow(self: *Self) void {
    drainPendingIngestionsWithLimit(self, std.math.maxInt(usize));
}

fn drainPendingIngestionsWithLimit(self: *Self, max_count: usize) void {
    var snapshot = std.ArrayListUnmanaged(PendingIngestion).empty;
    {
        self.ingestion_queue.mutex.lock();
        defer self.ingestion_queue.mutex.unlock();
        if (self.ingestion_queue.pending_ingestions.items.len == 0) return;
        snapshot.appendSlice(self.allocator, self.ingestion_queue.pending_ingestions.items) catch {
            self.decayPendingLocked();
            return;
        };
        self.ingestion_queue.pending_ingestions.clearRetainingCapacity();
    }
    defer snapshot.deinit(self.allocator);

    const resolver = self.ingestion_queue.chunk_resolver;
    const limit = @min(snapshot.items.len, max_count);

    // Process the head of the snapshot and retain the tail for a later frame.
    var offset: usize = 0;
    while (offset < snapshot.items.len) : (offset += 1) {
        // Keep untouched entries ahead of retried unavailable chunks. The
        // experimental queue must not starve edits behind missing coarse LODs.
        const i = if (self.near_source_enabled) (offset + limit) % snapshot.items.len else offset;
        const entry = snapshot.items[i];
        if (entry.pending_levels == 0) continue;
        if (i >= limit) {
            self.rerecordPending(entry.cx, entry.cz, entry.provenance, entry.pending_levels, 0);
            continue;
        }
        var requested = entry.pending_levels;
        if (self.near_source_enabled and requested & 3 != 0) {
            if (self.captureResolvedNearChunk(entry.cx, entry.cz, if (entry.provenance == .edited) .edited else .generated)) requested &= 0xfc;
        }
        if (requested == 0) continue;
        const chunk = if (resolver) |r| r.resolve(entry.cx, entry.cz) else null;
        if (chunk) |c| {
            const remaining = applyIngestionToRegionsMask(self, entry.cx, entry.cz, c, entry.provenance, requested);
            if (remaining != 0) {
                self.rerecordPending(entry.cx, entry.cz, entry.provenance, remaining, 0);
            }
        } else {
            self.rerecordPending(entry.cx, entry.cz, entry.provenance, requested, 0);
        }
    }
}

/// Preserve already accepted edit provenance when the bounded queue is under
/// pressure. Non-edit work may be displaced, but an edited entry is never
/// silently evicted to make room for ordinary streaming retries.
/// Assumes `ingestion_queue.mutex` is held.
fn makePendingRoomLocked(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance) bool {
    if (self.ingestion_queue.pending_ingestions.items.len < MAX_PENDING_INGESTIONS) return true;

    for (self.ingestion_queue.pending_ingestions.items, 0..) |entry, index| {
        if (entry.provenance != .edited) {
            _ = self.ingestion_queue.pending_ingestions.orderedRemove(index);
            return true;
        }
    }

    log.log.warn("LOD deferred-ingestion queue is full; retaining existing edited work and rejecting ({}, {}) provenance={}", .{ cx, cz, provenance });
    return false;
}

/// Immediately applies pending edited chunks, bypassing the ordinary
/// coalescing cooldown. Used by explicit save points that must persist the
/// corresponding LOD source snapshot in the same transaction.
pub fn flushEditedChunksNow(self: *Self) void {
    self.ingestion_queue.edit_cooldown = 0.0;
    flushEditedChunksWithLimit(self, std.math.maxInt(usize));
}

/// Bypasses the cooldown but consumes only the ordinary per-frame ingestion
/// budget. Autosave uses this to start persistence without a large edit burst.
pub fn flushEditedChunksBounded(self: *Self) void {
    self.ingestion_queue.edit_cooldown = 0.0;
    flushEditedChunksWithLimit(self, self.ingestion_queue.drain_per_frame);
}

/// Flush debounced player edits: re-ingest edited chunks with the `edited`
/// provenance. Runs on a cooldown so rapid edits coalesce into one rebuild.
pub fn flushEditedChunks(self: *Self) void {
    self.ingestion_queue.edit_cooldown -= LOD_FRAME_DT_APPROX;
    if (self.ingestion_queue.edit_cooldown > 0.0) return;

    flushEditedChunksWithLimit(self, std.math.maxInt(usize));
}

fn flushEditedChunksWithLimit(self: *Self, max_count: usize) void {
    var snapshot = std.ArrayListUnmanaged(ChunkCoordKey).empty;
    {
        self.ingestion_queue.mutex.lock();
        defer self.ingestion_queue.mutex.unlock();
        if (self.ingestion_queue.edit_dirty.count() == 0) return;
        var it = self.ingestion_queue.edit_dirty.keyIterator();
        while (it.next()) |k| {
            if (snapshot.items.len >= max_count) break;
            snapshot.append(self.allocator, k.*) catch break;
        }
        for (snapshot.items) |key| _ = self.ingestion_queue.edit_dirty.remove(key);
    }
    defer snapshot.deinit(self.allocator);

    const resolver = self.ingestion_queue.chunk_resolver;
    for (snapshot.items) |k| {
        const near_captured = !self.near_source_enabled or self.captureResolvedNearChunk(k.cx, k.cz, .edited);
        if (!near_captured) self.requestIngestion(k.cx, k.cz, .edited);
        if (resolver) |r| {
            if (r.resolve(k.cx, k.cz)) |chunk| {
                self.ingestCoarseChunk(k.cx, k.cz, chunk, .edited);
                continue;
            }
        }
        // Chunk not resident now: defer until the resolver can fetch it.
        self.requestIngestion(k.cx, k.cz, .edited);
    }
    self.ingestion_queue.edit_cooldown = EDIT_FLUSH_COOLDOWN;
}
