//! LOD Chunk data structures for Distant Horizons-style rendering.
//!
//! LOD levels:
//! - LOD0: Full detail, 2x2 chunks merged
//! - LOD1: 2x block resolution, 4x4 chunks merged
//! - LOD2: 4x block resolution, 8x8 chunks merged
//! - LOD3: 8x block resolution, 16x16 chunks merged, heightmap-only

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const BlockType = @import("block.zig").BlockType;
const BiomeId = @import("worldgen/biome.zig").BiomeId;

/// LOD level enum - higher values = more simplified
pub const LODLevel = enum(u3) {
    lod0 = 0, // Full detail (2x2 chunks = 4 chunks)
    lod1 = 1, // 2x simplified (4x4 chunks = 16 chunks)
    lod2 = 2, // 4x simplified (8x8 chunks = 64 chunks)
    lod3 = 3, // 8x simplified (16x16 chunks = 256 chunks, heightmap only)

    pub const count = 4;

    pub fn scale(self: LODLevel) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }

    pub fn chunksPerSide(self: LODLevel) u32 {
        return self.scale() * 2;
    }

    pub fn totalChunks(self: LODLevel) u32 {
        const side = self.chunksPerSide();
        return side * side;
    }

    pub fn blockSize(self: LODLevel) u32 {
        return self.scale();
    }

    /// Get the region size in blocks for this LOD level
    pub fn regionSizeBlocks(self: LODLevel) u32 {
        return CHUNK_SIZE_X * self.chunksPerSide();
    }
};

/// State for LOD chunks/regions
pub const LODState = enum {
    missing,
    queued_for_generation,
    generating,
    generated,
    queued_for_mesh,
    meshing,
    mesh_ready,
    uploading,
    renderable,
    unloading,
};

/// Simplified data for distant LOD levels (LOD1+).
/// Only stores essential data needed for rendering distant terrain.
pub const LODSimplifiedData = struct {
    /// Width/depth of the data grid (depends on LOD level)
    width: u32,
    /// Heightmap values (one per grid cell)
    heightmap: []f32,
    /// Biome IDs (one per grid cell)
    biomes: []BiomeId,
    /// Top surface block type (one per grid cell)
    top_blocks: []BlockType,
    /// Average color per column (packed RGB for fast rendering)
    colors: []u32,

    allocator: std.mem.Allocator,

    /// Get optimal grid size for a given LOD level.
    /// Get grid size for LOD terrain rendering (balanced for performance).
    /// Grid size must be a divisor of region size to prevent gaps.
    /// - LOD1: 32x32 grid = 2 blocks/cell
    /// - LOD2: 32x32 grid = 4 blocks/cell
    /// - LOD3: 32x32 grid = 8 blocks/cell
    pub fn getGridSize(lod_level: LODLevel) u32 {
        if (lod_level == .lod0) return 16;
        return 32;
    }

    /// Get cell size in blocks for a given LOD level and grid size.
    pub fn getCellSizeBlocks(lod_level: LODLevel) u32 {
        const region_size = lod_level.regionSizeBlocks();
        const grid_size = getGridSize(lod_level);
        return region_size / grid_size;
    }

    pub fn init(allocator: std.mem.Allocator, lod_level: LODLevel) !LODSimplifiedData {
        // Grid size scales with LOD level for consistent 2 blocks per cell
        const grid_size = getGridSize(lod_level);
        const count = grid_size * grid_size;

        return LODSimplifiedData{
            .width = grid_size,
            .heightmap = try allocator.alloc(f32, count),
            .biomes = try allocator.alloc(BiomeId, count),
            .top_blocks = try allocator.alloc(BlockType, count),
            .colors = try allocator.alloc(u32, count),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LODSimplifiedData) void {
        self.allocator.free(self.heightmap);
        self.allocator.free(self.biomes);
        self.allocator.free(self.top_blocks);
        self.allocator.free(self.colors);
        self.* = undefined;
    }

    /// Get heightmap value at grid position
    pub fn getHeight(self: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
        if (gx >= self.width or gz >= self.width) return 0;
        return self.heightmap[gz * self.width + gx];
    }

    /// Set heightmap value at grid position
    pub fn setHeight(self: *LODSimplifiedData, gx: u32, gz: u32, height: f32) void {
        if (gx >= self.width or gz >= self.width) return;
        self.heightmap[gz * self.width + gx] = height;
    }

    /// Calculate total heap memory used by this data structure
    pub fn totalMemoryBytes(self: *const LODSimplifiedData) usize {
        const count = self.width * self.width;
        return count * (@sizeOf(f32) + @sizeOf(BiomeId) + @sizeOf(BlockType) + @sizeOf(u32));
    }
};

/// LOD region key - identifies a region at a specific LOD level
pub const LODRegionKey = struct {
    /// Region X coordinate (in region units, not chunks)
    rx: i32,
    /// Region Z coordinate
    rz: i32,
    /// LOD level
    lod: LODLevel,

    pub fn fromChunkCoords(chunk_x: i32, chunk_z: i32, lod: LODLevel) LODRegionKey {
        const scale: i32 = @intCast(lod.chunksPerSide());
        return .{
            .rx = @divFloor(chunk_x, scale),
            .rz = @divFloor(chunk_z, scale),
            .lod = lod,
        };
    }

    pub fn hash(self: LODRegionKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.rx));
        const uz: u64 = @bitCast(@as(i64, self.rz));
        const ul: u64 = @intFromEnum(self.lod);
        return ux ^ (uz *% 0x9e3779b97f4a7c15) ^ (ul *% 0x517cc1b727220a95);
    }

    pub fn eql(a: LODRegionKey, b: LODRegionKey) bool {
        return a.rx == b.rx and a.rz == b.rz and a.lod == b.lod;
    }

    /// Get the chunk coordinates that this region covers
    pub fn chunkBounds(self: LODRegionKey) struct { min_x: i32, min_z: i32, max_x: i32, max_z: i32 } {
        const scale: i32 = @intCast(self.lod.chunksPerSide());
        return .{
            .min_x = self.rx * scale,
            .min_z = self.rz * scale,
            .max_x = self.rx * scale + scale - 1,
            .max_z = self.rz * scale + scale - 1,
        };
    }
};

/// Context for LODRegionKey HashMap
pub const LODRegionKeyContext = struct {
    pub fn hash(self: @This(), key: LODRegionKey) u64 {
        _ = self;
        return key.hash();
    }

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

    /// Pin count for preventing unload during async work
    pin_count: std.atomic.Value(u32),

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

    /// Dirty flag for re-meshing
    dirty: bool,

    pub fn init(rx: i32, rz: i32, lod: LODLevel) LODChunk {
        return .{
            .region_x = rx,
            .region_z = rz,
            .lod_level = lod,
            .state = .missing,
            .job_token = 0,
            .pin_count = std.atomic.Value(u32).init(0),
            .data = .{ .empty = {} },
            .mesh_handle = 0,
            .dirty = false,
        };
    }

    pub fn deinit(self: *LODChunk, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.data) {
            .simplified => |*s| s.deinit(),
            .full => {}, // Full chunks are managed elsewhere
            .empty => {},
        }
        self.* = undefined;
    }

    pub fn pin(self: *LODChunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    pub fn unpin(self: *LODChunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    pub fn isPinned(self: *const LODChunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    /// World-space bounds structure for LOD regions
    pub const WorldBounds = struct {
        min_x: i32,
        min_z: i32,
        max_x: i32,
        max_z: i32,
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
        };
    }
};

/// Configuration interface for LOD system to decouple settings from logic.
pub const ILODConfig = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getRadii: *const fn (ptr: *anyopaque) [LODLevel.count]i32,
        setLOD0Radius: *const fn (ptr: *anyopaque, radius: i32) void,
        getLODForDistance: *const fn (ptr: *anyopaque, dist_chunks: i32) LODLevel,
        isInRange: *const fn (ptr: *anyopaque, dist_chunks: i32) bool,
        getMaxUploadsPerFrame: *const fn (ptr: *anyopaque) u32,
        calculateMaskRadius: *const fn (ptr: *anyopaque) f32,
    };

    pub fn getRadii(self: ILODConfig) [LODLevel.count]i32 {
        return self.vtable.getRadii(self.ptr);
    }
    pub fn setLOD0Radius(self: ILODConfig, radius: i32) void {
        self.vtable.setLOD0Radius(self.ptr, radius);
    }
    pub fn getLODForDistance(self: ILODConfig, dist_chunks: i32) LODLevel {
        return self.vtable.getLODForDistance(self.ptr, dist_chunks);
    }
    pub fn isInRange(self: ILODConfig, dist_chunks: i32) bool {
        return self.vtable.isInRange(self.ptr, dist_chunks);
    }
    pub fn getMaxUploadsPerFrame(self: ILODConfig) u32 {
        return self.vtable.getMaxUploadsPerFrame(self.ptr);
    }

    /// Calculate the masking radius used by shaders to discard LOD pixels overlapping with high-detail chunks.
    /// This is a pure function based on config state, extracted for testability.
    pub fn calculateMaskRadius(self: ILODConfig) f32 {
        return self.vtable.calculateMaskRadius(self.ptr);
    }
};

/// Concrete implementation of LOD system configuration.
pub const LODConfig = struct {
    /// Radius in chunks for each LOD level
    /// LOD0 = render_distance (user-controlled block chunks)
    /// LOD1/2/3 = Fixed large values for "infinite" terrain view
    radii: [LODLevel.count]i32 = .{ 16, 40, 80, 160 },

    /// Memory budget in MB
    memory_budget_mb: u32 = 256,

    /// Maximum uploads per frame per LOD level
    max_uploads_per_frame: u32 = 8, // Increased from 4 for faster loading

    /// Enable fog-masked transitions
    fog_transitions: bool = true,

    pub fn getLODForDistance(self: *const LODConfig, dist_chunks: i32) LODLevel {
        inline for (0..LODLevel.count) |i| {
            if (dist_chunks <= self.radii[i]) return @enumFromInt(@as(u3, @intCast(i)));
        }
        return .lod3; // Beyond max distance, still use LOD3
    }

    pub fn isInRange(self: *const LODConfig, dist_chunks: i32) bool {
        return dist_chunks <= self.radii[LODLevel.count - 1];
    }

    /// Returns the interface for this concrete config.
    pub fn interface(self: *LODConfig) ILODConfig {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = ILODConfig.VTable{
        .getRadii = getRadiiWrapper,
        .setLOD0Radius = setLOD0RadiusWrapper,
        .getLODForDistance = getLODForDistanceWrapper,
        .isInRange = isInRangeWrapper,
        .getMaxUploadsPerFrame = getMaxUploadsPerFrameWrapper,
        .calculateMaskRadius = calculateMaskRadiusWrapper,
    };

    fn getRadiiWrapper(ptr: *anyopaque) [LODLevel.count]i32 {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        return self.radii;
    }
    fn setLOD0RadiusWrapper(ptr: *anyopaque, radius: i32) void {
        const self: *LODConfig = @ptrCast(@alignCast(ptr));
        self.radii[0] = radius;
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
        // Return radii[0] - 2.0 to ensure a 2-chunk overlap between LODs and block chunks
        return @as(f32, @floatFromInt(self.radii[0])) - 2.0;
    }
};

// Tests
test "LODLevel scale calculations" {
    try std.testing.expectEqual(@as(u32, 1), LODLevel.lod0.scale());
    try std.testing.expectEqual(@as(u32, 2), LODLevel.lod1.scale());
    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod2.scale());
    try std.testing.expectEqual(@as(u32, 8), LODLevel.lod3.scale());

    try std.testing.expectEqual(@as(u32, 4), LODLevel.lod0.totalChunks());
    try std.testing.expectEqual(@as(u32, 16), LODLevel.lod1.totalChunks());
    try std.testing.expectEqual(@as(u32, 64), LODLevel.lod2.totalChunks());
    try std.testing.expectEqual(@as(u32, 256), LODLevel.lod3.totalChunks());
}

test "LODRegionKey from chunk coords" {
    const key1 = LODRegionKey.fromChunkCoords(5, 7, .lod1);
    try std.testing.expectEqual(@as(i32, 1), key1.rx); // 5 / 4 = 1
    try std.testing.expectEqual(@as(i32, 1), key1.rz); // 7 / 4 = 1

    const key2 = LODRegionKey.fromChunkCoords(-3, -5, .lod2);
    try std.testing.expectEqual(@as(i32, -1), key2.rx); // -3 / 8 = -1
    try std.testing.expectEqual(@as(i32, -1), key2.rz); // -5 / 8 = -1
}

test "LODConfig distance calculation" {
    const config = LODConfig{};
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(10));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(20));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(50));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(100));
}

test "ILODConfig.calculateMaskRadius" {
    var config = LODConfig{
        .radii = .{ 16, 40, 80, 160 },
    };
    const interface = config.interface();
    // Implementation returns radii[0] - 2.0
    try std.testing.expectEqual(@as(f32, 14.0), interface.calculateMaskRadius());

    config.radii[0] = 32;
    try std.testing.expectEqual(@as(f32, 30.0), interface.calculateMaskRadius());
}
