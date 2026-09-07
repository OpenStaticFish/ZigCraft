const std = @import("std");
const fs = @import("fs");
const Self = @import("lod_manager.zig").LODManager;
const LODRegionKey = @import("lod_chunk.zig").LODRegionKey;
const LODRegionKeyContext = @import("lod_chunk.zig").LODRegionKeyContext;
const LODSimplifiedData = @import("lod_chunk.zig").LODSimplifiedData;
const lod_chunk = @import("lod_chunk.zig");
const manager_ctx = @import("lod_manager_context.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const cache_io = @import("lod_cache_io.zig");
const log = @import("engine-core").log;

/// Cache setup is an explicit world-load operation. It may perform synchronous
/// filesystem maintenance, unlike the frame/update path.
pub fn enableCache(self: *Self, save_dir_path: []const u8) !void {
    if (self.source_hierarchy) |source| return source.setPersistence(save_dir_path);
    self.flushCacheIO();
    // Experimental source/header maintenance must never touch shipped caches.
    // LOD0/1 are memory-only; coarse caches use an isolated derived namespace.
    const cache_dir_path = if (self.near_source_enabled)
        try fs.path.join(self.allocator, &.{ save_dir_path, "near-source-v1" })
    else
        try self.allocator.dupe(u8, save_dir_path);
    errdefer self.allocator.free(cache_dir_path);

    const live_header = lod_store.StoreHeader{
        .seed = self.generator.seed,
        .generator_identity_hash = self.generator.identity_hash,
        .generator_version = self.generator.version,
    };
    if (try lod_store.readHeader(self.allocator, cache_dir_path)) |stored_header| {
        if (stored_header.seed != live_header.seed or
            stored_header.lod_data_version != live_header.lod_data_version or
            stored_header.generator_identity_hash != live_header.generator_identity_hash or
            stored_header.generator_version != live_header.generator_version)
        {
            log.log.warn("LOD store identity changed; discarding stale LOD source store", .{});
            try lod_store.deleteStore(self.allocator, cache_dir_path);
        }
    }
    try lod_store.writeHeader(self.allocator, cache_dir_path, live_header);

    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.cache_store.cache_dir_path) |old_path| self.allocator.free(old_path);
    self.cache_store.cache_dir_path = cache_dir_path;
    self.cache_store.logged_legacy_cache_notice = false;
    log.log.info("LOD source store enabled at '{s}/lod'", .{cache_dir_path});
}

/// Enqueues at most one source-data snapshot. Cloning is intentionally the
/// only update-thread cache work; serialization and filesystem writes run on
/// CacheIoPipeline's dedicated worker.
pub fn flushDirtyStores(self: *Self) void {
    _ = queueDirtyStores(self, 1);
}

/// Settles older writes, then drains every currently eligible dirty source
/// snapshot in bounded batches. Explicit save points use this so an edited
/// snapshot cannot be skipped behind a stale worldgen write.
pub fn flushDirtyStoresNow(self: *Self) void {
    flushAllDirtyStores(self);
}

/// Removes known-stale payloads for edited ingestions that could not be
/// applied synchronously. Call only after `flushDirtyStoresNow`, which settles
/// older asynchronous writes before these payloads are deleted.
pub fn invalidatePendingEditedStoresNow(self: *Self) void {
    const path = self.cacheDirPathSnapshot() orelse return;
    defer self.allocator.free(path);

    var stale_keys = std.HashMap(LODRegionKey, void, LODRegionKeyContext, std.hash_map.default_max_load_percentage).init(self.allocator);
    defer stale_keys.deinit();

    self.ingestion_queue.mutex.lock();
    for (self.ingestion_queue.pending_ingestions.items) |pending| {
        if (pending.provenance != .edited) continue;
        var level: usize = if (self.near_source_enabled) 2 else 1;
        while (level < lod_chunk.LODLevel.count) : (level += 1) {
            const level_mask = @as(u8, 1) << @intCast(level);
            if (pending.pending_levels & level_mask == 0) continue;
            const lod: lod_chunk.LODLevel = @enumFromInt(@as(u3, @intCast(level)));
            stale_keys.put(LODRegionKey.fromChunkCoords(pending.cx, pending.cz, lod), {}) catch {
                log.log.warn("Failed to track stale LOD{} store payload for invalidation", .{level});
            };
        }
    }
    // Queue saturation can leave an edited coordinate in `edit_dirty` rather
    // than `pending_ingestions`. Its full active LOD ladder is equally stale.
    var dirty_iter = self.ingestion_queue.edit_dirty.keyIterator();
    while (dirty_iter.next()) |dirty| {
        var level: usize = if (self.near_source_enabled) 2 else 1;
        while (level < lod_chunk.activeLODCount(self.config)) : (level += 1) {
            const lod: lod_chunk.LODLevel = @enumFromInt(@as(u3, @intCast(level)));
            stale_keys.put(LODRegionKey.fromChunkCoords(dirty.cx, dirty.cz, lod), {}) catch {
                log.log.warn("Failed to track dirty LOD{} store payload for invalidation", .{level});
            };
        }
    }
    self.ingestion_queue.mutex.unlock();

    self.cache_store.store_mutex.lock();
    defer self.cache_store.store_mutex.unlock();
    var iter = stale_keys.keyIterator();
    while (iter.next()) |key| {
        const cache_key = self.cacheKey(key.*);
        lod_store.deletePayload(self.allocator, path, cache_key);
        const legacy_path = self.legacyCacheFilePath(path, cache_key) catch continue;
        fs.cwd().deleteFile(legacy_path) catch |err| {
            if (err != error.FileNotFound) log.log.warn("Failed to invalidate stale legacy LOD cache '{s}': {}", .{ legacy_path, err });
        };
        self.allocator.free(legacy_path);
    }
}

pub fn flushCacheIO(self: *Self) void {
    self.cache_io.waitUntilIdle();
    drainCacheCompletions(self);
}

/// Deinit-only flushing. Accepted work may block here; normal updates must use
/// `flushDirtyStores` and never wait for I/O.
pub fn shutdownCacheIO(self: *Self) void {
    flushAllDirtyStores(self);
}

fn flushAllDirtyStores(self: *Self) void {
    // An older write can occupy a region's queued flag. Apply its completion
    // before scanning, otherwise a stale completion may hide the newer dirty
    // revision from the first (and only) batch.
    self.flushCacheIO();

    var attempts: usize = 0;
    while (attempts < 2048) : (attempts += 1) {
        const queued = queueDirtyStores(self, cache_io.MAX_PENDING_TASKS);
        if (queued == 0) break;
        self.flushCacheIO();
    }
    self.flushCacheIO();

    if (attempts == 2048) {
        log.log.warn("LOD source-store flush stopped after {} batches; dirty snapshots remain eligible for retry", .{attempts});
    }
}

pub fn drainCacheCompletions(self: *Self) void {
    var completions: std.ArrayListUnmanaged(cache_io.Completion) = .empty;
    defer {
        for (completions.items) |*completion| deinitCompletion(completion);
        completions.deinit(self.allocator);
    }
    self.cache_io.drainCompletions(&completions);

    for (completions.items) |*completion| switch (completion.*) {
        .read => |*read| {
            var dispatch_generation = false;
            var log_legacy_notice = false;
            self.mutex.lock();
            const chunk = self.regions[@intFromEnum(read.key.lod)].get(read.key);
            if (chunk) |region| {
                if (region.cache_read_queued and region.job_token == read.token and region.getState() == .queued_for_generation) {
                    region.cache_read_queued = false;
                    log_legacy_notice = read.used_legacy;
                    switch (read.result) {
                        .hit => |*data| {
                            if (self.usesNearSource(read.key.lod) or
                                (regionRequiresSpans(self, read.key) and !data.hasVerticalSpans()) or
                                data.width != LODSimplifiedData.getGridSizeForDensity(read.key.lod, self.sourceSampleDensity(read.key.lod)))
                            {
                                data.deinit();
                                read.result = .miss;
                                self.cache_misses += 1;
                                dispatch_generation = true;
                            } else {
                                region.data = .{ .simplified = data.* };
                                // Ownership moved into the region. Retag the
                                // completion so deferred cleanup does not
                                // deinitialize the consumed payload.
                                read.result = .miss;
                                region.updateHeightBoundsFromData();
                                region.bumpSourceRevision();
                                region.setState(.generated);
                                self.enqueueTransition(read.key, region, .mesh);
                                self.cache_hits += 1;
                            }
                        },
                        .miss => {
                            self.cache_misses += 1;
                            dispatch_generation = true;
                        },
                    }
                }
            }
            self.mutex.unlock();
            if (log_legacy_notice) self.logLegacyCacheNotice();
            if (dispatch_generation) self.dispatchCacheMiss(read.key, read.token);
        },
        .write => |write| {
            // Explicit saveCachedSourceData requests are not tied to a live
            // region lifecycle and use revision zero.
            if (write.revision == 0) continue;
            self.mutex.lock();
            if (self.regions[@intFromEnum(write.key.lod)].get(write.key)) |region| {
                if (region.store_write_queued and region.source_revision == write.revision) {
                    region.store_write_queued = false;
                    region.store_dirty = !write.success;
                    region.store_size_limited = write.size_limited;
                    region.store_size_limit_cap_mb = if (write.size_limited) write.store_size_cap_mb else 0;
                } else if (region.store_write_queued) {
                    // A newer source snapshot arrived while this write was in
                    // flight. Preserve dirty state and let a later update
                    // enqueue that newer revision.
                    region.store_write_queued = false;
                }
            }
            self.mutex.unlock();
        },
    };
}

fn queueDirtyStores(self: *Self, max_count: usize) usize {
    const path = self.cacheDirPathSnapshot() orelse return 0;
    defer self.allocator.free(path);
    var queued: usize = 0;
    self.mutex.lock();
    defer self.mutex.unlock();
    const active = lod_chunk.activeLODCount(self.config);
    var level: usize = if (self.near_source_enabled) 2 else 1;
    while (level < active and queued < max_count) : (level += 1) {
        var iter = self.regions[level].iterator();
        while (iter.next()) |entry| {
            if (queued >= max_count) break;
            const region = entry.value_ptr.*;
            if (!region.store_dirty or region.store_write_queued) continue;
            const store_size_cap_mb = if (self.cache_store.use_config_store_size_cap) self.config.getLODStoreSizeCapMB() else self.cache_store.store_size_cap_mb;
            if (region.store_size_limited and store_size_cap_mb <= region.store_size_limit_cap_mb) continue;
            const snapshot = switch (region.data) {
                .simplified => |*data| lod_cache.cloneSourceData(data, entry.key_ptr.*.lod, self.allocator) catch |err| {
                    log.log.warn("Failed to snapshot LOD{} cache ({}, {}): {}", .{ @intFromEnum(entry.key_ptr.*.lod), entry.key_ptr.*.rx, entry.key_ptr.*.rz, err });
                    continue;
                },
                else => continue,
            };
            const key = entry.key_ptr.*;
            const revision = region.source_revision;
            region.store_write_queued = true;
            const accepted = self.cache_io.enqueueWrite(path, key, self.cacheKey(key), revision, snapshot, store_size_cap_mb) catch |err| blk: {
                log.log.warn("Failed to queue LOD{} cache write ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
                break :blk false;
            };
            if (!accepted) {
                var unused = snapshot;
                unused.deinit();
                region.store_write_queued = false;
                return queued;
            }
            queued += 1;
        }
    }
    return queued;
}

fn regionRequiresSpans(self: *Self, key: LODRegionKey) bool {
    return self.sourceRequiresSpans(key.lod);
}

pub fn cacheKey(self: *const Self, key: LODRegionKey) lod_cache.Key {
    return .{ .seed = self.generator.seed, .generator_identity_hash = self.generator.identity_hash, .generator_version = self.generator.version, .rx = key.rx, .rz = key.rz, .lod = key.lod };
}

pub fn legacyCacheFilePath(self: *Self, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
    return std.fmt.allocPrint(self.allocator, "{s}/lod_cache/lod_{}_{}_{}_{}_{}_{}.dat", .{ save_dir_path, key.seed, key.generator_identity_hash, key.generator_version, key.rx, key.rz, @intFromEnum(key.lod) });
}

pub fn logLegacyCacheNotice(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.cache_store.logged_legacy_cache_notice) return;
    self.cache_store.logged_legacy_cache_notice = true;
    log.log.warn("Using read-only legacy LOD cache fallback; new writes go to lod/ region store", .{});
}

pub fn cacheDirPathSnapshot(self: *Self) ?[]u8 {
    if (self.usesCanonicalSource()) return null;
    self.mutex.lockShared();
    defer self.mutex.unlockShared();
    const path = self.cache_store.cache_dir_path orelse return null;
    return self.allocator.dupe(u8, path) catch |err| {
        log.log.warn("LOD cache path snapshot allocation failed: {}", .{err});
        return null;
    };
}

pub fn cacheEnabled(self: *Self) bool {
    if (self.usesCanonicalSource()) return false;
    self.mutex.lockShared();
    defer self.mutex.unlockShared();
    return self.cache_store.cache_dir_path != null;
}

// Synchronous helpers remain explicit setup/diagnostic APIs. Update and
// generation paths use CacheIoPipeline exclusively.
pub fn readStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) !?[]u8 {
    if (self.usesCanonicalSource()) return null;
    if (self.usesNearSource(cache_key.lod)) return null;
    self.cache_store.store_mutex.lock();
    defer self.cache_store.store_mutex.unlock();
    return lod_store.readPayload(self.allocator, save_dir_path, cache_key);
}

pub fn writeStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key, bytes: []const u8) !void {
    if (self.usesCanonicalSource()) return;
    if (self.usesNearSource(cache_key.lod)) return;
    self.cache_store.store_mutex.lock();
    defer self.cache_store.store_mutex.unlock();
    const store_size_cap_mb = if (self.cache_store.use_config_store_size_cap) self.config.getLODStoreSizeCapMB() else self.cache_store.store_size_cap_mb;
    try lod_store.writePayload(self.allocator, save_dir_path, cache_key, bytes, store_size_cap_mb);
}

pub fn deleteStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) void {
    if (self.usesCanonicalSource()) return;
    if (self.usesNearSource(cache_key.lod)) return;
    self.cache_store.store_mutex.lock();
    defer self.cache_store.store_mutex.unlock();
    lod_store.deletePayload(self.allocator, save_dir_path, cache_key);
}

pub fn deleteStoreContainer(self: *Self, path: []const u8) void {
    self.cache_store.store_mutex.lock();
    defer self.cache_store.store_mutex.unlock();
    fs.cwd().deleteFile(path) catch |err| {
        if (err != error.FileNotFound) log.log.warn("Failed to delete corrupt LOD store container '{s}': {}", .{ path, err });
    };
}

pub fn loadCachedSourceData(self: *Self, key: LODRegionKey) ?LODSimplifiedData {
    if (self.usesCanonicalSource()) return null;
    if (self.usesNearSource(key.lod)) return null;
    const path = self.cacheDirPathSnapshot() orelse return null;
    defer self.allocator.free(path);
    const cache_key = self.cacheKey(key);
    if (self.readStorePayload(path, cache_key) catch |err| switch (err) {
        lod_store.StoreError.CorruptContainer => {
            const container_path = lod_store.containerPath(self.allocator, path, cache_key) catch return null;
            defer self.allocator.free(container_path);
            log.log.warn("Discarding corrupt LOD store container '{s}'", .{container_path});
            self.deleteStoreContainer(container_path);
            return null;
        },
        else => {
            log.log.warn("Failed to read LOD store for LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            return null;
        },
    }) |bytes| {
        defer self.allocator.free(bytes);
        return lod_cache.deserialize(bytes, cache_key, self.allocator) catch |err| {
            log.log.warn("Discarding corrupt LOD store payload LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            self.deleteStorePayload(path, cache_key);
            return null;
        };
    }
    const legacy_path = self.legacyCacheFilePath(path, cache_key) catch return null;
    defer self.allocator.free(legacy_path);
    const bytes = fs.cwd().readFileAlloc(legacy_path, self.allocator, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            log.log.warn("Failed to read legacy LOD cache '{s}': {}", .{ legacy_path, err });
            return null;
        },
    };
    defer self.allocator.free(bytes);
    self.logLegacyCacheNotice();
    return lod_cache.deserialize(bytes, cache_key, self.allocator) catch |err| {
        log.log.warn("Discarding corrupt legacy LOD cache '{s}': {}", .{ legacy_path, err });
        fs.cwd().deleteFile(legacy_path) catch |delete_err| {
            if (delete_err != error.FileNotFound) log.log.warn("Failed to delete corrupt legacy LOD cache '{s}': {}", .{ legacy_path, delete_err });
        };
        return null;
    };
}

pub fn recordCacheHit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.cache_hits += 1;
}

pub fn recordCacheMiss(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.cache_misses += 1;
}

/// Explicit API used by tools/tests. Like frame writes, it snapshots then
/// serializes on the cache worker; callers may use flushCacheIO to wait.
pub fn saveCachedSourceData(self: *Self, key: LODRegionKey, data: *const LODSimplifiedData) void {
    if (self.usesCanonicalSource()) return;
    if (self.usesNearSource(key.lod)) return;
    const path = self.cacheDirPathSnapshot() orelse return;
    defer self.allocator.free(path);
    const snapshot = lod_cache.cloneSourceData(data, key.lod, self.allocator) catch |err| {
        log.log.warn("Failed to snapshot LOD{} cache ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
        return;
    };
    const store_size_cap_mb = if (self.cache_store.use_config_store_size_cap) self.config.getLODStoreSizeCapMB() else self.cache_store.store_size_cap_mb;
    const accepted = self.cache_io.enqueueWrite(path, key, self.cacheKey(key), 0, snapshot, store_size_cap_mb) catch false;
    if (!accepted) {
        var unused = snapshot;
        unused.deinit();
    }
}

pub fn initCacheTestManager(allocator: std.mem.Allocator, cache_dir_path: []const u8) !Self {
    _ = cache_dir_path;
    var manager = Self{
        .allocator = allocator,
        .config = undefined,
        .regions = undefined,
        .meshes = undefined,
        .job_dispatcher = undefined,
        .upload_queues = undefined,
        .transition_queue = .empty,
        .player_cx = std.atomic.Value(i32).init(0),
        .player_cz = std.atomic.Value(i32).init(0),
        .scan_states = [_]manager_ctx.LODScanState{manager_ctx.LODScanState{}} ** lod_chunk.LODLevel.count,
        .stats = .{},
        .profiling = .init(false),
        .cache_hits = 0,
        .cache_misses = 0,
        .cancelled_jobs = 0,
        .mutex = .{},
        .gpu_bridge = undefined,
        .generator = .{ .ptr = undefined, .generate_heightmap_only = undefined, .maybe_recenter_cache = undefined, .seed = 42, .identity_hash = 99, .version = 7 },
        .atlas = undefined,
        .paused = false,
        .memory_governor = .{},
        .update_tick = 0,
        .mesh_disposal = .{},
        .renderer = undefined,
        .cache_store = .{},
        .cache_io = undefined,
        .cleanup_covered_regions = true,
        .ingestion_queue = @import("lod_manager.zig").LODIngestionQueue.init(allocator),
    };
    manager.cache_io = try cache_io.CacheIoPipeline.init(allocator, &manager.profiling);
    return manager;
}

fn deinitCompletion(completion: *cache_io.Completion) void {
    switch (completion.*) {
        .read => |*read| switch (read.result) {
            .hit => |*data| data.deinit(),
            .miss => {},
        },
        .write => {},
    }
}
