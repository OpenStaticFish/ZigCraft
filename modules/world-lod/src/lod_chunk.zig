//! LOD Chunk data structures for Distant Horizons-style rendering.
//!
//! LOD levels merge progressively larger chunk regions. Runtime settings choose
//! each level's grid detail and mesh path.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
pub const LODMeshPath = @import("engine-rhi").LODMeshPath;

/// LOD level enum - higher values = more simplified
pub const LODLevel = @import("lod_types.zig").LODLevel;
pub const regionSizeBlocks = world_core.regionSizeBlocks;
pub const TRANSITION_FADE_FRAMES: u8 = 30;

/// State for LOD chunks/regions
pub const LODState = @import("lod_types.zig").LODState;

/// Simplified data for distant LOD levels (LOD1+).
/// Only stores essential data needed for rendering distant terrain.
pub const LODSimplifiedData = world_core.LODSimplifiedData;

/// LOD region key - identifies a region at a specific LOD level
pub const LODRegionKey = struct {
    /// Region X coordinate (in region units, not chunks)
    rx: i32,
    /// Region Z coordinate
    rz: i32,
    /// LOD level
    lod: LODLevel,

    /// Converts full-detail chunk coordinates to the containing LOD region key.
    /// Uses floor division so negative world coordinates map to the correct parent region.
    pub fn fromChunkCoords(chunk_x: i32, chunk_z: i32, lod: LODLevel) LODRegionKey {
        const scale: i32 = @intCast(lod.chunksPerSide());
        return .{
            .rx = @divFloor(chunk_x, scale),
            .rz = @divFloor(chunk_z, scale),
            .lod = lod,
        };
    }

    /// Hashes the region coordinates and LOD level for use in region maps.
    /// The hash is deterministic and does not inspect mutable chunk state.
    pub fn hash(self: LODRegionKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.rx));
        const uz: u64 = @bitCast(@as(i64, self.rz));
        const ul: u64 = @intFromEnum(self.lod);
        return ux ^ (uz *% 0x9e3779b97f4a7c15) ^ (ul *% 0x517cc1b727220a95);
    }

    /// Compares two region keys by coordinates and LOD level.
    /// Intended for hash-map key equality and has no side effects.
    pub fn eql(a: LODRegionKey, b: LODRegionKey) bool {
        return a.rx == b.rx and a.rz == b.rz and a.lod == b.lod;
    }

    /// Returns the coarser parent region that spatially contains this region.
    /// Returns `null` for the coarsest LOD because no parent level exists.
    pub fn parentKey(self: LODRegionKey) ?LODRegionKey {
        const lod_idx = @intFromEnum(self.lod);
        if (lod_idx + 1 >= LODLevel.count) return null;
        return .{
            .rx = @divFloor(self.rx, 2),
            .rz = @divFloor(self.rz, 2),
            .lod = @enumFromInt(@as(u3, @intCast(lod_idx + 1))),
        };
    }

    /// Returns the four direct finer child regions covered by this region.
    /// Returns `null` for LOD0 because it has no finer LOD children.
    pub fn childKeys(self: LODRegionKey) ?[4]LODRegionKey {
        const lod_idx = @intFromEnum(self.lod);
        if (lod_idx == 0) return null;
        const child_lod: LODLevel = @enumFromInt(@as(u3, @intCast(lod_idx - 1)));
        const base_x = self.rx * 2;
        const base_z = self.rz * 2;
        return .{
            .{ .rx = base_x, .rz = base_z, .lod = child_lod },
            .{ .rx = base_x + 1, .rz = base_z, .lod = child_lod },
            .{ .rx = base_x, .rz = base_z + 1, .lod = child_lod },
            .{ .rx = base_x + 1, .rz = base_z + 1, .lod = child_lod },
        };
    }

    /// Clip a draw of this region to a descendant's X/Z footprint. Internal
    /// boundaries are half-open; preserve vertical faces on the outer edge.
    pub fn ownershipBounds(self: LODRegionKey, owner: LODRegionKey) [4]f32 {
        const size: i32 = @intCast(regionSizeBlocks(self.lod));
        const owner_size: i32 = @intCast(regionSizeBlocks(owner.lod));
        const x = owner.rx * owner_size - self.rx * size;
        const z = owner.rz * owner_size - self.rz * size;
        std.debug.assert(x >= 0 and z >= 0 and x + owner_size <= size and z + owner_size <= size);
        return .{
            @floatFromInt(if (x == 0) -1 else x),
            @floatFromInt(if (z == 0) -1 else z),
            @floatFromInt(x + owner_size + @as(i32, if (x + owner_size == size) 1 else 0)),
            @floatFromInt(z + owner_size + @as(i32, if (z + owner_size == size) 1 else 0)),
        };
    }

    /// Tests a local surface sample against a half-open ownership rectangle.
    /// A face exactly on a shared edge probes inward, opposite its local-space
    /// outward normal, so the owner retains its exposed vertical face while
    /// horizontal surfaces still partition half-open.
    pub fn ownershipContainsLocalSurface(bounds: [4]f32, local_xz: [2]f32, local_normal_xz: [2]f32) bool {
        if (bounds[2] <= bounds[0] or bounds[3] <= bounds[1]) return true;
        const epsilon: f32 = 0.001;
        var probe = local_xz;
        if (@abs(local_xz[0] - bounds[0]) <= epsilon or @abs(local_xz[0] - bounds[2]) <= epsilon) {
            probe[0] -= normalDirection(local_normal_xz[0]) * epsilon;
        }
        if (@abs(local_xz[1] - bounds[1]) <= epsilon or @abs(local_xz[1] - bounds[3]) <= epsilon) {
            probe[1] -= normalDirection(local_normal_xz[1]) * epsilon;
        }
        return probe[0] >= bounds[0] and probe[0] < bounds[2] and probe[1] >= bounds[1] and probe[1] < bounds[3];
    }

    fn normalDirection(component: f32) f32 {
        return if (component > 0) 1 else if (component < 0) -1 else 0;
    }

    /// Get the chunk coordinates that this region covers
    pub fn chunkBounds(self: LODRegionKey) ChunkBounds {
        const scale: i32 = @intCast(self.lod.chunksPerSide());
        return .{
            .min_x = self.rx * scale,
            .min_z = self.rz * scale,
            .max_x = self.rx * scale + scale - 1,
            .max_z = self.rz * scale + scale - 1,
        };
    }
};

pub const ChunkBounds = struct {
    min_x: i32,
    min_z: i32,
    max_x: i32,
    max_z: i32,

    /// Computes squared distance from a chunk-coordinate point to this bounds rectangle.
    /// Points inside the rectangle return zero; used to avoid square roots in range tests.
    pub fn distanceSquaredToPoint(self: ChunkBounds, point_x: i32, point_z: i32) i64 {
        const dx = axisDistance(point_x, self.min_x, self.max_x);
        const dz = axisDistance(point_z, self.min_z, self.max_z);
        const distance_sq = @as(i128, dx) * dx + @as(i128, dz) * dz;
        return @intCast(@min(distance_sq, std.math.maxInt(i64)));
    }

    /// Tests whether this chunk bounds intersects a radius around a chunk-coordinate center.
    /// The radius is expressed in chunks and is evaluated radially, not as an axis-aligned square.
    pub fn intersectsRadius(self: ChunkBounds, center_x: i32, center_z: i32, radius_chunks: i32) bool {
        const radius_sq: i64 = @as(i64, radius_chunks) * @as(i64, radius_chunks);
        return self.distanceSquaredToPoint(center_x, center_z) <= radius_sq;
    }

    fn axisDistance(point: i32, min_value: i32, max_value: i32) i64 {
        if (point < min_value) return @as(i64, min_value) - @as(i64, point);
        if (point > max_value) return @as(i64, point) - @as(i64, max_value);
        return 0;
    }
};

/// Context for LODRegionKey HashMap
pub const LODRegionKeyContext = struct {
    /// Hashes a region key for `std.HashMap` storage.
    /// The context has no state; hashing delegates to the key's deterministic hash.
    pub fn hash(self: @This(), key: LODRegionKey) u64 {
        _ = self;
        return key.hash();
    }

    /// Compares two region keys for `std.HashMap` lookup.
    /// The context has no state and the comparison is side-effect-free.
    pub fn eql(self: @This(), a: LODRegionKey, b: LODRegionKey) bool {
        _ = self;
        return a.eql(b);
    }
};

/// LOD Chunk - represents terrain data at a specific LOD level
pub const LODChunk = struct {
    /// Region position
    region_x: i32,
    region_z: i32,

    /// LOD level
    lod_level: LODLevel,

    /// Current state
    state: LODState,

    /// Job token for tracking async work
    job_token: u32,
    /// Encoded scheduling priority retained across cache lookup and lifecycle
    /// transitions so bootstrap horizon seeds keep their spatial ordering.
    job_priority: i32,
    preserve_job_priority: bool,
    /// Runtime admission class, retained through remesh/recovery but never persisted.
    service_lane: u3 = 4,
    canonical_refresh_requested: std.atomic.Value(bool) = .init(false),
    refresh_in_flight: std.atomic.Value(bool) = .init(false),
    canonical_retry_tick: u32 = 0,
    /// Borrowed while simplified data allocations keep the quota owner alive.
    canonical_allocator: ?*@import("lod_budget_allocator.zig").BudgetAllocator = null,

    /// Pin count for preventing unload during async work
    pin_count: std.atomic.Value(u32),

    /// Per-region cancellation signal for worker jobs invalidated by pause,
    /// teleport, or horizon changes. Unlike the manager teardown flag, this
    /// remains set until a new job is explicitly dispatched for the region.
    cancel_requested: std.atomic.Value(bool),

    /// Chunk data - either full detail or simplified
    data: union(enum) {
        /// LOD0: Full chunk data (pointer to existing Chunk)
        full: *Chunk,
        /// LOD1+: Simplified heightmap-based data
        simplified: LODSimplifiedData,
        /// Not yet generated
        empty: void,
    },

    /// Mesh handle (0 = no mesh)
    mesh_handle: u32,

    /// Actual source-data height bounds in world block coordinates.
    min_height: f32,
    max_height: f32,

    /// Number of direct 2x2 finer child regions currently renderable.
    ready_children: u8,

    /// Remaining render ticks for child fade-in or parent fade-out after a
    /// hierarchy coverage transition.
    transition_frames_remaining: u8,

    /// Dirty flag for re-meshing
    dirty: bool,

    /// Source data changed since the last store flush (chunk-derived ingestion
    /// or edit). The manager writes the region container to disk lazily.
    store_dirty: bool,

    /// Monotonic source revision used to reject stale cache write completions.
    source_revision: u32,

    /// Cache pipeline state. These flags are owned by the manager update
    /// thread and prevent duplicate requests without pinning region memory.
    cache_read_queued: bool,
    store_write_queued: bool,
    /// Suppresses retries for a snapshot that cannot fit the current store
    /// cap. A source revision or cap increase makes it eligible again.
    store_size_limited: bool,
    store_size_limit_cap_mb: u32,
    /// Sticky for the current source revision after a compact runtime
    /// submission failure, preventing an auto/force rebuild loop on this
    /// device session. Source changes clear it and may retry compact safely.
    compact_disabled: bool,

    /// Creates an empty LOD region record in the missing state.
    /// Source data, mesh handles, readiness counts, and transition state are initialized to safe defaults.
    pub fn init(rx: i32, rz: i32, lod: LODLevel) LODChunk {
        return .{
            .region_x = rx,
            .region_z = rz,
            .lod_level = lod,
            .state = .missing,
            .job_token = 0,
            .job_priority = 0,
            .preserve_job_priority = false,
            .pin_count = std.atomic.Value(u32).init(0),
            .cancel_requested = std.atomic.Value(bool).init(false),
            .data = .{ .empty = {} },
            .mesh_handle = 0,
            .min_height = 0.0,
            .max_height = @floatFromInt(CHUNK_SIZE_Y),
            .ready_children = 0,
            .transition_frames_remaining = 0,
            .dirty = false,
            .store_dirty = false,
            .source_revision = 0,
            .cache_read_queued = false,
            .store_write_queued = false,
            .store_size_limited = false,
            .store_size_limit_cap_mb = 0,
            .compact_disabled = false,
        };
    }

    /// Releases heap-owned simplified data and mesh references held by the LOD chunk.
    /// Pinned chunks must not be deinitialized while worker jobs still reference them.
    pub fn deinit(self: *LODChunk, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.data) {
            .simplified => |*s| s.deinit(),
            .full => {}, // Full chunks are managed elsewhere
            .empty => {},
        }
        self.* = undefined;
    }

    /// Increments the async-work pin count for this LOD chunk.
    /// Managers must not unload or deinitialize pinned chunks while worker jobs may still reference them.
    pub fn pin(self: *LODChunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    /// Decrements the async-work pin count for this LOD chunk.
    /// Must be paired with a previous `pin`; callers are responsible for avoiding underflow.
    pub fn unpin(self: *LODChunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    /// Reports whether any async job currently pins this LOD chunk.
    /// This is an atomic read suitable for eviction checks.
    pub fn isPinned(self: *const LODChunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    pub fn requestCancellation(self: *LODChunk) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn resetCancellation(self: *LODChunk) void {
        self.cancel_requested.store(false, .release);
    }

    pub fn cancellationRequested(self: *const LODChunk) bool {
        return self.cancel_requested.load(.acquire);
    }

    /// Returns the immutable map key corresponding to this chunk's region coordinates and LOD level.
    /// The key can be used to look up the same chunk in manager maps.
    pub fn key(self: *const LODChunk) LODRegionKey {
        return .{ .rx = self.region_x, .rz = self.region_z, .lod = self.lod_level };
    }

    /// Returns the current lifecycle state of this LOD chunk.
    /// The value drives scheduler decisions such as generation, meshing, upload, and rendering.
    pub fn getState(self: *const LODChunk) LODState {
        return self.state;
    }

    /// Sets the lifecycle state used by LOD scheduling and rendering.
    /// Call from the manager/update thread that owns the chunk maps.
    pub fn setState(self: *LODChunk, state: LODState) void {
        self.state = state;
    }

    /// Reports whether generation, meshing, or upload work is currently in flight for this chunk.
    /// Eviction code should keep in-flight chunks until work completes or is cancelled.
    pub fn isInFlight(self: *const LODChunk) bool {
        return self.state == .generating or self.state == .meshing or self.state == .uploading;
    }

    /// Reports whether this chunk has uploaded mesh data ready for rendering.
    /// This is a state query only; it does not validate the mesh handle.
    pub fn isRenderable(self: *const LODChunk) bool {
        return self.state == .renderable;
    }

    /// Returns the LOD level represented by this region.
    /// Higher levels cover larger areas with more simplified geometry.
    pub fn lodLevel(self: *const LODChunk) LODLevel {
        return self.lod_level;
    }

    /// Returns how many direct finer children are currently renderable.
    /// Parent fallback rendering uses this count to decide coverage and fade behavior.
    pub fn readyChildren(self: *const LODChunk) u8 {
        return self.ready_children;
    }

    /// Returns the normalized fade progress for parent/child LOD hierarchy transitions.
    /// Child regions fade in while fully covered parents fade out according to remaining transition frames.
    pub fn transitionFadeProgress(self: *const LODChunk) f32 {
        if (self.transition_frames_remaining == 0) return 1.0;
        const remaining = @as(f32, @floatFromInt(self.transition_frames_remaining));
        const total = @as(f32, @floatFromInt(TRANSITION_FADE_FRAMES));
        const t = @min(remaining / total, 1.0);
        if (self.lod_level != .lod1 and self.ready_children >= 4) return t;
        return 1.0 - t;
    }

    /// Adjusts the count of renderable direct child regions, clamped to `[0, 4]`.
    /// Crossing into full child coverage starts a transition fade; losing coverage cancels it.
    pub fn adjustReadyChildren(self: *LODChunk, delta: i8) void {
        const before = self.ready_children;
        if (delta > 0) {
            self.ready_children = @min(self.ready_children + @as(u8, @intCast(delta)), 4);
        } else if (delta < 0) {
            const amount: u8 = @intCast(-delta);
            self.ready_children = if (amount >= self.ready_children) 0 else self.ready_children - amount;
        }
        if (before < 4 and self.ready_children >= 4) {
            self.transition_frames_remaining = TRANSITION_FADE_FRAMES;
        } else if (self.ready_children < 4) {
            self.transition_frames_remaining = 0;
        }
    }

    /// Marks this chunk renderable after mesh upload completes.
    /// Sets child readiness, starts a transition fade, and moves lifecycle state to `.renderable`.
    pub fn markRenderable(self: *LODChunk, ready_children: u8) void {
        self.ready_children = @min(ready_children, 4);
        self.transition_frames_remaining = TRANSITION_FADE_FRAMES;
        self.state = .renderable;
    }

    /// Advances transition fading by one render/update tick.
    /// Does nothing once the transition counter has reached zero.
    pub fn tickTransition(self: *LODChunk) void {
        if (self.transition_frames_remaining > 0) self.transition_frames_remaining -= 1;
    }

    /// Reports whether all four direct finer children cover this region.
    /// Partial child coverage must never hide the parent: quality thresholds
    /// may tune transitions, but cannot create a terrain hole.
    pub fn isCoveredByFinerLOD(self: *const LODChunk, fallback_missing_child_threshold: f32) bool {
        _ = fallback_missing_child_threshold;
        if (self.lod_level == .lod0) return false;
        return self.ready_children >= 4 and self.transition_frames_remaining == 0;
    }

    /// Marks source data dirty after chunk-derived ingestion or edits.
    /// Also marks persistent cache storage dirty so the manager can flush updated source data.
    pub fn markSourceDirty(self: *LODChunk) void {
        self.dirty = true;
        self.store_dirty = true;
        self.store_size_limited = false;
        self.bumpSourceRevision();
    }

    /// Advances the immutable source identity. A fresh source revision is
    /// allowed to retry compact rendering after a device-local failure.
    pub fn bumpSourceRevision(self: *LODChunk) void {
        self.source_revision +%= 1;
        self.compact_disabled = false;
    }

    /// Sets the ready-child count directly, clamped to four direct children.
    /// Used when reconstructing or synchronizing hierarchy state from manager bookkeeping.
    pub fn setReadyChildren(self: *LODChunk, ready_children: u8) void {
        self.ready_children = @min(ready_children, 4);
    }

    /// World-space bounds structure for LOD regions
    pub const WorldBounds = struct {
        min_x: i32,
        min_z: i32,
        max_x: i32,
        max_z: i32,
        min_y: f32,
        max_y: f32,
    };

    /// Get the world-space bounds of this LOD region
    pub fn worldBounds(self: *const LODChunk) WorldBounds {
        const scale: i32 = @intCast(self.lod_level.chunksPerSide());
        const size: i32 = scale * CHUNK_SIZE_X;
        return .{
            .min_x = self.region_x * size,
            .min_z = self.region_z * size,
            .max_x = self.region_x * size + size,
            .max_z = self.region_z * size + size,
            .min_y = self.min_height,
            .max_y = self.max_height,
        };
    }

    /// Recomputes world-space min/max height bounds from simplified source data.
    /// Full or empty chunks leave existing bounds unchanged; call after replacing simplified data.
    pub fn updateHeightBoundsFromData(self: *LODChunk) void {
        switch (self.data) {
            .simplified => |*data| {
                var min_height: f32 = std.math.floatMax(f32);
                var max_height: f32 = -std.math.floatMax(f32);
                if (data.scene_grid) |grid| if (grid.heightBounds()) |bounds| {
                    min_height = bounds.min;
                    max_height = bounds.max;
                };
                if (data.hasVerticalSpans()) {
                    const counts = data.vertical_span_counts.?;
                    const spans = data.vertical_spans.?;
                    for (counts, 0..) |span_count, column_idx| {
                        var span_idx: usize = 0;
                        while (span_idx < span_count) : (span_idx += 1) {
                            const span = spans[column_idx * world_core.MAX_LOD_VERTICAL_SPANS + span_idx];
                            min_height = @min(min_height, span.min_height);
                            max_height = @max(max_height, span.max_height);
                        }
                    }
                }
                for (data.heightmap) |height| {
                    min_height = @min(min_height, height);
                    max_height = @max(max_height, height);
                }
                if (min_height <= max_height) {
                    self.min_height = min_height;
                    self.max_height = max_height;
                }
            },
            else => {},
        }
    }

    /// Returns the full-detail chunk-coordinate bounds covered by this LOD region.
    /// Bounds are inclusive and derived from region coordinates plus chunks-per-side for the LOD level.
    pub fn chunkBounds(self: *const LODChunk) ChunkBounds {
        return .{
            .min_x = self.region_x * @as(i32, @intCast(self.lod_level.chunksPerSide())),
            .min_z = self.region_z * @as(i32, @intCast(self.lod_level.chunksPerSide())),
            .max_x = (self.region_x + 1) * @as(i32, @intCast(self.lod_level.chunksPerSide())) - 1,
            .max_z = (self.region_z + 1) * @as(i32, @intCast(self.lod_level.chunksPerSide())) - 1,
        };
    }
};

/// Configuration interface for LOD system to decouple settings from logic.
pub const ILODConfig = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getRadii: *const fn (ptr: *anyopaque) [LODLevel.count]i32,
        getChunkRenderRadius: *const fn (ptr: *anyopaque) i32,
        getActiveLODCount: *const fn (ptr: *anyopaque) u32,
        setActiveLODCount: *const fn (ptr: *anyopaque, count: u32) void,
        setChunkRenderRadius: *const fn (ptr: *anyopaque, radius: i32) void,
        setLOD0Radius: *const fn (ptr: *anyopaque, radius: i32) void,
        setRadii: *const fn (ptr: *anyopaque, radii: [LODLevel.count]i32) void,
        getLODForDistance: *const fn (ptr: *anyopaque, dist_chunks: i32) LODLevel,
        isInRange: *const fn (ptr: *anyopaque, dist_chunks: i32) bool,
        getMaxUploadsPerFrame: *const fn (ptr: *anyopaque) u32,
        calculateMaskRadius: *const fn (ptr: *anyopaque) f32,
        getQEMTarget: *const fn (ptr: *anyopaque, lod: LODLevel) u32,
        getQEMMinInputTriangles: *const fn (ptr: *anyopaque) u32,
        getHorizontalDetail: *const fn (ptr: *anyopaque, lod: LODLevel) u32,
        getSampleDensity: *const fn (ptr: *anyopaque, lod: LODLevel) f32,
        getCompactTilesEnabled: *const fn (ptr: *anyopaque) bool,
        getVerticalSpanBudget: *const fn (ptr: *anyopaque) u8,
        getMeshPath: *const fn (ptr: *anyopaque) LODMeshPath,
        getFogStartPercent: *const fn (ptr: *anyopaque, lod: LODLevel) f32,
        getFallbackMissingChildThreshold: *const fn (ptr: *anyopaque) f32,
        getMemoryBudgetMB: *const fn (ptr: *anyopaque) u32,
        getLODStoreSizeCapMB: *const fn (ptr: *anyopaque) u32,
    };

    /// Returns configured outer radii for every LOD level in chunks.
    /// Callers should use `getActiveLODCount` to know how many entries are currently active.
    pub fn getRadii(self: ILODConfig) [LODLevel.count]i32 {
        return self.vtable.getRadii(self.ptr);
    }
    /// Returns the high-detail chunk render radius that LOD terrain must avoid overlapping.
    /// Shader masking and eviction use this to preserve the full-detail chunk ring.
    pub fn getChunkRenderRadius(self: ILODConfig) i32 {
        return self.vtable.getChunkRenderRadius(self.ptr);
    }
    /// Returns the number of LOD levels currently enabled by configuration.
    /// Implementations clamp the value to at least one and at most `LODLevel.count`.
    pub fn getActiveLODCount(self: ILODConfig) u32 {
        return self.vtable.getActiveLODCount(self.ptr);
    }
    /// Sets how many LOD levels should participate in scheduling and rendering.
    /// Implementations should clamp out-of-range values to the supported LOD count.
    pub fn setActiveLODCount(self: ILODConfig, count: u32) void {
        self.vtable.setActiveLODCount(self.ptr, count);
    }
    /// Sets the full-detail chunk render radius used by LOD masking and radius expansion.
    /// Implementations should clamp invalid radii to a positive value.
    pub fn setChunkRenderRadius(self: ILODConfig, radius: i32) void {
        self.vtable.setChunkRenderRadius(self.ptr, radius);
    }
    /// Sets the outer radius for the LOD0 ring.
    /// This affects near-distance LOD scheduling without changing the full-detail chunk radius.
    pub fn setLOD0Radius(self: ILODConfig, radius: i32) void {
        self.vtable.setLOD0Radius(self.ptr, radius);
    }
    /// Replaces all configured LOD outer radii at once.
    /// Callers must provide radii in increasing order if they want monotonic distance selection.
    pub fn setRadii(self: ILODConfig, radii: [LODLevel.count]i32) void {
        self.vtable.setRadii(self.ptr, radii);
    }
    /// Selects the LOD level for a distance from the player measured in chunks.
    /// Distances beyond active radii resolve to the coarsest active LOD.
    pub fn getLODForDistance(self: ILODConfig, dist_chunks: i32) LODLevel {
        return self.vtable.getLODForDistance(self.ptr, dist_chunks);
    }
    /// Reports whether a chunk-distance lies inside the active LOD horizon.
    /// Used before scheduling or retaining distant LOD regions.
    pub fn isInRange(self: ILODConfig, dist_chunks: i32) bool {
        return self.vtable.isInRange(self.ptr, dist_chunks);
    }
    /// Returns the maximum number of LOD uploads the manager should attempt per frame.
    /// This is a scheduler throttle, separate from byte-budget throttling.
    pub fn getMaxUploadsPerFrame(self: ILODConfig) u32 {
        return self.vtable.getMaxUploadsPerFrame(self.ptr);
    }

    /// Calculate the masking radius used by shaders to discard LOD pixels overlapping with high-detail chunks.
    /// This is a pure function based on config state, extracted for testability.
    pub fn calculateMaskRadius(self: ILODConfig) f32 {
        return self.vtable.calculateMaskRadius(self.ptr);
    }

    /// Returns the target triangle budget for QEM simplification at one LOD level.
    /// A value of zero means that level should not use QEM reduction.
    pub fn getQEMTarget(self: ILODConfig, lod: LODLevel) u32 {
        return self.vtable.getQEMTarget(self.ptr, lod);
    }

    /// Returns the minimum input triangle count required before QEM simplification is attempted.
    /// Smaller meshes use the cheaper non-QEM path to avoid unnecessary work.
    pub fn getQEMMinInputTriangles(self: ILODConfig) u32 {
        return self.vtable.getQEMMinInputTriangles(self.ptr);
    }

    /// Returns the horizontal sample resolution used to generate a mesh for one LOD level.
    /// Higher values preserve more terrain detail at higher CPU/GPU cost.
    pub fn getHorizontalDetail(self: ILODConfig, lod: LODLevel) u32 {
        return self.vtable.getHorizontalDetail(self.ptr, lod);
    }
    /// Returns the source-sample density used before meshing. Far LODs may
    /// reduce this independently of their render radius.
    pub fn getSampleDensity(self: ILODConfig, lod: LODLevel) f32 {
        return self.vtable.getSampleDensity(self.ptr, lod);
    }
    /// Returns whether far LODs may use compact GPU tiles. Callers can disable
    /// them for retained-overlay scenes that require the expanded fallback.
    pub fn getCompactTilesEnabled(self: ILODConfig) bool {
        return self.vtable.getCompactTilesEnabled(self.ptr);
    }

    /// Returns the maximum number of vertical spans retained per LOD column.
    /// Implementations clamp this to the storage capacity of `LODSimplifiedData`.
    pub fn getVerticalSpanBudget(self: ILODConfig) u8 {
        return self.vtable.getVerticalSpanBudget(self.ptr);
    }

    /// Returns which mesh-generation algorithm the LOD manager should use.
    /// The value selects between column-span, QEM, or other backend-supported paths.
    pub fn getMeshPath(self: ILODConfig) LODMeshPath {
        return self.vtable.getMeshPath(self.ptr);
    }

    /// Returns where fog should begin within an LOD level's radius, as a fraction in `[0, 1]`.
    /// Renderers use this to hide distant LOD transitions and horizon cutoffs.
    pub fn getFogStartPercent(self: ILODConfig, lod: LODLevel) f32 {
        return self.vtable.getFogStartPercent(self.ptr, lod);
    }

    /// Returns the fraction of missing finer children allowed before a parent fallback remains visible.
    /// Values are clamped by concrete implementations to `[0, 1]`.
    pub fn getFallbackMissingChildThreshold(self: ILODConfig) f32 {
        return self.vtable.getFallbackMissingChildThreshold(self.ptr);
    }

    /// Returns the approximate memory budget for LOD meshes and source data in MiB.
    /// The manager uses this to decide when to shrink radii or evict regions.
    pub fn getMemoryBudgetMB(self: ILODConfig) u32 {
        return self.vtable.getMemoryBudgetMB(self.ptr);
    }

    /// Returns the persistent LOD cache store size cap in MiB.
    /// Cache maintenance uses this to bound disk usage for source-data containers.
    pub fn getLODStoreSizeCapMB(self: ILODConfig) u32 {
        return self.vtable.getLODStoreSizeCapMB(self.ptr);
    }
};

/// Returns the active LOD count as a `usize`, clamped to the supported range.
/// Use this when indexing fixed arrays whose length is `LODLevel.count`.
pub fn activeLODCount(config: ILODConfig) usize {
    return @intCast(std.math.clamp(config.getActiveLODCount(), 1, LODLevel.count));
}

/// Concrete implementation of LOD system configuration.
pub const LODConfig = struct {
    pub const default_chunk_render_radius: i32 = 16;
    pub const default_horizon_radius: i32 = 512;
    pub const minimum_horizon_radius: i32 = 256;
    /// Production user setting limit. Larger horizons remain available only to
    /// explicit benchmark/diagnostic configurations until additional coarse
    /// levels remove the current logical-memory and compact-pool pressure.
    pub const maximum_user_horizon_radius: i32 = 512;
    pub const target_lod1_radius: i32 = 96; // keep 2-block cells visible farther out.
    pub const target_lod2_radius: i32 = 256;
    pub const target_lod3_radius: i32 = 512;
    /// Keep enough horizon beyond full detail for the complete LOD ladder to
    /// remain useful as users raise render distance.
    pub const horizon_render_distance_scale: i64 = 32;

    /// Radius of real full-detail chunks. LOD0 is a separate 1-block-column
    /// LOD ring that extends beyond this radius.
    chunk_render_radius: i32 = default_chunk_render_radius,

    radii: [LODLevel.count]i32 = .{ 32, target_lod1_radius, target_lod2_radius, target_lod3_radius, default_horizon_radius },

    memory_budget_mb: u32 = 256,

    lod_store_size_cap_mb: u32 = @import("lod_store.zig").DEFAULT_STORE_SIZE_CAP_MB,

    max_uploads_per_frame: u32 = 32,

    fog_transitions: bool = true,

    /// Fog start position as percentage of LOD radius (0.0-1.0) where fog begins.
    /// Values closer to 0.0 start fog near the player; 1.0 disables fog for that level.
    fog_start_percent: [LODLevel.count]f32 = .{ 0.55, 0.48, 0.38, 0.28, 0.22 },

    horizontal_detail: [LODLevel.count]u32 = .{ 33, 65, 65, 129, 129 },

    /// LOD3 reduces worker input where four-block cells remain visually stable.
    /// Keep the outer horizon at its full 65-sample grid: reducing it to 17
    /// samples creates 32-block plateaus and visibly detached height seams.
    sample_density: [LODLevel.count]f32 = .{ 1.0, 1.0, 1.0, 0.5, 1.0 },

    compact_tiles_enabled: bool = true,

    vertical_span_budget: u8 = 4,

    mesh_path: LODMeshPath = .column_spans,

    qem_triangle_targets: [LODLevel.count]u32 = .{ 0, 2000, 800, 200, 64 },

    qem_min_input_triangles: u32 = 50,

    skip_cutout_lod2: bool = false,

    skip_lighting_lod3: bool = false,

    // The coarsest level remains active even when it shares the horizon radius
    // with its child: it is the fast, large-area fallback while that child loads.
    active_lod_count: u32 = LODLevel.count,

    /// Maximum fraction of direct finer child regions that may be missing before
    /// a coarser parent must remain visible as fallback terrain.
    fallback_missing_child_threshold: f32 = 0.2,

    /// Returns the configured QEM triangle target for one LOD level.
    /// Used by mesh builders to choose simplification aggressiveness.
    pub fn getQEMTarget(self: *const LODConfig, lod: LODLevel) u32 {
        return self.qem_triangle_targets[@intFromEnum(lod)];
    }

    /// Expands a full-detail render distance into the default LOD radius ladder.
    /// Ordinary settings use the qualified user horizon; benchmarks and
    /// diagnostics request larger ladders explicitly through radiiForDistances.
    pub fn radiiForRenderDistance(distance: i32) [LODLevel.count]i32 {
        return radiiForDistances(distance, normalizeUserHorizonDistance(distance, default_horizon_radius));
    }

    /// Returns the minimum useful distant-LOD horizon for a full-detail radius.
    /// Arithmetic saturates at the coordinate representation limit rather than
    /// introducing an arbitrary settings cap.
    pub fn recommendedHorizonDistance(distance: i32) i32 {
        const requested = @as(i64, @max(distance, 1));
        const scaled = @min(requested * horizon_render_distance_scale, @as(i64, std.math.maxInt(i32)));
        return @intCast(@max(@as(i64, minimum_horizon_radius), scaled));
    }

    /// Normalizes the explicit outer LOD limit without silently expanding it
    /// to the recommended long-distance profile.
    pub fn normalizeHorizonDistance(render_distance: i32, horizon_distance: i32) i32 {
        return @max(horizon_distance, @max(render_distance, minimum_horizon_radius));
    }

    /// Clamps the normal user-facing distant terrain control to the currently
    /// qualified production range. Benchmark configs use the uncapped helper.
    pub fn normalizeUserHorizonDistance(render_distance: i32, horizon_distance: i32) i32 {
        return @min(normalizeHorizonDistance(render_distance, horizon_distance), @max(render_distance, maximum_user_horizon_radius));
    }

    /// Steps the explicit outer LOD limit geometrically. The recommendation is
    /// a preset default, not a mandatory minimum, so users can trade reach for
    /// contiguous fill and lower generation pressure.
    pub fn stepHorizonDistance(render_distance: i32, horizon_distance: i32, increase: bool) i32 {
        const minimum = @max(render_distance, minimum_horizon_radius);
        const maximum = @max(render_distance, maximum_user_horizon_radius);
        if (horizon_distance > maximum) return maximum;
        const current = std.math.clamp(horizon_distance, minimum, maximum);
        if (!increase) return @max(minimum, @divFloor(current, 2));
        return @intCast(@min(@as(i64, current) * 2, @as(i64, maximum)));
    }

    /// Expands full-detail and horizon distances into monotonically increasing LOD radii.
    /// Radii are expressed in chunks and are clamped so they do not exceed the horizon.
    pub fn radiiForDistances(distance: i32, horizon_distance: i32) [LODLevel.count]i32 {
        const requested = @max(distance, 1);
        const lod0_target = @max(@as(i64, requested) * 3, @as(i64, requested) + 16);
        const lod0 = @as(i32, @intCast(@min(lod0_target, @as(i64, @max(horizon_distance, requested)))));
        const horizon = @max(horizon_distance, lod0);
        const max_radius_i64 = @as(i64, horizon);
        const lod1_target = @max(@as(i64, lod0) * 2, @as(i64, target_lod1_radius));
        const lod1 = @as(i32, @intCast(@min(lod1_target, max_radius_i64)));
        const lod2_target = @max(@as(i64, lod1) * 2, @as(i64, target_lod2_radius));
        const lod2 = @as(i32, @intCast(@min(lod2_target, max_radius_i64)));
        const lod3_target = @max(@as(i64, lod2) * 2, @as(i64, target_lod3_radius));
        const lod3 = @as(i32, @intCast(@min(lod3_target, max_radius_i64)));
        return .{ lod0, lod1, lod2, lod3, horizon };
    }

    /// Returns how many LOD levels should be active for a render-distance setting.
    pub fn activeCountForRenderDistance(distance: i32) u32 {
        _ = distance;
        return LODLevel.count;
    }

    /// Returns the coarsest supported LOD level.
    /// Use as a fallback when a distance exceeds all configured active radii.
    pub fn coarsestLOD() LODLevel {
        return @enumFromInt(@as(u3, @intCast(LODLevel.count - 1)));
    }

    /// Selects the concrete LOD level for a chunk distance using this config's active radii.
    /// Distances beyond active radii resolve to the coarsest active LOD.
    pub fn getLODForDistance(self: *const LODConfig, dist_chunks: i32) LODLevel {
        const active_lod_count = activeLODCount(self.interfaceConst());
        for (0..active_lod_count) |i| {
            if (dist_chunks <= self.radii[i]) return @enumFromInt(@as(u3, @intCast(i)));
        }
        return @enumFromInt(@as(u3, @intCast(active_lod_count - 1)));
    }

    /// Reports whether a chunk distance lies inside this config's active LOD horizon.
    /// The horizon is the outer radius of the coarsest active LOD.
    pub fn isInRange(self: *const LODConfig, dist_chunks: i32) bool {
        return dist_chunks <= self.radii[activeLODCount(self.interfaceConst()) - 1];
    }

    /// Returns the interface for this concrete config.
    pub fn interface(self: *LODConfig) ILODConfig {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn interfaceConst(self: *const LODConfig) ILODConfig {
        return .{
            .ptr = @constCast(self),
            .vtable = &VTABLE,
        };
    }

    const VTABLE = ILODConfig.VTable{
        .getRadii = getRadiiWrapper,
        .getChunkRenderRadius = getChunkRenderRadiusWrapper,
        .getActiveLODCount = getActiveLODCountWrapper,
        .setActiveLODCount = setActiveLODCountWrapper,
        .setChunkRenderRadius = setChunkRenderRadiusWrapper,
        .setLOD0Radius = setLOD0RadiusWrapper,
        .setRadii = setRadiiWrapper,
        .getLODForDistance = getLODForDistanceWrapper,
        .isInRange = isInRangeWrapper,
        .getMaxUploadsPerFrame = getMaxUploadsPerFrameWrapper,
        .calculateMaskRadius = calculateMaskRadiusWrapper,
        .getQEMTarget = getQEMTargetWrapper,
        .getQEMMinInputTriangles = getQEMMinInputTrianglesWrapper,
        .getHorizontalDetail = getHorizontalDetailWrapper,
        .getSampleDensity = getSampleDensityWrapper,
        .getCompactTilesEnabled = getCompactTilesEnabledWrapper,
        .getVerticalSpanBudget = getVerticalSpanBudgetWrapper,
        .getMeshPath = getMeshPathWrapper,
        .getFogStartPercent = getFogStartPercentWrapper,
        .getFallbackMissingChildThreshold = getFallbackMissingChildThresholdWrapper,
        .getMemoryBudgetMB = getMemoryBudgetMBWrapper,
        .getLODStoreSizeCapMB = getLODStoreSizeCapMBWrapper,
    };

    fn getRadiiWrapper(ptr: *anyopaque) [LODLevel.count]i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.radii;
    }
    fn getChunkRenderRadiusWrapper(ptr: *anyopaque) i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.chunk_render_radius;
    }
    fn getActiveLODCountWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.active_lod_count, 1, LODLevel.count);
    }
    fn setActiveLODCountWrapper(ptr: *anyopaque, count: u32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.active_lod_count = std.math.clamp(count, 1, LODLevel.count);
    }
    fn setChunkRenderRadiusWrapper(ptr: *anyopaque, radius: i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.chunk_render_radius = @max(radius, 1);
    }
    fn setLOD0RadiusWrapper(ptr: *anyopaque, radius: i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.radii[0] = radius;
    }
    fn setRadiiWrapper(ptr: *anyopaque, radii: [LODLevel.count]i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.radii = radii;
    }
    fn getLODForDistanceWrapper(ptr: *anyopaque, dist_chunks: i32) LODLevel {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.getLODForDistance(dist_chunks);
    }
    fn isInRangeWrapper(ptr: *anyopaque, dist_chunks: i32) bool {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.isInRange(dist_chunks);
    }
    fn getMaxUploadsPerFrameWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.max_uploads_per_frame;
    }
    fn calculateMaskRadiusWrapper(ptr: *anyopaque) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        // Keep a small overlap so the chunk ring and LOD ring blend instead of
        // leaving a camera-centered dead zone between them.
        const overlap_chunks = @max(self.chunk_render_radius - 2, 0);
        return @as(f32, @floatFromInt(overlap_chunks)) * @as(f32, @floatFromInt(CHUNK_SIZE_X));
    }
    fn getQEMTargetWrapper(ptr: *anyopaque, lod: LODLevel) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.getQEMTarget(lod);
    }
    fn getQEMMinInputTrianglesWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.qem_min_input_triangles;
    }
    fn getHorizontalDetailWrapper(ptr: *anyopaque, lod: LODLevel) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.horizontal_detail[@intFromEnum(lod)];
    }
    fn getSampleDensityWrapper(ptr: *anyopaque, lod: LODLevel) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.sample_density[@intFromEnum(lod)], 0.0625, 1.0);
    }
    fn getCompactTilesEnabledWrapper(ptr: *anyopaque) bool {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.compact_tiles_enabled;
    }
    fn getVerticalSpanBudgetWrapper(ptr: *anyopaque) u8 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return @min(self.vertical_span_budget, @as(u8, @intCast(world_core.MAX_LOD_VERTICAL_SPANS)));
    }
    fn getMeshPathWrapper(ptr: *anyopaque) LODMeshPath {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.mesh_path;
    }
    fn getFogStartPercentWrapper(ptr: *anyopaque, lod: LODLevel) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.fog_start_percent[@intFromEnum(lod)];
    }
    fn getFallbackMissingChildThresholdWrapper(ptr: *anyopaque) f32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return std.math.clamp(self.fallback_missing_child_threshold, 0.0, 1.0);
    }
    fn getMemoryBudgetMBWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.memory_budget_mb;
    }
    fn getLODStoreSizeCapMBWrapper(ptr: *anyopaque) u32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.lod_store_size_cap_mb;
    }
};

// Tests
test "LODLevel scale calculations" {
    try std.testing.expectEqual(@as(u32, 1), LODLevel.lod0.scale());
    try std.testing.expectEqual(@as(u32, 2), LODLevel.lod1.scale());
    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod2.scale());
    try std.testing.expectEqual(@as(u32, 8), LODLevel.lod3.scale());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod4.scale());

    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod0.totalChunks());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod1.totalChunks());
    try std.testing.expectEqual(@as(u32, 64), LODLevel.lod2.totalChunks());
    try std.testing.expectEqual(@as(u32, 256), LODLevel.lod3.totalChunks());
    try std.testing.expectEqual(@as(u32, 1024), LODLevel.lod4.totalChunks());
}

test "LODRegionKey from chunk coords" {
    const key1 = LODRegionKey.fromChunkCoords(5, 7, .lod1);
    try std.testing.expectEqual(@as(i32, 1), key1.rx); // 5 / 4 = 1
    try std.testing.expectEqual(@as(i32, 1), key1.rz); // 7 / 4 = 1

    const key2 = LODRegionKey.fromChunkCoords(-3, -5, .lod2);
    try std.testing.expectEqual(@as(i32, -1), key2.rx); // -3 / 8 = -1
    try std.testing.expectEqual(@as(i32, -1), key2.rz); // -5 / 8 = -1
}

test "LODRegionKey parent and child keys handle negative coordinates" {
    const child = LODRegionKey{ .rx = -1, .rz = -3, .lod = .lod1 };
    const parent = child.parentKey().?;
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -2, .lod = .lod2 }, parent);

    const children = parent.childKeys().?;
    try std.testing.expectEqual(LODRegionKey{ .rx = -2, .rz = -4, .lod = .lod1 }, children[0]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -4, .lod = .lod1 }, children[1]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -2, .rz = -3, .lod = .lod1 }, children[2]);
    try std.testing.expectEqual(LODRegionKey{ .rx = -1, .rz = -3, .lod = .lod1 }, children[3]);
}

test "LODConfig distance calculation" {
    const config = LODConfig{};
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(50));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(100));
}

test "LODConfig keeps outer horizon cells below detached-plateau scale" {
    var config = LODConfig{};
    const interface = config.interface();
    const width = world_core.LODSimplifiedData.getGridSizeForDensity(.lod4, interface.getSampleDensity(.lod4));
    const cell_size = regionSizeBlocks(.lod4) / (width - 1);

    try std.testing.expectEqual(@as(u32, 65), width);
    try std.testing.expectEqual(@as(u32, 8), cell_size);
}

test "LODConfig distance calculation respects active LOD count" {
    const config = LODConfig{
        .radii = .{ 16, 32, 64, 128, 256 },
        .active_lod_count = 2,
    };

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(100));
    try std.testing.expect(!config.isInRange(100));
}

test "ILODConfig exposes clamped active LOD count" {
    var config = LODConfig{ .active_lod_count = 2 };
    var interface = config.interface();
    try std.testing.expectEqual(@as(u32, 2), interface.getActiveLODCount());

    config.active_lod_count = 0;
    interface = config.interface();
    try std.testing.expectEqual(@as(u32, 1), interface.getActiveLODCount());

    config.active_lod_count = LODLevel.count + 10;
    interface = config.interface();
    try std.testing.expectEqual(@as(u32, LODLevel.count), interface.getActiveLODCount());
}

test "LODConfig expands render distance into distant LOD horizon" {
    try std.testing.expectEqual(@as(u32, LODLevel.count), LODConfig.activeCountForRenderDistance(8));
    try std.testing.expectEqual(@as(u32, LODLevel.count), LODConfig.activeCountForRenderDistance(32));

    const low_radii = LODConfig.radiiForRenderDistance(8);
    try std.testing.expectEqual(@as(i32, 24), low_radii[0]);
    try std.testing.expectEqual(@as(i32, 96), low_radii[1]);
    try std.testing.expectEqual(@as(i32, 256), low_radii[2]);
    try std.testing.expectEqual(@as(i32, 512), low_radii[3]);
    try std.testing.expectEqual(@as(i32, 512), low_radii[4]);

    const radii = LODConfig.radiiForRenderDistance(32);
    try std.testing.expectEqual(@as(i32, 96), radii[0]);
    try std.testing.expectEqual(@as(i32, 192), radii[1]);
    try std.testing.expectEqual(@as(i32, 384), radii[2]);
    try std.testing.expectEqual(@as(i32, 512), radii[3]);
    try std.testing.expectEqual(@as(i32, 512), radii[4]);

    try std.testing.expectEqual(@as(i32, 256), LODConfig.recommendedHorizonDistance(8));
    try std.testing.expectEqual(@as(i32, 131_072), LODConfig.recommendedHorizonDistance(4096));
    try std.testing.expectEqual(std.math.maxInt(i32), LODConfig.recommendedHorizonDistance(std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i32, 4096), LODConfig.normalizeHorizonDistance(4096, 2048));
    try std.testing.expectEqual(@as(i32, 512), LODConfig.stepHorizonDistance(32, 1024, false));
    try std.testing.expectEqual(@as(i32, 256), LODConfig.stepHorizonDistance(32, 512, false));
    try std.testing.expectEqual(@as(i32, 256), LODConfig.stepHorizonDistance(32, 256, false));
    try std.testing.expectEqual(@as(i32, 512), LODConfig.stepHorizonDistance(32, 512, true));
    try std.testing.expectEqual(@as(i32, 256), LODConfig.normalizeUserHorizonDistance(32, 128));
    try std.testing.expectEqual(@as(i32, 512), LODConfig.normalizeUserHorizonDistance(32, 1024));
    try std.testing.expectEqual(@as(i32, 600), LODConfig.normalizeUserHorizonDistance(600, 512));

    const custom_horizon = LODConfig.radiiForDistances(12, 1024);
    try std.testing.expectEqual(@as(i32, 36), custom_horizon[0]);
    try std.testing.expectEqual(@as(i32, 96), custom_horizon[1]);
    try std.testing.expectEqual(@as(i32, 256), custom_horizon[2]);
    try std.testing.expectEqual(@as(i32, 512), custom_horizon[3]);
    try std.testing.expectEqual(@as(i32, 1024), custom_horizon[4]);

    const beyond_horizon = LODConfig.radiiForDistances(4096, 2048);
    try std.testing.expectEqual([_]i32{4096} ** LODLevel.count, beyond_horizon);

    const integer_limit = LODConfig.radiiForDistances(std.math.maxInt(i32), 2048);
    try std.testing.expectEqual([_]i32{std.math.maxInt(i32)} ** LODLevel.count, integer_limit);
}

test "LODConfig keeps the coarse fallback when tail radii match" {
    var config = LODConfig{ .active_lod_count = LODLevel.count };
    const interface = config.interface();

    interface.setRadii(.{ 96, 192, 256, 256, 256 });
    try std.testing.expectEqual(@as(u32, LODLevel.count), interface.getActiveLODCount());
    try std.testing.expectEqual(@as(i32, 256), interface.getRadii()[@intFromEnum(LODLevel.lod4)]);

    interface.setRadii(.{ 30, 96, 256, 512, 512 });
    try std.testing.expectEqual(@as(u32, LODLevel.count), interface.getActiveLODCount());

    interface.setRadii(.{ 36, 96, 256, 512, 1024 });
    try std.testing.expectEqual(@as(u32, LODLevel.count), interface.getActiveLODCount());
}

test "ChunkBounds intersects radius radially" {
    const axis_region = ChunkBounds{ .min_x = 16, .min_z = 0, .max_x = 31, .max_z = 15 };
    try std.testing.expect(axis_region.intersectsRadius(0, 0, 16));

    const diagonal_region = ChunkBounds{ .min_x = 16, .min_z = 16, .max_x = 31, .max_z = 31 };
    try std.testing.expect(!diagonal_region.intersectsRadius(0, 0, 16));
    try std.testing.expectEqual(@as(i64, 16 * 16 + 16 * 16), diagonal_region.distanceSquaredToPoint(0, 0));

    const extreme_region = ChunkBounds{
        .min_x = std.math.maxInt(i32),
        .min_z = std.math.maxInt(i32),
        .max_x = std.math.maxInt(i32),
        .max_z = std.math.maxInt(i32),
    };
    try std.testing.expectEqual(std.math.maxInt(i64), extreme_region.distanceSquaredToPoint(std.math.minInt(i32), std.math.minInt(i32)));
}

test "ILODConfig.calculateMaskRadius" {
    var config = LODConfig{
        .chunk_render_radius = 16,
        .radii = .{ 16, 40, 80, 160, 512 },
    };
    const interface = config.interface();
    try std.testing.expectEqual(@as(f32, 224.0), interface.calculateMaskRadius());

    config.chunk_render_radius = 32;
    try std.testing.expectEqual(@as(f32, 480.0), interface.calculateMaskRadius());
}

test "ILODConfig exposes fallback missing child threshold" {
    var config = LODConfig{ .fallback_missing_child_threshold = 0.2 };
    var interface = config.interface();
    try std.testing.expectEqual(@as(f32, 0.2), interface.getFallbackMissingChildThreshold());

    config.fallback_missing_child_threshold = -1.0;
    try std.testing.expectEqual(@as(f32, 0.0), interface.getFallbackMissingChildThreshold());

    config.fallback_missing_child_threshold = 2.0;
    try std.testing.expectEqual(@as(f32, 1.0), interface.getFallbackMissingChildThreshold());
}

test "LOD parent remains visible until all direct children are ready" {
    var parent = LODChunk.init(0, 0, .lod4);
    parent.state = .renderable;
    parent.ready_children = 3;
    parent.transition_frames_remaining = 0;

    try std.testing.expect(!parent.isCoveredByFinerLOD(1.0));
    parent.ready_children = 4;
    try std.testing.expect(parent.isCoveredByFinerLOD(0.0));
}

test "ILODConfig exposes LOD quality tuning controls" {
    var config = LODConfig{
        .horizontal_detail = .{ 16, 24, 32, 40, 24 },
        .vertical_span_budget = 99,
        .mesh_path = .qem,
        .compact_tiles_enabled = false,
    };
    const interface = config.interface();

    try std.testing.expectEqual(@as(u32, 32), interface.getHorizontalDetail(.lod2));
    try std.testing.expectEqual(@as(u8, world_core.MAX_LOD_VERTICAL_SPANS), interface.getVerticalSpanBudget());
    try std.testing.expectEqual(LODMeshPath.qem, interface.getMeshPath());
    try std.testing.expect(!interface.getCompactTilesEnabled());
}
