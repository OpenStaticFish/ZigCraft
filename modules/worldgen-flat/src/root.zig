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
const LightingComputer = @import("worldgen-common").LightingComputer;

pub const FlatWorldGenerator = struct {
    seed: u64,
    allocator: std.mem.Allocator,

    const FLAT_HEIGHT: i32 = 64;

    pub const INFO = GeneratorInfo{
        .name = "Flat World",
        .description = "A perfectly flat world, ideal for testing and building.",
        .version = 1,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator) FlatWorldGenerator {
        return .{ .seed = seed, .allocator = allocator };
    }

    pub fn generate(self: *FlatWorldGenerator, chunk: *Chunk, stop_flag: ?*const bool) worldgen_api.WorldgenError!void {
        chunk.generated = false;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                chunk.setSurfaceHeight(local_x, local_z, @intCast(FLAT_HEIGHT));
                chunk.setBiome(local_x, local_z, .plains);

                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    const block: BlockType = if (y == 0)
                        .bedrock
                    else if (y < FLAT_HEIGHT - 3)
                        .stone
                    else if (y < FLAT_HEIGHT)
                        .dirt
                    else if (y == FLAT_HEIGHT)
                        .grass
                    else
                        .air;
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        try LightingComputer.computeSkylight(chunk, self.allocator);

        chunk.generated = true;
        chunk.dirty = true;
    }

    pub fn getSeed(self: *const FlatWorldGenerator) u64 {
        return self.seed;
    }

    pub fn getRegionInfo(self: *const FlatWorldGenerator, world_x: i32, world_z: i32) RegionInfo {
        _ = self;
        return .{ .mood = .calm, .role = .transit, .focus = .none, .center_x = world_x, .center_z = world_z };
    }

    pub fn getColumnInfo(self: *const FlatWorldGenerator, wx: f32, wz: f32) ColumnInfo {
        _ = self;
        _ = wx;
        _ = wz;
        return .{ .height = FLAT_HEIGHT, .biome = .plains, .is_ocean = false, .temperature = 0.5, .humidity = 0.5, .continentalness = 0.5 };
    }

    pub fn generator(self: *FlatWorldGenerator) Generator {
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
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        try self.generate(chunk, stop_flag);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!Generator {
    const gen = context.allocator.create(FlatWorldGenerator) catch return error.OutOfMemory;
    gen.* = FlatWorldGenerator.init(context.seed, context.allocator);
    return gen.generator();
}

test "FlatWorldGenerator propagates lighting allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var gen = FlatWorldGenerator.init(0, failing.allocator());
    var chunk = Chunk.init(0, 0);

    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:flat",
    .aliases = &.{"flat"},
    .info = FlatWorldGenerator.INFO,
    .create = create,
};
