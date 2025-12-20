//! Terrain generator using layered noise stack per worldgen-spec2.md
//! Implements: domain warping, multi-noise biomes, controlled caves,
//! ocean shaping, river carving, and varied mountain/cliff generation.

const std = @import("std");
const noise_mod = @import("noise.zig");
const Noise = noise_mod.Noise;
const smoothstep = noise_mod.smoothstep;
const clamp01 = noise_mod.clamp01;
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const Biome = @import("../block.zig").Biome;

/// Terrain generation parameters
const Params = struct {
    // Section 4.1: Domain Warping
    warp_scale: f32 = 1.0 / 1100.0,
    warp_amplitude: f32 = 50.0,

    // Section 4.2: Continentalness (large scale landmass)
    continental_scale: f32 = 1.0 / 2600.0,
    deep_ocean_threshold: f32 = 0.35,
    coast_threshold: f32 = 0.46,

    // Section 4.3: Erosion (sharp vs smooth terrain)
    erosion_scale: f32 = 1.0 / 1100.0,

    // Section 4.4: Peaks/Valleys (mountain rhythm)
    peaks_scale: f32 = 1.0 / 900.0,

    // Section 4.5: Climate
    temperature_scale: f32 = 1.0 / 5000.0,
    humidity_scale: f32 = 1.0 / 4000.0,
    temp_lapse: f32 = 0.25, // Temperature reduction per altitude

    // Section 5: Height function
    sea_level: i32 = 64,
    mount_amp: f32 = 120.0,
    detail_scale: f32 = 1.0 / 220.0,
    detail_amp: f32 = 12.0,

    // Section 6: Ocean shaping
    coast_jitter_scale: f32 = 1.0 / 650.0,
    seabed_scale: f32 = 1.0 / 280.0,
    seabed_amp: f32 = 6.0,

    // Section 7: Rivers
    river_scale: f32 = 1.0 / 1200.0,
    river_min: f32 = 0.74,
    river_max: f32 = 0.84,
    river_depth_max: f32 = 12.0,

    // Section 10: Caves
    cave_mask_scale: f32 = 1.0 / 1200.0,
    cave_3d_scale: f32 = 0.025,
    cave_y_scale: f32 = 0.035, // Vertically stretched caves
    cave_threshold: f32 = 0.55,
    cave_surface_protection: i32 = 8, // No caves within N blocks of surface
};

pub const TerrainGenerator = struct {
    // Noise generators for different layers
    // Domain warp (2 noise fields for x/z offset)
    warp_noise_x: Noise,
    warp_noise_z: Noise,

    // Core 2D fields
    continentalness_noise: Noise,
    erosion_noise: Noise,
    peaks_noise: Noise,
    temperature_noise: Noise,
    humidity_noise: Noise,

    // Detail and feature noise
    detail_noise: Noise,
    coast_jitter_noise: Noise,
    seabed_noise: Noise,
    river_noise: Noise,

    // Cave noise (2D mask + 3D carving)
    cave_mask_noise: Noise,
    cave_3d_noise: Noise,

    // Filler depth variation
    filler_depth_noise: Noise,

    params: Params,

    pub fn init(seed: u64) TerrainGenerator {
        // Derive seeds for different layers to ensure they are independent
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        return .{
            .warp_noise_x = Noise.init(random.int(u64)),
            .warp_noise_z = Noise.init(random.int(u64)),
            .continentalness_noise = Noise.init(random.int(u64)),
            .erosion_noise = Noise.init(random.int(u64)),
            .peaks_noise = Noise.init(random.int(u64)),
            .temperature_noise = Noise.init(random.int(u64)),
            .humidity_noise = Noise.init(random.int(u64)),
            .detail_noise = Noise.init(random.int(u64)),
            .coast_jitter_noise = Noise.init(random.int(u64)),
            .seabed_noise = Noise.init(random.int(u64)),
            .river_noise = Noise.init(random.int(u64)),
            .cave_mask_noise = Noise.init(random.int(u64)),
            .cave_3d_noise = Noise.init(random.int(u64)),
            .filler_depth_noise = Noise.init(random.int(u64)),
            .params = .{},
        };
    }

    /// Generate terrain for a chunk
    pub fn generate(self: *const TerrainGenerator, chunk: *Chunk) void {
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // === Section 4.1: Domain Warping ===
                const warp = self.computeWarp(wx, wz);
                const xw = wx + warp.x;
                const zw = wz + warp.z;

                // === Section 4.2-4.5: Sample core 2D fields ===
                const c = self.getContinentalness(xw, zw); // [0,1]
                const e = self.getErosion(xw, zw); // [0,1]
                const pv = self.getPeaksValleys(xw, zw); // [0,1] ridged

                // === Section 6.1: Coastline jitter ===
                const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 3, 2.0, 0.5, p.coast_jitter_scale) * 0.05;
                const c_jittered = clamp01(c + coast_jitter);

                // === Section 5: Height function ===
                var terrain_height = self.computeHeight(c_jittered, e, pv, xw, zw);

                // === Section 7: River carving ===
                const river_mask = self.getRiverMask(xw, zw);
                if (river_mask > 0 and terrain_height > sea - 5) {
                    const river_depth = river_mask * p.river_depth_max;
                    terrain_height = @min(terrain_height, terrain_height - river_depth);
                }

                // === Section 6.2: Seabed variation for ocean columns ===
                var is_ocean = false;
                if (terrain_height < sea) {
                    is_ocean = true;
                    // Apply seabed variation
                    const deep_factor = 1.0 - smoothstep(p.deep_ocean_threshold, 0.5, c_jittered);
                    const seabed_detail = self.seabed_noise.fbm2D(xw, zw, 5, 2.0, 0.5, p.seabed_scale) * p.seabed_amp;
                    const base_seabed = sea - 18.0 - deep_factor * 35.0;
                    terrain_height = @min(terrain_height, base_seabed + seabed_detail);
                }

                const terrain_height_i: i32 = @intFromFloat(terrain_height);

                // === Section 4.5: Climate with altitude adjustment ===
                const altitude_offset: f32 = @max(0, terrain_height - sea);
                var temperature = self.getTemperature(xw, zw);
                temperature = clamp01(temperature - (altitude_offset / 512.0) * p.temp_lapse);
                const humidity = self.getHumidity(xw, zw);

                // === Section 8: Biome selection ===
                const mountain_mask = self.getMountainMask(pv, e);
                const biome = self.selectBiome(c_jittered, e, mountain_mask, terrain_height_i, temperature, humidity, river_mask);

                // === Section 9: Surface layers ===
                const filler_depth = self.getFillerDepth(xw, zw, e, biome);

                // === Section 10: Cave mask ===
                const cave_allowed = self.getCaveAllowed(xw, zw);

                // Fill column
                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, biome, filler_depth, is_ocean, sea);

                    // Cave carving (Section 10)
                    if (block != .air and block != .water and block != .bedrock) {
                        if (self.shouldCarve(wx, @floatFromInt(y), wz, terrain_height_i, cave_allowed)) {
                            block = if (y < p.sea_level) .water else .air;
                        }
                    }

                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        chunk.generated = true;

        // Ores
        self.generateOres(chunk);

        // Features (trees, cacti, etc.)
        self.generateFeatures(chunk);

        chunk.dirty = true;
    }

    // ========== Section 4.1: Domain Warping ==========

    fn computeWarp(self: *const TerrainGenerator, x: f32, z: f32) struct { x: f32, z: f32 } {
        const p = self.params;
        const offset_x = self.warp_noise_x.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        const offset_z = self.warp_noise_z.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        return .{ .x = offset_x, .z = offset_z };
    }

    // ========== Section 4.2-4.5: Core 2D Fields ==========

    fn getContinentalness(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.continentalness_noise.fbm2D(x, z, 4, 2.0, 0.5, self.params.continental_scale);
        return (val + 1.0) * 0.5; // Normalize to [0, 1]
    }

    fn getErosion(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.erosion_noise.fbm2D(x, z, 4, 2.0, 0.5, self.params.erosion_scale);
        return (val + 1.0) * 0.5;
    }

    fn getPeaksValleys(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        return self.peaks_noise.ridged2D(x, z, 5, 2.0, 0.5, self.params.peaks_scale);
    }

    fn getTemperature(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.temperature_noise.fbm2D(x, z, 3, 2.0, 0.5, self.params.temperature_scale);
        return (val + 1.0) * 0.5;
    }

    fn getHumidity(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.humidity_noise.fbm2D(x, z, 3, 2.0, 0.5, self.params.humidity_scale);
        return (val + 1.0) * 0.5;
    }

    // ========== Section 5: Height Function ==========

    fn getMountainMask(self: *const TerrainGenerator, pv: f32, e: f32) f32 {
        _ = self;
        // Mountains where peaks are high AND erosion is low (rugged)
        const peak_factor = smoothstep(0.55, 0.85, pv);
        const rugged_factor = 1.0 - smoothstep(0.45, 0.80, e);
        return peak_factor * rugged_factor;
    }

    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32, x: f32, z: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // Section 5.1: Base height from continentalness
        const land_factor = smoothstep(0.35, 0.75, c);
        var base_height = std.math.lerp(sea - 55.0, sea + 70.0, land_factor);

        // Section 5.2: Mountain lift
        const m_mask = self.getMountainMask(pv, e);
        const mount = std.math.pow(f32, m_mask, 1.7) * p.mount_amp;
        base_height += mount;

        // Section 5.3: Local detail (hills)
        const detail = self.detail_noise.fbm2D(x, z, 5, 2.0, 0.5, p.detail_scale) * p.detail_amp;
        base_height += detail;

        // Section 5.5: Cliff/terrace shaping - reduce smoothness in rugged areas
        // Higher erosion = smoother terrain, lower = more cliffs
        // We can add subtle terracing in low-erosion mountain areas
        if (m_mask > 0.3 and e < 0.4) {
            const terrace_step: f32 = 4.0;
            const terrace_strength: f32 = 0.25 * (1.0 - e);
            const terraced = @round(base_height / terrace_step) * terrace_step;
            base_height = std.math.lerp(base_height, terraced, terrace_strength);
        }

        return base_height;
    }

    // ========== Section 7: Rivers ==========

    fn getRiverMask(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        // Use ridged noise inverted (valleys are rivers)
        const r = self.river_noise.ridged2D(x, z, 4, 2.0, 0.5, p.river_scale);
        const river_val = 1.0 - r;
        return smoothstep(p.river_min, p.river_max, river_val);
    }

    // ========== Section 8: Biome Selection ==========

    fn selectBiome(
        self: *const TerrainGenerator,
        c: f32,
        e: f32,
        mountain_mask: f32,
        height: i32,
        temp: f32,
        humidity: f32,
        river_mask: f32,
    ) Biome {
        _ = self;
        _ = e;
        const sea = 64;

        // River biome
        if (river_mask > 0.5 and height <= sea) {
            return .river;
        }

        // Deep ocean
        if (c < 0.35) {
            return .deep_ocean;
        }

        // Ocean
        if (c < 0.46 and height < sea - 2) {
            return .ocean;
        }

        // Beach (near sea level, coastal)
        if (c < 0.52 and @abs(height - sea) < 4) {
            return .beach;
        }

        // Land biomes
        // Mountains (high elevation or rugged)
        if (height > sea + 95 or mountain_mask > 0.6) {
            if (temp < 0.35) {
                return .snowy_mountains;
            }
            return .mountains;
        }

        // Climate-based biomes
        if (temp < 0.25) {
            return .snow_tundra;
        }

        if (temp < 0.40) {
            return .taiga;
        }

        if (temp > 0.65 and humidity < 0.35) {
            return .desert;
        }

        if (humidity > 0.55) {
            return .forest;
        }

        return .plains;
    }

    // ========== Section 9: Surface Layers ==========

    fn getFillerDepth(self: *const TerrainGenerator, x: f32, z: f32, erosion: f32, biome: Biome) i32 {
        _ = biome;
        // Base filler depth with variation
        const base: f32 = 3.0;
        const variation = self.filler_depth_noise.fbm2D(x, z, 2, 2.0, 0.5, 0.01) * 2.0;
        var depth = base + variation;

        // Reduce on cliffs (low erosion = more exposed rock)
        if (erosion < 0.35) {
            depth *= erosion / 0.35;
        }

        return @intFromFloat(@max(1, depth));
    }

    fn getBlockAt(
        self: *const TerrainGenerator,
        y: i32,
        terrain_height: i32,
        biome: Biome,
        filler_depth: i32,
        is_ocean: bool,
        sea: f32,
    ) BlockType {
        _ = self;
        const sea_level: i32 = @intFromFloat(sea);

        if (y == 0) return .bedrock;

        // Above terrain
        if (y > terrain_height) {
            if (y <= sea_level) return .water;
            return .air;
        }

        // Ocean floor
        if (is_ocean and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            return biome.getOceanFloorBlock(depth);
        }

        // Surface block
        if (y == terrain_height) {
            // Snow on top of cold biomes
            if (biome == .snowy_mountains or biome == .snow_tundra) {
                return .snow_block;
            }
            return biome.getSurfaceBlock();
        }

        // Filler layers (dirt/sand under surface)
        if (y > terrain_height - filler_depth) {
            return biome.getFillerBlock();
        }

        // Stone below
        return .stone;
    }

    // ========== Section 10: Caves ==========

    fn getCaveAllowed(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        const mask_val = self.cave_mask_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.cave_mask_scale);
        return smoothstep(0.58, 0.80, mask_val);
    }

    fn shouldCarve(self: *const TerrainGenerator, x: f32, y: f32, z: f32, terrain_height: i32, cave_allowed: f32) bool {
        const p = self.params;

        // No caves if region doesn't allow
        if (cave_allowed < 0.1) return false;

        // Surface protection
        const yi: i32 = @intFromFloat(y);
        if (yi > terrain_height - p.cave_surface_protection) return false;

        // Depth band preference (caves prefer mid-depths)
        const band = smoothstep(12, 60, y) * (1.0 - smoothstep(120, 180, y));
        if (band < 0.1) return false;

        // 3D carving noise
        const n = self.cave_3d_noise.fbm3D(
            x * p.cave_3d_scale,
            y * p.cave_y_scale,
            z * p.cave_3d_scale,
            4,
            2.0,
            0.5,
            1.0,
        );

        // Threshold with cave_allowed influence
        const threshold = p.cave_threshold + (1.0 - cave_allowed) * 0.2;
        return n > threshold;
    }

    // ========== Ores ==========

    fn generateOres(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(
            self.erosion_noise.seed +%
                @as(u64, @bitCast(@as(i64, chunk.chunk_x))) *% 59381 +%
                @as(u64, @bitCast(@as(i64, chunk.chunk_z))) *% 28411,
        );
        const random = prng.random();

        self.placeOreVeins(chunk, .coal_ore, 20, 6, 10, 128, random);
        self.placeOreVeins(chunk, .iron_ore, 10, 4, 5, 64, random);
        self.placeOreVeins(chunk, .gold_ore, 3, 3, 2, 32, random);
    }

    fn placeOreVeins(
        self: *const TerrainGenerator,
        chunk: *Chunk,
        block: BlockType,
        count: u32,
        size: u32,
        min_y: i32,
        max_y: i32,
        random: std.Random,
    ) void {
        _ = self;
        for (0..count) |_| {
            const cx = random.uintLessThan(u32, CHUNK_SIZE_X);
            const cz = random.uintLessThan(u32, CHUNK_SIZE_Z);
            const range = max_y - min_y;
            if (range <= 0) continue;
            const cy = min_y + @as(i32, @intCast(random.uintLessThan(u32, @intCast(range))));

            const vein_size = random.uintLessThan(u32, size) + 2;

            var i: u32 = 0;
            while (i < vein_size) : (i += 1) {
                const ox = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oy = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oz = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;

                const tx = @as(i32, @intCast(cx)) + ox;
                const ty = cy + oy;
                const tz = @as(i32, @intCast(cz)) + oz;

                if (chunk.getBlockSafe(tx, ty, tz) == .stone) {
                    if (tx >= 0 and tx < CHUNK_SIZE_X and
                        ty >= 0 and ty < CHUNK_SIZE_Y and
                        tz >= 0 and tz < CHUNK_SIZE_Z)
                    {
                        chunk.setBlock(@intCast(tx), @intCast(ty), @intCast(tz), block);
                    }
                }
            }
        }
    }

    // ========== Features (Trees, Cacti, etc.) ==========

    fn generateFeatures(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(
            self.continentalness_noise.seed ^
                @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^
                (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32),
        );
        const random = prng.random();

        // Attempt to place features
        const attempts = 12;
        for (0..attempts) |_| {
            const lx = random.uintLessThan(u32, CHUNK_SIZE_X);
            const lz = random.uintLessThan(u32, CHUNK_SIZE_Z);

            // Find surface y
            var y: i32 = CHUNK_SIZE_Y - 1;
            while (y > 0) : (y -= 1) {
                if (chunk.getBlock(lx, @intCast(y), lz) != .air) break;
            }

            const surface_block = chunk.getBlock(lx, @intCast(y), lz);

            // Tree placement (on grass)
            if (surface_block == .grass) {
                if (random.float(f32) < 0.06) {
                    self.placeTree(chunk, lx, @intCast(y + 1), lz, random);
                }
            }
            // Cactus placement (on sand, not underwater)
            else if (surface_block == .sand and y > self.params.sea_level) {
                if (random.float(f32) < 0.015) {
                    self.placeCactus(chunk, lx, @intCast(y + 1), lz, random);
                }
            }
        }
    }

    fn placeTree(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, random: std.Random) void {
        _ = self;
        const height = 4 + random.uintLessThan(u32, 3);

        // Trunk
        for (0..height) |i| {
            const ty = y + @as(u32, @intCast(i));
            if (ty < CHUNK_SIZE_Y) {
                chunk.setBlock(x, ty, z, .wood);
            }
        }

        // Leaves
        const leaf_start = y + height - 2;
        const leaf_end = y + height + 1;

        var ly: u32 = leaf_start;
        while (ly <= leaf_end) : (ly += 1) {
            const range: i32 = if (ly == leaf_end) 1 else 2;
            var lz: i32 = -range;
            while (lz <= range) : (lz += 1) {
                var lx: i32 = -range;
                while (lx <= range) : (lx += 1) {
                    if (lx == 0 and lz == 0 and ly < y + height) continue;

                    if (lx * lx + lz * lz <= range * range + 1) {
                        const target_x = @as(i32, @intCast(x)) + lx;
                        const target_z = @as(i32, @intCast(z)) + lz;

                        if (target_x >= 0 and target_x < CHUNK_SIZE_X and
                            target_z >= 0 and target_z < CHUNK_SIZE_Z and
                            ly < CHUNK_SIZE_Y)
                        {
                            if (chunk.getBlock(@intCast(target_x), ly, @intCast(target_z)) == .air) {
                                chunk.setBlock(@intCast(target_x), ly, @intCast(target_z), .leaves);
                            }
                        }
                    }
                }
            }
        }
    }

    fn placeCactus(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, random: std.Random) void {
        _ = self;
        const height = 2 + random.uintLessThan(u32, 3);
        for (0..height) |i| {
            const cy = y + @as(u32, @intCast(i));
            if (cy < CHUNK_SIZE_Y) {
                chunk.setBlock(x, cy, z, .cactus);
            }
        }
    }
};
