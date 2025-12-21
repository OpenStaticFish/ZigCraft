//! Cave system per cave-system.md spec
//! Implements worm/tunnel caves and noise cavities with proper surface protection.

const std = @import("std");
const noise_mod = @import("noise.zig");
const Noise = noise_mod.Noise;
const smoothstep = noise_mod.smoothstep;

const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;

/// Cave system parameters
/// These values are tuned for natural-looking caves that don't overwhelm the terrain.
///
/// Future enhancements:
/// - TODO: Make worm_branch_chance configurable per biome (more caves in mountains)
/// - TODO: Add debug visualization toggles (show cave regions, worm paths)
/// - TODO: Consider sparse representation for CaveCarveMap in very large worlds
pub const CaveParams = struct {
    // Section 3: Cave Region Mask (2D)
    region_scale: f32 = 1.0 / 900.0, // Smaller scale = more variation
    region_threshold: f32 = 0.42, // Lower = more areas have caves

    // Section 4: Surface Protection
    min_surface_depth: i32 = 8, // No caves within N blocks of surface

    // Section 5: Worm Caves
    worms_per_chunk_min: u32 = 1,
    worms_per_chunk_max: u32 = 3,
    worm_y_min: i32 = 15,
    worm_y_max: i32 = 110,
    worm_radius_min: f32 = 2.5,
    worm_radius_max: f32 = 5.0,
    worm_length_min: u32 = 80,
    worm_length_max: u32 = 180,
    worm_step_size: f32 = 1.2,
    worm_turn_strength: f32 = 0.12,
    worm_branch_chance: f32 = 0.03,

    // Section 6: Noise Cavities
    cavity_scale: f32 = 1.0 / 50.0,
    cavity_y_scale: f32 = 1.0 / 40.0, // Slightly stretched vertically
    cavity_threshold: f32 = 0.62, // Lower = more cavities
    cavity_y_min: i32 = 15,
    cavity_y_max: i32 = 140,

    // Sea level for underwater cave handling
    sea_level: i32 = 64,
};

/// Cave carving data for a chunk.
/// Stores a boolean per block indicating whether it should be carved as air.
///
/// Memory usage: CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z bytes (currently 65KB per chunk)
/// This is allocated per-chunk during generation and freed immediately after.
///
/// For very large worlds with bigger chunks, consider:
/// - Sparse representation (hashmap of carved positions)
/// - Run-length encoding for vertical spans
/// - Bitpacking (8 blocks per byte)
pub const CaveCarveMap = struct {
    // Comptime safety check: ensure carve map doesn't exceed reasonable memory
    comptime {
        const size = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z;
        if (size > 1_000_000) {
            @compileError("CaveCarveMap size exceeds 1MB - consider using a sparse representation");
        }
    }

    data: []bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CaveCarveMap {
        const size = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z;
        const data = try allocator.alloc(bool, size);
        @memset(data, false);
        return .{ .data = data, .allocator = allocator };
    }

    pub fn deinit(self: *CaveCarveMap) void {
        self.allocator.free(self.data);
    }

    pub fn set(self: *CaveCarveMap, x: u32, y: u32, z: u32, val: bool) void {
        if (x >= CHUNK_SIZE_X or y >= CHUNK_SIZE_Y or z >= CHUNK_SIZE_Z) return;
        self.data[x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z] = val;
    }

    pub fn get(self: *const CaveCarveMap, x: u32, y: u32, z: u32) bool {
        if (x >= CHUNK_SIZE_X or y >= CHUNK_SIZE_Y or z >= CHUNK_SIZE_Z) return false;
        return self.data[x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z];
    }
};

/// Cave system generator
pub const CaveSystem = struct {
    // Noise generators
    region_noise: Noise, // 2D cave region mask
    worm_noise: Noise, // For worm direction perturbation
    cavity_noise: Noise, // 3D noise cavities

    params: CaveParams,
    seed: u64,

    pub fn init(seed: u64) CaveSystem {
        var prng = std.Random.DefaultPrng.init(seed +% 0xCA7E5EED);
        const random = prng.random();

        return .{
            .region_noise = Noise.init(random.int(u64)),
            .worm_noise = Noise.init(random.int(u64)),
            .cavity_noise = Noise.init(random.int(u64)),
            .params = .{},
            .seed = seed,
        };
    }

    /// Check if caves are allowed at this XZ position (2D region mask)
    pub fn getCaveRegionValue(self: *const CaveSystem, x: f32, z: f32) f32 {
        const p = self.params;
        // fBm normalized to [0,1]
        return self.region_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.region_scale);
    }

    /// Returns true if this XZ region allows caves
    pub fn isCaveRegion(self: *const CaveSystem, x: f32, z: f32) bool {
        return self.getCaveRegionValue(x, z) >= self.params.region_threshold;
    }

    /// Generate worm caves for a chunk and surrounding area
    /// This needs to check neighboring chunks too since worms cross boundaries
    pub fn generateWormCaves(
        self: *const CaveSystem,
        chunk: *Chunk,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        allocator: std.mem.Allocator,
    ) !CaveCarveMap {
        var carve_map = try CaveCarveMap.init(allocator);

        const chunk_x = chunk.chunk_x;
        const chunk_z = chunk.chunk_z;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();

        // Check this chunk and neighbors for worm spawns that might affect us
        // Worms can travel ~180 blocks, so check a 3-chunk radius
        const check_radius: i32 = 3;

        var cz = chunk_z - check_radius;
        while (cz <= chunk_z + check_radius) : (cz += 1) {
            var cx = chunk_x - check_radius;
            while (cx <= chunk_x + check_radius) : (cx += 1) {
                // Deterministic worm spawning for this chunk
                self.spawnWormsForChunk(
                    cx,
                    cz,
                    world_x,
                    world_z,
                    surface_heights,
                    &carve_map,
                );
            }
        }

        return carve_map;
    }

    /// Spawn worms originating from a specific chunk
    fn spawnWormsForChunk(
        self: *const CaveSystem,
        source_chunk_x: i32,
        source_chunk_z: i32,
        target_world_x: i32,
        target_world_z: i32,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        carve_map: *CaveCarveMap,
    ) void {
        const p = self.params;

        // Check if this source chunk is in a cave region
        const source_center_x: f32 = @floatFromInt(source_chunk_x * 16 + 8);
        const source_center_z: f32 = @floatFromInt(source_chunk_z * 16 + 8);
        if (!self.isCaveRegion(source_center_x, source_center_z)) return;

        // Seeded RNG for this chunk's worms
        const chunk_seed = self.seed +%
            @as(u64, @bitCast(@as(i64, source_chunk_x))) *% 341873128712 +%
            @as(u64, @bitCast(@as(i64, source_chunk_z))) *% 132897987541;
        var prng = std.Random.DefaultPrng.init(chunk_seed);
        const random = prng.random();

        // Determine number of worms
        const range = p.worms_per_chunk_max - p.worms_per_chunk_min + 1;
        const num_worms = p.worms_per_chunk_min + random.uintLessThan(u32, range);

        for (0..num_worms) |_| {
            self.carveWorm(
                source_chunk_x,
                source_chunk_z,
                target_world_x,
                target_world_z,
                surface_heights,
                carve_map,
                random,
            );
        }
    }

    /// Carve a single worm tunnel using sphere-marching algorithm.
    /// The worm moves forward while its direction is perturbed by 3D Perlin noise,
    /// creating natural, winding cave tunnels.
    fn carveWorm(
        self: *const CaveSystem,
        source_chunk_x: i32,
        source_chunk_z: i32,
        target_world_x: i32,
        target_world_z: i32,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        carve_map: *CaveCarveMap,
        random: std.Random,
    ) void {
        const p = self.params;

        // Starting position (random point within source chunk)
        var pos_x: f32 = @floatFromInt(source_chunk_x * 16 + @as(i32, @intCast(random.uintLessThan(u32, 16))));
        var pos_y: f32 = @floatFromInt(p.worm_y_min + @as(i32, @intCast(random.uintLessThan(u32, @intCast(p.worm_y_max - p.worm_y_min)))));
        var pos_z: f32 = @floatFromInt(source_chunk_z * 16 + @as(i32, @intCast(random.uintLessThan(u32, 16))));

        // Random initial direction vector
        // Y component scaled by 0.3 to bias toward horizontal movement
        var dir_x: f32 = random.float(f32) * 2.0 - 1.0;
        var dir_y: f32 = (random.float(f32) * 2.0 - 1.0) * 0.3;
        var dir_z: f32 = random.float(f32) * 2.0 - 1.0;

        // Normalize to unit vector
        const len = @sqrt(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z);
        if (len > 0.001) {
            dir_x /= len;
            dir_y /= len;
            dir_z /= len;
        }

        // Randomize worm length and initial radius within configured ranges
        const length_range = p.worm_length_max - p.worm_length_min;
        const worm_length = p.worm_length_min + random.uintLessThan(u32, length_range + 1);
        var radius = p.worm_radius_min + random.float(f32) * (p.worm_radius_max - p.worm_radius_min);

        // Main worm carving loop - each step carves a sphere and moves forward
        var step: u32 = 0;
        while (step < worm_length) : (step += 1) {
            // Carve spherical cavity at current position
            self.carveSphere(
                pos_x,
                pos_y,
                pos_z,
                radius,
                target_world_x,
                target_world_z,
                surface_heights,
                carve_map,
            );

            // Advance position along direction vector
            pos_x += dir_x * p.worm_step_size;
            pos_y += dir_y * p.worm_step_size;
            pos_z += dir_z * p.worm_step_size;

            // === Direction Perturbation using 3D Perlin Noise ===
            // Sample noise at current position (scaled by 0.05 for smooth, large-scale curves)
            // Offset samples by 100 units to get uncorrelated values for each axis
            const noise_x = self.worm_noise.perlin3D(pos_x * 0.05, pos_y * 0.05, pos_z * 0.05);
            const noise_y = self.worm_noise.perlin3D(pos_x * 0.05 + 100, pos_y * 0.05, pos_z * 0.05);
            const noise_z = self.worm_noise.perlin3D(pos_x * 0.05, pos_y * 0.05 + 100, pos_z * 0.05);

            // Apply noise to direction (Y scaled by 0.5 for less vertical wandering)
            dir_x += noise_x * p.worm_turn_strength;
            dir_y += noise_y * p.worm_turn_strength * 0.5;
            dir_z += noise_z * p.worm_turn_strength;

            // Dampen vertical component to keep caves mostly horizontal
            dir_y *= 0.95;

            // Re-normalize direction to unit length
            const new_len = @sqrt(dir_x * dir_x + dir_y * dir_y + dir_z * dir_z);
            if (new_len > 0.001) {
                dir_x /= new_len;
                dir_y /= new_len;
                dir_z /= new_len;
            }

            // Occasionally vary tunnel radius for natural width variation
            if (random.float(f32) < 0.1) {
                radius += (random.float(f32) - 0.5) * 0.5;
                radius = std.math.clamp(radius, p.worm_radius_min, p.worm_radius_max);
            }

            // Keep worm in valid Y range
            if (pos_y < @as(f32, @floatFromInt(p.worm_y_min))) {
                dir_y = @abs(dir_y);
            }
            if (pos_y > @as(f32, @floatFromInt(p.worm_y_max))) {
                dir_y = -@abs(dir_y);
            }
        }
    }

    /// Carve a sphere at the given world position
    fn carveSphere(
        self: *const CaveSystem,
        center_x: f32,
        center_y: f32,
        center_z: f32,
        radius: f32,
        target_world_x: i32,
        target_world_z: i32,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        carve_map: *CaveCarveMap,
    ) void {
        const p = self.params;
        const r_ceil: i32 = @intFromFloat(@ceil(radius));

        var dy: i32 = -r_ceil;
        while (dy <= r_ceil) : (dy += 1) {
            var dz: i32 = -r_ceil;
            while (dz <= r_ceil) : (dz += 1) {
                var dx: i32 = -r_ceil;
                while (dx <= r_ceil) : (dx += 1) {
                    const dist_sq = @as(f32, @floatFromInt(dx * dx + dy * dy + dz * dz));
                    if (dist_sq > radius * radius) continue;

                    const world_xi: i32 = @as(i32, @intFromFloat(center_x)) + dx;
                    const world_yi: i32 = @as(i32, @intFromFloat(center_y)) + dy;
                    const world_zi: i32 = @as(i32, @intFromFloat(center_z)) + dz;

                    // Check if within target chunk
                    const local_x = world_xi - target_world_x;
                    const local_z = world_zi - target_world_z;

                    if (local_x < 0 or local_x >= CHUNK_SIZE_X) continue;
                    if (local_z < 0 or local_z >= CHUNK_SIZE_Z) continue;
                    if (world_yi < 1 or world_yi >= CHUNK_SIZE_Y) continue; // Protect bedrock

                    // Surface protection
                    const surface_idx = @as(usize, @intCast(local_x)) + @as(usize, @intCast(local_z)) * CHUNK_SIZE_X;
                    const surface_height = surface_heights[surface_idx];
                    if (world_yi > surface_height - p.min_surface_depth) continue;

                    // Mark for carving
                    carve_map.set(
                        @intCast(local_x),
                        @intCast(world_yi),
                        @intCast(local_z),
                        true,
                    );
                }
            }
        }
    }

    /// Check if a block should be carved by noise cavities
    pub fn shouldCarveNoiseCavity(
        self: *const CaveSystem,
        world_x: f32,
        world_y: f32,
        world_z: f32,
        surface_height: i32,
        cave_region_value: f32,
    ) bool {
        const p = self.params;
        const yi: i32 = @intFromFloat(world_y);

        // Region must allow caves
        if (cave_region_value < p.region_threshold) return false;

        // Surface protection
        if (yi > surface_height - p.min_surface_depth) return false;

        // Depth band (caves prefer mid-depths)
        const band = smoothstep(
            @floatFromInt(p.cavity_y_min),
            @floatFromInt(p.cavity_y_min + 30),
            world_y,
        ) * (1.0 - smoothstep(
            @floatFromInt(p.cavity_y_max - 20),
            @floatFromInt(p.cavity_y_max),
            world_y,
        ));
        if (band < 0.1) return false;

        // 3D cavity noise
        const n = self.cavity_noise.fbm3D(
            world_x * p.cavity_scale,
            world_y * p.cavity_y_scale,
            world_z * p.cavity_scale,
            4,
            2.0,
            0.5,
            1.0,
        );

        // Threshold adjusted by cave region strength and depth band
        const region_factor = (cave_region_value - p.region_threshold) / (1.0 - p.region_threshold);
        const threshold = p.cavity_threshold - region_factor * 0.1 * band;

        return n > threshold;
    }
};
