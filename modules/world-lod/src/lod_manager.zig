//! LOD Manager - orchestrates multi-level chunk loading for extreme render distances.
//!
//! Implements a Distant Horizons-style system where:
//! - LOD0 (0-16 chunks): Full detail, 2x2 chunks merged
//! - LOD1 (16-32 chunks): 2x simplified, 4x4 chunks merged
//! - LOD2 (32-64 chunks): 4x simplified, 8x8 chunks merged
//! - LOD3 (64-100 chunks): 8x simplified, 16x16 chunks merged, heightmap only
//!
//! Key principles:
//! - Near/fine LODs are queued first so coarse parents do not dominate mid-ground
//! - Coarse LODs remain available as fallback while finer children stream
//! - Smooth transitions via fog masking
//!
//! GPU operations are decoupled via LODGPUBridge and LODRenderInterface (Issue #246).

const std = @import("std");
const fs = @import("fs");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
pub const LODStats = @import("lod_stats.zig").LODStats;
pub const LODWaitIdleReason = @import("lod_stats.zig").LODWaitIdleReason;

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const ChunkMesh = @import("world-meshing").ChunkMesh;
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const AABB = math.AABB;
const Vertex = @import("engine-rhi").Vertex;
const engine_core = @import("engine-core");
const log = engine_core.log;

const JobSystem = engine_core.job_system;
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;

const RingBuffer = engine_core.ring_buffer.RingBuffer;

const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const TextureAtlas = @import("engine-assets").TextureAtlas;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const lod_manager_context = @import("lod_manager_context.zig");
const lod_manager_core = @import("lod_manager_core_ops.zig");
const lod_manager_cache_ops = @import("lod_manager_cache_ops.zig");
const lod_manager_ingestion_ops = @import("lod_manager_ingestion_ops.zig");
const lod_manager_generation_ops = @import("lod_manager_generation_ops.zig");
const lod_manager_upload_ops = @import("lod_manager_upload_ops.zig");
const lod_manager_eviction_ops = @import("lod_manager_eviction_ops.zig");
const lod_manager_benchmark_fixture_ops = @import("lod_manager_benchmark_fixture_ops.zig");
const CacheIoPipeline = @import("lod_cache_io.zig").CacheIoPipeline;
const LODColumnProvenance = world_core.LODColumnProvenance;
const ChunkCoordKey = lod_manager_context.ChunkCoordKey;
const ChunkCoordKeyContext = lod_manager_context.ChunkCoordKeyContext;
const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);
const PendingIngestion = lod_manager_context.PendingIngestion;
const PlayerChunkPos = lod_manager_context.PlayerChunkPos;
const LifecycleQueue = lod_manager_context.LifecycleQueue;
const LODScanState = lod_manager_context.LODScanState;
pub const ChunkResolver = lod_manager_context.ChunkResolver;
const MAX_LOD_REGIONS = lod_manager_context.MAX_LOD_REGIONS;

/// LOD transition request
const LODTransition = struct {
    region_key: LODRegionKey,
    target_lod: LODLevel,
    priority: i32,
};

pub const LODCacheStore = struct {
    cache_dir_path: ?[]const u8 = null,
    logged_legacy_cache_notice: bool = false,
    store_size_cap_mb: u32 = lod_store.DEFAULT_STORE_SIZE_CAP_MB,
    use_config_store_size_cap: bool = false,
    store_mutex: sync.Mutex = .{},
};

pub const LODIngestionQueue = struct {
    pending_ingestions: std.ArrayListUnmanaged(PendingIngestion) = .empty,
    edit_dirty: ChunkCoordSet,
    mutex: sync.Mutex = .{},
    chunk_resolver: ?ChunkResolver = null,
    edit_cooldown: f32 = 0.0,
    drain_per_frame: u32 = 4,

    /// Creates an empty ingestion queue for chunk-derived LOD source updates.
    /// The caller owns the queue and must call `deinit` with the same allocator before discarding it.
    pub fn init(allocator: std.mem.Allocator) LODIngestionQueue {
        return .{ .edit_dirty = ChunkCoordSet.init(allocator) };
    }

    /// Releases pending ingestion records and dirty-edit tracking owned by the queue.
    /// The caller must ensure no other thread is appending to or draining this queue.
    pub fn deinit(self: *LODIngestionQueue, allocator: std.mem.Allocator) void {
        self.pending_ingestions.deinit(allocator);
        self.edit_dirty.deinit();
    }
};

pub const LODMeshDisposalQueue = struct {
    queue: std.ArrayListUnmanaged(*LODMesh) = .empty,
    timer: f32 = 0,
};

pub const LODMemoryGovernor = struct {
    used_bytes: usize = 0,
    /// Exact known allocations plus conservative reservations for admitted
    /// regions. This is the value checked before accepting new work.
    logical_admission_bytes: usize = 0,
    radius_shrink_chunks: [LODLevel.count]i32 = [_]i32{0} ** LODLevel.count,
};

pub const LODJobDispatcher = struct {
    queues: [LODLevel.count]*JobQueue,
    worker_pool: ?*WorkerPool = null,
    next_token: u32 = 1,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// LOD Manager - coordinates all LOD levels.
/// Uses callback interfaces (LODGPUBridge, LODRenderInterface) for GPU operations
/// instead of a direct RHI dependency.
pub const LODManager = struct {
    const Self = @This();

    pub const NearChunkSummary = @import("lod_near_source.zig").NearChunkSummary;
    pub const NearSourceKind = enum(u8) { generated, loaded, edited };
    pub const NearSourceCapture = struct {
        summary: NearChunkSummary,
        kind: NearSourceKind,
        sequence: u64,
    };
    pub const NearSourceRetry = struct {
        cx: i32,
        cz: i32,
        capture: NearSourceCapture,
    };

    // The experiment flag is immutable after initialization. The map uses the manager mutex,
    // never the ingestion or storage locks, and retains no full-detail pins.
    near_source_enabled: bool = false,
    near_sources: std.AutoArrayHashMapUnmanaged(ChunkCoordKey, NearSourceCapture) = .empty,
    near_source_sequence: std.atomic.Value(u64) = .init(1),
    near_source_sequence_floor: u64 = 0,
    near_source_retries: std.ArrayListUnmanaged(NearSourceRetry) = .empty,
    near_source_cursor: usize = 0,
    near_source_limit: usize = 4096,

    allocator: std.mem.Allocator,
    config: ILODConfig,

    // Storage per LOD level (LOD0 uses existing World.chunks)
    regions: [LODLevel.count]RegionMap,

    // Mesh storage per LOD level
    meshes: [LODLevel.count]MeshMap,

    // LOD job queues, worker pool, tokens, and teardown signaling.
    job_dispatcher: LODJobDispatcher,

    // Upload queues per LOD level
    upload_queues: [LODLevel.count]RingBuffer(*LODChunk),

    // Transition queue for LOD upgrades/downgrades
    transition_queue: std.ArrayListUnmanaged(LODTransition),

    // Current player position (chunk coords), read by worker threads for stale-job checks.
    player_cx: std.atomic.Value(i32),
    player_cz: std.atomic.Value(i32),
    scan_states: [LODLevel.count]LODScanState,

    // Stats
    stats: LODStats,
    profiling: @import("lod_stats.zig").LODProfilingCollector,
    cache_hits: u32,
    cache_misses: u32,
    cancelled_jobs: u32,

    // Mutex for thread safety
    mutex: sync.RwLock,

    // GPU bridge for upload/destroy/sync operations (replaces direct RHI field)
    gpu_bridge: LODGPUBridge,

    // Terrain generator for LOD generation (mutable for cache recentering)
    generator: LODGenerator,

    atlas: *const TextureAtlas,

    // Paused state
    paused: bool,

    // Memory tracking and pressure hysteresis.
    memory_governor: LODMemoryGovernor,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan optimization)
    mesh_disposal: LODMeshDisposalQueue,

    // Type-erased renderer interface (replaces direct LODRenderer(RHI) field)
    renderer: LODRenderInterface,

    // Optional source-data persistence store.
    cache_store: LODCacheStore,

    // Dedicated, bounded single-worker cache I/O pipeline. It is intentionally
    // separate from the generation pool so disk latency cannot occupy terrain
    // generation workers or the update path.
    cache_io: *CacheIoPipeline,

    // Keep cleanup behavior testable, but allow the live world to opt out.
    cleanup_covered_regions: bool = true,

    // -- Chunk-derived LOD ingestion (issue #752 Phase 2) --
    // Pending chunk ingestions whose containing LOD region did not yet have
    // source data when the chunk finished generating/loading. Drained from
    // update() once the regions appear.
    ingestion_queue: LODIngestionQueue,

    // Bounded, tokenized lifecycle heaps. Resident maps are consulted only
    // when a token is popped; stale work is rejected by token/revision.
    generation_tokens: LifecycleQueue = .{},
    transition_tokens: LifecycleQueue = .{},
    fade_tokens: LifecycleQueue = .{},

    // Number of regions admitted to the generation/mesh/upload pipeline. This
    // is maintained at lifecycle boundaries so scheduling does not need to
    // recount every region map before each admission pass.
    pending_region_count: usize = 0,

    /// A benchmark-only resident fixture owns the normal maps/meshes but opts
    /// out of scheduler/eviction mutation for the duration of its session.
    benchmark_fixture_active: bool = false,

    // Callback type to check if a regular chunk is loaded and renderable
    pub const ChunkChecker = lod_gpu.ChunkChecker;

    // ----------------------------------------------------------------------
    // Chunk-derived LOD ingestion (issue #752 Phase 2)
    // ----------------------------------------------------------------------

    /// Initialize the LOD manager facade and its extracted operation state.
    pub fn init(allocator: std.mem.Allocator, config: ILODConfig, gpu_bridge: LODGPUBridge, render_iface: LODRenderInterface, generator: LODGenerator, atlas: *const TextureAtlas) !*Self {
        return lod_manager_core.init(allocator, config, gpu_bridge, render_iface, generator, atlas);
    }

    /// Test-only lightweight manager state. Cache ownership starts disabled;
    /// tests that need persistence should call enableCache() and free it after.
    pub fn initCacheTestManager(allocator: std.mem.Allocator, cache_dir_path: []const u8) !Self {
        return lod_manager_cache_ops.initCacheTestManager(allocator, cache_dir_path);
    }

    /// Stores the player's current chunk position for scheduler and stale-job checks.
    /// Safe for worker reads through atomics; write from the world update thread.
    pub fn storePlayerChunkPos(self: *Self, cx: i32, cz: i32) void {
        return lod_manager_core.storePlayerChunkPos(self, cx, cz);
    }

    /// Loads the most recently stored player chunk position.
    /// Worker jobs use this snapshot to decide whether generated LOD work is still relevant.
    pub fn loadPlayerChunkPos(self: *const Self) PlayerChunkPos {
        return lod_manager_core.loadPlayerChunkPos(self);
    }

    /// Releases LOD manager queues, caches, meshes, and worker-owned resources.
    /// Call after pending LOD work has been quiesced or made safe to discard.
    pub fn deinit(self: *Self) void {
        return lod_manager_core.deinit(self);
    }

    /// Advances LOD scheduling, ingestion, generation, uploads, transitions, cache flushes, and eviction for one frame.
    /// Call from the world update thread; errors report failed queueing, mesh creation, or budget/eviction work.
    pub fn update(self: *Self, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        return lod_manager_core.update(self, player_pos, player_velocity, chunk_checker, checker_ctx);
    }

    /// Installs the bounded `gpu-culling-scale` benchmark source set through
    /// the normal compact upload bridge. This is intentionally unavailable to
    /// normal session code except through the benchmark fixture launcher.
    pub fn installGpuCullingScaleFixture(self: *Self) !void {
        return lod_manager_benchmark_fixture_ops.install(self);
    }

    /// Returns a snapshot of LOD scheduling, cache, generation, upload, and renderability counters.
    /// The returned data is diagnostic only and does not hold locks after the call returns.
    pub fn getStats(self: *Self) LODStats {
        return lod_manager_core.getStats(self);
    }

    /// Returns the configured outer radius of the coarsest active LOD band.
    pub fn getHorizonRenderRadius(self: *Self) i32 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        const active_count = lod_chunk.activeLODCount(self.config);
        return self.config.getRadii()[active_count - 1];
    }

    /// Returns whether the coarsest active level has produced drawable fallback
    /// terrain within the current horizon. Scoping this to the player prevents
    /// stale regions after a teleport from releasing foreground prefetch early.
    pub fn hasRenderableCoarsestNear(self: *Self, player_cx: i32, player_cz: i32) bool {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        const active_count = lod_chunk.activeLODCount(self.config);
        if (active_count == 0) return false;
        const lod: LODLevel = @enumFromInt(active_count - 1);
        const scale: i64 = @intCast(lod.chunksPerSide());
        const radius: i64 = self.config.getRadii()[active_count - 1];
        var it = self.regions[active_count - 1].iterator();
        while (it.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.getState() != .renderable) continue;
            const center_x = @as(i64, chunk.region_x) * scale + @divFloor(scale, 2);
            const center_z = @as(i64, chunk.region_z) * scale + @divFloor(scale, 2);
            const dx = center_x - player_cx;
            const dz = center_z - player_cz;
            if (@as(i128, dx) * dx + @as(i128, dz) * dz <= @as(i128, radius) * radius) return true;
        }
        return false;
    }

    /// Pauses new LOD generation and scheduling work.
    /// Existing regions and meshes remain available for rendering while paused.
    pub fn pause(self: *Self) void {
        return lod_manager_core.pause(self);
    }

    /// Resumes LOD scheduling after a pause.
    /// Pending queues may be processed by subsequent `update` calls.
    pub fn unpause(self: *Self) void {
        return lod_manager_core.unpause(self);
    }

    /// Selects the configured LOD level for a chunk coordinate relative to the stored player position.
    /// This is a read-only policy query used by streaming and debug code.
    pub fn getLODForDistance(self: *const Self, chunk_x: i32, chunk_z: i32) LODLevel {
        return lod_manager_core.getLODForDistance(self, chunk_x, chunk_z);
    }

    /// Returns whether a chunk coordinate falls inside the configured LOD horizon.
    /// This is a read-only culling/scheduling query based on the current player chunk position.
    pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
        return lod_manager_core.isInRange(self, chunk_x, chunk_z);
    }

    /// Renders currently renderable LOD regions through the configured renderer.
    /// Generation and upload queues are not drained by this call.
    pub fn render(self: *Self, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, layer: LODRenderLayer) void {
        return lod_manager_core.render(self, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer);
    }

    /// Renders a frame-aware LOD layer. The monotonic WorldRenderer serial
    /// allows terrain and water to share one visibility projection.
    pub fn renderFrame(self: *Self, frame_serial: u64, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, detail_render_radius: i32, layer: LODRenderLayer) void {
        return lod_manager_core.renderFrame(self, frame_serial, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, detail_render_radius, layer);
    }

    /// Prepares same-frame GPU LOD culling before active graphics passes.
    pub fn prepareFrame(self: *Self, frame_serial: u64, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, max_distance_chunks: ?i32, detail_render_radius: i32) void {
        return lod_manager_core.prepareFrame(self, frame_serial, view_proj, camera_pos, chunk_checker, checker_ctx, max_distance_chunks, detail_render_radius);
    }

    /// Enables persistent source-data caching for LOD regions below `save_dir_path`.
    /// Allocates and stores the cache path; errors indicate allocation or filesystem setup failure.
    /// The near-source experiment isolates coarse caching in `near-source-v1`
    /// and keeps LOD0/1 source entirely memory-only, including explicit saves.
    pub fn enableCache(self: *Self, save_dir_path: []const u8) !void {
        return lod_manager_cache_ops.enableCache(self, save_dir_path);
    }

    /// Writes dirty cached source-data containers to persistent storage.
    /// Intended for the world update/shutdown path; IO failures are logged and leave data eligible for retry.
    pub fn flushDirtyStores(self: *Self) void {
        return lod_manager_cache_ops.flushDirtyStores(self);
    }

    /// Settles older writes, then queues and waits for every current dirty
    /// source snapshot. Used by explicit save points.
    pub fn flushDirtyStoresNow(self: *Self) void {
        return lod_manager_cache_ops.flushDirtyStoresNow(self);
    }

    /// Deletes settled cache payloads for edited source updates that are still
    /// blocked on missing or in-flight regions. The pending ingestion remains
    /// queued and will write a fresh snapshot after it can be applied.
    pub fn invalidatePendingEditedStoresNow(self: *Self) void {
        return lod_manager_cache_ops.invalidatePendingEditedStoresNow(self);
    }

    /// Flushes completed cache IO work and applies read/write completions.
    /// Call from the main thread when synchronous cache progress is required.
    pub fn flushCacheIO(self: *Self) void {
        return lod_manager_cache_ops.flushCacheIO(self);
    }

    /// Applies completed cache reads/writes without waiting for worker I/O.
    pub fn drainCacheCompletions(self: *Self) void {
        return lod_manager_cache_ops.drainCacheCompletions(self);
    }

    /// Shutdown-only cache flush. This may block until the bounded worker has
    /// serialized and persisted accepted snapshots.
    pub fn shutdownCacheIO(self: *Self) void {
        return lod_manager_cache_ops.shutdownCacheIO(self);
    }

    /// Builds the persistent cache key for an LOD region using generator identity and LOD coordinates.
    /// The returned key is deterministic for the same generator seed/version and region key.
    pub fn cacheKey(self: *const Self, key: LODRegionKey) lod_cache.Key {
        return lod_manager_cache_ops.cacheKey(self, key);
    }

    /// Constructs the legacy single-region cache file path for migration or cleanup.
    /// The returned path is heap allocated and must be freed by the caller.
    pub fn legacyCacheFilePath(self: *Self, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
        return lod_manager_cache_ops.legacyCacheFilePath(self, save_dir_path, key);
    }

    /// Logs the one-time notice that legacy LOD cache data was detected.
    /// This mutates only the cache-store diagnostic flag to avoid repeated log spam.
    pub fn logLegacyCacheNotice(self: *Self) void {
        return lod_manager_cache_ops.logLegacyCacheNotice(self);
    }

    /// Returns a heap-owned snapshot of the configured cache directory path.
    /// Returns `null` when caching is disabled or allocation fails.
    pub fn cacheDirPathSnapshot(self: *Self) ?[]u8 {
        return lod_manager_cache_ops.cacheDirPathSnapshot(self);
    }

    /// Reports whether persistent LOD source-data caching is currently configured.
    /// This is a read-only query protected by the cache-store synchronization.
    pub fn cacheEnabled(self: *Self) bool {
        return lod_manager_cache_ops.cacheEnabled(self);
    }

    /// Reads a serialized LOD cache payload from the container store.
    /// Returns `null` for cache misses; errors report filesystem or allocation failures.
    pub fn readStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) !?[]u8 {
        return lod_manager_cache_ops.readStorePayload(self, save_dir_path, cache_key);
    }

    /// Writes a serialized LOD cache payload to the container store.
    /// Errors report filesystem, allocation, or store-encoding failures.
    pub fn writeStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key, bytes: []const u8) !void {
        return lod_manager_cache_ops.writeStorePayload(self, save_dir_path, cache_key, bytes);
    }

    /// Deletes one payload from the LOD cache store if it exists.
    /// Missing payloads are ignored because cache deletion is best-effort cleanup.
    pub fn deleteStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) void {
        return lod_manager_cache_ops.deleteStorePayload(self, save_dir_path, cache_key);
    }

    /// Deletes an entire LOD cache store container path.
    /// Used by cleanup and migration paths; failures are intentionally non-fatal.
    pub fn deleteStoreContainer(self: *Self, path: []const u8) void {
        return lod_manager_cache_ops.deleteStoreContainer(self, path);
    }

    /// Loads simplified source data for an LOD region from cache when available and valid.
    /// Returns `null` for misses, invalid payloads, disabled cache, or generator-version mismatch.
    pub fn loadCachedSourceData(self: *Self, key: LODRegionKey) ?LODSimplifiedData {
        return lod_manager_cache_ops.loadCachedSourceData(self, key);
    }

    /// Increments cache-hit counters used by LOD diagnostics.
    /// This does not mutate cached data or scheduling state.
    pub fn recordCacheHit(self: *Self) void {
        return lod_manager_cache_ops.recordCacheHit(self);
    }

    /// Increments cache-miss counters used by LOD diagnostics.
    /// This is called when no reusable source data was found for a region.
    pub fn recordCacheMiss(self: *Self) void {
        return lod_manager_cache_ops.recordCacheMiss(self);
    }

    /// Serializes and stores simplified source data for a completed LOD region.
    /// The input data is borrowed for the call; persistence failures are logged for later diagnosis.
    pub fn saveCachedSourceData(self: *Self, key: LODRegionKey, data: *const LODSimplifiedData) void {
        return lod_manager_cache_ops.saveCachedSourceData(self, key, data);
    }

    /// Dispatches a generation fallback after an asynchronous cache miss.
    /// Cache completion processing is the only caller; it never performs I/O.
    pub fn dispatchCacheMiss(self: *Self, key: LODRegionKey, token: u32) void {
        return lod_manager_generation_ops.dispatchCacheMiss(self, key, token);
    }

    /// Installs the callback used to resolve full-detail chunks for ingestion retries.
    /// Call from the world update thread before requesting deferred ingestion.
    pub fn setChunkResolver(self: *Self, resolver: ChunkResolver) void {
        return lod_manager_ingestion_ops.setChunkResolver(self, resolver);
    }

    pub fn usesNearSource(self: *const Self, lod: LODLevel) bool {
        return self.near_source_enabled and @intFromEnum(lod) <= 1;
    }

    pub fn sourceSampleDensity(self: *const Self, lod: LODLevel) f32 {
        return if (self.usesNearSource(lod)) 1.0 else self.config.getSampleDensity(lod);
    }

    pub fn sourceRequiresSpans(self: *Self, lod: LODLevel) bool {
        return self.usesNearSource(lod) or (self.config.getVerticalSpanBudget() > 0 and self.effectiveMeshPath(lod) == .column_spans);
    }

    /// Caller owns block mutation synchronization and chunk lifetime. Scans
    /// outside the manager lock; submit only after generation is publishable.
    pub fn captureNearChunk(self: *Self, chunk: *const Chunk, kind: NearSourceKind) ?NearSourceCapture {
        if (!self.near_source_enabled or self.benchmark_fixture_active) return null;
        const sequence = self.near_source_sequence.fetchAdd(1, .monotonic);
        return .{ .summary = NearChunkSummary.capture(chunk), .kind = kind, .sequence = sequence };
    }

    /// True means accepted or consumed as obsolete. False requests a bounded
    /// retry; callers must not reinterpret an old capture with a new sequence.
    pub fn submitNearChunk(self: *Self, cx: i32, cz: i32, capture: NearSourceCapture) bool {
        return @import("lod_manager_near_source_ops.zig").submit(self, cx, cz, capture);
    }

    /// Bounded value-only retry, independent of coarse ingestion and residency.
    /// Queue saturation/allocation failure is logged; no chunk pins are retained.
    pub fn deferNearChunk(self: *Self, cx: i32, cz: i32, capture: NearSourceCapture) void {
        return @import("lod_manager_near_source_ops.zig").deferCapture(self, cx, cz, capture);
    }

    /// Main-thread resolver capture. Callback locks mutation/storage itself;
    /// no manager or ingestion lock is held while calling into the runtime.
    pub fn captureResolvedNearChunk(self: *Self, cx: i32, cz: i32, kind: NearSourceKind) bool {
        return @import("lod_manager_near_source_ops.zig").captureResolved(self, cx, cz, kind);
    }

    /// Caller holds manager mutex and owns mutable region source data.
    pub fn overlayNearSourcesLocked(self: *Self, region: *LODChunk) u32 {
        return @import("lod_manager_near_source_ops.zig").overlayRegionLocked(self, region);
    }

    /// Folds one full-detail chunk into every matching LOD region's simplified source data.
    /// Marks affected source data dirty so meshes and cache payloads can be refreshed.
    pub fn ingestChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
        // The scale fixture's source set is immutable for a matched CPU/GPU
        // run. Full-detail streamer arrivals must not remesh a fixture tile.
        if (self.benchmark_fixture_active) return;
        return lod_manager_ingestion_ops.ingestChunk(self, cx, cz, chunk, provenance);
    }

    /// Legacy downsampling only (LOD2+ with the experiment, LOD1+ otherwise).
    /// Near snapshots are captured before publication and submitted separately,
    /// even when fresh coarse ingestion is off.
    pub fn ingestCoarseChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
        if (self.benchmark_fixture_active) return;
        return lod_manager_ingestion_ops.ingestCoarseChunk(self, cx, cz, chunk, provenance);
    }

    /// Queues ingestion for a chunk whose target LOD regions may not exist yet.
    /// The request is retried by later update ticks until it applies or manager teardown.
    pub fn requestIngestion(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance) void {
        if (self.benchmark_fixture_active) return;
        return lod_manager_ingestion_ops.requestIngestion(self, cx, cz, provenance);
    }

    /// Marks a full-detail chunk as edited so its containing LOD regions can be refreshed.
    /// The edit is debounced and flushed into ingestion work from the update thread.
    pub fn markChunkEdited(self: *Self, cx: i32, cz: i32) void {
        if (self.benchmark_fixture_active) return;
        return lod_manager_ingestion_ops.markChunkEdited(self, cx, cz);
    }

    /// Applies queued edit provenance before full-detail storage unloads the
    /// resolver-owned chunk. Returns the LOD-level mask still waiting for a
    /// source region and optionally retains that work for a later retry.
    pub fn flushEditedChunkForUnload(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, retain_pending: bool) u8 {
        if (self.benchmark_fixture_active) return 0;
        return lod_manager_ingestion_ops.flushEditedChunkForUnload(self, cx, cz, chunk, retain_pending);
    }

    /// Applies chunk-derived source samples to currently loaded LOD regions.
    /// Returns a bitmask describing which LOD levels still need the update.
    pub fn applyIngestionToRegions(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) u8 {
        return lod_manager_ingestion_ops.applyIngestionToRegions(self, cx, cz, chunk, provenance);
    }

    /// Records a deferred ingestion request while the ingestion mutex is already held.
    /// `mask` tracks which LOD levels still need the chunk once regions become
    /// available. Returns false when bounded queue admission fails.
    pub fn recordPendingLocked(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8) bool {
        return lod_manager_ingestion_ops.recordPendingLocked(self, cx, cz, provenance, mask);
    }

    /// Refreshes an existing deferred ingestion request with a new mask. The
    /// legacy `ttl` argument is ignored; work remains durable until it applies.
    pub fn rerecordPending(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8, ttl: u16) void {
        return lod_manager_ingestion_ops.rerecordPending(self, cx, cz, provenance, mask, ttl);
    }

    /// Removes completed pending-ingestion records while the ingestion mutex is held.
    /// Unresolved requests remain durable; queue capacity bounds memory usage.
    pub fn decayPendingLocked(self: *Self) void {
        return lod_manager_ingestion_ops.decayPendingLocked(self);
    }

    /// Resolves and applies a bounded number of deferred ingestion requests for this frame.
    /// Uses the installed chunk resolver and leaves unresolved requests queued for later ticks.
    pub fn drainPendingIngestions(self: *Self) void {
        return lod_manager_ingestion_ops.drainPendingIngestions(self);
    }

    /// Immediately attempts every currently deferred ingestion once. Entries
    /// that are still unavailable remain queued for later update ticks.
    pub fn drainPendingIngestionsNow(self: *Self) void {
        return lod_manager_ingestion_ops.drainPendingIngestionsNow(self);
    }

    /// Converts debounced edited-chunk coordinates into ingestion requests.
    /// Clears the dirty-edit set once requests have been queued or applied.
    pub fn flushEditedChunks(self: *Self) void {
        return lod_manager_ingestion_ops.flushEditedChunks(self);
    }

    /// Immediately applies pending edited chunks without waiting for the
    /// coalescing cooldown. Used by explicit save points.
    pub fn flushEditedChunksNow(self: *Self) void {
        return lod_manager_ingestion_ops.flushEditedChunksNow(self);
    }

    /// Immediately consumes at most the ordinary per-frame edit budget.
    /// Intended for autosave paths that must not synchronously drain all edits.
    pub fn flushEditedChunksBounded(self: *Self) void {
        return lod_manager_ingestion_ops.flushEditedChunksBounded(self);
    }

    /// Queues missing or dirty regions for generation at one LOD level.
    /// Errors report allocation or job-queue failures; call from the world update thread.
    pub fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        return lod_manager_generation_ops.queueLODRegions(self, lod, velocity, chunk_checker, checker_ctx);
    }

    /// Drains completed generation jobs and schedules mesh work for accepted source data.
    /// Errors report mesh allocation or queueing failures.
    pub fn processQueuedGenerations(self: *Self, velocity: Vec3) !void {
        return lod_manager_generation_ops.processQueuedGenerations(self, velocity);
    }

    /// Advances LOD region lifecycle transitions such as generated-to-meshing and meshing-to-uploading.
    /// Errors report failed mesh creation or upload queue insertion.
    pub fn processStateTransitions(self: *Self, velocity: Vec3) !void {
        return lod_manager_generation_ops.processStateTransitions(self, velocity);
    }

    /// Adds a revision-checked mesh or upload lifecycle token. Used when
    /// workers and ingestion change state without a resident-map sweep.
    pub fn enqueueTransition(self: *Self, key: LODRegionKey, chunk: *const LODChunk, stage: lod_manager_context.LifecycleStage) void {
        return lod_manager_generation_ops.enqueueTransition(self, key, chunk, stage);
    }

    /// Schedules bounded fade decay only for regions actively transitioning.
    pub fn enqueueFade(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
        return lod_manager_generation_ops.enqueueFade(self, key, chunk);
    }

    /// Returns the mesh object for a region, allocating it when absent.
    /// The returned mesh is manager-owned and remains valid until eviction or manager teardown.
    pub fn getOrCreateMesh(self: *Self, key: LODRegionKey) !*LODMesh {
        return lod_manager_generation_ops.getOrCreateMesh(self, key);
    }

    /// Builds CPU mesh data for one LOD chunk from its current source data.
    /// Errors report allocation or meshing failures; successful builds enqueue upload work.
    pub fn buildMeshForChunk(self: *Self, chunk: *LODChunk) !void {
        return lod_manager_generation_ops.buildMeshForChunk(self, chunk);
    }

    /// Selects the mesh-building path to use for a particular LOD level.
    /// The result combines global config with per-level fallbacks for performance and quality.
    pub fn effectiveMeshPath(self: *Self, lod: LODLevel) lod_chunk.LODMeshPath {
        return lod_manager_generation_ops.effectiveMeshPath(self, lod);
    }

    /// Uploads queued LOD meshes using the configured per-frame upload budget.
    /// Must run on the render/update thread that owns the GPU bridge.
    pub fn processUploads(self: *Self) void {
        return lod_manager_upload_ops.processUploads(self);
    }

    /// Uploads queued LOD meshes until `upload_budget_bytes` is exhausted.
    /// Chunks that cannot be uploaded within the budget are left queued for later frames.
    pub fn processUploadsWithBudget(self: *Self, upload_budget_bytes: usize) void {
        return lod_manager_upload_ops.processUploadsWithBudget(self, upload_budget_bytes);
    }

    /// Recovers compact draw failures on the update thread through the normal
    /// CPU mesh and bounded upload path.
    pub fn recoverCompactDrawFailures(self: *Self) void {
        return lod_manager_upload_ops.recoverCompactDrawFailures(self);
    }

    /// Explicitly records a device-wide LOD wait. Routine upload, eviction,
    /// and pool maintenance must use frame-safe retirement instead.
    pub fn waitIdleTracked(self: *Self, reason: LODWaitIdleReason) void {
        self.gpu_bridge.waitIdleTracked(&self.profiling, reason);
    }

    /// Places an LOD chunk back onto an upload queue after a deferred or failed upload attempt.
    /// The chunk remains manager-owned and must stay pinned as required by the caller path.
    pub fn requeueUpload(self: *Self, lod_idx: usize, chunk: *LODChunk) void {
        return lod_manager_upload_ops.requeueUpload(self, lod_idx, chunk);
    }

    /// Replaces a failed compact upload with the maintained CPU heightfield.
    pub fn fallbackCompactMeshToCpu(self: *Self, mesh: *LODMesh, chunk: *LODChunk) !void {
        return lod_manager_generation_ops.fallbackCompactMeshToCpu(self, mesh, chunk);
    }

    /// Counts direct finer child regions that are currently renderable for a parent region.
    /// Used to decide parent fallback visibility and transition fades.
    pub fn countRenderableChildren(self: *Self, key: LODRegionKey) u8 {
        return lod_manager_upload_ops.countRenderableChildren(self, key);
    }

    /// Reports whether a region should contribute visible geometry in the current hierarchy state.
    /// Excludes empty, covered, or non-renderable regions that should not affect parent readiness.
    pub fn regionContributesGeometry(self: *Self, key: LODRegionKey, chunk: *const LODChunk) bool {
        return lod_manager_upload_ops.regionContributesGeometry(self, key, chunk);
    }

    /// Adjusts a parent region's renderable-child count after child visibility changes.
    /// This may start or cancel transition fades used to hide parent fallback terrain.
    pub fn adjustParentReadyChildren(self: *Self, key: LODRegionKey, delta: i8) void {
        return lod_manager_upload_ops.adjustParentReadyChildren(self, key, delta);
    }

    /// Marks a region renderable after its mesh upload completes.
    /// Updates parent readiness and transition state so hierarchy blending remains consistent.
    pub fn markRegionRenderable(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        return lod_manager_upload_ops.markRegionRenderable(self, key, chunk);
    }

    /// Decrements active transition fade counters for renderable regions.
    /// Call once per update tick before rendering fade-dependent LOD hierarchy state.
    pub fn decayTransitionFrames(self: *Self) void {
        return lod_manager_upload_ops.decayTransitionFrames(self);
    }

    /// Updates hierarchy bookkeeping when a region is removed or evicted.
    /// Parent ready-child counts are reduced if the removed region contributed geometry.
    pub fn noteRegionRemoved(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
        return lod_manager_upload_ops.noteRegionRemoved(self, key, chunk);
    }

    /// Demotes a renderable region back to mesh/upload work after its source data changes.
    /// Parent readiness is updated before the region leaves the renderable set.
    pub fn demoteRegionForRemesh(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        return lod_manager_upload_ops.demoteRegionForRemesh(self, key, chunk);
    }

    /// Evicts LOD regions outside their configured radii and queues their meshes for destruction.
    /// Errors report allocation or bookkeeping failures during eviction.
    pub fn unloadDistantRegions(self: *Self) !void {
        return lod_manager_eviction_ops.unloadDistantRegions(self);
    }

    /// Evicts regions for one LOD level beyond `max_radius` chunks from the player.
    /// Pinned or in-flight regions are preserved until background work releases them.
    pub fn unloadDistantForLevel(self: *Self, lod: LODLevel, max_radius: i32) !void {
        return lod_manager_eviction_ops.unloadDistantForLevel(self, lod, max_radius);
    }

    /// Defers GPU mesh destruction so the backend is not forced to free resources mid-frame.
    /// The mesh pointer must remain valid until `processMeshDeletions` consumes it.
    pub fn queueMeshDeletion(self: *Self, mesh: *LODMesh) void {
        return lod_manager_eviction_ops.queueMeshDeletion(self, mesh);
    }

    /// Destroys up to `max_count` deferred LOD meshes through the GPU bridge.
    /// Intended to amortize resource deletion across frames.
    pub fn processMeshDeletions(self: *Self, max_count: usize) void {
        return lod_manager_eviction_ops.processMeshDeletions(self, max_count);
    }

    /// Enforces the configured LOD memory budget by shrinking radii or evicting regions.
    /// Errors report eviction failures; call from the world update thread.
    pub fn enforceMemoryBudget(self: *Self) !void {
        return lod_manager_eviction_ops.enforceMemoryBudget(self);
    }

    /// Recomputes diagnostic stats from current LOD maps, queues, cache counters, and memory state.
    /// This mutates only the stats snapshot exposed by `getStats`.
    pub fn updateStats(self: *Self) void {
        return lod_manager_eviction_ops.updateStats(self);
    }

    /// Removes LOD fallback regions fully covered by loaded full-detail chunks.
    /// Uses `checker` to avoid drawing duplicate distant terrain inside the high-detail area.
    pub fn unloadLODWhereChunksLoaded(self: *Self, checker: ChunkChecker, ctx: *anyopaque) void {
        return lod_manager_eviction_ops.unloadLODWhereChunksLoaded(self, checker, ctx);
    }

    /// Tests whether every full-detail chunk inside `bounds` is loaded and renderable.
    /// Used before unloading an overlapping LOD region to prevent visible holes.
    pub fn areAllChunksLoaded(self: *Self, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
        return lod_manager_eviction_ops.areAllChunksLoaded(self, bounds, checker, ctx);
    }
};
