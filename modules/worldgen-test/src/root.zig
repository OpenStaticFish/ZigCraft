const std = @import("std");
const worldgen_api = @import("worldgen-api");
const Generator = worldgen_api.Generator;
const GeneratorInfo = worldgen_api.GeneratorInfo;
const ColumnInfo = worldgen_api.ColumnInfo;
const RegionInfo = worldgen_api.RegionInfo;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const build_options = @import("worldgen_test_options");
const LightingComputer = @import("worldgen-common").LightingComputer;

pub const ShadowTestWorldGenerator = struct {
    seed: u64,
    allocator: std.mem.Allocator,

    const GROUND_Y: i32 = 63;
    const CAVE_MIN_X: i32 = -8;
    const CAVE_MAX_X: i32 = 8;
    const CAVE_MIN_Z: i32 = -22;
    const CAVE_MAX_Z: i32 = 14;
    const CAVE_MIN_Y: i32 = GROUND_Y + 1;
    const CAVE_MAX_Y: i32 = GROUND_Y + 11;

    pub const INFO = GeneratorInfo{
        .name = "Shadow Test Scene",
        .description = "Deterministic low-block scene for shadow and cave entrance lighting captures.",
        .version = 1,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator) ShadowTestWorldGenerator {
        return .{ .seed = seed, .allocator = allocator };
    }

    pub fn generate(self: *ShadowTestWorldGenerator, chunk: *Chunk, stop_flag: ?*const bool) worldgen_api.WorldgenError!void {
        chunk.generated = false;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx = chunkWorldOffset(chunk.chunk_x, local_x, CHUNK_SIZE_X);
                const wz = chunkWorldOffset(chunk.chunk_z, local_z, CHUNK_SIZE_Z);
                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    chunk.setBlock(local_x, @intCast(y), local_z, blockAt(wx, y, wz));
                }
            }
        }

        updateColumnMetadata(chunk);
        try LightingComputer.computeSkylight(chunk, self.allocator);
        try LightingComputer.computeBlockLight(chunk, self.allocator);

        chunk.generated = true;
        chunk.dirty = true;
    }

    fn blockAt(wx: i32, y: i32, wz: i32) BlockType {
        if (isDugCaveVariant()) return dugCaveBlockAt(wx, y, wz);

        if (y == 0) return .bedrock;
        if (y < GROUND_Y) return .stone;
        if (isWaterPool(wx, y, wz)) return if (y == GROUND_Y) .sand else .water;
        if (y == GROUND_Y) return if (insideCaveFootprint(wx, wz)) .stone else .grass;
        if (isCaveShell(wx, y, wz)) return .stone;
        if (isSealedCaveShell(wx, y, wz)) return .stone;
        if (isEmitterRoomShell(wx, y, wz)) return .white_terracotta;
        if (wx == -46 and wz == 0 and y == GROUND_Y + 3) return .glowstone;
        if (isCrossChunkCorridorShell(wx, y, wz)) return .cobblestone;
        if (isBendOccluder(wx, y, wz)) return .stone;
        if (isStonePillar(wx, y, wz)) return .stone;
        if (isTreeTrunk(wx, y, wz)) return .wood;
        if (isTreeCanopy(wx, y, wz)) return .leaves;
        return .air;
    }

    fn dugCaveBlockAt(wx: i32, y: i32, wz: i32) BlockType {
        if (y == 0) return .bedrock;
        if (y < GROUND_Y) return .stone;
        if (y == GROUND_Y) return if (insideDugCaveFootprint(wx, wz)) .stone else .grass;
        if (isDugTunnelAir(wx, y, wz)) return .air;
        if (isDugCaveMass(wx, y, wz)) return if (y == GROUND_Y + 11) .grass else .dirt;
        if (isTreeTrunk(wx, y, wz)) return .wood;
        if (isTreeCanopy(wx, y, wz)) return .leaves;
        return .air;
    }

    fn isDugCaveVariant() bool {
        return std.ascii.eqlIgnoreCase(build_options.shadow_test_variant, "dug-cave") or std.ascii.eqlIgnoreCase(build_options.shadow_test_variant, "dug");
    }

    fn insideDugCaveFootprint(wx: i32, wz: i32) bool {
        return wx >= -7 and wx <= 7 and wz >= -22 and wz <= 14;
    }

    fn isDugCaveMass(wx: i32, y: i32, wz: i32) bool {
        return insideDugCaveFootprint(wx, wz) and y >= GROUND_Y + 1 and y <= GROUND_Y + 11;
    }

    fn isDugTunnelAir(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 1 or y > GROUND_Y + 6) return false;
        if (wz < -22 or wz > 14) return false;
        return wx >= -4 and wx <= 4;
    }

    fn insideCaveFootprint(wx: i32, wz: i32) bool {
        return wx >= CAVE_MIN_X and wx <= CAVE_MAX_X and wz >= CAVE_MIN_Z and wz <= CAVE_MAX_Z;
    }

    fn isCaveShell(wx: i32, y: i32, wz: i32) bool {
        if (!insideCaveFootprint(wx, wz) or y < CAVE_MIN_Y or y > CAVE_MAX_Y) return false;
        return y == CAVE_MAX_Y or wx == CAVE_MIN_X or wx == CAVE_MAX_X or wz == CAVE_MIN_Z;
    }

    fn isBendOccluder(wx: i32, y: i32, wz: i32) bool {
        if (y < CAVE_MIN_Y or y >= CAVE_MAX_Y) return false;
        return rect(wx, wz, CAVE_MIN_X + 1, 3, -5, -3);
    }

    fn isStonePillar(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 1 or y > GROUND_Y + 13) return false;
        if (rect(wx, wz, -4, -3, -6, -5)) return y <= GROUND_Y + 9;
        if (rect(wx, wz, 3, 4, 2, 3)) return y <= GROUND_Y + 9;
        if (rect(wx, wz, -6, -5, 18, 19)) return true;
        if (rect(wx, wz, 5, 6, 18, 19)) return true;
        return y == GROUND_Y + 13 and wx >= -6 and wx <= 6 and wz >= 18 and wz <= 19;
    }

    fn isTreeTrunk(wx: i32, y: i32, wz: i32) bool {
        return wx == 12 and wz == 20 and y >= GROUND_Y + 1 and y <= GROUND_Y + 7;
    }

    fn isTreeCanopy(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 6 or y > GROUND_Y + 10) return false;
        const dx = absDiffI32(wx, 12);
        const dz = absDiffI32(wz, 20);
        const radius: u64 = if (y == GROUND_Y + 10) 1 else 3;
        return dx <= radius and dz <= radius and !(dx == 3 and dz == 3);
    }

    fn isWaterPool(wx: i32, y: i32, wz: i32) bool {
        return rect(wx, wz, 20, 30, -6, 6) and y >= GROUND_Y and y <= GROUND_Y + 2;
    }

    fn isSealedCaveShell(wx: i32, y: i32, wz: i32) bool {
        if (!rect(wx, wz, -32, -18, -8, 8) or y < GROUND_Y + 1 or y > GROUND_Y + 8) return false;
        return wx == -32 or wx == -18 or wz == -8 or wz == 8 or y == GROUND_Y + 8;
    }

    fn isEmitterRoomShell(wx: i32, y: i32, wz: i32) bool {
        if (!rect(wx, wz, -54, -38, -8, 8) or y < GROUND_Y + 1 or y > GROUND_Y + 8) return false;
        return wx == -54 or wx == -38 or wz == -8 or wz == 8 or y == GROUND_Y + 8;
    }

    fn isCrossChunkCorridorShell(wx: i32, y: i32, wz: i32) bool {
        if (!rect(wx, wz, 8, 24, 28, 36) or y < GROUND_Y + 1 or y > GROUND_Y + 7) return false;
        return wz == 28 or wz == 36 or y == GROUND_Y + 7;
    }

    fn rect(wx: i32, wz: i32, min_x: i32, max_x: i32, min_z: i32, max_z: i32) bool {
        return wx >= min_x and wx <= max_x and wz >= min_z and wz <= max_z;
    }

    fn updateColumnMetadata(chunk: *Chunk) void {
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                chunk.setBiome(local_x, local_z, .plains);
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const block = chunk.getBlock(local_x, @intCast(y), local_z);
                    if (block != .air and block != .water) {
                        chunk.setSurfaceHeight(local_x, local_z, @intCast(y));
                        break;
                    }
                }
            }
        }
    }

    pub fn getSeed(self: *const ShadowTestWorldGenerator) u64 {
        return self.seed;
    }

    pub fn getRegionInfo(self: *const ShadowTestWorldGenerator, world_x: i32, world_z: i32) RegionInfo {
        _ = self;
        return .{ .mood = .calm, .role = .destination, .focus = .none, .center_x = world_x, .center_z = world_z };
    }

    pub fn getColumnInfo(self: *const ShadowTestWorldGenerator, wx: f32, wz: f32) ColumnInfo {
        _ = self;
        _ = wx;
        _ = wz;
        return .{ .height = GROUND_Y, .biome = .plains, .is_ocean = false, .temperature = 0.5, .humidity = 0.5, .continentalness = 0.5 };
    }

    pub fn generator(self: *ShadowTestWorldGenerator) Generator {
        return .{ .ptr = self, .vtable = &VTABLE, .info = INFO };
    }

    const VTABLE = Generator.VTable{
        .generate = generateWrapper,
        .getSeed = getSeedWrapper,
        .getRegionInfo = getRegionInfoWrapper,
        .getColumnInfo = getColumnInfoWrapper,
        .column_info_thread_safe = true,
        .deinit = deinitWrapper,
    };

    fn generateWrapper(ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) worldgen_api.WorldgenError!void {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        try self.generate(chunk, stop_flag);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

fn chunkWorldOffset(chunk_coord: i32, local_offset: anytype, chunk_size: anytype) i32 {
    return clampI32(@as(i64, chunk_coord) * @as(i64, @intCast(chunk_size)) + @as(i64, @intCast(local_offset)));
}

fn absDiffI32(a: i32, b: i32) u64 {
    const diff = @as(i64, a) - @as(i64, b);
    return @intCast(if (diff < 0) -diff else diff);
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!Generator {
    const gen = context.allocator.create(ShadowTestWorldGenerator) catch return error.OutOfMemory;
    gen.* = ShadowTestWorldGenerator.init(context.seed, context.allocator);
    return gen.generator();
}

test "ShadowTestWorldGenerator propagates lighting allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var gen = ShadowTestWorldGenerator.init(0, failing.allocator());
    var chunk = Chunk.init(0, 0);

    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}

test "lighting baseline corridor crosses the x chunk boundary" {
    try std.testing.expectEqual(BlockType.air, ShadowTestWorldGenerator.blockAt(15, ShadowTestWorldGenerator.GROUND_Y + 2, 32));
    try std.testing.expectEqual(BlockType.air, ShadowTestWorldGenerator.blockAt(16, ShadowTestWorldGenerator.GROUND_Y + 2, 32));
    try std.testing.expectEqual(BlockType.cobblestone, ShadowTestWorldGenerator.blockAt(15, ShadowTestWorldGenerator.GROUND_Y + 2, 28));
    try std.testing.expectEqual(BlockType.cobblestone, ShadowTestWorldGenerator.blockAt(16, ShadowTestWorldGenerator.GROUND_Y + 2, 28));
}

test "lighting baseline contains water and an RGB emitter" {
    try std.testing.expectEqual(BlockType.water, ShadowTestWorldGenerator.blockAt(25, ShadowTestWorldGenerator.GROUND_Y + 1, 0));
    try std.testing.expectEqual(BlockType.glowstone, ShadowTestWorldGenerator.blockAt(-46, ShadowTestWorldGenerator.GROUND_Y + 3, 0));
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:shadow-test",
    .aliases = &.{ "test", "shadow-test", "lighting-test" },
    .info = ShadowTestWorldGenerator.INFO,
    .create = create,
};
