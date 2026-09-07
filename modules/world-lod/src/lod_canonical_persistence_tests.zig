//! CPU-only saved blocks -> canonical sources -> scene projection round trips.
const std = @import("std");
const testing = std.testing;
const fs = @import("fs");
const core = @import("world-core");
const persistence = @import("world-persistence");
const store = persistence.summary_store;
const scene = core.lod_scene;
const builder = @import("lod_scene_builder.zig");
const SourceHierarchy = @import("lod_source_hierarchy.zig").SourceHierarchy;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const JobQueue = @import("engine-core").job_system.JobQueue;
const a = testing.allocator;
const identity: store.Identity = .{ .seed = 42, .generator_hash = 123, .generator_version = 7 };
const sizes = [_]u32{ 1, 2, 4, 8 };
// Both saved chunks occupy the same negative-coordinate region, but are not adjacent.
const ground_cx: i32 = -3;
const air_cx: i32 = -1;
const saved_cz: i32 = -2;
const region_path = "regions/r.-1.-1.mca";
const ground_sidecar = "summaries/v1/r.-1.-1/c.-3.-2.zsum";
const air_sidecar = "summaries/v1/r.-1.-1/c.-1.-2.zsum";

const Fixture = struct {
    tmp: testing.TmpDir,
    sm: *persistence.SaveManager,
    queue: JobQueue,
    hierarchy: ?*SourceHierarchy = null,
    loads: usize = 0,
    saved_loads: usize = 0,
    generations: usize = 0,
    saved_generations: usize = 0,

    fn init() !*Fixture {
        const self = try a.create(Fixture);
        errdefer a.destroy(self);
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = fs.Dir{ .inner = tmp.dir };
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const root = try dir.realpath(".", &path_buf);
        const sm = try persistence.SaveManager.init(a, root, "canonical-test", identity.seed, "canonical-test");
        errdefer sm.deinit();
        self.* = .{ .tmp = tmp, .sm = sm, .queue = JobQueue.init(a) };
        errdefer self.queue.deinit();
        self.hierarchy = try SourceHierarchy.init(a, self.generator(), &self.queue, 64 * 1024 * 1024);
        errdefer self.stopHierarchy();
        try self.hierarchy.?.setPersistence(sm.save_dir_path);
        return self;
    }

    fn deinit(self: *Fixture) void {
        // The committed callback may borrow the hierarchy until the writer joins.
        self.sm.deinit();
        self.stopHierarchy();
        self.queue.deinit();
        self.tmp.cleanup();
        a.destroy(self);
    }

    fn stopHierarchy(self: *Fixture) void {
        // No source workers are spawned. stop invokes cleanup for queued generic jobs.
        self.queue.stop();
        if (self.hierarchy) |hierarchy| hierarchy.deinit();
        self.hierarchy = null;
    }

    fn restartHierarchy(self: *Fixture) !void {
        self.stopHierarchy();
        self.queue.deinit();
        self.queue = JobQueue.init(a);
        self.hierarchy = try SourceHierarchy.init(a, self.generator(), &self.queue, 64 * 1024 * 1024);
        try self.hierarchy.?.setPersistence(self.sm.save_dir_path);
    }

    fn generator(self: *Fixture) LODGenerator {
        return .{
            .ptr = self,
            .generate_heightmap_only = cheapData,
            .maybe_recenter_cache = recenter,
            .seed = identity.seed,
            .identity_hash = identity.generator_hash,
            .version = identity.generator_version,
            .summary_context = self,
            .load_chunk_summary = load,
            .generate_chunk_summary = generate,
            .saved_source_epoch = savedEpoch,
        };
    }

    fn cheapData(_: *anyopaque, data: *core.LODSimplifiedData, _: i32, _: i32, _: core.LODLevel, _: ?*const builder.AtomicBool) void {
        @memset(data.heightmap, 200);
        @memset(data.top_blocks, .sand);
    }

    fn recenter(_: *anyopaque, _: i32, _: i32) bool {
        return false;
    }

    fn savedEpoch(ptr: *anyopaque) u64 {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        return self.sm.sourceEpoch();
    }

    // Adapter boundary only: world-runtime cannot be imported without a module cycle.
    // Match its strict load contract; all disk reads and captures are production code.
    fn load(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator) !?scene.ChunkSummary {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.loads += 1;
        const scratch = try allocator.create(core.Chunk);
        defer allocator.destroy(scratch);
        scratch.* = core.Chunk.init(cx, cz);
        switch (self.sm.readSavedChunk(cx, cz, scratch)) {
            .not_found => return null,
            .read_error => return error.SavedSourceReadFailed,
            .corrupt_data => return error.SavedSourceCorrupt,
            .success, .success_relight_required => {},
        }
        self.saved_loads += 1;
        var summary = try scene.ChunkSummary.capture(allocator, scratch);
        summary.origin = .saved;
        return summary;
    }

    fn generate(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator, cancel: ?*const builder.AtomicBool) !scene.ChunkSummary {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        self.generations += 1;
        if (cz == saved_cz and (cx == ground_cx or cx == air_cx)) {
            self.saved_generations += 1;
            return error.GeneratedSavedFootprint;
        }
        const scratch = try allocator.create(core.Chunk);
        defer allocator.destroy(scratch);
        scratch.* = core.Chunk.init(cx, cz);
        scratch.setBlock(0, 0, 0, .sand);
        var summary = try scene.ChunkSummary.capture(allocator, scratch);
        summary.origin = .generated;
        return summary;
    }

    fn flush(self: *Fixture) !void {
        const failed = self.sm.flush();
        defer a.free(failed);
        try testing.expectEqual(@as(usize, 0), failed.len);
        try testing.expectEqual(@as(usize, 0), self.sm.pending_saves.load(.acquire));
    }

    fn seedWorld(self: *Fixture) !void {
        const chunk = try layeredChunk();
        defer a.destroy(chunk);
        {
            chunk.pin();
            defer chunk.unpin();
            try testing.expect(self.sm.tryEnqueueSave(chunk));
        }
        // Reuse scratch only after admission copied the first immutable snapshot.
        chunk.* = core.Chunk.init(air_cx, saved_cz);
        chunk.lighting_valid = true;
        chunk.pin();
        defer chunk.unpin();
        try testing.expect(self.sm.tryEnqueueSave(chunk));
        try self.flush();
        try testing.expectEqual(@as(u64, 2), self.sm.sourceEpoch());
    }

    fn prepare(self: *Fixture, cx: i32) !void {
        const provider = self.hierarchy.?.provider();
        try provider.prepare_fn(provider.ptr, cx, saved_cz, cx, saved_cz, true, null);
    }

    fn acquire(self: *Fixture, cx: i32) !builder.Lease {
        const provider = self.hierarchy.?.provider();
        provider.lock_fn(provider.ptr);
        defer provider.unlock_fn(provider.ptr);
        return provider.acquire_fn(provider.ptr, cx, saved_cz) orelse error.MissingSavedSummary;
    }

    fn runQueued(self: *Fixture) void {
        while (self.queue.tryPop()) |job| job.data.generic.process_fn(job.data.generic.context);
    }

    fn buildSceneGrid(self: *Fixture, cx: i32, size: u32) !scene.SceneGrid {
        // Exact saved footprints load synchronously. Keep unknown halo cells on the
        // intentionally wrong cheap fallback, without admitting background generation.
        try self.prepare(cx);
        // Pausing cancels queued work, so execute the real sidecar writes first.
        self.runQueued();
        self.queue.setPaused(true);
        defer self.queue.setPaused(false);
        var fallback = try core.LODSimplifiedData.initWithGridSize(a, .lod0, 16 / size + 1);
        defer fallback.deinit();
        self.generator().generateHeightmapOnly(&fallback, cx, saved_cz, .lod0, null);
        return builder.build(a, &fallback, cx * 16, saved_cz * 16, 16, self.hierarchy.?.provider(), false, null);
    }

    fn readFile(self: *Fixture, path: []const u8) ![]u8 {
        return self.sm.save_dir.readFileAlloc(path, a, 4 * 1024 * 1024);
    }

    fn expectFileUnchanged(self: *Fixture, path: []const u8, before: []const u8) !void {
        const after = try self.readFile(path);
        defer a.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
};

fn layeredChunk() !*core.Chunk {
    const chunk = try a.create(core.Chunk);
    chunk.* = core.Chunk.init(ground_cx, saved_cz);
    chunk.lighting_valid = true;
    for (0..16) |z| for (0..16) |x| {
        for (0..12) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        for (12..16) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .dirt);
        chunk.setBlock(@intCast(x), 16, @intCast(z), .grass);
        for (22..25) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .stone);
        for (32..34) |y| chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .cobblestone);
        if (z >= 8) for (40..43) |y| {
            chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .leaves);
        };
        if (x >= 8) for (48..50) |y| {
            chunk.setBlock(@intCast(x), @intCast(y), @intCast(z), .water);
        };
    };
    return chunk;
}

fn expectLayeredGrid(grid: *scene.SceneGrid, bridge: core.BlockType) !void {
    const blocks = [_]core.BlockType{ .stone, .dirt, .grass, .stone, bridge, .leaves, .water };
    const bottoms = [_]f32{ 0, 12, 16, 22, 32, 40, 48 };
    const tops = [_]f32{ 12, 16, 17, 25, 34, 43, 50 };
    for (0..grid.width) |z| for (0..grid.width) |x| {
        const gx: i32 = @intCast(x);
        const gz: i32 = @intCast(z);
        const info = grid.columnInfo(gx, gz);
        try testing.expectEqual(grid.cell_size * grid.cell_size, info.known_area);
        try testing.expectEqual(info.known_area, info.total_area);
        try testing.expectEqual(grid.cell_size > 1, info.approximate);
        const spans = grid.column(gx, gz);
        var index: usize = 0;
        for (blocks, bottoms, tops, 0..) |block, bottom, top, band| {
            if (band == 5 and z * grid.cell_size < 8) continue;
            if (band == 6 and x * grid.cell_size < 8) continue;
            try testing.expect(index < spans.len);
            const span = spans[index];
            try testing.expectEqual(block, span.block);
            try testing.expectEqual(bottom, span.min_y);
            try testing.expectEqual(top, span.max_y);
            try testing.expectEqual(@as(f32, 1), span.coverage);
            try testing.expectEqual(@as(f32, 0.5), span.center_x);
            try testing.expectEqual(@as(f32, 0.5), span.center_z);
            index += 1;
        }
        // Exact band bounds and count forbid filling the cave or detached gaps.
        try testing.expectEqual(index, spans.len);
    };
}

fn expectAirGrid(grid: *scene.SceneGrid) !void {
    for (0..grid.width) |z| for (0..grid.width) |x| {
        const gx: i32 = @intCast(x);
        const gz: i32 = @intCast(z);
        const info = grid.columnInfo(gx, gz);
        try testing.expectEqual(grid.cell_size * grid.cell_size, info.known_area);
        try testing.expectEqual(info.known_area, info.total_area);
        try testing.expect(!info.approximate);
        try testing.expectEqual(@as(usize, 0), grid.column(gx, gz).len);
    };
}

fn expectSameFootprints(before: *scene.SceneGrid, after: *scene.SceneGrid) !void {
    try testing.expectEqual(before.cell_size, after.cell_size);
    try testing.expectEqual(before.width, after.width);
    try testing.expectEqual(before.origin_x, after.origin_x);
    try testing.expectEqual(before.origin_z, after.origin_z);
    for (0..before.width) |z| for (0..before.width) |x| {
        const gx: i32 = @intCast(x);
        const gz: i32 = @intCast(z);
        const left = before.columnInfo(gx, gz);
        const right = after.columnInfo(gx, gz);
        try testing.expectEqual(left.known_area, right.known_area);
        try testing.expectEqual(left.total_area, right.total_area);
        try testing.expectEqual(left.approximate, right.approximate);
        try testing.expectEqualDeep(before.column(gx, gz), after.column(gx, gz));
    };
}

test "canonical persistence saved strata and known air project deterministically at cells 1 2 4 8" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.seedWorld();
    const region = try f.readFile(region_path);
    defer a.free(region);
    for (sizes) |size| {
        var ground = try f.buildSceneGrid(ground_cx, size);
        defer ground.deinit();
        try expectLayeredGrid(&ground, .cobblestone);
        var air = try f.buildSceneGrid(air_cx, size);
        defer air.deinit();
        try expectAirGrid(&air);
        // Unknown halo has actual fallback geometry; empty saved cells did not use it.
        try testing.expectEqual(@as(u32, 0), air.columnInfo(-1, -1).known_area);
        try testing.expect(air.column(-1, -1).len > 0);
        for ([_]i32{ ground_cx, air_cx }) |cx| {
            var repeated = try f.buildSceneGrid(cx, size);
            defer repeated.deinit();
            try expectSameFootprints(if (cx == ground_cx) &ground else &air, &repeated);
        }
    }
    const saved = try f.acquire(ground_cx);
    defer saved.release();
    try testing.expectEqual(scene.Origin.saved, saved.summary.origin);
    const empty = try f.acquire(air_cx);
    defer empty.release();
    try testing.expectEqual(scene.Origin.saved, empty.summary.origin);
    try testing.expectEqual(@as(usize, 0), empty.summary.runs.len);
    try testing.expectEqual(@as(usize, 2), f.saved_loads);
    try testing.expectEqual(@as(usize, 0), f.generations);
    try testing.expectEqual(@as(usize, 0), f.saved_generations);
    f.runQueued();
    try f.expectFileUnchanged(region_path, region);
}

fn expectReadRepair(corrupt: bool) !void {
    const f = try Fixture.init();
    defer f.deinit();
    try f.seedWorld();
    const region = try f.readFile(region_path);
    defer a.free(region);
    var originals: [8]scene.SceneGrid = undefined;
    var initialized: usize = 0;
    defer for (originals[0..initialized]) |*grid| grid.deinit();
    for ([_]i32{ ground_cx, air_cx }) |cx| for (sizes) |size| {
        originals[initialized] = try f.buildSceneGrid(cx, size);
        initialized += 1;
    };
    f.runQueued();
    var fingerprints: [2]u64 = undefined;
    for ([_]i32{ ground_cx, air_cx }, 0..) |cx, i| {
        var summary = (try store.read(a, f.sm.save_dir_path, identity, cx, saved_cz)).?;
        defer summary.deinit();
        try testing.expectEqual(scene.Origin.saved, summary.origin);
        fingerprints[i] = summary.fingerprint();
    }
    f.stopHierarchy();
    if (corrupt) {
        for ([_][]const u8{ ground_sidecar, air_sidecar }, [_]i32{ ground_cx, air_cx }) |path, cx| {
            const bytes = try f.readFile(path);
            defer a.free(bytes);
            bytes[bytes.len - 1] ^= 1;
            const file = try f.sm.save_dir.openFile(path, .{ .mode = .read_write });
            defer file.close();
            try file.writePositionalAll(bytes, 0);
            try file.sync();
            try testing.expectError(error.ChecksumMismatch, store.read(a, f.sm.save_dir_path, identity, cx, saved_cz));
        }
    } else {
        // Remove only named sidecars and test-owned legacy derived files, never regions.
        try f.sm.save_dir.makePath("lod/0");
        for ([_][]const u8{ "lod/store.json", "lod/0/r.-1.-1.zlod" }) |path| {
            {
                const file = try f.sm.save_dir.createFile(path, .{ .exclusive = true });
                defer file.close();
                try file.writeAll("obsolete derived test fixture");
            }
            try f.sm.save_dir.deleteFile(path);
        }
        try f.sm.save_dir.deleteFile(ground_sidecar);
        try f.sm.save_dir.deleteFile(air_sidecar);
        for ([_]i32{ ground_cx, air_cx }) |cx| {
            try testing.expect((try store.read(a, f.sm.save_dir_path, identity, cx, saved_cz)) == null);
        }
    }
    try f.expectFileUnchanged(region_path, region);
    const loads = f.saved_loads;
    try f.restartHierarchy();
    for (originals[0..initialized], 0..) |*original, i| {
        const cx = if (i < sizes.len) ground_cx else air_cx;
        var repaired = try f.buildSceneGrid(cx, original.cell_size);
        defer repaired.deinit();
        try expectSameFootprints(original, &repaired);
        if (cx == ground_cx) try expectLayeredGrid(&repaired, .cobblestone) else try expectAirGrid(&repaired);
    }
    f.runQueued();
    for ([_]i32{ ground_cx, air_cx }, fingerprints) |cx, fingerprint| {
        var repaired = (try store.read(a, f.sm.save_dir_path, identity, cx, saved_cz)).?;
        defer repaired.deinit();
        try testing.expectEqual(scene.Origin.saved, repaired.origin);
        try testing.expectEqual(fingerprint, repaired.fingerprint());
    }
    try testing.expectEqual(loads + 2, f.saved_loads);
    try testing.expectEqual(@as(usize, 0), f.generations);
    try testing.expectEqual(@as(usize, 0), f.saved_generations);
    try f.expectFileUnchanged(region_path, region);
}

test "canonical persistence deleted sidecars and legacy derived files repair from unchanged saved regions" {
    try expectReadRepair(false);
}

test "canonical persistence corrupt summaries repair from saved blocks without regeneration" {
    try expectReadRepair(true);
}

test "canonical persistence corrupt block payload is a strict error and never overwrites region or sidecar" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.seedWorld();
    try f.prepare(ground_cx);
    f.runQueued();
    const sidecar = try f.readFile(ground_sidecar);
    defer a.free(sidecar);
    const original = try f.readFile(region_path);
    defer a.free(original);
    try f.restartHierarchy();
    const epoch = f.sm.sourceEpoch();
    {
        f.sm.region_cache_mutex.lock();
        defer f.sm.region_cache_mutex.unlock();
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const path = try f.sm.save_dir.realpath(region_path, &path_buf);
        var region = try persistence.RegionFile.open(a, path);
        defer region.close();
        const payload = try region.readChunk(@intCast(@mod(ground_cx, 32)), @intCast(@mod(saved_cz, 32)), a);
        defer a.free(payload);
        // Recompress a bad serializer CRC so the failure is block corruption, not absence.
        payload[persistence.chunk_serializer.HEADER_SIZE] ^= 1;
        try region.writeChunk(@intCast(@mod(ground_cx, 32)), @intCast(@mod(saved_cz, 32)), payload);
    }
    const corrupted = try f.readFile(region_path);
    defer a.free(corrupted);
    try testing.expect(!std.mem.eql(u8, original, corrupted));
    const scratch = try a.create(core.Chunk);
    defer a.destroy(scratch);
    scratch.* = core.Chunk.init(90, 91);
    scratch.setBlock(1, 2, 3, .gold_ore);
    const before = try a.create(core.Chunk);
    defer a.destroy(before);
    before.* = scratch.*;
    try testing.expectEqual(persistence.LoadResult.corrupt_data, f.sm.readSavedChunk(ground_cx, saved_cz, scratch));
    try testing.expectEqualDeep(before.*, scratch.*);
    for (sizes) |size| try testing.expectError(error.SavedSourceCorrupt, f.buildSceneGrid(ground_cx, size));
    f.runQueued();
    try testing.expectEqual(@as(usize, 0), f.hierarchy.?.countKnown());
    try testing.expectEqual(@as(usize, 0), f.generations);
    try testing.expectEqual(@as(usize, 0), f.saved_generations);
    try testing.expectEqual(epoch, f.sm.sourceEpoch());
    try f.flush();
    try f.expectFileUnchanged(region_path, corrupted);
    try f.expectFileUnchanged(ground_sidecar, sidecar);
}

test "canonical persistence saved edit epoch refreshes nonlive sources without mutating old grids" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.seedWorld();
    var old = try f.buildSceneGrid(ground_cx, 8);
    defer old.deinit();
    const lease = try f.acquire(ground_cx);
    defer lease.release();
    try testing.expectEqual(scene.Origin.saved, lease.summary.origin);
    const old_fingerprint = lease.summary.fingerprint();
    const old_epoch = f.hierarchy.?.epoch();
    const saved_epoch = f.sm.sourceEpoch();
    const loads = f.saved_loads;
    f.runQueued();
    const edited = try a.create(core.Chunk);
    defer a.destroy(edited);
    edited.* = core.Chunk.init(ground_cx, saved_cz);
    try testing.expectEqual(persistence.LoadResult.success, f.sm.readSavedChunk(ground_cx, saved_cz, edited));
    edited.pin();
    defer edited.unpin();
    for (0..16) |z| for (0..16) |x| for (32..34) |y| {
        edited.setBlock(@intCast(x), @intCast(y), @intCast(z), .gold_ore);
    };
    try testing.expect(f.sm.tryEnqueueSave(edited));
    try f.flush();
    try testing.expectEqual(saved_epoch + 1, f.sm.sourceEpoch());
    try testing.expectEqual(old_epoch, f.hierarchy.?.epoch());
    const region = try f.readFile(region_path);
    defer a.free(region);
    var fresh = try f.buildSceneGrid(ground_cx, 8);
    defer fresh.deinit();
    try testing.expect(fresh.source_epoch > old.source_epoch);
    try testing.expectEqual(loads + 1, f.saved_loads);
    try expectLayeredGrid(&old, .cobblestone);
    try expectLayeredGrid(&fresh, .gold_ore);
    try testing.expectEqual(old_fingerprint, lease.summary.fingerprint());
    const current = try f.acquire(ground_cx);
    defer current.release();
    try testing.expectEqual(scene.Origin.saved, current.summary.origin);
    try testing.expect(current.summary.fingerprint() != old_fingerprint);
    f.runQueued();
    var repaired = (try store.read(a, f.sm.save_dir_path, identity, ground_cx, saved_cz)).?;
    defer repaired.deinit();
    try testing.expectEqual(current.summary.fingerprint(), repaired.fingerprint());
    try testing.expectEqual(@as(usize, 0), f.saved_generations);
    try f.expectFileUnchanged(region_path, region);
}

test "canonical persistence committed callback captures the immutable accepted snapshot" {
    const Observer = struct {
        fixture: *Fixture,
        calls: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        fingerprint: std.atomic.Value(u64) = .init(0),
        epoch: std.atomic.Value(u64) = .init(0),

        fn order(ptr: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.fixture.hierarchy.?.reserveRevision();
        }

        fn committed(ptr: *anyopaque, chunk: *const core.Chunk) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.capture(chunk) catch self.failed.store(true, .release);
            _ = self.calls.fetchAdd(1, .release);
        }

        fn capture(self: *@This(), chunk: *const core.Chunk) !void {
            const source = self.fixture.hierarchy.?;
            var summary = try scene.ChunkSummary.capture(a, chunk);
            errdefer summary.deinit();
            self.fingerprint.store(summary.fingerprint(), .release);
            self.epoch.store(self.fixture.sm.sourceEpoch(), .release);
            const scratch = try a.create(core.Chunk);
            defer a.destroy(scratch);
            scratch.* = core.Chunk.init(chunk.chunk_x, chunk.chunk_z);
            try testing.expectEqual(persistence.LoadResult.success, self.fixture.sm.readSavedChunk(chunk.chunk_x, chunk.chunk_z, scratch));
            try testing.expectEqualSlices(core.BlockType, &chunk.blocks, &scratch.blocks);
            try testing.expectEqualSlices(core.PackedLight, &chunk.light, &scratch.light);
            summary.origin = .saved;
            summary.revision = chunk.canonical_save_order;
            source.commitSaved(summary);
        }
    };
    const f = try Fixture.init();
    var observer: Observer = .{ .fixture = f };
    defer f.deinit();
    f.sm.setSnapshotOrderProvider(&observer, Observer.order);
    f.sm.setSavedCallback(&observer, Observer.committed);
    const chunk = try layeredChunk();
    defer a.destroy(chunk);
    chunk.pin();
    defer chunk.unpin();
    var expected = try scene.ChunkSummary.capture(a, chunk);
    defer expected.deinit();
    try testing.expect(f.sm.tryEnqueueSave(chunk));
    // Mutation after admission must not change either the disk or callback snapshot.
    chunk.setBlock(0, 32, 0, .gold_ore);
    try f.flush();
    try testing.expect(!observer.failed.load(.acquire));
    try testing.expectEqual(@as(usize, 1), observer.calls.load(.acquire));
    try testing.expectEqual(@as(u64, 0), observer.epoch.load(.acquire));
    try testing.expectEqual(@as(u64, 1), f.sm.sourceEpoch());
    try testing.expectEqual(expected.fingerprint(), observer.fingerprint.load(.acquire));
    // Acquire before prepare: a later read repair must not hide a missing commit hook.
    const committed = try f.acquire(ground_cx);
    defer committed.release();
    try testing.expectEqual(scene.Origin.saved, committed.summary.origin);
    try testing.expectEqual(expected.fingerprint(), committed.summary.fingerprint());
    try testing.expectEqual(@as(usize, 0), f.loads);
    var sidecar = (try store.read(a, f.sm.save_dir_path, identity, ground_cx, saved_cz)).?;
    defer sidecar.deinit();
    try testing.expectEqual(expected.fingerprint(), sidecar.fingerprint());
    const region = try f.readFile(region_path);
    defer a.free(region);
    var grid = try f.buildSceneGrid(ground_cx, 1);
    defer grid.deinit();
    try expectLayeredGrid(&grid, .cobblestone);
    try testing.expectEqual(@as(usize, 0), f.generations);
    try testing.expectEqual(@as(usize, 0), f.saved_generations);
    try f.expectFileUnchanged(region_path, region);
}
