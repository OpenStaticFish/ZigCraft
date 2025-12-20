//! Terrain generator using noise functions.

const std = @import("std");
const Noise = @import("noise.zig").Noise;
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;

pub const TerrainGenerator = struct {
    // Noise generators for different layers
    continentalness_noise: Noise,
    erosion_noise: Noise,
    peaks_valleys_noise: Noise,
    temperature_noise: Noise,
    humidity_noise: Noise,
    river_noise: Noise,
    cave_noise: Noise,

    // Terrain parameters
    sea_level: i32 = 64,

    pub fn init(seed: u64) TerrainGenerator {
        // Derive seeds for different layers to ensure they are independent
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        return .{
            .continentalness_noise = Noise.init(random.int(u64)),
            .erosion_noise = Noise.init(random.int(u64)),
            .peaks_valleys_noise = Noise.init(random.int(u64)),
            .temperature_noise = Noise.init(random.int(u64)),
            .humidity_noise = Noise.init(random.int(u64)),
            .river_noise = Noise.init(random.int(u64)),
            .cave_noise = Noise.init(random.int(u64)),
        };
    }

    /// Generate terrain for a chunk
    pub fn generate(self: *const TerrainGenerator, chunk: *Chunk) void {
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // 1. Compute Global Maps
                const continentalness = self.getContinentalness(wx, wz);
                const erosion = self.getErosion(wx, wz);
                const peaks_valleys = self.getPeaksValleys(wx, wz);
                const river_val = self.getRiverValue(wx, wz);

                // 2. Compute Base Height
                var height_val = self.computeHeight(continentalness, erosion, peaks_valleys);

                // River Carving
                if (river_val < 0.05) { // River threshold
                    // Carve down to slightly below sea level or smooth it out
                    // Normalize river value 0..0.05 to 0..1 for depth blending
                    const t = river_val / 0.05;
                    const river_bed = @as(f32, @floatFromInt(self.sea_level - 2));
                    height_val = std.math.lerp(river_bed, height_val, t * t); // Quadratic ease-out for banks
                }

                const terrain_height: i32 = @intFromFloat(height_val);

                // 3. Biome info (for surface blocks)
                const temperature = self.temperature_noise.fbm2D(wx, wz, 2, 2.0, 0.5, 0.002);
                const humidity = self.humidity_noise.fbm2D(wx, wz, 2, 2.0, 0.5, 0.002);

                // Fill column
                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height, continentalness, temperature, humidity);

                    // Cave carving
                    if (block != .air and block != .water and block != .bedrock) {
                        const wy: f32 = @floatFromInt(y);
                        // 3D noise for caves. Scale 0.04 seems reasonable for "cheese" caves
                        const cave_val = self.cave_noise.perlin3D(wx * 0.04, wy * 0.04, wz * 0.04);
                        if (cave_val > 0.4) {
                            block = .air;
                        }
                    }

                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        chunk.generated = true;

        // 4. Ores
        self.generateOres(chunk);

        // 5. Decorate (Trees, Cacti, etc.)
        self.generateFeatures(chunk);

        chunk.dirty = true;
    }

    fn generateOres(self: *const TerrainGenerator, chunk: *Chunk) void {
        // Seed based on chunk and salt
        var prng = std.Random.DefaultPrng.init(self.erosion_noise.seed +% @as(u64, @bitCast(@as(i64, chunk.chunk_x))) *% 59381 +% @as(u64, @bitCast(@as(i64, chunk.chunk_z))) *% 28411);
        const random = prng.random();

        self.placeOreVeins(chunk, .coal_ore, 20, 6, 10, 128, random);
        self.placeOreVeins(chunk, .iron_ore, 10, 4, 5, 64, random);
        self.placeOreVeins(chunk, .gold_ore, 3, 3, 2, 32, random);
    }

    fn placeOreVeins(self: *const TerrainGenerator, chunk: *Chunk, block: BlockType, count: u32, size: u32, min_y: i32, max_y: i32, random: std.Random) void {
        _ = self;
        for (0..count) |_| {
            const cx = random.uintLessThan(u32, CHUNK_SIZE_X);
            const cz = random.uintLessThan(u32, CHUNK_SIZE_Z);
            const range = max_y - min_y;
            if (range <= 0) continue;
            const cy = min_y + @as(i32, @intCast(random.uintLessThan(u32, @intCast(range))));

            // Simple blob vein
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
                    chunk.setBlock(@intCast(tx), @intCast(ty), @intCast(tz), block);
                }
            }
        }
    }

    fn generateFeatures(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(self.continentalness_noise.seed ^ @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^ (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32));
        const random = prng.random();

        // Attempt to place features

        // Oases (Rare, Desert only)
        if (random.float(f32) < 0.02) {
            const wx = @as(f32, @floatFromInt(chunk.getWorldX() + 8));
            const wz = @as(f32, @floatFromInt(chunk.getWorldZ() + 8));
            const temp = self.temperature_noise.fbm2D(wx, wz, 2, 2.0, 0.5, 0.002);
            const humidity = self.humidity_noise.fbm2D(wx, wz, 2, 2.0, 0.5, 0.002);

            if (temp > 0.5 and humidity < -0.2) {
                self.placeOasis(chunk, 8, 8);
            }
        }

        // Simple approach: try N times
        const attempts = 10;
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
                if (random.float(f32) < 0.05) { // 5% chance per attempt on grass
                    self.placeTree(chunk, lx, @intCast(y + 1), lz, random);
                }
            }
            // Cactus placement (on sand)
            else if (surface_block == .sand) {
                if (random.float(f32) < 0.02) { // 2% chance on sand
                    self.placeCactus(chunk, lx, @intCast(y + 1), lz, random);
                }
            }
        }
    }

    fn placeOasis(self: *const TerrainGenerator, chunk: *Chunk, cx: u32, cz: u32) void {
        _ = self;
        var cy: i32 = CHUNK_SIZE_Y - 1;
        while (cy > 0) : (cy -= 1) {
            if (chunk.getBlock(cx, @intCast(cy), cz) != .air) break;
        }

        const radius = 6;
        var z: i32 = -radius;
        while (z <= radius) : (z += 1) {
            var x: i32 = -radius;
            while (x <= radius) : (x += 1) {
                const dist = x * x + z * z;
                if (dist < radius * radius) {
                    const tx = @as(i32, @intCast(cx)) + x;
                    const tz = @as(i32, @intCast(cz)) + z;

                    if (tx >= 0 and tx < CHUNK_SIZE_X and tz >= 0 and tz < CHUNK_SIZE_Z) {
                        // Water pool
                        chunk.setBlock(@intCast(tx), @intCast(cy), @intCast(tz), .water);
                        if (cy > 0) chunk.setBlock(@intCast(tx), @intCast(cy - 1), @intCast(tz), .water);
                        if (cy > 1) chunk.setBlock(@intCast(tx), @intCast(cy - 2), @intCast(tz), .sand);

                        // Palm trees around edge
                        if (dist > (radius - 3) * (radius - 3) and @mod(x + z, 4) == 0) {
                            if (cy + 4 < CHUNK_SIZE_Y) {
                                chunk.setBlock(@intCast(tx), @intCast(cy + 1), @intCast(tz), .wood);
                                chunk.setBlock(@intCast(tx), @intCast(cy + 2), @intCast(tz), .wood);
                                chunk.setBlock(@intCast(tx), @intCast(cy + 3), @intCast(tz), .wood);
                                chunk.setBlock(@intCast(tx), @intCast(cy + 4), @intCast(tz), .leaves);
                            }
                        }
                    }
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

        // Leaves (very simple blob)
        const leaf_start = y + height - 2;
        const leaf_end = y + height + 1;

        var ly: u32 = leaf_start;
        while (ly <= leaf_end) : (ly += 1) {
            const range: i32 = if (ly == leaf_end) 1 else 2;
            var lz: i32 = -range;
            while (lz <= range) : (lz += 1) {
                var lx: i32 = -range;
                while (lx <= range) : (lx += 1) {
                    // Don't replace trunk
                    if (lx == 0 and lz == 0 and ly < y + height) continue;

                    // Simple distance check for roundness
                    if (lx * lx + lz * lz <= range * range + 1) {
                        const target_x = @as(i32, @intCast(x)) + lx;
                        const target_z = @as(i32, @intCast(z)) + lz;

                        // Check bounds (simple v1: only place if inside chunk)
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

    fn getContinentalness(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        // Large scale features: 0.002 frequency
        return self.continentalness_noise.fbm2D(x, z, 3, 2.0, 0.5, 0.002);
    }

    fn getErosion(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        return self.erosion_noise.fbm2D(x, z, 3, 2.0, 0.5, 0.003);
    }

    fn getPeaksValleys(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        return self.peaks_valleys_noise.fbm2D(x, z, 4, 2.0, 0.5, 0.008);
    }

    fn getRiverValue(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        // Rivers are low frequency, winding. We use abs(noise) close to 0.
        // Frequency: 0.001 (very large scale)
        const val = self.river_noise.fbm2D(x, z, 4, 2.0, 0.5, 0.0015);
        return @abs(val);
    }

    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32) f32 {
        _ = e; // Erosion could smooth things out later

        // Base height from continentalness
        // c in [-1, 1]
        // -1.0 .. -0.2 => Deep Ocean / Ocean
        // -0.2 .. 0.0  => Coast
        // 0.0 .. 1.0   => Land / Mountains

        var base_height: f32 = @floatFromInt(self.sea_level);

        if (c < -0.3) {
            // Deep Ocean
            base_height += c * 30.0;
        } else if (c < 0.1) {
            // Ocean/Beach transition
            base_height += c * 10.0;
        } else {
            // Land
            base_height += c * 50.0;

            // Add peaks and valleys on land
            base_height += pv * 20.0;
        }

        return base_height;
    }

    fn getBlockAt(self: *const TerrainGenerator, y: i32, terrain_height: i32, continentalness: f32, temp: f32, humidity: f32) BlockType {
        if (y == 0) return .bedrock;

        if (y > terrain_height) {
            if (y <= self.sea_level) return .water;
            return .air;
        }

        // Surface blocks
        if (y == terrain_height) {
            if (y <= self.sea_level + 1 and continentalness < 0.15) {
                return .sand; // Beach
            }
            if (temp < -0.3) return .snow_block; // Cold biome
            if (temp > 0.5 and humidity < -0.2) return .sand; // Desert
            return .grass;
        }

        // Subsurface
        if (y > terrain_height - 4) {
            if (y <= self.sea_level + 1 and continentalness < 0.15) {
                return .sand;
            }
            if (temp > 0.5 and humidity < -0.2) return .sand; // Desert sand depth
            return .dirt;
        }

        return .stone;
    }
};
