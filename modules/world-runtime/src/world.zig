//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const ChunkKey = world_core.ChunkKey;
const worldToChunk = world_core.worldToChunk;
const worldToLocal = world_core.worldToLocal;
const world_meshing = @import("world-meshing");
const NeighborChunks = world_meshing.NeighborChunks;
const ChunkStorage = world_meshing.ChunkStorage;
const ChunkData = world_meshing.ChunkData;
const gen_interface = @import("world-worldgen");
const Generator = gen_interface.Generator;
const WorldMap = gen_interface.WorldMap;
const registry = @import("world-worldgen").registry;
const rhi_mod = @import("engine-rhi").rhi;
const RHI = rhi_mod.RHI;
const WorldLOD = @import("world-lod").WorldLOD(RHI);
const LODGenerator = @import("world-lod").LODGenerator;

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}
const LODManager = @import("world-lod").LODManager;
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const IShadowScene = @import("engine-rhi").IShadowScene;
const ShadowConfig = @import("engine-rhi").ShadowConfig;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const MAX_MDI_CHUNKS = @import("world_renderer.zig").MAX_MDI_CHUNKS;
const RenderStats = @import("world_renderer.zig").RenderStats;
const RenderLayer = @import("world_renderer.zig").RenderLayer;
const ShadowStats = @import("world_renderer.zig").ShadowStats;
const ChunkStateCounts = world_core.ChunkStateCounts;
const VoxelCollisionWorld = @import("engine-physics").VoxelCollisionWorld;
const GraphicsWorldRenderView = @import("engine-rhi").IWorldRenderView;
const ILPVWorld = @import("engine-rhi").ILPVWorld;
const block_registry = @import("world-core").block_registry;
const LpvGridBuilder = @import("lpv_grid_builder.zig").LpvGridBuilder;

pub const DebugLightInfo = struct {
    sky: u4,
    block: u4,
};
const WorldStateData = world_core.WorldStateData;
pub const GpuMeshDispatch = struct {
    dispatch_fn: ?*const fn (ctx: *anyopaque) void,
    dispatch_ctx: ?*anyopaque,
};

pub const WorldOrchestration = struct {
    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(renderer: anytype, streamer: anytype, world: anytype, player_pos: Vec3, dt: f32) !void {
        renderer.beginFrame();
        try streamer.updateFrame(player_pos, dt);
        world.checkAutoSave();
    }

    /// Renders all enabled world layers for the current camera.
    /// LOD rendering is controlled by `render_lod` and the world configuration; call after `update` has advanced queues.
    pub fn render(renderer: anytype, streamer: anytype, lod_manager: anytype, lod_enabled: bool, view_proj: Mat4, camera_pos: Vec3, render_lod: bool, layer: anytype) void {
        const allow_lod = lod_enabled and render_lod;
        renderer.render(view_proj, camera_pos, streamer.getActiveRenderDistance(), lod_manager, allow_lod, layer);
    }
};
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const WorkerPool = engine_core.WorkerPool;
const Job = engine_core.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const log = engine_core.log;
const runtime_env = engine_core.runtime_env;

const LODConfig = @import("world-lod").lod_chunk.LODConfig;
const ILODConfig = @import("world-lod").lod_chunk.ILODConfig;
const LODLevel = @import("world-lod").LODLevel;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const SaveManager = @import("world-persistence").SaveManager;
const LoadResult = @import("world-persistence").LoadResult;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;

fn lodGeneratorFromGenerator(world: *World) LODGenerator {
    const generator = world.generator;
    return .{
        .ptr = generator.ptr,
        .generate_heightmap_only = generator.vtable.generateHeightmapOnly,
        .maybe_recenter_cache = generator.vtable.maybeRecenterCache,
        .seed = generator.getSeed(),
        .identity_hash = std.hash.Wyhash.hash(0, generator.info.name),
        .version = generator.info.version,
        .summary_context = world,
        .load_chunk_summary = loadCanonicalSummary,
        .generate_chunk_summary = generateCanonicalSummary,
        .saved_source_epoch = canonicalSavedEpoch,
    };
}

fn loadCanonicalSummary(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator) !?world_core.lod_scene.ChunkSummary {
    const world: *World = @ptrCast(@alignCast(ptr));
    const sm = world.save_manager orelse return null;
    const scratch = try allocator.create(Chunk);
    defer allocator.destroy(scratch);
    scratch.* = Chunk.init(cx, cz);
    switch (sm.readSavedChunk(cx, cz, scratch)) {
        .not_found => return null,
        .read_error => return error.SavedSourceReadFailed,
        .corrupt_data => return error.SavedSourceCorrupt,
        .success => {},
        .success_relight_required => {
            // Strict reads retain stale light bytes. Rebuild only this worker's
            // saved scratch, using generation's chunk-local lighting passes;
            // never reconcile against mutable resident chunks or regenerate blocks.
            try gen_interface.LightingComputer.computeSkylight(scratch, allocator);
            try gen_interface.LightingComputer.computeBlockLight(scratch, allocator);
            scratch.lighting_valid = true;
        },
    }
    var summary = try world_core.lod_scene.ChunkSummary.capture(allocator, scratch);
    summary.origin = .saved;
    return summary;
}

fn generateCanonicalSummary(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator, cancel: ?*const std.atomic.Value(bool)) !world_core.lod_scene.ChunkSummary {
    const world: *World = @ptrCast(@alignCast(ptr));
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
    const scratch = try allocator.create(Chunk);
    defer allocator.destroy(scratch);
    scratch.* = Chunk.init(cx, cz);
    // Generator's legacy bool pointer is not atomic. Check at one-chunk
    // boundaries rather than aliasing atomic storage through that API.
    try world.generator.generate(scratch, null);
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
    if (!scratch.generated) return error.IncompleteGeneration;
    var summary = try world_core.lod_scene.ChunkSummary.capture(allocator, scratch);
    summary.origin = .generated;
    return summary;
}

fn canonicalSavedEpoch(ptr: *anyopaque) u64 {
    const world: *World = @ptrCast(@alignCast(ptr));
    return if (world.save_manager) |sm| sm.sourceEpoch() else 0;
}

fn canonicalSnapshotOrder(ptr: *anyopaque) u64 {
    const source: *LODManager.SourceHierarchy = @ptrCast(@alignCast(ptr));
    return source.reserveRevision();
}

fn canonicalChunkCommitted(ptr: *anyopaque, chunk: *const Chunk) void {
    const world: *World = @ptrCast(@alignCast(ptr));
    const source = if (world.lod) |lod| lod.manager.source_hierarchy else null;
    // Publish the durable ordering fence even when allocating a summary fails.
    if (source) |hierarchy| hierarchy.noteCommitted(.{ .cx = chunk.chunk_x, .cz = chunk.chunk_z }, chunk.canonical_save_order, null);
    // Save callbacks run after region/queue locks are released. Geometry
    // lineage can become saved even when newer derived lighting is dirty.
    world.storage.lighting_mutex.lock();
    world.storage.chunks_mutex.lockShared();
    if (world.storage.chunks.get(.{ .x = chunk.chunk_x, .z = chunk.chunk_z })) |data| {
        switch (data.chunk.state) {
            .missing, .queued_for_generation, .generating => {},
            else => if (data.chunk.source_kind == .edited and
                data.chunk.content_revision.load(.acquire) == chunk.content_revision.load(.acquire))
            {
                data.chunk.source_kind = .saved;
            },
        }
    }
    world.storage.chunks_mutex.unlockShared();
    world.storage.lighting_mutex.unlock();

    const lod = world.lod orelse return;
    const manager = lod.manager;
    const hierarchy = source orelse return;
    // SaveManager lends the same immutable snapshot that just committed.
    var summary = LODManager.SceneSummary.capture(manager.allocator, chunk) catch |err| {
        log.log.warn("Canonical committed capture failed ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
        return;
    };
    summary.origin = .saved;
    summary.revision = chunk.canonical_save_order;
    hierarchy.commitSaved(summary);
}

test "canonical save callback preserves newer edits and independent lighting revisions" {
    const testing = std.testing;
    var world: World = undefined;
    world.storage = ChunkStorage.init(testing.allocator);
    defer world.storage.deinitWithoutRHI();
    world.lod = null;
    const resident = try world.storage.getOrCreate(0, 0);
    resident.chunk.generated = true;
    resident.chunk.state = .renderable;
    resident.chunk.source_kind = .saved;
    var mutation = WorldMutationCoordinator.init(&world.storage, testing.allocator, null, false);
    _ = try mutation.applyBlockMutation(0, 0, 0, .stone);
    const old = resident.chunk;
    _ = try mutation.applyBlockMutation(1, 0, 0, .gold_ore);
    canonicalChunkCommitted(&world, &old);
    try testing.expectEqual(Chunk.SourceKind.edited, resident.chunk.source_kind);
    try testing.expect(resident.chunk.modified);

    const current = resident.chunk;
    resident.chunk.markLightChanged();
    canonicalChunkCommitted(&world, &current);
    try testing.expectEqual(Chunk.SourceKind.saved, resident.chunk.source_kind);
    try testing.expectEqual(@as(u64, 1), resident.chunk.light_revision.load(.acquire));
    try testing.expectEqual(current.content_revision.load(.acquire), resident.chunk.content_revision.load(.acquire));
    try testing.expect(resident.chunk.modified);
    try testing.expectEqual(BlockType.gold_ore, resident.chunk.getBlock(1, 0, 0));
}

const CanonicalOrderFixture = struct {
    const a = std.testing.allocator;
    tmp: std.testing.TmpDir,
    world: World = undefined,
    lod: WorldLOD = undefined,
    streamer: WorldStreamer = undefined,
    manager: LODManager = undefined,
    queue: JobQueue,
    sm: *SaveManager,
    chunk: *Chunk = undefined,

    fn init() !*@This() {
        const self = try a.create(@This());
        errdefer a.destroy(self);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const fs = @import("fs");
        const dir = fs.Dir{ .inner = tmp.dir };
        var path: [fs.max_path_bytes]u8 = undefined;
        const sm = try SaveManager.init(a, try dir.realpath(".", &path), "snapshot-order", 0, "test");
        errdefer sm.deinit();
        self.* = .{ .tmp = tmp, .queue = JobQueue.init(a), .sm = sm };
        errdefer self.queue.deinit();
        self.world.storage = ChunkStorage.init(a);
        errdefer self.world.storage.deinitWithoutRHI();
        self.world.save_manager = sm;
        self.world.lod = &self.lod;
        self.manager = try LODManager.initCacheTestManager(a, "");
        errdefer self.manager.cache_io.deinit();
        self.manager.source_hierarchy = try LODManager.SourceHierarchy.init(a, .{
            .ptr = &self.world,
            .generate_heightmap_only = undefined,
            .maybe_recenter_cache = undefined,
            .seed = 0,
            .identity_hash = 0,
            .version = 1,
            .load_chunk_summary = loadCanonicalSummary,
            .saved_source_epoch = canonicalSavedEpoch,
        }, &self.queue, 16 * 1024 * 1024);
        errdefer self.manager.source_hierarchy.?.deinit();
        self.lod.manager = &self.manager;
        self.streamer.storage = &self.world.storage;
        self.streamer.lod_coordinator = .init(16);
        self.streamer.setLODManager(&self.manager);
        self.chunk = &(try self.world.storage.getOrCreate(0, 0)).chunk;
        self.chunk.generated = true;
        self.chunk.state = .renderable;
        self.chunk.lighting_valid = true;
        sm.setSnapshotOrderProvider(self.manager.source_hierarchy.?, canonicalSnapshotOrder);
        sm.setSavedCallback(&self.world, canonicalChunkCommitted);
        return self;
    }

    fn deinit(self: *@This()) void {
        self.sm.deinit();
        self.queue.stop();
        self.manager.source_hierarchy.?.deinit();
        self.manager.ingestion_queue.deinit(a);
        self.manager.cache_io.deinit();
        self.queue.deinit();
        self.world.storage.deinitWithoutRHI();
        self.tmp.cleanup();
        a.destroy(self);
    }

    fn edit(self: *@This(), block: BlockType) !void {
        var mutation = WorldMutationCoordinator.init(&self.world.storage, a, null, false);
        _ = try mutation.applyBlockMutation(0, 0, 0, block);
    }

    fn enqueue(self: *@This()) !void {
        self.world.storage.lighting_mutex.lock();
        defer self.world.storage.lighting_mutex.unlock();
        self.chunk.pin();
        defer self.chunk.unpin();
        try std.testing.expect(self.sm.tryEnqueueSave(self.chunk));
    }

    fn flush(self: *@This()) !void {
        const failed = self.sm.flush();
        defer a.free(failed);
        try std.testing.expectEqual(@as(usize, 0), failed.len);
        try std.testing.expectEqual(@as(usize, 0), self.sm.pending_saves.load(.acquire));
    }

    fn prepare(self: *@This()) !void {
        const provider = self.manager.source_hierarchy.?.provider();
        try provider.prepare_fn(provider.ptr, 0, 0, 0, 0, true, null);
    }

    fn acquire(self: *@This()) ?LODManager.SourceHierarchy.Lease {
        const provider = self.manager.source_hierarchy.?.provider();
        provider.lock_fn(provider.ptr);
        defer provider.unlock_fn(provider.ptr);
        return provider.acquire_fn(provider.ptr, 0, 0);
    }
};

test "canonical saved relight repairs missing stale and legacy lights before cache persistence" {
    const testing = std.testing;
    const a = testing.allocator;
    const persistence = @import("world-persistence");
    const fs = @import("fs");
    const identity: persistence.summary_store.Identity = .{ .seed = 0, .generator_hash = 0, .generator_version = 1 };
    for ([_]enum { missing, stale, legacy }{ .missing, .stale, .legacy }) |mode| {
        const f = try CanonicalOrderFixture.init();
        defer f.deinit();
        // A roof, an elevated saved emitter and a floating block with air gaps.
        // Leave the heightmap at zero: relighting must inspect actual saved blocks.
        for (0..CHUNK_SIZE_Z) |z| for (0..CHUNK_SIZE_X) |x| {
            f.chunk.setBlock(@intCast(x), 120, @intCast(z), .stone);
        };
        f.chunk.setBlock(8, 100, 8, .glowstone);
        f.chunk.setBlock(8, 64, 8, .gold_ore);
        f.chunk.setBiome(8, 8, .desert);
        if (mode != .missing) @memset(&f.chunk.light, world_core.PackedLight.initRGB(3, 15, 15, 15));
        f.chunk.lighting_valid = mode == .legacy;
        const bytes = try persistence.chunk_serializer.serializeChunk(f.chunk, a);
        defer a.free(bytes);
        if (mode == .legacy) bytes[4] = 2;
        const path = try fs.path.join(a, &.{ f.sm.save_dir_path, "regions/r.0.0.mca" });
        defer a.free(path);
        var region = try persistence.RegionFile.create(a, path);
        defer region.close();
        try region.writeChunk(0, 0, bytes);

        const scratch = try a.create(Chunk);
        defer a.destroy(scratch);
        scratch.* = Chunk.init(0, 0);
        try testing.expectEqual(LoadResult.success_relight_required, f.sm.readSavedChunk(0, 0, scratch));
        var stale = try world_core.lod_scene.ChunkSummary.capture(a, scratch);
        defer stale.deinit();
        stale.origin = .saved;
        try persistence.summary_store.write(a, f.sm.save_dir_path, identity, &stale);
        const epoch = f.sm.sourceEpoch();

        // Both cold repair and a fresh hierarchy over its persisted sidecar must
        // use the strict saved callback, not trust lighting-free fingerprints.
        for (0..2) |_| {
            const source = try LODManager.SourceHierarchy.init(a, f.manager.source_hierarchy.?.generator, &f.queue, 16 * 1024 * 1024);
            defer source.deinit();
            defer while (f.queue.tryPop()) |job| job.data.generic.process_fn(job.data.generic.context);
            try source.setPersistence(f.sm.save_dir_path);
            const provider = source.provider();
            try provider.prepare_fn(provider.ptr, 0, 0, 0, 0, true, null);
            provider.lock_fn(provider.ptr);
            const lease = provider.acquire_fn(provider.ptr, 0, 0).?;
            provider.unlock_fn(provider.ptr);
            defer lease.release();
            try testing.expectEqual(world_core.lod_scene.Origin.saved, lease.summary.origin);
            try testing.expectEqual(stale.fingerprint(), lease.summary.fingerprint());
            const roof = lease.summary.column(0, 0)[0];
            try testing.expectEqualDeep(world_core.PackedLight.init(15, 0), roof.light_top);
            try testing.expectEqualDeep(world_core.PackedLight.init(0, 0), roof.light_bottom);
            const emitter = lease.summary.column(8, 8)[1];
            const rgb = block_registry.getBlockDefinition(.glowstone).light_emission;
            const emitted = world_core.PackedLight.initRGB(0, rgb[0] - 1, rgb[1] - 1, rgb[2] - 1);
            try testing.expectEqualDeep(emitted, emitter.light_top);
            try testing.expectEqualDeep(emitted, emitter.light_bottom);
            try testing.expectEqualDeep(world_core.PackedLight.init(0, 0), lease.summary.column(8, 8)[0].light_top);

            try testing.expect(f.queue.count() > 0);
            while (f.queue.tryPop()) |job| job.data.generic.process_fn(job.data.generic.context);
            var cached = (try persistence.summary_store.read(a, f.sm.save_dir_path, identity, 0, 0)).?;
            defer cached.deinit();
            try testing.expectEqual(world_core.lod_scene.Origin.saved, cached.origin);
            try testing.expectEqualDeep(lease.summary.columns, cached.columns);
            try testing.expectEqualDeep(lease.summary.runs, cached.runs);
        }
        const after = try region.readChunk(0, 0, a);
        defer a.free(after);
        try testing.expectEqualSlices(u8, bytes, after);
        try testing.expectEqual(epoch, f.sm.sourceEpoch());
        try testing.expectEqual(@as(usize, 0), f.sm.pending_saves.load(.acquire));
        try testing.expectEqual(LoadResult.success_relight_required, f.sm.readSavedChunk(0, 0, scratch));
        try testing.expectEqualSlices(BlockType, &f.chunk.blocks, &scratch.blocks);
        try testing.expectEqualDeep(f.chunk.light, scratch.light);
    }
}

test "canonical saved relight preserves current lighting including omitted zero light payloads" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |has_light| {
        const f = try CanonicalOrderFixture.init();
        defer f.deinit();
        f.sm.setSavedCallback(null, null);
        f.chunk.setBlock(8, 64, 8, .stone);
        if (has_light) f.chunk.setLight(8, 65, 8, world_core.PackedLight.initRGB(2, 3, 4, 5));
        f.chunk.lighting_valid = true;
        var expected = try world_core.lod_scene.ChunkSummary.capture(testing.allocator, f.chunk);
        defer expected.deinit();
        try f.enqueue();
        try f.flush();
        // Resident edits must not replace strict disk authority or get relit.
        f.chunk.setBlock(8, 64, 8, .glowstone);
        f.chunk.setLight(8, 65, 8, world_core.PackedLight.init(15, 15));
        var summary = (try loadCanonicalSummary(&f.world, 0, 0, testing.allocator)).?;
        defer summary.deinit();
        try testing.expectEqual(world_core.lod_scene.Origin.saved, summary.origin);
        try testing.expectEqualDeep(expected.columns, summary.columns);
        try testing.expectEqualDeep(expected.runs, summary.runs);
        try testing.expectEqual(BlockType.glowstone, f.chunk.getBlock(8, 64, 8));
        try testing.expectEqualDeep(world_core.PackedLight.init(15, 15), f.chunk.getLight(8, 65, 8));
    }
}

test "canonical saved relight propagates allocation failures without publishing partial lighting" {
    const testing = std.testing;
    const f = try CanonicalOrderFixture.init();
    defer f.deinit();
    f.sm.setSavedCallback(null, null);
    @memset(&f.chunk.blocks, .stone);
    for (0..CHUNK_SIZE_Z) |z| for (0..CHUNK_SIZE_X) |x| {
        f.chunk.setBlock(@intCast(x), 255, @intCast(z), .air);
    };
    f.chunk.setBlock(8, 254, 8, .glowstone);
    @memset(&f.chunk.light, world_core.PackedLight.init(1, 15));
    f.chunk.lighting_valid = false;
    try f.enqueue();
    try f.flush();
    const epoch = f.sm.sourceEpoch();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, world: *World) !void {
            var summary = (try loadCanonicalSummary(world, 0, 0, allocator)).?;
            defer summary.deinit();
            try testing.expectEqual(world_core.lod_scene.Origin.saved, summary.origin);
            try testing.expectEqual(@as(u4, 15), summary.column(8, 8)[1].light_top.getSkyLight());
            const emission = block_registry.getBlockDefinition(.glowstone).light_emission;
            try testing.expectEqual(emission[0] - 1, summary.column(8, 8)[1].light_top.getBlockLightR());
        }
    }.run, .{&f.world});
    try testing.expectEqual(epoch, f.sm.sourceEpoch());
    try testing.expectEqual(@as(usize, 0), f.sm.pending_saves.load(.acquire));
    try testing.expect(f.acquire() == null);
}

test "canonical snapshot ordering commits uncaptured B and rejects old callbacks against live C" {
    const testing = std.testing;
    const f = try CanonicalOrderFixture.init();
    defer f.deinit();
    const source = f.manager.source_hierarchy.?;
    try f.edit(.stone);
    try testing.expect(f.manager.captureResolvedScene(0, 0));
    const a = f.acquire().?;
    defer a.release();
    try f.edit(.gold_ore);
    const order_b = source.next_revision.load(.acquire);
    try f.enqueue();
    // No B capture exists when its real SaveManager callback arrives.
    try f.flush();
    try testing.expectEqual(Chunk.SourceKind.saved, f.chunk.source_kind);
    const b = f.acquire().?;
    defer b.release();
    try testing.expectEqual(order_b, b.summary.revision);
    try testing.expectEqual(BlockType.gold_ore, b.summary.runs[0].block);
    try testing.expect(f.manager.captureResolvedScene(0, 0));
    try f.prepare();
    try testing.expectEqual(BlockType.stone, a.summary.runs[0].block);
    try testing.expectEqual(world_core.lod_scene.Origin.live, a.summary.origin);

    {
        // Hold disk I/O, not the source or mutation locks, to order the actual
        // writer callback after a newer unsaved capture without scheduler sleeps.
        f.sm.region_cache_mutex.lock();
        defer f.sm.region_cache_mutex.unlock();
        try f.enqueue();
        try f.edit(.dirt);
        try testing.expect(f.manager.captureResolvedScene(0, 0));
    }
    try f.flush();
    try f.prepare();
    const c = f.acquire().?;
    defer c.release();
    try testing.expectEqual(BlockType.dirt, c.summary.runs[0].block);
    try testing.expectEqual(world_core.lod_scene.Origin.live, c.summary.origin);
    try testing.expectEqual(Chunk.SourceKind.edited, f.chunk.source_kind);
    try testing.expectEqual(BlockType.gold_ore, b.summary.runs[0].block);
}

test "canonical snapshot ordering repairs callback capture and publication OOM before saved recapture" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |fail_capture| {
        const f = try CanonicalOrderFixture.init();
        defer f.deinit();
        const source = f.manager.source_hierarchy.?;
        try f.edit(.stone);
        try testing.expect(f.manager.captureResolvedScene(0, 0));
        const old = f.acquire().?;
        defer old.release();
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        {
            f.sm.region_cache_mutex.lock();
            defer f.sm.region_cache_mutex.unlock();
            try f.edit(.gold_ore);
            try f.enqueue();
            if (fail_capture) f.manager.allocator = failing.allocator() else source.allocator = failing.allocator();
        }
        try f.flush();
        f.manager.allocator = testing.allocator;
        source.allocator = testing.allocator;
        try testing.expectEqual(Chunk.SourceKind.saved, f.chunk.source_kind);
        try testing.expect(f.acquire() == null);
        // Exercise both repair paths, not just successful callback publication.
        if (fail_capture) {
            try testing.expect(f.manager.captureResolvedScene(0, 0));
            try f.prepare();
        } else {
            try f.prepare();
            try testing.expect(f.manager.captureResolvedScene(0, 0));
            try f.prepare();
        }
        const repaired = f.acquire().?;
        defer repaired.release();
        try testing.expectEqual(BlockType.gold_ore, repaired.summary.runs[0].block);
        try testing.expectEqual(world_core.lod_scene.Origin.saved, repaired.summary.origin);
        try testing.expectEqual(BlockType.stone, old.summary.runs[0].block);
    }
}

test "canonical snapshot ordering preserves newer light through callback epoch and repairs newer light commit OOM" {
    const testing = std.testing;
    const f = try CanonicalOrderFixture.init();
    defer f.deinit();
    const source = f.manager.source_hierarchy.?;
    const light_a = world_core.PackedLight.init(15, 0);
    const light_b = world_core.PackedLight.initRGB(2, 9, 7, 5);
    const light_c = world_core.PackedLight.initRGB(3, 1, 2, 3);
    try f.edit(.stone);
    f.chunk.setLight(0, 1, 0, light_a);
    try testing.expect(f.manager.captureResolvedScene(0, 0));
    const a = f.acquire().?;
    defer a.release();
    {
        f.sm.region_cache_mutex.lock();
        defer f.sm.region_cache_mutex.unlock();
        try f.enqueue();
        f.chunk.setLight(0, 1, 0, light_b);
        f.chunk.markLightChanged();
        try testing.expect(f.manager.captureResolvedScene(0, 0));
    }
    const b = f.acquire().?;
    defer b.release();
    try f.flush();
    const committed = f.acquire().?;
    defer committed.release();
    try testing.expectEqualDeep(light_b, committed.summary.runs[0].light_top);
    try testing.expectEqual(b.summary.revision, committed.summary.revision);
    try testing.expectEqual(world_core.lod_scene.Origin.saved, committed.summary.origin);
    // SaveManager has advanced its epoch after the callback. Strict disk
    // revalidation must not promote disk light A to a newer observation.
    try f.prepare();
    const revalidated = f.acquire().?;
    defer revalidated.release();
    try testing.expectEqualDeep(light_b, revalidated.summary.runs[0].light_top);
    try testing.expectEqual(b.summary.revision, revalidated.summary.revision);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    {
        f.sm.region_cache_mutex.lock();
        defer f.sm.region_cache_mutex.unlock();
        f.chunk.setLight(0, 1, 0, light_c);
        f.chunk.markLightChanged();
        try f.enqueue();
        source.allocator = failing.allocator();
    }
    try f.flush();
    source.allocator = testing.allocator;
    try testing.expect(f.acquire() == null);
    try f.prepare();
    const repaired = f.acquire().?;
    defer repaired.release();
    try testing.expectEqualDeep(light_c, repaired.summary.runs[0].light_top);
    try testing.expectEqualDeep(light_a, a.summary.runs[0].light_top);
    try testing.expectEqualDeep(light_b, b.summary.runs[0].light_top);
    try testing.expectEqualDeep(light_b, revalidated.summary.runs[0].light_top);
}

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

/// Named statistics struct for World (extracted from anonymous return type for interface use).
pub const WorldStatsData = struct {
    chunks_loaded: usize,
    total_vertices: u64,
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};

pub const IWorld = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void,
        render: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        renderOpaque: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        renderFluid: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        deinit: *const fn (ptr: *anyopaque) void,
        getRenderStats: *const fn (ptr: *anyopaque) RenderStats,
        getStats: *const fn (ptr: *anyopaque) WorldStatsData,
        getLODStats: *const fn (ptr: *anyopaque) ?@import("world-lod").LODStats,
        isLODEnabled: *const fn (ptr: *anyopaque) bool,
        shadowScene: *const fn (ptr: *anyopaque) IShadowScene,
        enableSaveManager: *const fn (ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void,
        takeSaveFailureWarningCount: *const fn (ptr: *anyopaque) usize,
        pauseGeneration: *const fn (ptr: *anyopaque) void,
        isPaused: *const fn (ptr: *anyopaque) bool,
        collisionWorld: *const fn (ptr: *anyopaque) VoxelCollisionWorld,
        getBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType,
        setBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void,
        getColumnInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo,
        getDebugLightInfo: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo,
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo,
        getGenerator: *const fn (ptr: *anyopaque) Generator,
        getGeneratorName: *const fn (ptr: *anyopaque) []const u8,
        getRenderDistance: *const fn (ptr: *anyopaque) i32,
        setRenderDistance: *const fn (ptr: *anyopaque, distance: i32) void,
        getHorizonDistance: *const fn (ptr: *anyopaque) i32,
        setHorizonDistance: *const fn (ptr: *anyopaque, distance: i32) void,
        isLODRenderingEnabled: *const fn (ptr: *anyopaque) bool,
        toggleLODRendering: *const fn (ptr: *anyopaque) bool,
        getChunkStateCounts: *const fn (ptr: *anyopaque) ChunkStateCounts,
        isStartupBusy: *const fn (ptr: *anyopaque) bool,
        getWorldStateData: *const fn (ptr: *anyopaque) WorldStateData,
        lpvWorld: *const fn (ptr: *anyopaque) ILPVWorld,
        graphicsRenderView: *const fn (ptr: *anyopaque) GraphicsWorldRenderView,
        getGpuMeshDispatch: *const fn (ptr: *anyopaque) GpuMeshDispatch,
        isGpuCullingEnabled: *const fn (ptr: *anyopaque) bool,
    };

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: IWorld, player_pos: Vec3, dt: f32) !void {
        try self.vtable.update(self.ptr, player_pos, dt);
    }

    /// Renders all enabled world layers for the current camera.
    /// LOD rendering is controlled by `render_lod` and the world configuration; call after `update` has advanced queues.
    pub fn render(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.render(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderOpaque(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderFluid(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// Stops world jobs and releases streaming, meshing, LOD, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: IWorld) void {
        self.vtable.deinit(self.ptr);
    }

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: IWorld) RenderStats {
        return self.vtable.getRenderStats(self.ptr);
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: IWorld) WorldStatsData {
        return self.vtable.getStats(self.ptr);
    }

    /// Returns distant-terrain LOD statistics when LOD is available.
    /// Returns `null` when the world has no active LOD manager.
    pub fn getLODStats(self: IWorld) ?@import("world-lod").LODStats {
        return self.vtable.getLODStats(self.ptr);
    }

    /// Reports whether the world was constructed with LOD support.
    /// This is a capability flag, separate from runtime LOD render toggles.
    pub fn isLODEnabled(self: IWorld) bool {
        return self.vtable.isLODEnabled(self.ptr);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: IWorld) IShadowScene {
        return self.vtable.shadowScene(self.ptr);
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: IWorld, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.vtable.enableSaveManager(self.ptr, save_dir_path, world_name);
    }

    /// Returns and clears the accumulated save-failure warning count.
    /// Use to surface persistence warnings without repeating already-consumed failures.
    pub fn takeSaveFailureWarningCount(self: IWorld) usize {
        return self.vtable.takeSaveFailureWarningCount(self.ptr);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: IWorld) void {
        self.vtable.pauseGeneration(self.ptr);
    }

    /// Reports whether chunk generation is currently paused.
    /// Rendering and loaded-chunk queries may still continue while paused.
    pub fn isPaused(self: IWorld) bool {
        return self.vtable.isPaused(self.ptr);
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: IWorld) VoxelCollisionWorld {
        return self.vtable.collisionWorld(self.ptr);
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.vtable.getBlock(self.ptr, world_x, world_y, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.vtable.setBlock(self.ptr, world_x, world_y, world_z, block);
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.vtable.getColumnInfo(self.ptr, world_x, world_z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: IWorld, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.vtable.getDebugLightInfo(self.ptr, world_x, world_y, world_z);
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.vtable.getRegionInfo(self.ptr, world_x, world_z);
    }

    /// Returns the active world generator interface.
    /// The generator is owned by the world runtime.
    pub fn getGenerator(self: IWorld) Generator {
        return self.vtable.getGenerator(self.ptr);
    }

    /// Returns the display name of the active world generator.
    /// The slice is owned by the generator metadata.
    pub fn getGeneratorName(self: IWorld) []const u8 {
        return self.vtable.getGeneratorName(self.ptr);
    }

    /// Returns the active chunk render distance in chunks.
    /// Used by streaming, renderer masks, and settings UI.
    pub fn getRenderDistance(self: IWorld) i32 {
        return self.vtable.getRenderDistance(self.ptr);
    }

    /// Changes the active chunk render distance.
    /// The streamer reconciles loaded chunks on subsequent updates.
    pub fn setRenderDistance(self: IWorld, distance: i32) void {
        self.vtable.setRenderDistance(self.ptr, distance);
    }

    /// Returns the distant-terrain horizon distance in chunks.
    /// Used by LOD scheduling and settings UI.
    pub fn getHorizonDistance(self: IWorld) i32 {
        return self.vtable.getHorizonDistance(self.ptr);
    }

    /// Changes the distant-terrain horizon distance.
    /// LOD queues and visibility update on subsequent world ticks.
    pub fn setHorizonDistance(self: IWorld, distance: i32) void {
        self.vtable.setHorizonDistance(self.ptr, distance);
    }

    /// Reports whether LOD drawing is currently enabled.
    /// This runtime toggle is separate from LOD subsystem availability.
    pub fn isLODRenderingEnabled(self: IWorld) bool {
        return self.vtable.isLODRenderingEnabled(self.ptr);
    }

    /// Toggles LOD drawing and returns the new enabled state.
    /// Does not destroy LOD data; it only changes render participation.
    pub fn toggleLODRendering(self: IWorld) bool {
        return self.vtable.toggleLODRendering(self.ptr);
    }

    /// Returns counts of chunks in each streaming/meshing state.
    /// Used for diagnostics and startup-busy checks.
    pub fn getChunkStateCounts(self: IWorld) ChunkStateCounts {
        return self.vtable.getChunkStateCounts(self.ptr);
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: IWorld) bool {
        return self.vtable.isStartupBusy(self.ptr);
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: IWorld) WorldStateData {
        return self.vtable.getWorldStateData(self.ptr);
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: IWorld) ILPVWorld {
        return self.vtable.lpvWorld(self.ptr);
    }

    /// Returns the graphics-facing world render view.
    /// Use for renderer systems that need chunk buffers without full world mutation access.
    pub fn graphicsRenderView(self: IWorld) GraphicsWorldRenderView {
        return self.vtable.graphicsRenderView(self.ptr);
    }

    /// Returns the optional GPU meshing dispatch hook.
    /// The hook is null when GPU meshing is unavailable.
    pub fn getGpuMeshDispatch(self: IWorld) GpuMeshDispatch {
        return self.vtable.getGpuMeshDispatch(self.ptr);
    }

    /// Returns true when chunk visibility is currently produced by GPU culling.
    pub fn isGpuCullingEnabled(self: IWorld) bool {
        return self.vtable.isGpuCullingEnabled(self.ptr);
    }

    /// Narrows the world facade to simulation and mutation operations.
    /// Use to avoid giving consumers render or telemetry access.
    pub fn simulation(self: IWorld) IWorldSimulation {
        return .{ .world = self };
    }

    /// Narrows the world facade to render-facing operations.
    /// Use by graphics systems that should not mutate simulation state.
    pub fn renderView(self: IWorld) IWorldRenderView {
        return .{ .world = self };
    }

    /// Narrows the world facade to diagnostics and settings operations.
    /// Use by UI/debug systems that only need world state snapshots.
    pub fn telemetry(self: IWorld) IWorldTelemetry {
        return .{ .world = self };
    }
};

pub const IWorldSimulation = struct {
    world: IWorld,

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: IWorldSimulation, player_pos: Vec3, dt: f32) !void {
        try self.world.update(player_pos, dt);
    }

    /// Stops world jobs and releases streaming, meshing, LOD, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: IWorldSimulation) void {
        self.world.deinit();
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: IWorldSimulation, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.world.enableSaveManager(save_dir_path, world_name);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: IWorldSimulation) void {
        self.world.pauseGeneration();
    }

    /// Reports whether chunk generation is currently paused.
    /// Rendering and loaded-chunk queries may still continue while paused.
    pub fn isPaused(self: IWorldSimulation) bool {
        return self.world.isPaused();
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: IWorldSimulation) VoxelCollisionWorld {
        return self.world.collisionWorld();
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.world.setBlock(world_x, world_y, world_z, block);
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: IWorldSimulation, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.world.getColumnInfo(world_x, world_z);
    }
};

pub const IWorldRenderView = struct {
    world: IWorld,

    /// Renders all enabled world layers for the current camera.
    /// LOD rendering is controlled by `render_lod` and the world configuration; call after `update` has advanced queues.
    pub fn render(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.render(view_proj, camera_pos, render_lod);
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderOpaque(view_proj, camera_pos, render_lod);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderFluid(view_proj, camera_pos, render_lod);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: IWorldRenderView) IShadowScene {
        return self.world.shadowScene();
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: IWorldRenderView) ILPVWorld {
        return self.world.lpvWorld();
    }

    /// Returns the graphics-facing world render view.
    /// Use for renderer systems that need chunk buffers without full world mutation access.
    pub fn graphicsRenderView(self: IWorldRenderView) GraphicsWorldRenderView {
        return self.world.graphicsRenderView();
    }

    /// Returns the optional GPU meshing dispatch hook.
    /// The hook is null when GPU meshing is unavailable.
    pub fn getGpuMeshDispatch(self: IWorldRenderView) GpuMeshDispatch {
        return self.world.getGpuMeshDispatch();
    }
};

pub const IWorldTelemetry = struct {
    world: IWorld,

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: IWorldTelemetry) RenderStats {
        return self.world.getRenderStats();
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: IWorldTelemetry) WorldStatsData {
        return self.world.getStats();
    }

    /// Returns distant-terrain LOD statistics when LOD is available.
    /// Returns `null` when the world has no active LOD manager.
    pub fn getLODStats(self: IWorldTelemetry) ?@import("world-lod").LODStats {
        return self.world.getLODStats();
    }

    /// Reports whether the world was constructed with LOD support.
    /// This is a capability flag, separate from runtime LOD render toggles.
    pub fn isLODEnabled(self: IWorldTelemetry) bool {
        return self.world.isLODEnabled();
    }

    /// Returns the active chunk render distance in chunks.
    /// Used by streaming, renderer masks, and settings UI.
    pub fn getRenderDistance(self: IWorldTelemetry) i32 {
        return self.world.getRenderDistance();
    }

    /// Changes the active chunk render distance.
    /// The streamer reconciles loaded chunks on subsequent updates.
    pub fn setRenderDistance(self: IWorldTelemetry, distance: i32) void {
        self.world.setRenderDistance(distance);
    }

    /// Returns the distant-terrain horizon distance in chunks.
    /// Used by LOD scheduling and settings UI.
    pub fn getHorizonDistance(self: IWorldTelemetry) i32 {
        return self.world.getHorizonDistance();
    }

    /// Changes the distant-terrain horizon distance.
    /// LOD queues and visibility update on subsequent world ticks.
    pub fn setHorizonDistance(self: IWorldTelemetry, distance: i32) void {
        self.world.setHorizonDistance(distance);
    }

    /// Reports whether LOD drawing is currently enabled.
    /// This runtime toggle is separate from LOD subsystem availability.
    pub fn isLODRenderingEnabled(self: IWorldTelemetry) bool {
        return self.world.isLODRenderingEnabled();
    }

    /// Toggles LOD drawing and returns the new enabled state.
    /// Does not destroy LOD data; it only changes render participation.
    pub fn toggleLODRendering(self: IWorldTelemetry) bool {
        return self.world.toggleLODRendering();
    }

    /// Returns counts of chunks in each streaming/meshing state.
    /// Used for diagnostics and startup-busy checks.
    pub fn getChunkStateCounts(self: IWorldTelemetry) ChunkStateCounts {
        return self.world.getChunkStateCounts();
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: IWorldTelemetry) bool {
        return self.world.isStartupBusy();
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: IWorldTelemetry) WorldStateData {
        return self.world.getWorldStateData();
    }

    /// Returns the display name of the active world generator.
    /// The slice is owned by the generator metadata.
    pub fn getGeneratorName(self: IWorldTelemetry) []const u8 {
        return self.world.getGeneratorName();
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.world.getDebugLightInfo(world_x, world_y, world_z);
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: IWorldTelemetry, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.world.getRegionInfo(world_x, world_z);
    }

    /// Returns the active world generator interface.
    /// The generator is owned by the world runtime.
    pub fn getGenerator(self: IWorldTelemetry) Generator {
        return self.world.getGenerator();
    }
};

pub const ChunkPos = struct { x: i32, z: i32 };

pub const World = struct {
    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        render_distance: i32,
        seed: u64,
        rhi: RHI,
        atlas: *const TextureAtlas,
        generator_index: usize = 0,
        lod_config: ?ILODConfig = null,
    };

    storage: ChunkStorage,
    streamer: *WorldStreamer,
    renderer: *WorldRenderer,
    allocator: std.mem.Allocator,
    generator: Generator,
    render_distance: i32,
    lod_chunk_render_radius_limit: i32,
    horizon_distance: i32,
    rhi: RHI,
    paused: bool = false,
    safe_mode: bool,
    safe_render_distance: i32,
    map_mutation_revision: std.atomic.Value(u64) = .init(0),

    // LOD System (Issue #114, #293)
    lod: ?*WorldLOD,
    lod_enabled: bool, // Runtime toggle for LOD rendering

    // Save system (Issue #380)
    save_manager: ?*SaveManager,

    // GPU Block Buffer (Batch 5 - Issue #389)
    gpu_block_buffer: ?*GpuBlockBuffer,

    // Mutation coordinator (Issue #550)
    mutation: WorldMutationCoordinator,

    // LPV lighting grid builder (Issue #789)
    lpv_grid_builder: LpvGridBuilder,

    /// Creates a world runtime with chunk storage, streaming, meshing, rendering, and optional LOD support.
    /// The allocator, generator, and RHI-backed resources must remain valid for the world lifetime. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn init(options: InitOptions) !*World {
        const allocator = options.allocator;
        const world = try allocator.create(World);
        errdefer allocator.destroy(world);

        const storage = ChunkStorage.init(allocator);
        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const safe_render_distance: i32 = @max(options.render_distance, 2);
        const streamer_render_distance: i32 = if (options.lod_config) |lod_config|
            effectiveChunkRenderRadius(safe_render_distance, lod_config.getChunkRenderRadius(), true)
        else
            effectiveChunkRenderRadius(safe_render_distance, safe_render_distance, false);
        const max_uploads: usize = if (strict_safe_mode)
            @as(usize, 4)
        else if (safe_mode)
            @as(usize, 8)
        else
            @as(usize, 32);
        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: limiting uploads to {} per frame", .{max_uploads});
        }

        world.* = .{
            .storage = storage,
            .streamer = undefined,
            .renderer = undefined,
            .allocator = allocator,
            .render_distance = safe_render_distance,
            .lod_chunk_render_radius_limit = streamer_render_distance,
            .horizon_distance = if (options.lod_config) |lod_config| lod_config.getRadii()[LODLevel.count - 1] else LODConfig.default_horizon_radius,
            .generator = try registry.createGenerator(options.generator_index, options.seed, allocator),
            .rhi = options.rhi,
            .paused = false,
            .safe_mode = safe_mode,
            .safe_render_distance = safe_render_distance,
            .map_mutation_revision = .init(0),
            .lod = null,
            .lod_enabled = false,
            .save_manager = null,
            .gpu_block_buffer = null,
            .mutation = undefined,
            .lpv_grid_builder = undefined,
        };
        errdefer world.generator.deinit(allocator);

        world.lpv_grid_builder = LpvGridBuilder.init(&world.storage);

        log.log.info("World.init: initializing WorldRenderer", .{});
        const culling_size = options.rhi.query().getRenderResolution();
        var culling_system = if (!safe_mode) blk: {
            break :blk options.rhi.cullingFactory().createCullingSystem(allocator, MAX_MDI_CHUNKS) catch |err| {
                log.log.warn("GPU culling init failed ({}), falling back to CPU culling", .{err});
                break :blk null;
            };
        } else null;
        errdefer if (culling_system) |system| system.deinit();

        world.renderer = try WorldRenderer.init(allocator, options.rhi.resourceManager(), options.rhi.renderContext(), options.rhi.query(), &world.storage, options.atlas, options.rhi, &culling_system, culling_size, safe_mode);
        errdefer world.renderer.deinit();

        world.gpu_block_buffer = world.renderer.getGpuBlockBuffer();

        world.mutation = WorldMutationCoordinator.init(
            &world.storage,
            allocator,
            world.gpu_block_buffer,
            world.renderer.getGpuMesher() != null,
        );

        log.log.info("World.init: initializing WorldStreamer (render_distance={}, requested={})", .{ streamer_render_distance, safe_render_distance });
        world.streamer = try WorldStreamer.init(allocator, &world.storage, world.generator, options.atlas, streamer_render_distance, options.lod_config != null, world.renderer.vertex_allocator, max_uploads, world.gpu_block_buffer, world.renderer.getGpuMesher());
        errdefer world.streamer.deinit();

        if (options.lod_config) |lod_config| {
            world.lod = try WorldLOD.init(allocator, options.rhi, lod_config, lodGeneratorFromGenerator(world), options.atlas);
            world.lod_enabled = true;
            world.streamer.setLODManager(world.lod.?.manager);
        }
        return world;
    }

    /// Stops world jobs and releases streaming, meshing, LOD, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: *World) void {
        self.pauseGeneration();
        // Workers borrow SaveManager, generator and storage. Join both pools
        // before flushing or destroying any of these owners.
        self.streamer.stopWorkersAndJoin();
        if (self.lod) |lod| lod.manager.stopWorkersAndJoin();

        self.rhi.query().waitIdle();

        if (self.save_manager) |sm| {
            self.saveAllModifiedChunks();
            sm.deinit();
            self.save_manager = null;
            self.streamer.setSaveManager(null);
        }

        self.streamer.deinit();

        // Storage must be deinitialized before renderer because it uses the renderer's vertex_allocator
        // to free mesh buffers.
        // On shutdown we can skip per-chunk GPU frees since the allocator is destroyed next.
        self.storage.deinitWithoutRHI();
        self.renderer.deinit();

        if (self.lod) |lod| {
            lod.deinit();
        }

        self.generator.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: *World) void {
        self.paused = true;
        self.streamer.setPaused(true);

        if (self.lod) |lod| {
            lod.pause();
        }
    }

    /// Resumes background chunk generation after a pause.
    /// Queued work may continue on subsequent `update` calls.
    pub fn resumeGeneration(self: *World) void {
        self.paused = false;
        self.streamer.setPaused(false);

        if (self.lod) |lod| {
            lod.unpause();
        }
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: *World, save_dir_path: []const u8, world_name: []const u8) !void {
        if (self.save_manager != null) return error.PersistenceAlreadyEnabled;
        const seed = self.generator.getSeed();
        const gen_name = self.generator.info.name;
        const sm = try SaveManager.init(self.allocator, save_dir_path, world_name, seed, gen_name);
        self.streamer.prepareStartupPersistence(sm, self.renderer.frame_serial) catch |err| {
            // No callbacks or worker borrows exist before this barrier.
            sm.deinit();
            return err;
        };
        self.save_manager = sm;
        sm.setSavedCallback(self, canonicalChunkCommitted);
        if (self.lod) |lod| if (lod.manager.source_hierarchy) |source| {
            sm.setSnapshotOrderProvider(source, canonicalSnapshotOrder);
        };
        self.streamer.setSaveManager(sm);
        if (self.lod) |lod| {
            // Once published, World retains sm even if cache setup fails.
            // Only World.deinit may destroy it, after joining every borrower.
            try lod.enableCache(save_dir_path);
        }
    }

    /// Returns and clears the accumulated save-failure warning count.
    /// Use to surface persistence warnings without repeating already-consumed failures.
    pub fn takeSaveFailureWarningCount(self: *World) usize {
        const sm = self.save_manager orelse return 0;
        return sm.takePersistedFailedSaveCount();
    }

    fn enqueueModifiedChunks(self: *World, sm: *SaveManager) std.ArrayListUnmanaged(ChunkKey) {
        var dirty_keys = std.ArrayListUnmanaged(ChunkKey).empty;

        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();
        self.storage.chunks_mutex.lock();
        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.modified and chunk.generated) {
                dirty_keys.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.log.err("Failed to track dirty chunk ({}, {}) for save: {}", .{ entry.key_ptr.*.x, entry.key_ptr.*.z, err });
                    continue;
                };

                chunk.pin();
                if (sm.tryEnqueueSave(chunk)) chunk.modified = false;
                chunk.unpin();
            }
        }
        self.storage.chunks_mutex.unlock();

        return dirty_keys;
    }

    fn remarkFailedSaves(self: *World, failed: []ChunkKey) void {
        self.storage.chunks_mutex.lock();
        for (failed) |key| {
            if (self.storage.chunks.get(key)) |data| {
                data.chunk.modified = true;
            }
        }
        self.storage.chunks_mutex.unlock();
    }

    /// Applies pending block edits to LOD source data and waits for the
    /// corresponding source-store writes. Full-detail save points call this
    /// while resident chunks are still available to the ingestion resolver.
    fn flushLODEditsForPersistence(self: *World) void {
        const lod = self.lod orelse return;
        lod.manager.flushEditedChunksNow();
        lod.manager.drainPendingIngestionsNow();
        lod.manager.flushDirtyStoresNow();
        // In-flight or currently missing target regions cannot accept the
        // authoritative edit yet. Remove their settled old payloads so reload
        // regenerates them instead of briefly displaying stale distant terrain.
        lod.manager.invalidatePendingEditedStoresNow();
    }

    /// Starts bounded LOD persistence work without waiting for cache storage.
    /// Autosave uses this path to avoid turning a slow source-store write into
    /// an unbounded frame stall; explicit saves still use the full barrier.
    fn queueLODEditsForPersistence(self: *World) void {
        const lod = self.lod orelse return;
        lod.manager.flushEditedChunksBounded();
        lod.manager.drainPendingIngestions();
        lod.manager.flushDirtyStores();
    }

    /// Synchronously saves chunks marked dirty by mutations or streaming.
    /// Returns errors from persistence and leaves unsaved chunks dirty for later retry.
    pub fn saveAllModifiedChunks(self: *World) void {
        const sm = self.save_manager orelse return;

        self.flushLODEditsForPersistence();

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        defer sm.allocator.free(failed);
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred while saving modified chunks", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// Runs autosave bookkeeping and persists dirty chunks when the save interval has elapsed.
    /// No work occurs when persistence is disabled.
    pub fn checkAutoSave(self: *World) void {
        const sm = self.save_manager orelse return;
        if (!sm.shouldAutoSave()) return;

        self.queueLODEditsForPersistence();

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        defer sm.allocator.free(failed);
        sm.markAutoSaved();
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred during auto-save", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// Attempts to load a chunk from persistent storage.
    /// Returns `null` when no saved data exists for the requested chunk.
    pub fn loadChunkFromSave(self: *World, cx: i32, cz: i32, out_chunk: *Chunk) LoadResult {
        const sm = self.save_manager orelse return .not_found;
        return sm.loadChunk(cx, cz, out_chunk);
    }

    /// Set render distance and trigger chunk loading/unloading update
    pub fn setRenderDistance(self: *World, distance: i32) void {
        const requested = @max(distance, 2);
        const target = if (self.safe_mode) @min(requested, self.safe_render_distance) else requested;

        if (self.render_distance != target) {
            if (self.safe_mode and target != requested) {
                log.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance {} -> {}", .{ distance, target });
            }
            log.log.info("Render distance changed: {} -> {}", .{ self.render_distance, target });
            self.render_distance = target;
            self.applyRenderDistance();
        }
    }

    /// Updates the full-detail streaming radius limit. Presets seed this value
    /// during startup; the live World setting then synchronizes it to the
    /// explicitly requested full-detail radius.
    pub fn setLODChunkRenderRadiusLimit(self: *World, limit: i32) void {
        const target = @max(limit, 1);
        if (self.lod_chunk_render_radius_limit == target) return;
        self.lod_chunk_render_radius_limit = target;
        self.applyRenderDistance();
    }

    fn applyRenderDistance(self: *World) void {
        const chunk_render_radius = effectiveChunkRenderRadius(self.render_distance, self.lod_chunk_render_radius_limit, self.lod != null);
        self.streamer.setRenderDistance(chunk_render_radius);

        if (self.lod) |lod| {
            const radii = effectiveLODRadii(self.render_distance, self.lod_chunk_render_radius_limit, self.horizon_distance);
            lod.setChunkRenderRadius(chunk_render_radius);
            lod.setRadii(radii);
        }
    }

    pub fn effectiveChunkRenderRadius(render_distance: i32, preset_limit: i32, lod_enabled: bool) i32 {
        const requested = @max(render_distance, 2);
        return if (lod_enabled) @max(@min(requested, preset_limit), 2) else requested;
    }

    /// Builds the live LOD ladder from the same capped near-detail radius used
    /// by chunk streaming. The requested horizon remains independent.
    pub fn effectiveLODRadii(render_distance: i32, preset_limit: i32, horizon_distance: i32) [LODLevel.count]i32 {
        const chunk_render_radius = effectiveChunkRenderRadius(render_distance, preset_limit, true);
        return LODConfig.radiiForDistances(chunk_render_radius, horizon_distance);
    }

    /// Changes the distant-terrain horizon distance.
    /// LOD queues and visibility update on subsequent world ticks.
    pub fn setHorizonDistance(self: *World, distance: i32) void {
        const target = LODConfig.normalizeHorizonDistance(self.render_distance, distance);
        if (self.horizon_distance == target) return;
        log.log.info("Horizon distance changed: {} -> {}", .{ self.horizon_distance, target });
        self.horizon_distance = target;
        if (self.lod) |lod| {
            const radii = effectiveLODRadii(self.render_distance, self.lod_chunk_render_radius_limit, target);
            lod.setRadii(radii);
        }
    }

    /// Installs the bounded benchmark-only LOD source set used to exercise the
    /// production compute/indirect culling path at high cardinality.
    pub fn installGpuCullingScaleFixture(self: *World) !void {
        const lod = self.lod orelse return error.LODDisabled;
        try lod.installGpuCullingScaleFixture();
    }

    /// Returns a resident chunk or creates storage for it.
    /// May allocate chunk data and enqueue follow-up generation or meshing work. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        return self.storage.getOrCreate(chunk_x, chunk_z);
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: *World, world_x: i32, world_y: i32, world_z: i32) BlockType {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: *World, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return null;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return null;
        const local = worldToLocal(world_x, world_z);
        const light = data.chunk.getLight(local.x, @intCast(world_y), local.z);
        return .{
            .sky = light.getSkyLight(),
            .block = light.getBlockLight(),
        };
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.generator.getColumnInfo(@floatFromInt(world_x), @floatFromInt(world_z));
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.generator.getRegionInfo(world_x, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        const result = (try self.mutation.applyBlockMutation(world_x, world_y, world_z, block)) orelse return;
        self.storage.markMapSurfaceChanged();
        _ = self.map_mutation_revision.fetchAdd(1, .release);
        self.streamer.enqueueMutationLighting(&self.mutation, result) catch |err| {
            log.log.warn("Failed to enqueue block lighting update, applying synchronously: {}", .{err});
            try self.mutation.updateLighting(result);
            self.streamer.requestDirtyRemesh(result.chunk_x, result.chunk_z);
        };
        // Notify the LOD system so distant terrain reflects player edits after
        // the player teleports away. Coalesced on a debounce inside LODManager.
        if (self.lod) |lod| {
            const wc = world_core.worldToChunk(world_x, world_z);
            lod.manager.markChunkEdited(wc.chunk_x, wc.chunk_z);
        }
    }

    pub fn getMapSurfaceRevision(self: *const World) u64 {
        return self.map_mutation_revision.load(.acquire);
    }

    pub fn getMapResidencyRevision(self: *const World) u64 {
        return self.storage.getMapSurfaceRevision();
    }

    /// Copies actual loaded top surfaces for a map viewport. The map worker
    /// receives only immutable values, never live chunk pointers.
    pub fn captureLoadedMapSurface(
        self: *World,
        overlay: *WorldMap.LoadedSurfaceOverlay,
        center_x: f32,
        center_z: f32,
        scale: f32,
        width: u32,
        height: u32,
    ) !void {
        const half_width = @as(f32, @floatFromInt(width)) * scale * 0.5;
        const half_height = @as(f32, @floatFromInt(height)) * scale * 0.5;
        const min_world_x: i32 = @intFromFloat(@floor(center_x - half_width));
        const max_world_x: i32 = @intFromFloat(@ceil(center_x + half_width));
        const min_world_z: i32 = @intFromFloat(@floor(center_z - half_height));
        const max_world_z: i32 = @intFromFloat(@ceil(center_z + half_height));
        const min_chunk = worldToChunk(min_world_x, min_world_z);
        const max_chunk = worldToChunk(max_world_x, max_world_z);

        try overlay.ensureUnusedCapacity(self.storage.count());

        // Match mutation/lighting lock order. Generated chunks are immutable
        // for this short copy except for mutations, which lighting_mutex blocks.
        self.storage.lighting_mutex.lock();
        self.storage.chunks_mutex.lockShared();

        var iterator = self.storage.iteratorUnsafe();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.x < min_chunk.chunk_x or key.x > max_chunk.chunk_x or key.z < min_chunk.chunk_z or key.z > max_chunk.chunk_z) continue;
            const chunk = &entry.value_ptr.*.chunk;
            // Generation rebuilds the cached surface before publishing the
            // chunk as generated. Skip chunks still owned by a worker so this
            // shared-lock copy never races that unlocked rebuild.
            if (!chunk.generated or chunk.state != .generated) continue;
            if (!chunk.mapSurfaceIsCurrent()) _ = chunk.rebuildMapSurface();
            overlay.appendAssumeCapacity(.{
                .chunk_x = key.x,
                .chunk_z = key.z,
                .heights = chunk.map_surface_heights,
                .blocks = chunk.map_surface_blocks,
            });
        }
        self.storage.chunks_mutex.unlockShared();
        self.storage.lighting_mutex.unlock();
        overlay.finish();
    }

    /// Get chunk data at chunk coordinates.
    /// WARNING: Returned pointer is only guaranteed valid if called from the main thread
    /// and used before the next call to World.update (which may unload chunks).
    /// If accessing from a background thread, the chunk must be pinned first.
    pub fn getChunk(self: *World, cx: i32, cz: i32) ?*ChunkData {
        return self.storage.get(cx, cz);
    }

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: *World, player_pos: Vec3, dt: f32) !void {
        // RHI frame begin has completed the current slot fence. Orchestration
        // increments WorldRenderer's serial inside update, before streaming.
        if (self.lod) |lod| lod.manager.gpu_bridge.beginFrame(self.renderer.frame_serial + 1);
        try WorldOrchestration.update(self.renderer, self.streamer, self, player_pos, dt);
    }

    /// Renders all enabled world layers for the current camera.
    /// LOD rendering is controlled by `render_lod` and the world configuration; call after `update` has advanced queues.
    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .all);
    }

    /// Render-graph prepass entry point: dispatch LOD compute before a graphics
    /// render pass becomes active. Normal rendering remains a CPU fallback.
    pub fn prepareLODCulling(self: *World, view_proj: Mat4, camera_pos: Vec3) void {
        if (self.lod) |lod| {
            const detail_render_radius = @min(self.streamer.getActiveRenderDistance(), lod.manager.config.getChunkRenderRadius());
            lod.manager.prepareFrame(self.renderer.frame_serial, view_proj, camera_pos, ChunkStorage.isChunkTerrainReadyForHandoff, @ptrCast(&self.storage), lod.manager.getHorizonRenderRadius(), detail_render_radius);
        }
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .terrain);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .fluid);
    }

    /// Renders world geometry into the active shadow pass.
    /// The shadow renderer provides receiver-volume-derived caster bounds.
    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
        _ = shadow_config; // Bounds already encode the configured caster reach.
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, caster_min, caster_max);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: *World) IShadowScene {
        return .{
            .ptr = self,
            .vtable = &.{
                .renderShadowPass = renderShadowPassWrapper,
            },
        };
    }

    fn renderShadowPassWrapper(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderShadowPass(light_space_matrix, camera_pos, caster_min, caster_max, shadow_config);
    }

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: *const World) RenderStats {
        return self.renderer.last_render_stats;
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: *World) VoxelCollisionWorld {
        return .{ .ptr = self, .vtable = &COLLISION_VTABLE };
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: *World) ILPVWorld {
        return self.lpv_grid_builder.interface();
    }

    /// Shadow stats reset in `beginFrame()` and accumulate across all shadow passes until the next frame.
    /// Call `resetShadowStats()` manually if you need per-cascade stats.
    pub fn getShadowStats(self: *const World) ShadowStats {
        return self.renderer.last_shadow_stats;
    }

    /// Clears accumulated shadow rendering counters.
    /// Use before measuring a fresh shadow pass or diagnostic interval.
    pub fn resetShadowStats(self: *World) void {
        self.renderer.resetShadowStats();
    }

    /// Counts chunks by state for the debug inspector overlay.
    /// Note: Holds a shared mutex lock while iterating all chunks.
    /// May cause minor contention with world streamer threads under heavy load.
    pub fn getChunkStateCounts(self: *World) ChunkStateCounts {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var counts: ChunkStateCounts = .{};
        counts.total = @intCast(self.storage.chunks.count());

        var iter = self.storage.chunks.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr.*.chunk.state;
            switch (state) {
                .missing => counts.missing += 1,
                .generating => counts.generating += 1,
                .meshing => counts.meshing += 1,
                .renderable => counts.renderable += 1,
                else => counts.other_states += 1,
            }
            if (entry.value_ptr.*.chunk.dirty) counts.dirty += 1;
        }
        return counts;
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: *World) WorldStatsData {
        const streamer_stats = self.streamer.getStats();

        return .{
            .chunks_loaded = self.storage.count(),
            // Runtime callers only need queue and chunk counts here. Recomputing the
            // full loaded-vertex sum every frame walks every chunk mesh under lock and
            // can stall the main thread while the world is streaming.
            .total_vertices = self.renderer.last_render_stats.vertices_rendered,
            .gen_queue = streamer_stats.gen_queue,
            .mesh_queue = streamer_stats.mesh_queue,
            .upload_queue = streamer_stats.upload_queue,
        };
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: *World) bool {
        return self.streamer.isStartupBusy(self.render_distance);
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: *World) WorldStateData {
        const stats = self.getStats();
        return .{
            .generator_name = self.generator.info.name,
            .seed = self.generator.getSeed(),
            .gen_queue = @as(u32, @intCast(stats.gen_queue)),
            .mesh_queue = @as(u32, @intCast(stats.mesh_queue)),
            .upload_queue = @as(u32, @intCast(stats.upload_queue)),
        };
    }

    /// Returns the full `IWorld` facade for this world instance.
    /// The facade borrows the world and must not outlive it.
    pub fn interface(self: *World) IWorld {
        return .{ .ptr = self, .vtable = &IWORLD_VTABLE };
    }

    /// Narrows the world facade to render-facing operations.
    /// Use by graphics systems that should not mutate simulation state.
    pub fn renderView(self: *World) GraphicsWorldRenderView {
        return .{ .ptr = self, .vtable = &WORLD_RENDER_VIEW_VTABLE };
    }

    const IWORLD_VTABLE = IWorld.VTable{
        .update = iupdate,
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
        .deinit = ideinit,
        .getRenderStats = igetRenderStats,
        .getStats = igetStats,
        .getLODStats = igetLODStats,
        .isLODEnabled = iisLODEnabled,
        .shadowScene = ishadowScene,
        .enableSaveManager = ienableSaveManager,
        .takeSaveFailureWarningCount = itakeSaveFailureWarningCount,
        .pauseGeneration = ipauseGeneration,
        .isPaused = iisPaused,
        .collisionWorld = icollisionWorld,
        .getBlock = igetBlock,
        .setBlock = isetBlock,
        .getColumnInfo = igetColumnInfo,
        .getDebugLightInfo = igetDebugLightInfo,
        .getRegionInfo = igetRegionInfo,
        .getGenerator = igetGenerator,
        .getGeneratorName = igetGeneratorName,
        .getRenderDistance = igetRenderDistance,
        .setRenderDistance = isetRenderDistance,
        .getHorizonDistance = igetHorizonDistance,
        .setHorizonDistance = isetHorizonDistance,
        .isLODRenderingEnabled = iisLODRenderingEnabled,
        .toggleLODRendering = itoggleLODRendering,
        .getChunkStateCounts = igetChunkStateCounts,
        .isStartupBusy = iisStartupBusy,
        .getWorldStateData = igetWorldStateData,
        .lpvWorld = ilpvWorld,
        .graphicsRenderView = igraphicsRenderView,
        .getGpuMeshDispatch = igetGpuMeshDispatch,
        .isGpuCullingEnabled = iisGpuCullingEnabled,
    };

    const WORLD_RENDER_VIEW_VTABLE = GraphicsWorldRenderView.VTable{
        .prepareLODCulling = iprepareLODCulling,
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
    };

    fn iprepareLODCulling(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.prepareLODCulling(view_proj, camera_pos);
    }

    fn iupdate(ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.update(player_pos, dt);
    }

    fn irender(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.render(view_proj, camera_pos, render_lod);
    }

    fn irenderOpaque(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderOpaque(view_proj, camera_pos, render_lod);
    }

    fn irenderFluid(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderFluid(view_proj, camera_pos, render_lod);
    }

    fn ideinit(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn igetRenderStats(ptr: *anyopaque) RenderStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRenderStats();
    }

    fn igetStats(ptr: *anyopaque) WorldStatsData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getStats();
    }

    fn igetLODStats(ptr: *anyopaque) ?@import("world-lod").LODStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getLODStats();
    }

    fn iisLODEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isLODEnabled();
    }

    fn ishadowScene(ptr: *anyopaque) IShadowScene {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.shadowScene();
    }

    fn ienableSaveManager(ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.enableSaveManager(save_dir_path, world_name);
    }

    fn itakeSaveFailureWarningCount(ptr: *anyopaque) usize {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.takeSaveFailureWarningCount();
    }

    fn ipauseGeneration(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.pauseGeneration();
    }

    fn iisPaused(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.paused;
    }

    fn icollisionWorld(ptr: *anyopaque) VoxelCollisionWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.collisionWorld();
    }

    fn igetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getBlock(world_x, world_y, world_z);
    }

    fn isetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.setBlock(world_x, world_y, world_z, block);
    }

    fn igetColumnInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(world_x, world_z);
    }

    fn igetDebugLightInfo(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getDebugLightInfo(world_x, world_y, world_z);
    }

    fn igetRegionInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn igetGenerator(ptr: *anyopaque) Generator {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator;
    }

    fn igetGeneratorName(ptr: *anyopaque) []const u8 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator.info.name;
    }

    fn igetRenderDistance(ptr: *anyopaque) i32 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.render_distance;
    }

    fn isetRenderDistance(ptr: *anyopaque, distance: i32) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.setRenderDistance(distance);
    }

    fn igetHorizonDistance(ptr: *anyopaque) i32 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.horizon_distance;
    }

    fn isetHorizonDistance(ptr: *anyopaque, distance: i32) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.setHorizonDistance(distance);
    }

    fn iisLODRenderingEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.lod_enabled;
    }

    fn itoggleLODRendering(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.lod_enabled = !self.lod_enabled;
        return self.lod_enabled;
    }

    fn igetChunkStateCounts(ptr: *anyopaque) ChunkStateCounts {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getChunkStateCounts();
    }

    fn iisStartupBusy(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isStartupBusy();
    }

    fn igetWorldStateData(ptr: *anyopaque) WorldStateData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getWorldStateData();
    }

    fn ilpvWorld(ptr: *anyopaque) ILPVWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.lpvWorld();
    }

    fn igraphicsRenderView(ptr: *anyopaque) GraphicsWorldRenderView {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.renderView();
    }

    fn igetGpuMeshDispatch(ptr: *anyopaque) GpuMeshDispatch {
        const self: *World = @ptrCast(@alignCast(ptr));
        return if (self.renderer.getGpuMesher() != null)
            .{ .dispatch_fn = WorldRenderer.processGpuMeshing, .dispatch_ctx = @ptrCast(self.renderer) }
        else
            .{ .dispatch_fn = null, .dispatch_ctx = null };
    }

    fn iisGpuCullingEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.renderer.isGpuCullingEnabled();
    }

    const COLLISION_VTABLE = VoxelCollisionWorld.VTable{
        .isSolidAt = collisionIsSolidAt,
    };

    fn collisionIsSolidAt(ptr: *anyopaque, x: i32, y: i32, z: i32) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        const block = self.getBlock(x, y, z);
        return block_registry.getBlockDefinition(block).is_solid;
    }

    /// Get LOD system statistics (returns null if LOD not enabled)
    pub fn getLODStats(self: *World) ?@import("world-lod").LODStats {
        if (self.lod) |lod| {
            return lod.getStats();
        }
        return null;
    }

    /// Check if LOD system is enabled
    pub fn isLODEnabled(self: *const World) bool {
        return self.lod != null;
    }
};
