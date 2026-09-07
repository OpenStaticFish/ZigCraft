const Self = @import("lod_manager.zig").LODManager;
const world_core = @import("world-core");
const lod_chunk = @import("lod_chunk.zig");
const ChunkCoordKey = @import("lod_manager_context.zig").ChunkCoordKey;
const log = @import("engine-core").log;

pub const MAX_NEAR_SOURCE_RETRIES: usize = 128;

/// Conservative retained-capacity accounting includes array/hash overhead.
pub fn memoryBytes(self: *const Self) usize {
    return self.near_sources.capacity() * (@sizeOf(Self.NearSourceCapture) + @sizeOf(ChunkCoordKey) + 32) +
        self.near_source_retries.capacity * @sizeOf(Self.NearSourceRetry);
}

pub fn captureResolved(self: *Self, cx: i32, cz: i32, kind: Self.NearSourceKind) bool {
    if (self.usesCanonicalSource()) return false;
    if (!self.near_source_enabled or self.benchmark_fixture_active) return false;
    self.ingestion_queue.mutex.lock();
    const resolver = self.ingestion_queue.chunk_resolver;
    self.ingestion_queue.mutex.unlock();
    const r = resolver orelse return false;
    const capture_fn = r.capture_near_fn orelse return false;
    const sequence = self.near_source_sequence.fetchAdd(1, .monotonic);
    const summary = capture_fn(r.ptr, cx, cz) orelse return false;
    const capture = Self.NearSourceCapture{ .summary = summary, .kind = kind, .sequence = sequence };
    if (submit(self, cx, cz, capture)) return true;
    deferCapture(self, cx, cz, capture);
    return false;
}

pub fn submit(self: *Self, cx: i32, cz: i32, capture: Self.NearSourceCapture) bool {
    if (self.usesCanonicalSource()) return false;
    if (!self.near_source_enabled or self.benchmark_fixture_active) return false;
    self.mutex.lock();
    defer self.mutex.unlock();
    return submitLocked(self, cx, cz, capture);
}

fn submitLocked(self: *Self, cx: i32, cz: i32, capture: Self.NearSourceCapture) bool {
    // Retirement removes per-coordinate authority history. Reject old captures
    // even if a fresh lower-kind capture has already recreated the coordinate.
    // A global floor deliberately favors dropping evidence over reviving edits
    // from an earlier source lifetime.
    if (capture.sequence < self.near_source_sequence_floor) return true;
    const key = ChunkCoordKey{ .cx = cx, .cz = cz };
    if (self.near_sources.getPtr(key)) |previous| {
        // Loaded snapshots also outrank fresh generation, but must never
        // replace a later runtime edit merely because publication was delayed.
        if (@intFromEnum(capture.kind) < @intFromEnum(previous.kind) or
            (capture.kind == previous.kind and capture.sequence < previous.sequence)) return true;
        previous.* = capture;
    } else {
        const entry_bytes = @sizeOf(Self.NearSourceCapture) + @sizeOf(ChunkCoordKey) + 32;
        const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
        // Reserve growth slack as well as payloads; at most 1/8 of the LOD
        // budget goes to retained summaries (4096 entries with no budget).
        const limit = @min(self.near_source_limit, if (budget == 0) self.near_source_limit else budget / 16 / entry_bytes);
        if (limit == 0) return false;
        if (self.near_sources.count() >= limit) {
            const player = self.loadPlayerChunkPos();
            var farthest = distanceSquared(key, player.cx, player.cz);
            var victim: ?usize = null;
            for (self.near_sources.keys(), 0..) |resident, index| {
                const distance = distanceSquared(resident, player.cx, player.cz);
                if (distance >= farthest) {
                    farthest = distance;
                    victim = index;
                }
            }
            self.near_sources.swapRemoveAt(victim orelse return false);
            self.near_source_sequence_floor = self.near_source_sequence.fetchAdd(1, .monotonic) + 1;
        }
        const before = memoryBytes(self);
        defer {
            const added = memoryBytes(self) -| before;
            self.memory_governor.used_bytes +|= added;
            self.memory_governor.logical_admission_bytes +|= added;
        }
        self.near_sources.put(self.allocator, key, capture) catch return false;
    }
    applyCoordinateLocked(self, key);
    return true;
}

pub fn deferCapture(self: *Self, cx: i32, cz: i32, capture: Self.NearSourceCapture) void {
    if (!self.near_source_enabled or self.benchmark_fixture_active) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (capture.sequence < self.near_source_sequence_floor) return;
    for (self.near_source_retries.items) |*pending| {
        if (pending.cx != cx or pending.cz != cz) continue;
        if (@intFromEnum(capture.kind) > @intFromEnum(pending.capture.kind) or
            (capture.kind == pending.capture.kind and capture.sequence >= pending.capture.sequence)) pending.capture = capture;
        return;
    }
    if (self.near_source_retries.items.len >= MAX_NEAR_SOURCE_RETRIES) {
        log.log.warn("Near-source retry queue full; dropping ({}, {}) kind={s}", .{ cx, cz, @tagName(capture.kind) });
        return;
    }
    const before = memoryBytes(self);
    defer {
        const added = memoryBytes(self) -| before;
        self.memory_governor.used_bytes +|= added;
        self.memory_governor.logical_admission_bytes +|= added;
    }
    self.near_source_retries.append(self.allocator, .{ .cx = cx, .cz = cz, .capture = capture }) catch |err| {
        log.log.warn("Near-source retry allocation failed for ({}, {}): {}", .{ cx, cz, err });
    };
}

fn distanceSquared(key: ChunkCoordKey, cx: i32, cz: i32) i128 {
    const dx = @as(i128, key.cx) - cx;
    const dz = @as(i128, key.cz) - cz;
    return dx * dx + dz * dz;
}

/// Regions can disappear under full-detail coverage without losing summaries.
/// Only distance/cap pressure or manager teardown removes captured source.
pub fn prune(self: *Self) void {
    if (!self.near_source_enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    const player = self.loadPlayerChunkPos();
    const radius: i128 = @as(i128, @max(self.config.getRadii()[1], self.config.getChunkRenderRadius())) + 8;
    var index: usize = 0;
    while (index < self.near_sources.count()) {
        if (distanceSquared(self.near_sources.keys()[index], player.cx, player.cz) > radius * radius) {
            self.near_sources.swapRemoveAt(index);
            self.near_source_sequence_floor = self.near_source_sequence.fetchAdd(1, .monotonic) + 1;
        } else {
            index += 1;
        }
    }
}

/// Fair bounded replay handles arrivals during mesh/upload jobs without
/// retaining their full-detail source or depending on a region's lifetime.
pub fn replay(self: *Self, max_count: usize) void {
    if (!self.near_source_enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    // Retry original snapshots, not resident pointers: load provenance and
    // ownership survive unload. Failed admissions rotate behind untouched work.
    for (0..@min(self.near_source_retries.items.len, max_count)) |_| {
        const pending = self.near_source_retries.orderedRemove(0);
        if (!submitLocked(self, pending.cx, pending.cz, pending.capture)) {
            self.near_source_retries.appendAssumeCapacity(pending);
        }
    }
    const count = self.near_sources.count();
    if (count == 0) return;
    for (0..@min(count, max_count)) |_| {
        self.near_source_cursor %= count;
        const key = self.near_sources.keys()[self.near_source_cursor];
        self.near_source_cursor += 1;
        applyCoordinateLocked(self, key);
    }
}

fn applyCoordinateLocked(self: *Self, coordinate: ChunkCoordKey) void {
    for (0..@min(@as(usize, 2), lod_chunk.activeLODCount(self.config))) |level| {
        const lod: lod_chunk.LODLevel = @enumFromInt(level);
        const key = lod_chunk.LODRegionKey.fromChunkCoords(coordinate.cx, coordinate.cz, lod);
        const region = self.regions[level].get(key) orelse continue;
        if (region.isPinned()) continue;
        switch (region.getState()) {
            .generated, .renderable, .mesh_ready => {},
            else => continue,
        }
        if (overlayRegionLocked(self, region) != 0) self.demoteRegionForRemesh(key, region);
    }
}

pub fn overlayRegionLocked(self: *Self, region: *lod_chunk.LODChunk) u32 {
    if (!self.usesNearSource(region.lodLevel())) return 0;
    const data = switch (region.data) {
        .simplified => |*data| data,
        else => return 0,
    };
    const size: i32 = @intCast(world_core.regionSizeBlocks(region.lodLevel()));
    if (data.width != @as(u32, @intCast(size + 1)) or !data.hasVerticalSpans()) return 0;
    const side: i32 = @intCast(region.lodLevel().chunksPerSide());
    const min_cx = region.region_x * side;
    const min_cz = region.region_z * side;
    var changed: u32 = 0;
    var z: i32 = 0;
    while (z < side) : (z += 1) {
        var x: i32 = 0;
        while (x < side) : (x += 1) {
            const cx = min_cx + x;
            const cz = min_cz + z;
            const source = self.near_sources.getPtr(.{ .cx = cx, .cz = cz }) orelse continue;
            const provenance: world_core.LODColumnProvenance = if (source.kind == .generated) .chunk_derived else .edited;
            changed += source.summary.apply(data, cx, cz, region.region_x * size, region.region_z * size, size, provenance);
        }
    }
    if (changed != 0) {
        region.markSourceDirty();
        region.updateHeightBoundsFromData();
    }
    return changed;
}
