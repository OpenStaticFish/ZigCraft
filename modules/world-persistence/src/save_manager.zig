//! Save manager - background thread orchestrating chunk serialization and region file writes.
//!
//! Ties together the region file format (region_file.zig) and chunk serializer
//! (chunk_serializer.zig) into a working save/load system. Manages a background
//! save thread, dirty chunk tracking, and auto-save intervals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_core = @import("engine-core");
const log = engine_core.log;
const fs = @import("fs");
const sync = @import("sync");
const timestampMs = engine_core.timestampMs;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const RegionFile = @import("region_file.zig").RegionFile;
const chunk_serializer = @import("chunk_serializer.zig");
const LevelData = @import("level_data.zig").LevelData;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const PackedLight = world_core.PackedLight;
const CHUNK_VOLUME = world_core.CHUNK_VOLUME;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

const ChunkKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkKey) u64 {
        _ = self;
        return key.hash();
    }

    pub fn eql(self: @This(), a: ChunkKey, b: ChunkKey) bool {
        _ = self;
        return a.eql(b);
    }
};

const QueueIndexMap = std.HashMap(ChunkKey, usize, ChunkKeyContext, std.hash_map.default_max_load_percentage);

const SAVE_THREAD_INTERVAL_NS: u64 = 25 * std.time.ns_per_ms;
const SAVE_RETRY_INTERVAL_MS: i64 = 1_000;
const AUTO_SAVE_INTERVAL_MS: i64 = 60_000;
const MAX_OPEN_REGIONS: usize = 16;
const SAVE_FAILURE_COUNT_FILE = "save_failures.dat";

pub const LoadResult = enum {
    success,
    success_relight_required,
    not_found,
    read_error,
    corrupt_data,
};

pub const SaveQueueEntry = struct {
    chunk_x: i32,
    chunk_z: i32,
    blocks: [CHUNK_VOLUME]BlockType,
    light: [CHUNK_VOLUME]PackedLight,
    biomes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    heightmap: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
    lighting_valid: bool,
    content_revision: u64 = 0,
    light_revision: u64 = 0,
    canonical_save_order: u64 = 0,
    sequence: u64 = 0,
    retry_after_ms: i64 = 0,

    fn restore(self: *const SaveQueueEntry, chunk: *Chunk) void {
        chunk.chunk_x = self.chunk_x;
        chunk.chunk_z = self.chunk_z;
        chunk.blocks = self.blocks;
        chunk.light = self.light;
        chunk.biomes = self.biomes;
        chunk.heightmap = self.heightmap;
        chunk.lighting_valid = self.lighting_valid;
        chunk.content_revision.store(self.content_revision, .release);
        chunk.light_revision.store(self.light_revision, .release);
        chunk.canonical_save_order = self.canonical_save_order;
        chunk.generated = true;
    }
};

const RegionCacheEntry = struct {
    region_x: i32,
    region_z: i32,
    region: RegionFile,
    last_used_ms: i64,
};

pub const SaveManager = struct {
    allocator: Allocator,
    save_dir: fs.Dir,
    save_dir_path: []const u8,
    world_name: []const u8,

    queue_mutex: sync.Mutex,
    queue: std.ArrayListUnmanaged(SaveQueueEntry),
    queue_index: QueueIndexMap,
    /// Writer-owned immutable snapshots, borrowed only under queue_mutex.
    in_flight: []const SaveQueueEntry = &.{},
    running: std.atomic.Value(bool),
    pending_saves: std.atomic.Value(usize),
    next_save_sequence: u64 = 0,
    source_epoch: std.atomic.Value(u64) = .init(0),
    saved_callback_ctx: ?*anyopaque = null,
    on_saved: ?*const fn (*anyopaque, *const Chunk) void = null,
    snapshot_order_ctx: ?*anyopaque = null,
    snapshot_order_fn: ?*const fn (*anyopaque) u64 = null,

    failed_mutex: sync.Mutex,
    failed_chunks: std.ArrayListUnmanaged(ChunkKey),
    failed_save_count: std.atomic.Value(usize),
    persisted_failed_save_count: std.atomic.Value(usize),
    persisted_failed_save_mutex: sync.Mutex,

    thread: std.Thread,

    region_cache_mutex: sync.Mutex,
    region_cache: std.ArrayListUnmanaged(RegionCacheEntry),

    level_data: LevelData,
    last_auto_save_ms: i64,

    pub fn init(allocator: Allocator, save_dir_path: []const u8, world_name: []const u8, seed: u64, generator_name: []const u8) !*SaveManager {
        var dir = try fs.cwd().makeOpenPath(save_dir_path, .{});
        errdefer dir.close();

        const sm = try allocator.create(SaveManager);
        errdefer allocator.destroy(sm);

        const name_copy = try allocator.dupe(u8, world_name);
        errdefer allocator.free(name_copy);

        const path_copy = try allocator.dupe(u8, save_dir_path);
        errdefer allocator.free(path_copy);

        const persisted_failures = loadPersistedSaveFailureCount(allocator, dir);

        sm.* = .{
            .allocator = allocator,
            .save_dir = dir,
            .save_dir_path = path_copy,
            .world_name = name_copy,
            .queue_mutex = .{},
            .queue = .empty,
            .queue_index = QueueIndexMap.init(allocator),
            .running = std.atomic.Value(bool).init(true),
            .pending_saves = std.atomic.Value(usize).init(0),
            .thread = undefined,
            .region_cache_mutex = .{},
            .region_cache = .empty,
            .failed_mutex = .{},
            .failed_chunks = .empty,
            .failed_save_count = std.atomic.Value(usize).init(0),
            .persisted_failed_save_count = std.atomic.Value(usize).init(persisted_failures),
            .persisted_failed_save_mutex = .{},
            .level_data = LevelData.loadFromFile(allocator, dir) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    const generator_copy = try allocator.dupe(u8, generator_name);
                    errdefer allocator.free(generator_copy);
                    break :blk LevelData.init(seed, generator_copy);
                },
                else => return err,
            },
            .last_auto_save_ms = timestampMs(),
        };

        try sm.level_data.saveToFile(allocator, sm.save_dir);

        try dir.makePath("regions");

        sm.thread = try std.Thread.spawn(.{}, saveThreadFn, .{sm});

        log.log.info("SaveManager initialized for world '{s}' at '{s}'", .{ world_name, save_dir_path });
        return sm;
    }

    pub fn deinit(self: *SaveManager) void {
        const failed = self.flush();
        self.allocator.free(failed);

        self.running.store(false, .release);
        self.thread.join();

        for (self.queue.items) |*entry| {
            log.log.err("Discarding unsaved snapshot ({}, {}) at SaveManager shutdown", .{ entry.chunk_x, entry.chunk_z });
        }

        self.flushRegionCache();

        self.level_data.touchLastPlayed();
        self.level_data.saveToFile(self.allocator, self.save_dir) catch |err| {
            log.log.err("Failed to save level.dat: {}", .{err});
            self.recordSaveFailure();
        };

        self.queue.deinit(self.allocator);
        self.queue_index.deinit();
        self.failed_chunks.deinit(self.allocator);

        self.save_dir.close();

        self.level_data.deinit(self.allocator);
        self.allocator.free(self.world_name);
        self.allocator.free(self.save_dir_path);
        self.allocator.destroy(self);
    }

    pub fn enqueueSave(self: *SaveManager, chunk: *const Chunk) void {
        _ = self.tryEnqueueSave(chunk);
    }

    /// Copies a pinned, caller-synchronized chunk. Never clears `modified`.
    /// False means no snapshot was accepted; the caller must keep it dirty.
    pub fn tryEnqueueSave(self: *SaveManager, chunk: *const Chunk) bool {
        std.debug.assert(chunk.pin_count.load(.acquire) > 0);

        self.queue_mutex.lock();
        const order_fn = self.snapshot_order_fn;
        const order_ctx = self.snapshot_order_ctx;
        self.queue_mutex.unlock();
        // Reserve before copying while the caller still owns stable chunk data.
        // The provider must only reserve an atomic order, never enter source locks.
        const order = if (order_fn) |reserve| reserve(order_ctx.?) else chunk.canonical_save_order;
        var snapshot = SaveQueueEntry{
            .chunk_x = chunk.chunk_x,
            .chunk_z = chunk.chunk_z,
            .blocks = chunk.blocks,
            .light = chunk.light,
            .biomes = chunk.biomes,
            .heightmap = chunk.heightmap,
            .lighting_valid = chunk.lighting_valid,
            .content_revision = chunk.content_revision.load(.acquire),
            .light_revision = chunk.light_revision.load(.acquire),
            .canonical_save_order = order,
        };

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        self.next_save_sequence +%= 1;
        snapshot.sequence = self.next_save_sequence;

        const key = ChunkKey{ .x = snapshot.chunk_x, .z = snapshot.chunk_z };
        if (self.queue_index.get(key)) |idx| {
            if (idx < self.queue.items.len) {
                self.queue.items[idx] = snapshot;
                return true;
            }
            _ = self.queue_index.remove(key);
        }

        self.queue.append(self.allocator, snapshot) catch |err| {
            log.log.err("Failed to enqueue chunk ({}, {}) for save: {}", .{ snapshot.chunk_x, snapshot.chunk_z, err });
            self.recordSaveFailure();
            return false;
        };
        self.queue_index.put(key, self.queue.items.len - 1) catch |err| {
            log.log.err("Failed to index queued chunk ({}, {}) for save: {}", .{ snapshot.chunk_x, snapshot.chunk_z, err });
            _ = self.queue.pop();
            self.recordSaveFailure();
            return false;
        };
        return true;
    }

    /// In-process committed-write notification epoch, published after on_saved.
    /// Not a transactional multi-chunk snapshot or a queued-save revision.
    pub fn sourceEpoch(self: *const SaveManager) u64 {
        return self.source_epoch.load(.acquire);
    }

    /// Register before starting readers/producers. Context must outlive the save
    /// thread (joined by deinit); replacing/unregistering does not join callbacks.
    /// Callback runs on the writer, without manager locks, and must not call RHI
    /// or flush/deinit. The immutable chunk borrow lasts only for the call.
    pub fn setSavedCallback(self: *SaveManager, ctx: ?*anyopaque, callback: ?*const fn (*anyopaque, *const Chunk) void) void {
        std.debug.assert(callback == null or ctx != null);
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.saved_callback_ctx = ctx;
        self.on_saved = callback;
    }

    /// Register before producers start; context must outlive all producers.
    /// Invoked without SaveManager locks, under the caller's chunk ownership.
    /// Only an atomic sequence reservation is permitted, not cache/storage work.
    pub fn setSnapshotOrderProvider(self: *SaveManager, ctx: ?*anyopaque, provider: ?*const fn (*anyopaque) u64) void {
        std.debug.assert(provider == null or ctx != null);
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.snapshot_order_ctx = ctx;
        self.snapshot_order_fn = provider;
    }

    /// Reads only existing on-disk data, never pending queue snapshots. Failure
    /// leaves out untouched. Stale lighting is reported, not reconciled/cleared.
    /// In-place write failures may alter disk without advancing sourceEpoch.
    /// Caller exclusively owns out and must join readers before deinit.
    pub fn readSavedChunk(self: *SaveManager, cx: i32, cz: i32, out: *Chunk) LoadResult {
        const rx: i32 = @divFloor(cx, 32);
        const rz: i32 = @divFloor(cz, 32);

        const data = blk: {
            self.region_cache_mutex.lock();
            defer self.region_cache_mutex.unlock();

            var rel_buf: [fs.max_path_bytes]u8 = undefined;
            const filename = std.fmt.bufPrint(&rel_buf, "regions/r.{}.{}.mca", .{ rx, rz }) catch unreachable;
            var abs_buf: [fs.max_path_bytes]u8 = undefined;
            const path = self.save_dir.realpath(filename, &abs_buf) catch |err| {
                return if (err == error.FileNotFound) .not_found else .read_error;
            };
            var region = RegionFile.openReadOnly(self.allocator, path) catch |err| {
                return if (err == error.FileNotFound) .not_found else .read_error;
            };
            defer region.close();

            break :blk region.readChunk(@intCast(@mod(cx, 32)), @intCast(@mod(cz, 32)), self.allocator) catch |err| {
                return if (err == error.ChunkNotFound) .not_found else .read_error;
            };
        };
        defer self.allocator.free(data);

        chunk_serializer.deserializeChunkAt(data, cx, cz, out) catch |err| {
            log.log.err("Failed to deserialize chunk ({}, {}): {}", .{ cx, cz, err });
            return .corrupt_data;
        };

        out.generated = true;
        out.source_kind = .saved;
        out.canonical_save_order = 0;
        return if (out.lighting_valid) .success else .success_relight_required;
    }

    pub const ResidentLoad = struct { result: LoadResult, pending: bool };

    /// Full-detail authority includes accepted saves, including retry backoff.
    /// Copies under queue_mutex into private scratch; no queue borrow escapes.
    /// Failure leaves out untouched. Caller exclusively owns out (including
    /// synchronization against mutation); residency state and pins are retained.
    pub fn loadResidentChunk(self: *SaveManager, cx: i32, cz: i32, out: *Chunk) ResidentLoad {
        var scratch = Chunk.init(cx, cz);
        var result: LoadResult = .not_found;
        var pending = false;
        var disk_epoch: ?u64 = null;
        // Recheck after disk I/O so an admission or completed write racing the
        // read wins as well, even if its queue entry has already been retired.
        while (true) {
            self.queue_mutex.lock();
            var latest: ?*const SaveQueueEntry = null;
            for (self.in_flight) |*entry| {
                if (entry.chunk_x == cx and entry.chunk_z == cz) latest = entry;
            }
            if (self.queue_index.get(.{ .x = cx, .z = cz })) |idx| {
                // The queue retains in-flight entries until commit and replaces
                // them only with newer accepted snapshots, including sequence wrap.
                latest = &self.queue.items[idx];
            }
            if (latest) |entry| {
                entry.restore(&scratch);
                pending = true;
            }
            const epoch = self.sourceEpoch();
            self.queue_mutex.unlock();
            if (pending) {
                result = if (scratch.lighting_valid) .success else .success_relight_required;
                break;
            }
            if (disk_epoch == epoch) break;
            disk_epoch = epoch;
            result = self.readSavedChunk(cx, cz, &scratch);
        }
        if (result != .success and result != .success_relight_required) return .{ .result = result, .pending = false };

        out.chunk_x = cx;
        out.chunk_z = cz;
        out.blocks = scratch.blocks;
        out.light = scratch.light;
        out.biomes = scratch.biomes;
        out.heightmap = scratch.heightmap;
        out.lighting_valid = scratch.lighting_valid;
        out.generated = true;
        out.dirty = true;
        out.source_kind = if (pending) .edited else .saved;
        out.canonical_save_order = scratch.canonical_save_order;
        if (pending) {
            out.content_revision.store(scratch.content_revision.load(.acquire), .release);
            out.light_revision.store(scratch.light_revision.load(.acquire), .release);
            out.modified = true;
        }
        if (result == .success_relight_required) {
            for (&out.light) |*light| light.* = PackedLight.init(0, 0);
            out.markLightChanged();
            log.log.info("Discarded stale derived lighting while loading chunk ({}, {})", .{ cx, cz });
        }
        return .{ .result = result, .pending = pending };
    }

    pub fn loadChunk(self: *SaveManager, cx: i32, cz: i32, out_chunk: *Chunk) LoadResult {
        return self.loadResidentChunk(cx, cz, out_chunk).result;
    }

    /// Marks metadata current only after a reconciled v3 chunk is persisted.
    /// Older chunks remain protected by their per-chunk lighting-validity marker.
    pub fn markLightingMigrationComplete(self: *SaveManager) void {
        if (self.level_data.lighting_algorithm_version == LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION) return;
        self.level_data.lighting_algorithm_version = LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION;
        self.level_data.saveToFile(self.allocator, self.save_dir) catch |err| {
            log.log.err("Failed to persist lighting migration metadata: {}", .{err});
            self.recordSaveFailure();
        };
    }

    pub fn shouldAutoSave(self: *const SaveManager) bool {
        const now = timestampMs();
        return (now - self.last_auto_save_ms) >= AUTO_SAVE_INTERVAL_MS;
    }

    pub fn markAutoSaved(self: *SaveManager) void {
        self.last_auto_save_ms = timestampMs();
    }

    /// Waits for ready work, not retry backoff. Returned coordinates are caller
    /// owned; failed snapshots remain queued for retry, even after consumption.
    pub fn flush(self: *SaveManager) []ChunkKey {
        var spins: u32 = 0;
        while (spins < 12000) : (spins += 1) {
            self.queue_mutex.lock();
            const now = timestampMs();
            var ready = false;
            for (self.queue.items) |*entry| {
                if (entry.retry_after_ms <= now) {
                    ready = true;
                    break;
                }
            }
            const saving = self.pending_saves.load(.acquire);
            self.queue_mutex.unlock();
            if (!ready and saving == 0) break;
            std.Options.debug_io.sleep(.fromNanoseconds(2 * std.time.ns_per_ms), .boot) catch {};
        }

        self.failed_mutex.lock();
        defer self.failed_mutex.unlock();
        return self.failed_chunks.toOwnedSlice(self.allocator) catch |err| {
            log.log.err("Failed to return failed save coordinates (retained for next flush): {}", .{err});
            return &.{};
        };
    }

    pub fn takeFailedSaveCount(self: *SaveManager) usize {
        return self.failed_save_count.swap(0, .acq_rel);
    }

    pub fn takePersistedFailedSaveCount(self: *SaveManager) usize {
        self.persisted_failed_save_mutex.lock();
        defer self.persisted_failed_save_mutex.unlock();

        const count = self.persisted_failed_save_count.swap(0, .acq_rel);
        if (count > 0) {
            self.save_dir.deleteFile(SAVE_FAILURE_COUNT_FILE) catch |err| {
                log.log.warn("Failed to clear persisted save failure count: {}", .{err});
            };
        }
        return count;
    }

    fn recordSaveFailure(self: *SaveManager) void {
        _ = self.failed_save_count.fetchAdd(1, .monotonic);
        self.persisted_failed_save_mutex.lock();
        defer self.persisted_failed_save_mutex.unlock();

        const persisted_count = self.persisted_failed_save_count.load(.acquire) + 1;
        self.persisted_failed_save_count.store(persisted_count, .release);
        persistSaveFailureCount(self.save_dir, persisted_count) catch |err| {
            log.log.err("Failed to persist save failure count: {}", .{err});
        };
    }

    fn saveThreadFn(self: *SaveManager) void {
        log.log.debug("Save thread started", .{});

        while (self.running.load(.acquire)) {
            // On error, treat as "no work done" so the loop sleeps before
            // retrying — otherwise a persistent fault (e.g. disk full) would
            // busy-loop at 100% CPU and spam the log.
            const did_work = self.processSaveQueue() catch |err| blk: {
                log.log.err("Save thread error: {}", .{err});
                break :blk false;
            };
            // Only idle-sleep when there is nothing to do. Previously the thread
            // slept a full interval between every batch, so flushing N dirty
            // chunks on exit took ceil(N/64)*interval. Draining back-to-back
            // collapses that to the actual IO/compression cost.
            if (!did_work) {
                std.Options.debug_io.sleep(.fromNanoseconds(SAVE_THREAD_INTERVAL_NS), .boot) catch {};
            }
        }

        _ = self.processSaveQueue() catch |err| blk: {
            log.log.err("Save thread final flush error: {}", .{err});
            break :blk false;
        };

        log.log.debug("Save thread exiting", .{});
    }

    fn processSaveQueue(self: *SaveManager) !bool {
        // Keep accepted entries in the queue until commit. Allocation failure
        // cannot strand queue_mutex; retaining a failed entry needs no allocation.
        const batch = blk: {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            const now = timestampMs();
            var count: usize = 0;
            for (self.queue.items) |*entry| {
                if (entry.retry_after_ms <= now) count += 1;
                if (count == 64) break;
            }
            if (count == 0) return false;

            const snapshots = try self.allocator.alloc(SaveQueueEntry, count);
            var i: usize = 0;
            for (self.queue.items) |*entry| {
                if (entry.retry_after_ms > now) continue;
                snapshots[i] = entry.*;
                i += 1;
                if (i == count) break;
            }
            self.pending_saves.store(count, .release);
            self.in_flight = snapshots;
            break :blk snapshots;
        };
        defer self.allocator.free(batch);
        defer {
            self.queue_mutex.lock();
            self.in_flight = &.{};
            self.pending_saves.store(0, .release);
            self.queue_mutex.unlock();
        }

        for (batch) |*entry| {
            const saved = blk: {
                self.saveOneChunk(entry) catch |err| {
                    self.recordSaveFailure();
                    log.log.err("Failed to save chunk ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, err });
                    self.failed_mutex.lock();
                    defer self.failed_mutex.unlock();
                    self.failed_chunks.append(self.allocator, .{ .x = entry.chunk_x, .z = entry.chunk_z }) catch |append_err| {
                        log.log.err("Failed to track failed chunk save ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, append_err });
                        self.recordSaveFailure();
                    };
                    break :blk false;
                };
                break :blk true;
            };

            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            self.in_flight = self.in_flight[1..];
            const key = ChunkKey{ .x = entry.chunk_x, .z = entry.chunk_z };
            const idx = self.queue_index.get(key).?;
            // A producer (including on_saved) may have supplied a newer snapshot.
            if (self.queue.items[idx].sequence != entry.sequence) continue;
            if (!saved) {
                self.queue.items[idx].retry_after_ms = timestampMs() + SAVE_RETRY_INTERVAL_MS;
                continue;
            }
            _ = self.queue_index.remove(key);
            _ = self.queue.swapRemove(idx);
            if (idx < self.queue.items.len) {
                const moved = &self.queue.items[idx];
                self.queue_index.getPtr(.{ .x = moved.chunk_x, .z = moved.chunk_z }).?.* = idx;
            }
        }
        return true;
    }

    fn saveOneChunk(self: *SaveManager, entry: *const SaveQueueEntry) !void {
        var chunk = Chunk.init(entry.chunk_x, entry.chunk_z);
        entry.restore(&chunk);
        chunk.source_kind = .saved;

        const serialized = chunk_serializer.serializeChunk(&chunk, self.allocator) catch |err| {
            log.log.err("Failed to serialize chunk ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, err });
            return err;
        };
        defer self.allocator.free(serialized);

        const rx: i32 = @divFloor(entry.chunk_x, 32);
        const rz: i32 = @divFloor(entry.chunk_z, 32);

        {
            self.region_cache_mutex.lock();
            defer self.region_cache_mutex.unlock();

            const region = try self.getOrOpenRegion(rx, rz);
            const local_x: u5 = @intCast(@mod(entry.chunk_x, 32));
            const local_z: u5 = @intCast(@mod(entry.chunk_z, 32));
            // writeChunk includes file.sync. This is not a crash-atomic update.
            try region.writeChunk(local_x, local_z, serialized);
        }

        if (entry.lighting_valid) self.markLightingMigrationComplete();

        self.queue_mutex.lock();
        const callback = self.on_saved;
        const callback_ctx = self.saved_callback_ctx;
        self.queue_mutex.unlock();
        if (callback) |notify| notify(callback_ctx.?, &chunk);
        _ = self.source_epoch.fetchAdd(1, .release);

        log.log.debug("Saved chunk ({}, {}) to region ({}, {})", .{ entry.chunk_x, entry.chunk_z, rx, rz });
    }

    fn getOrOpenRegion(self: *SaveManager, rx: i32, rz: i32) !*RegionFile {
        const now_ms = timestampMs();

        for (self.region_cache.items) |*entry| {
            if (entry.region_x == rx and entry.region_z == rz) {
                entry.last_used_ms = now_ms;
                return &entry.region;
            }
        }

        if (self.region_cache.items.len >= MAX_OPEN_REGIONS) {
            self.evictOldestRegion();
        }

        var rel_buf: [fs.max_path_bytes]u8 = undefined;
        const region_filename = std.fmt.bufPrint(&rel_buf, "regions/r.{}.{}.mca", .{ rx, rz }) catch unreachable;

        var region = blk: {
            var abs_buf: [fs.max_path_bytes]u8 = undefined;
            if (self.save_dir.realpath(region_filename, &abs_buf)) |abs_path| {
                break :blk try RegionFile.open(self.allocator, abs_path);
            } else |open_err| {
                if (open_err != error.FileNotFound) return open_err;
                const file = self.save_dir.createFile(region_filename, .{ .read = true, .exclusive = true }) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        const abs_path = try self.save_dir.realpath(region_filename, &abs_buf);
                        break :blk try RegionFile.open(self.allocator, abs_path);
                    }
                    return err;
                };
                file.close();
                break :blk try RegionFile.create(self.allocator, try self.save_dir.realpath(region_filename, &abs_buf));
            }
        };
        errdefer region.close();

        try self.region_cache.append(self.allocator, .{
            .region_x = rx,
            .region_z = rz,
            .region = region,
            .last_used_ms = now_ms,
        });

        return &self.region_cache.items[self.region_cache.items.len - 1].region;
    }

    fn evictOldestRegion(self: *SaveManager) void {
        if (self.region_cache.items.len == 0) return;

        var oldest_idx: usize = 0;
        var oldest_ts: i64 = self.region_cache.items[0].last_used_ms;
        for (self.region_cache.items[1..], 1..) |entry, i| {
            if (entry.last_used_ms < oldest_ts) {
                oldest_ts = entry.last_used_ms;
                oldest_idx = i;
            }
        }

        self.region_cache.items[oldest_idx].region.close();
        _ = self.region_cache.orderedRemove(oldest_idx);
    }

    fn flushRegionCache(self: *SaveManager) void {
        for (self.region_cache.items) |*entry| {
            entry.region.close();
        }
        self.region_cache.deinit(self.allocator);
    }
};

fn loadPersistedSaveFailureCount(allocator: Allocator, save_dir: fs.Dir) usize {
    const content = save_dir.readFileAlloc(SAVE_FAILURE_COUNT_FILE, allocator, 128) catch return 0;
    defer allocator.free(content);
    return std.fmt.parseInt(usize, std.mem.trim(u8, content, " \t\r\n"), 10) catch 0;
}

fn persistSaveFailureCount(save_dir: fs.Dir, count: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{}\n", .{count});
    const file = try save_dir.createFile(SAVE_FAILURE_COUNT_FILE, .{});
    defer file.close();
    try file.writeAll(text);
}

const testing = std.testing;

test "SaveManager init creates save directory and level.dat" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_world", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_world", 42, "overworld");
    defer sm.deinit();

    const file = dir.openFile("test_world/level.dat", .{}) catch {
        try testing.expect(false);
        return;
    };
    file.close();
}

test "SaveManager enqueue and flush processes chunks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_flush", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_flush", 99, "flat");
    defer sm.deinit();

    var chunk = Chunk.init(5, -3);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBiome(0, 0, .forest);
    chunk.generated = true;
    chunk.lighting_valid = true;
    chunk.pin();

    sm.enqueueSave(&chunk);
    chunk.unpin();
    _ = sm.flush();

    var loaded = Chunk.init(5, -3);
    try testing.expect(sm.loadChunk(5, -3, &loaded) == .success);
    try testing.expectEqual(BlockType.stone, loaded.getBlock(8, 64, 8));
    try testing.expectEqual(BiomeId.forest, loaded.getBiome(0, 0));
}

test "SaveManager loadChunk returns false for non-existent chunk" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_load_miss", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_load_miss", 0, "overworld");
    defer sm.deinit();

    var chunk = Chunk.init(100, 200);
    try testing.expect(sm.loadChunk(100, 200, &chunk) == .not_found);
}

test "SaveManager duplicate enqueue overwrites previous" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_dup", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_dup", 0, "flat");
    defer sm.deinit();

    var chunk1 = Chunk.init(0, 0);
    chunk1.setBlock(5, 5, 5, .dirt);
    chunk1.lighting_valid = true;
    chunk1.pin();

    var chunk2 = Chunk.init(0, 0);
    chunk2.setBlock(5, 5, 5, .gold_ore);
    chunk2.lighting_valid = true;
    chunk2.pin();

    sm.enqueueSave(&chunk1);
    chunk1.unpin();
    sm.enqueueSave(&chunk2);
    chunk2.unpin();
    _ = sm.flush();

    var loaded = Chunk.init(0, 0);
    try testing.expect(sm.loadChunk(0, 0, &loaded) == .success);
    try testing.expectEqual(BlockType.gold_ore, loaded.getBlock(5, 5, 5));
}

test "SaveManager persists and consumes save failure count" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_failures", .{base_path});

    {
        var sm = try SaveManager.init(testing.allocator, save_path, "test_failures", 0, "flat");
        sm.recordSaveFailure();
        try testing.expectEqual(@as(usize, 1), sm.takeFailedSaveCount());
        sm.deinit();
    }

    var sm = try SaveManager.init(testing.allocator, save_path, "test_failures", 0, "flat");
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 1), sm.takePersistedFailedSaveCount());
    try testing.expectEqual(@as(usize, 0), sm.takePersistedFailedSaveCount());
}

// Synchronous fixture: tests drive the real writer without scheduling races.
// The directory is borrowed, and no thread or owned level metadata is created.
fn initTestManager(allocator: Allocator, dir: fs.Dir) SaveManager {
    return .{
        .allocator = allocator,
        .save_dir = dir,
        .save_dir_path = "",
        .world_name = "",
        .queue_mutex = .{},
        .queue = .empty,
        .queue_index = QueueIndexMap.init(allocator),
        .running = .init(false),
        .pending_saves = .init(0),
        .failed_mutex = .{},
        .failed_chunks = .empty,
        .failed_save_count = .init(0),
        .persisted_failed_save_count = .init(0),
        .persisted_failed_save_mutex = .{},
        .thread = undefined,
        .region_cache_mutex = .{},
        .region_cache = .empty,
        .level_data = LevelData.init(0, ""),
        .last_auto_save_ms = 0,
    };
}

fn deinitTestManager(sm: *SaveManager) void {
    sm.flushRegionCache();
    sm.queue.deinit(sm.allocator);
    sm.queue_index.deinit();
    sm.failed_chunks.deinit(sm.allocator);
}

test "SaveManager readSavedChunk is noncreating and distinguishes region errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var sm = initTestManager(testing.allocator, dir);
    defer deinitTestManager(&sm);
    var out = Chunk.init(91, 92);
    out.setBlock(1, 2, 3, .gold_ore);
    out.pin();
    const before = out;

    try testing.expectEqual(LoadResult.not_found, sm.readSavedChunk(0, 0, &out));
    try testing.expectError(error.FileNotFound, dir.access("regions", .{}));
    try testing.expectEqualDeep(before, out);

    try dir.makePath("regions");
    try testing.expectEqual(LoadResult.not_found, sm.readSavedChunk(0, 0, &out));
    try testing.expectError(error.FileNotFound, dir.access("regions/r.0.0.mca", .{}));
    const malformed = try dir.createFile("regions/r.0.0.mca", .{});
    defer malformed.close();
    try malformed.writeAll("not a region header");
    try testing.expectEqual(LoadResult.read_error, sm.readSavedChunk(0, 0, &out));
    try testing.expectEqualDeep(before, out);

    // An existing non-file path must not be treated as an absent region.
    try dir.makePath("regions/r.1.0.mca");
    try testing.expectEqual(LoadResult.read_error, sm.readSavedChunk(32, 0, &out));
    try testing.expectEqualDeep(before, out);
    try testing.expectEqual(@as(usize, 0), sm.region_cache.items.len);
    try testing.expectEqual(@as(u64, 0), sm.sourceEpoch());
}

test "SaveManager saved decode is transactional and leaves relighting to loadChunk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var sm = initTestManager(testing.allocator, dir);
    defer deinitTestManager(&sm);
    try dir.makePath("regions");
    var base_buf: [fs.max_path_bytes]u8 = undefined;
    const base = try dir.realpath("regions", &base_buf);
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/r.-1.-2.mca", .{base});
    var region = try RegionFile.create(testing.allocator, path);
    defer region.close();

    var source = Chunk.init(-1, -33);
    source.setBlock(3, 4, 5, .stone);
    source.setSkyLight(3, 4, 5, 9);
    source.lighting_valid = true;
    var out = Chunk.init(80, 90);
    out.setBlock(1, 2, 3, .gold_ore);
    out.pin();
    const before = out;

    for (0..3) |case| {
        const data = try chunk_serializer.serializeChunk(&source, testing.allocator);
        defer testing.allocator.free(data);
        switch (case) {
            0 => data[chunk_serializer.HEADER_SIZE] ^= 1,
            // Coordinates are outside the payload CRC in the existing format.
            1 => std.mem.writeInt(i32, data[10..14], -2, .little),
            2 => {
                const biome_offset = chunk_serializer.HEADER_SIZE + CHUNK_VOLUME * (1 + @sizeOf(PackedLight));
                data[biome_offset] = 255;
                std.mem.writeInt(u32, data[6..10], std.hash.Crc32.hash(data[chunk_serializer.HEADER_SIZE..]), .little);
            },
            else => unreachable,
        }
        try region.writeChunk(31, 31, data);
        try testing.expectEqual(LoadResult.corrupt_data, sm.readSavedChunk(-1, -33, &out));
        try testing.expectEqualDeep(before, out);
        try testing.expectEqual(LoadResult.corrupt_data, sm.loadChunk(-1, -33, &out));
        try testing.expectEqualDeep(before, out);
    }

    const valid = try chunk_serializer.serializeChunk(&source, testing.allocator);
    defer testing.allocator.free(valid);
    try region.writeChunk(31, 31, valid);
    try testing.expectEqual(LoadResult.not_found, sm.readSavedChunk(-2, -33, &out));
    try testing.expectEqualDeep(before, out);
    try testing.expectEqual(LoadResult.success, sm.readSavedChunk(-1, -33, &out));
    try testing.expectEqual(@as(i32, -1), out.chunk_x);
    try testing.expectEqual(@as(i32, -33), out.chunk_z);
    try testing.expectEqualSlices(BlockType, &source.blocks, &out.blocks);
    try testing.expectEqual(@as(u32, 1), out.pin_count.load(.acquire));

    valid[4] = 2;
    try region.writeChunk(31, 31, valid);
    try testing.expectEqual(LoadResult.success_relight_required, sm.readSavedChunk(-1, -33, &out));
    try testing.expectEqual(@as(u4, 9), out.getSkyLight(3, 4, 5));
    try testing.expectEqual(@as(u64, 0), out.light_revision.load(.acquire));
    try testing.expectEqual(LoadResult.success_relight_required, sm.loadChunk(-1, -33, &out));
    try testing.expectEqual(@as(u4, 0), out.getSkyLight(3, 4, 5));
    try testing.expectEqual(@as(u64, 1), out.light_revision.load(.acquire));
    try testing.expectEqual(@as(u64, 0), sm.sourceEpoch());
}

test "SaveManager committed callbacks precede epoch and failed snapshots survive retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var sm = initTestManager(testing.allocator, dir);
    defer deinitTestManager(&sm);
    try dir.makePath("regions");
    var original = Chunk.init(0, 0);
    original.setBlock(0, 0, 0, .stone);
    original.markLightChanged();
    original.lighting_valid = true;
    original.pin();
    defer original.unpin();
    var replacement = Chunk.init(0, 0);
    replacement.setBlock(0, 0, 0, .gold_ore);
    replacement.lighting_valid = true;
    replacement.pin();
    defer replacement.unpin();

    const Observer = struct {
        sm: *SaveManager,
        replacement: ?*const Chunk,
        calls: usize = 0,
        unlocked: bool = true,
        admitted: bool = false,
        immutable: bool = true,
        epoch: u64 = 0,
        block: BlockType = .air,
        disk_block: BlockType = .air,
        result: LoadResult = .not_found,
        pending_restored: bool = true,
        snapshot_revisions: bool = true,
        content_revision: u64 = 0,
        light_revision: u64 = 0,

        fn saved(ctx: *anyopaque, chunk: *const Chunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            const region_unlocked = self.sm.region_cache_mutex.tryLock();
            if (region_unlocked) self.sm.region_cache_mutex.unlock();
            const queue_unlocked = self.sm.queue_mutex.tryLock();
            if (queue_unlocked) self.sm.queue_mutex.unlock();
            self.unlocked = self.unlocked and region_unlocked and queue_unlocked;
            if (!self.unlocked) return;
            self.epoch = self.sm.sourceEpoch();
            self.content_revision = chunk.content_revision.load(.acquire);
            self.light_revision = chunk.light_revision.load(.acquire);
            self.block = chunk.getBlock(0, 0, 0);
            var disk = Chunk.init(0, 0);
            self.result = self.sm.readSavedChunk(0, 0, &disk);
            self.disk_block = disk.getBlock(0, 0, 0);
            var resident = Chunk.init(0, 0);
            const in_flight = self.sm.loadResidentChunk(0, 0, &resident);
            self.pending_restored = self.pending_restored and in_flight.pending and
                resident.getBlock(0, 0, 0) == self.block;
            self.snapshot_revisions = self.snapshot_revisions and
                resident.content_revision.load(.acquire) == chunk.content_revision.load(.acquire) and
                resident.light_revision.load(.acquire) == chunk.light_revision.load(.acquire);
            if (self.replacement) |next| {
                self.replacement = null;
                self.admitted = self.sm.tryEnqueueSave(next);
                const queued = self.sm.loadResidentChunk(0, 0, &resident);
                self.pending_restored = self.pending_restored and queued.pending and
                    resident.getBlock(0, 0, 0) == next.getBlock(0, 0, 0);
            }
            self.immutable = self.immutable and chunk.getBlock(0, 0, 0) == self.block;
        }
    };
    var observer = Observer{ .sm = &sm, .replacement = &replacement };
    sm.setSavedCallback(&observer, Observer.saved);
    try testing.expect(sm.tryEnqueueSave(&original));
    original.setBlock(0, 0, 0, .dirt);
    var out = Chunk.init(0, 0);
    try testing.expectEqual(LoadResult.not_found, sm.readSavedChunk(0, 0, &out));
    try testing.expectEqual(@as(u64, 0), sm.sourceEpoch());
    try testing.expect(try sm.processSaveQueue());
    try testing.expect(observer.unlocked and observer.immutable and observer.admitted);
    try testing.expect(observer.pending_restored and observer.snapshot_revisions);
    try testing.expectEqual(@as(u64, 1), observer.content_revision);
    try testing.expectEqual(@as(u64, 1), observer.light_revision);
    try testing.expectEqual(LoadResult.success, observer.result);
    try testing.expectEqual(BlockType.stone, observer.block);
    try testing.expectEqual(observer.block, observer.disk_block);
    try testing.expectEqual(@as(u64, 0), observer.epoch);
    try testing.expectEqual(@as(u64, 1), sm.sourceEpoch());
    try testing.expectEqual(@as(usize, 1), sm.queue.items.len);
    try testing.expectEqual(LoadResult.success, sm.readSavedChunk(0, 0, &out));
    try testing.expectEqual(BlockType.stone, out.getBlock(0, 0, 0));
    try testing.expect(try sm.processSaveQueue());
    try testing.expectEqual(@as(u64, 2), sm.sourceEpoch());
    try testing.expectEqual(@as(u64, 1), observer.epoch);
    try testing.expectEqual(BlockType.gold_ore, observer.disk_block);
    try testing.expectEqual(@as(usize, 0), sm.queue.items.len);

    // Inject a deterministic write failure after admission, not an enqueue error.
    sm.region_cache.items[0].region.read_only = true;
    try testing.expect(sm.tryEnqueueSave(&original));
    try testing.expect(try sm.processSaveQueue());
    try testing.expectEqual(@as(u64, 2), sm.sourceEpoch());
    try testing.expectEqual(@as(usize, 2), observer.calls);
    try testing.expectEqual(@as(usize, 1), sm.queue.items.len);
    try testing.expect(sm.queue.items[0].retry_after_ms > 0);
    sm.queue.items[0].retry_after_ms = std.math.maxInt(i64);
    try testing.expect(!try sm.processSaveQueue());
    const failed = sm.flush();
    defer testing.allocator.free(failed);
    try testing.expectEqual(@as(usize, 1), failed.len);
    try testing.expectEqualDeep(ChunkKey{ .x = 0, .z = 0 }, failed[0]);
    try testing.expectEqual(BlockType.dirt, sm.queue.items[0].blocks[0]);
    try testing.expectEqual(LoadResult.success, sm.readSavedChunk(0, 0, &out));
    try testing.expectEqual(BlockType.gold_ore, out.getBlock(0, 0, 0));

    sm.region_cache.items[0].region.read_only = false;
    sm.queue.items[0].retry_after_ms = 0;
    try testing.expect(try sm.processSaveQueue());
    try testing.expectEqual(@as(u64, 3), sm.sourceEpoch());
    try testing.expectEqual(@as(usize, 3), observer.calls);
    try testing.expectEqual(BlockType.dirt, observer.disk_block);
    try testing.expectEqual(@as(usize, 0), sm.queue.items.len);
    sm.setSavedCallback(null, null);
}

test "SaveManager OOM releases queue mutex and preserves admission ownership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    chunk.pin();
    defer chunk.unpin();

    for (0..2) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var sm = initTestManager(failing.allocator(), dir);
        defer deinitTestManager(&sm);
        try testing.expect(!sm.tryEnqueueSave(&chunk));
        try testing.expect(chunk.modified);
        try testing.expectEqual(@as(usize, 0), sm.queue.items.len);
        try testing.expectEqual(@as(u32, 0), sm.queue_index.count());
        try testing.expect(sm.queue_mutex.tryLock());
        sm.queue_mutex.unlock();
    }

    var sm = initTestManager(testing.allocator, dir);
    defer deinitTestManager(&sm);
    try testing.expect(sm.tryEnqueueSave(&chunk));
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    sm.allocator = failing.allocator();
    defer sm.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, sm.processSaveQueue());
    try testing.expect(sm.queue_mutex.tryLock());
    sm.queue_mutex.unlock();
    try testing.expectEqual(@as(usize, 1), sm.queue.items.len);
    try testing.expectEqual(@as(usize, 0), sm.queue_index.get(.{ .x = 0, .z = 0 }).?);
    try testing.expectEqual(BlockType.stone, sm.queue.items[0].blocks[0]);
    try testing.expectEqual(@as(usize, 0), sm.pending_saves.load(.acquire));
    try testing.expectEqual(@as(u64, 0), sm.sourceEpoch());
    try testing.expect(chunk.modified);
}

test "SaveManager pending reload preserves failed unloaded edit and second edit through retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var sm = initTestManager(testing.allocator, dir);
    defer deinitTestManager(&sm);
    try dir.makePath("regions");

    var disk = Chunk.init(-1, 0);
    disk.setBlock(0, 0, 0, .stone);
    disk.lighting_valid = true;
    disk.pin();
    defer disk.unpin();
    try testing.expect(sm.tryEnqueueSave(&disk));
    try testing.expect(try sm.processSaveQueue());

    {
        var resident = Chunk.init(-1, 0);
        const loaded = sm.loadResidentChunk(-1, 0, &resident);
        try testing.expect(!loaded.pending);
        try testing.expectEqual(LoadResult.success, loaded.result);
        try testing.expectEqual(Chunk.SourceKind.saved, resident.source_kind);
        resident.setBlock(1, 0, 0, .gold_ore);
        resident.setSkyLight(1, 0, 0, 7);
        resident.markLightChanged();
        resident.canonical_save_order = 42;
        resident.pin();
        defer resident.unpin();
        try testing.expect(sm.tryEnqueueSave(&resident));
        // Fail before region allocation/header/payload mutation, not mid-write.
        sm.region_cache.items[0].region.read_only = true;
        try testing.expect(try sm.processSaveQueue());
        sm.queue.items[0].retry_after_ms = std.math.maxInt(i64);
    }
    try testing.expect(!try sm.processSaveQueue());
    try testing.expectEqual(LoadResult.success, sm.readSavedChunk(-1, 0, &disk));
    try testing.expectEqual(BlockType.air, disk.getBlock(1, 0, 0));
    try testing.expectEqual(@as(u64, 0), disk.canonical_save_order);

    var reloaded = Chunk.init(-1, 0);
    reloaded.state = .generating;
    reloaded.job_token = 41;
    reloaded.pin();
    defer reloaded.unpin();
    const pending = sm.loadResidentChunk(-1, 0, &reloaded);
    try testing.expect(pending.pending);
    try testing.expectEqual(LoadResult.success, pending.result);
    try testing.expectEqual(BlockType.gold_ore, reloaded.getBlock(1, 0, 0));
    try testing.expectEqual(@as(u4, 7), reloaded.getSkyLight(1, 0, 0));
    try testing.expectEqual(@as(u64, 1), reloaded.content_revision.load(.acquire));
    try testing.expectEqual(@as(u64, 1), reloaded.light_revision.load(.acquire));
    try testing.expectEqual(@as(u64, 42), reloaded.canonical_save_order);
    try testing.expectEqual(Chunk.SourceKind.edited, reloaded.source_kind);
    try testing.expect(reloaded.modified);
    try testing.expectEqual(Chunk.State.generating, reloaded.state);
    try testing.expectEqual(@as(u32, 41), reloaded.job_token);
    try testing.expectEqual(@as(u32, 1), reloaded.pin_count.load(.acquire));

    reloaded.setBlock(2, 0, 0, .dirt);
    reloaded.markLightChanged();
    try testing.expect(sm.tryEnqueueSave(&reloaded));
    sm.region_cache.items[0].region.read_only = false;
    try testing.expect(try sm.processSaveQueue());
    try testing.expectEqual(@as(usize, 0), sm.in_flight.len);
    try testing.expectEqual(@as(usize, 0), sm.queue.items.len);
    try testing.expectEqual(LoadResult.success, sm.readSavedChunk(-1, 0, &disk));
    try testing.expectEqual(BlockType.stone, disk.getBlock(0, 0, 0));
    try testing.expectEqual(BlockType.gold_ore, disk.getBlock(1, 0, 0));
    try testing.expectEqual(BlockType.dirt, disk.getBlock(2, 0, 0));
    try testing.expectEqual(@as(u4, 7), disk.getSkyLight(1, 0, 0));
    const failed = sm.flush();
    defer testing.allocator.free(failed);
    try testing.expectEqual(@as(usize, 1), failed.len);
}
