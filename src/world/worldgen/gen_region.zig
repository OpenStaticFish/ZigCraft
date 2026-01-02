//! GenRegion: Luanti-style generation region (80x256x80 = 5x5 chunks)
//! Per worldgen-luanti-style.md:
//! - Generate bigger than you store for coherent terrain
//! - Strict phase separation: Terrain -> Biome -> Surface -> Caves -> Features
//! - Terrain shape is biome-agnostic

const std = @import("std");
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;
const Noise = @import("noise.zig").Noise;
const smoothstep = @import("noise.zig").smoothstep;
const clamp01 = @import("noise.zig").clamp01;

/// GenRegion dimensions: 5x5 chunks = 80x80 blocks horizontally
pub const REGION_CHUNKS = 5;
pub const REGION_SIZE_X = CHUNK_SIZE_X * REGION_CHUNKS; // 80
pub const REGION_SIZE_Z = CHUNK_SIZE_Z * REGION_CHUNKS; // 80
pub const REGION_SIZE_Y = CHUNK_SIZE_Y; // 256

/// Per-column data computed during generation
pub const ColumnData = struct {
    /// Phase A outputs
    height: i32, // Surface height (top solid Y)
    slope: i32, // Max neighbor delta
    is_ocean: bool, // Ocean classification (not just underwater)
    continentalness: f32,
    erosion: f32,
    peaks: f32,

    /// Phase B outputs
    temperature: f32,
    humidity: f32,
    biome_a: BiomeId,
    biome_b: BiomeId,
    blend_t: f32,

    /// Phase C outputs
    shore_dist: i32, // Distance to ocean shore
    is_beach: bool, // Beach eligibility
};

/// GenRegion: Large generation volume for coherent worldgen
pub const GenRegion = struct {
    /// Region coordinates (aligned to 5x5 chunk grid)
    region_x: i32,
    region_z: i32,

    /// Per-column data (80x80)
    columns: [REGION_SIZE_X * REGION_SIZE_Z]ColumnData,

    /// Stone mask: true = solid, false = air (before caves)
    /// Indexed as [x + z * REGION_SIZE_X + y * REGION_SIZE_X * REGION_SIZE_Z]
    stone_mask: []bool,

    /// Final blocks after all phases
    blocks: []BlockType,

    allocator: std.mem.Allocator,

    pub fn init(region_x: i32, region_z: i32, allocator: std.mem.Allocator) !GenRegion {
        const volume = REGION_SIZE_X * REGION_SIZE_Y * REGION_SIZE_Z;
        const stone_mask = try allocator.alloc(bool, volume);
        @memset(stone_mask, false);
        const blocks = try allocator.alloc(BlockType, volume);
        @memset(blocks, .air);

        return .{
            .region_x = region_x,
            .region_z = region_z,
            .columns = undefined,
            .stone_mask = stone_mask,
            .blocks = blocks,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GenRegion) void {
        self.allocator.free(self.stone_mask);
        self.allocator.free(self.blocks);
    }

    /// Get world X coordinate of region origin
    pub fn getWorldX(self: *const GenRegion) i32 {
        return self.region_x * REGION_SIZE_X;
    }

    /// Get world Z coordinate of region origin
    pub fn getWorldZ(self: *const GenRegion) i32 {
        return self.region_z * REGION_SIZE_Z;
    }

    /// Get column data at local coordinates
    pub fn getColumn(self: *const GenRegion, local_x: u32, local_z: u32) *const ColumnData {
        return &self.columns[local_x + local_z * REGION_SIZE_X];
    }

    /// Get mutable column data
    pub fn getColumnMut(self: *GenRegion, local_x: u32, local_z: u32) *ColumnData {
        return &self.columns[local_x + local_z * REGION_SIZE_X];
    }

    /// Get block index in 3D arrays
    fn getBlockIndex(x: u32, y: u32, z: u32) usize {
        return @as(usize, x) + @as(usize, z) * REGION_SIZE_X + @as(usize, y) * REGION_SIZE_X * REGION_SIZE_Z;
    }

    /// Get stone mask at position
    pub fn isSolid(self: *const GenRegion, x: u32, y: u32, z: u32) bool {
        if (x >= REGION_SIZE_X or y >= REGION_SIZE_Y or z >= REGION_SIZE_Z) return false;
        return self.stone_mask[getBlockIndex(x, y, z)];
    }

    /// Set stone mask
    pub fn setSolid(self: *GenRegion, x: u32, y: u32, z: u32, solid: bool) void {
        if (x >= REGION_SIZE_X or y >= REGION_SIZE_Y or z >= REGION_SIZE_Z) return;
        self.stone_mask[getBlockIndex(x, y, z)] = solid;
    }

    /// Get block at position
    pub fn getBlock(self: *const GenRegion, x: u32, y: u32, z: u32) BlockType {
        if (x >= REGION_SIZE_X or y >= REGION_SIZE_Y or z >= REGION_SIZE_Z) return .air;
        return self.blocks[getBlockIndex(x, y, z)];
    }

    /// Set block at position
    pub fn setBlock(self: *GenRegion, x: u32, y: u32, z: u32, block: BlockType) void {
        if (x >= REGION_SIZE_X or y >= REGION_SIZE_Y or z >= REGION_SIZE_Z) return;
        self.blocks[getBlockIndex(x, y, z)] = block;
    }

    /// Copy a chunk's worth of blocks from this region
    pub fn copyToChunk(self: *const GenRegion, chunk: *Chunk) void {
        const chunk_world_x = chunk.getWorldX();
        const chunk_world_z = chunk.getWorldZ();
        const region_world_x = self.getWorldX();
        const region_world_z = self.getWorldZ();

        // Calculate local offset within region
        const offset_x = chunk_world_x - region_world_x;
        const offset_z = chunk_world_z - region_world_z;

        if (offset_x < 0 or offset_x >= REGION_SIZE_X or
            offset_z < 0 or offset_z >= REGION_SIZE_Z)
        {
            return; // Chunk not in this region
        }

        const ox: u32 = @intCast(offset_x);
        const oz: u32 = @intCast(offset_z);

        // Copy blocks
        var lz: u32 = 0;
        while (lz < CHUNK_SIZE_Z) : (lz += 1) {
            var lx: u32 = 0;
            while (lx < CHUNK_SIZE_X) : (lx += 1) {
                var y: u32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    const block = self.getBlock(ox + lx, y, oz + lz);
                    chunk.setBlock(lx, y, lz, block);
                }

                // Copy biome from column data
                const col = self.getColumn(ox + lx, oz + lz);
                chunk.setBiome(lx, lz, col.biome_a);
            }
        }

        chunk.generated = true;
        chunk.dirty = true;
    }
};

/// GenRegion cache using LRU eviction
pub const GenRegionCache = struct {
    const CacheEntry = struct {
        region: ?*GenRegion,
        last_used: u64,
    };

    entries: std.AutoHashMap(i64, CacheEntry),
    allocator: std.mem.Allocator,
    max_entries: usize,
    access_counter: u64,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) GenRegionCache {
        return .{
            .entries = std.AutoHashMap(i64, CacheEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
            .access_counter = 0,
        };
    }

    pub fn deinit(self: *GenRegionCache) void {
        var iter = self.entries.valueIterator();
        while (iter.next()) |entry| {
            if (entry.region) |region| {
                region.deinit();
                self.allocator.destroy(region);
            }
        }
        self.entries.deinit();
    }

    /// Make cache key from region coordinates
    fn makeKey(region_x: i32, region_z: i32) i64 {
        return @as(i64, region_x) | (@as(i64, region_z) << 32);
    }

    /// Get region from cache (returns null if not present)
    pub fn get(self: *GenRegionCache, region_x: i32, region_z: i32) ?*GenRegion {
        const key = makeKey(region_x, region_z);
        if (self.entries.getPtr(key)) |entry| {
            self.access_counter += 1;
            entry.last_used = self.access_counter;
            return entry.region;
        }
        return null;
    }

    /// Put region in cache (may evict LRU entry)
    pub fn put(self: *GenRegionCache, region: *GenRegion) !void {
        const key = makeKey(region.region_x, region.region_z);

        // Evict if at capacity
        if (self.entries.count() >= self.max_entries) {
            self.evictLRU();
        }

        self.access_counter += 1;
        try self.entries.put(key, .{
            .region = region,
            .last_used = self.access_counter,
        });
    }

    /// Evict least recently used entry
    fn evictLRU(self: *GenRegionCache) void {
        var oldest_key: ?i64 = null;
        var oldest_time: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_used < oldest_time) {
                oldest_time = entry.value_ptr.last_used;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                if (removed.value.region) |region| {
                    region.deinit();
                    self.allocator.destroy(region);
                }
            }
        }
    }

    /// Get region coordinates for a chunk
    pub fn getRegionCoords(chunk_x: i32, chunk_z: i32) struct { x: i32, z: i32 } {
        // Floor division to handle negative coordinates
        const rx = @divFloor(chunk_x, REGION_CHUNKS);
        const rz = @divFloor(chunk_z, REGION_CHUNKS);
        return .{ .x = rx, .z = rz };
    }
};

// ============================================================================
// Climate Cache for LOD Generation (Issue #114)
// ============================================================================

/// Coarse-resolution climate data for fast LOD terrain generation.
/// Caches temperature, humidity, and continentalness at 64-block resolution.
pub const ClimateCache = struct {
    /// Cell size in blocks (coarse sampling)
    pub const CELL_SIZE: u32 = 64;

    /// Cache grid dimensions
    pub const GRID_SIZE: u32 = 32; // 32x32 grid = 2048x2048 blocks coverage

    /// Cached climate values
    const CacheCell = struct {
        temperature: f32,
        humidity: f32,
        continentalness: f32,
        valid: bool,
    };

    cells: [GRID_SIZE * GRID_SIZE]CacheCell,
    origin_x: i32, // World X of grid origin
    origin_z: i32, // World Z of grid origin

    pub fn init() ClimateCache {
        return .{
            .cells = [_]CacheCell{.{
                .temperature = 0,
                .humidity = 0,
                .continentalness = 0,
                .valid = false,
            }} ** (GRID_SIZE * GRID_SIZE),
            .origin_x = 0,
            .origin_z = 0,
        };
    }

    /// Recenter the cache grid around a new origin.
    /// Invalidates all cells.
    pub fn recenter(self: *ClimateCache, center_x: i32, center_z: i32) void {
        const half_size: i32 = @intCast((GRID_SIZE * CELL_SIZE) / 2);
        self.origin_x = center_x - half_size;
        self.origin_z = center_z - half_size;

        // Invalidate all cells
        for (&self.cells) |*cell| {
            cell.valid = false;
        }
    }

    /// Check if a world position is within the cache grid
    pub fn contains(self: *const ClimateCache, world_x: i32, world_z: i32) bool {
        const grid_extent: i32 = @intCast(GRID_SIZE * CELL_SIZE);
        return world_x >= self.origin_x and
            world_x < self.origin_x + grid_extent and
            world_z >= self.origin_z and
            world_z < self.origin_z + grid_extent;
    }

    /// Get grid cell index for world position, or null if out of bounds
    fn getCellIndex(self: *const ClimateCache, world_x: i32, world_z: i32) ?usize {
        if (!self.contains(world_x, world_z)) return null;

        const local_x: u32 = @intCast(world_x - self.origin_x);
        const local_z: u32 = @intCast(world_z - self.origin_z);
        const cell_x = local_x / CELL_SIZE;
        const cell_z = local_z / CELL_SIZE;

        return cell_x + cell_z * GRID_SIZE;
    }

    /// Try to get cached climate values at a world position
    pub fn get(self: *const ClimateCache, world_x: i32, world_z: i32) ?struct { temp: f32, humid: f32, cont: f32 } {
        const idx = self.getCellIndex(world_x, world_z) orelse return null;
        const cell = &self.cells[idx];
        if (!cell.valid) return null;
        return .{ .temp = cell.temperature, .humid = cell.humidity, .cont = cell.continentalness };
    }

    /// Store climate values at a world position
    pub fn put(self: *ClimateCache, world_x: i32, world_z: i32, temperature: f32, humidity: f32, continentalness: f32) void {
        const idx = self.getCellIndex(world_x, world_z) orelse return;
        self.cells[idx] = .{
            .temperature = temperature,
            .humidity = humidity,
            .continentalness = continentalness,
            .valid = true,
        };
    }

    /// Get or compute climate values using provided noise functions
    pub fn getOrCompute(
        self: *ClimateCache,
        world_x: i32,
        world_z: i32,
        computeFn: *const fn (x: f32, z: f32) struct { temp: f32, humid: f32, cont: f32 },
    ) struct { temp: f32, humid: f32, cont: f32 } {
        if (self.get(world_x, world_z)) |cached| {
            return cached;
        }

        // Compute and cache
        const result = computeFn(@floatFromInt(world_x), @floatFromInt(world_z));
        self.put(world_x, world_z, result.temp, result.humid, result.cont);
        return result;
    }
};

// ============================================================================
// Classification Cache for LOD Generation (Issue #119 Phase 2)
// ============================================================================

const world_class = @import("world_class.zig");
pub const ClassCell = world_class.ClassCell;
pub const ContinentalZone = world_class.ContinentalZone;
pub const SurfaceType = world_class.SurfaceType;

/// Classification cache for LOD terrain generation.
/// Stores authoritative biome/surface/water decisions at coarse resolution.
/// LOD levels sample from this cache instead of recomputing.
pub const ClassificationCache = struct {
    /// Cell size in blocks (must match world_class.CELL_SIZE)
    pub const CELL_SIZE: u32 = world_class.CELL_SIZE; // 8 blocks

    /// Cache grid dimensions (covers 2048x2048 blocks = 128x128 chunks)
    pub const GRID_SIZE: u32 = 256;

    /// Optional cell - null means not yet computed
    const OptionalCell = ?ClassCell;

    cells: [GRID_SIZE * GRID_SIZE]OptionalCell,
    origin_x: i32, // World X of grid origin (in blocks)
    origin_z: i32, // World Z of grid origin (in blocks)

    pub fn init() ClassificationCache {
        return .{
            .cells = [_]OptionalCell{null} ** (GRID_SIZE * GRID_SIZE),
            .origin_x = 0,
            .origin_z = 0,
        };
    }

    /// Recenter the cache grid around a new origin.
    /// Invalidates all cells.
    pub fn recenter(self: *ClassificationCache, center_x: i32, center_z: i32) void {
        const half_size: i32 = @intCast((GRID_SIZE * CELL_SIZE) / 2);
        self.origin_x = center_x - half_size;
        self.origin_z = center_z - half_size;

        // Invalidate all cells
        for (&self.cells) |*cell| {
            cell.* = null;
        }
    }

    /// Check if a world position is within the cache grid
    pub fn contains(self: *const ClassificationCache, world_x: i32, world_z: i32) bool {
        const grid_extent: i32 = @intCast(GRID_SIZE * CELL_SIZE);
        return world_x >= self.origin_x and
            world_x < self.origin_x + grid_extent and
            world_z >= self.origin_z and
            world_z < self.origin_z + grid_extent;
    }

    /// Get grid cell index for world position, or null if out of bounds
    fn getCellIndex(self: *const ClassificationCache, world_x: i32, world_z: i32) ?usize {
        if (!self.contains(world_x, world_z)) return null;

        const local_x: u32 = @intCast(world_x - self.origin_x);
        const local_z: u32 = @intCast(world_z - self.origin_z);
        const cell_x = local_x / CELL_SIZE;
        const cell_z = local_z / CELL_SIZE;

        return cell_x + cell_z * GRID_SIZE;
    }

    /// Try to get cached classification at a world position
    pub fn get(self: *const ClassificationCache, world_x: i32, world_z: i32) ?ClassCell {
        const idx = self.getCellIndex(world_x, world_z) orelse return null;
        return self.cells[idx];
    }

    /// Store classification at a world position
    pub fn put(self: *ClassificationCache, world_x: i32, world_z: i32, cell: ClassCell) void {
        const idx = self.getCellIndex(world_x, world_z) orelse return;
        self.cells[idx] = cell;
    }

    /// Check if position has a cached value
    pub fn has(self: *const ClassificationCache, world_x: i32, world_z: i32) bool {
        const idx = self.getCellIndex(world_x, world_z) orelse return false;
        return self.cells[idx] != null;
    }
};
