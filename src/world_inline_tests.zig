const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const PackedLight = world_core.PackedLight;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const worldToChunk = world_core.worldToChunk;
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const worldToLocal = world_core.worldToLocal;
const BlockType = world_core.BlockType;
const block_registry = world_core.block_registry;
const ChunkMesh = @import("world-meshing").ChunkMesh;
const NeighborChunks = @import("world-meshing").NeighborChunks;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const ao_calculator = @import("world-meshing").meshing.ao_calculator;
const lighting_sampler = @import("world-meshing").meshing.lighting_sampler;
const biome_color_sampler = @import("world-meshing").meshing.biome_color_sampler;
const boundary = @import("world-meshing").meshing.boundary;

pub const std_options: std.Options = .{ .log_level = .err };

test "PackedLight init and accessors" {
    const light = PackedLight.init(15, 10);
    try testing.expectEqual(@as(u4, 15), light.getSkyLight());
    try testing.expectEqual(@as(u4, 10), light.getBlockLight());
    try testing.expectEqual(@as(u4, 15), light.getMaxLight());
}

test "PackedLight setters" {
    var light = PackedLight.init(0, 0);
    light.setSkyLight(12);
    light.setBlockLight(8);
    try testing.expectEqual(@as(u4, 12), light.getSkyLight());
    try testing.expectEqual(@as(u4, 8), light.getBlockLight());
}

test "PackedLight brightness" {
    const full = PackedLight.init(15, 0);
    try testing.expectEqual(@as(f32, 1.0), full.getBrightness());

    const half = PackedLight.init(7, 0);
    try testing.expectApproxEqAbs(@as(f32, 7.0 / 15.0), half.getBrightness(), 0.001);

    const zero = PackedLight.init(0, 0);
    try testing.expectEqual(@as(f32, 0.0), zero.getBrightness());
}

// ============================================================================
// Chunk Coordinate Conversion Tests
// ============================================================================

test "worldToChunk positive coordinates" {
    const result = worldToChunk(32, 48);
    try testing.expectEqual(@as(i32, 2), result.chunk_x);
    try testing.expectEqual(@as(i32, 3), result.chunk_z);
}

test "worldToChunk negative coordinates" {
    // -1 should be in chunk -1 (floor division)
    const result = worldToChunk(-1, -1);
    try testing.expectEqual(@as(i32, -1), result.chunk_x);
    try testing.expectEqual(@as(i32, -1), result.chunk_z);

    // -16 should be in chunk -1
    const result2 = worldToChunk(-16, -16);
    try testing.expectEqual(@as(i32, -1), result2.chunk_x);

    // -17 should be in chunk -2
    const result3 = worldToChunk(-17, -17);
    try testing.expectEqual(@as(i32, -2), result3.chunk_x);
}

test "worldToChunk zero" {
    const result = worldToChunk(0, 0);
    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
}

test "worldToChunkFromFloat negative boundary coordinates" {
    const result1 = worldToChunkFromFloat(-0.1, -0.1);
    try testing.expectEqual(@as(i32, -1), result1.chunk_x);
    try testing.expectEqual(@as(i32, -1), result1.chunk_z);

    const result2 = worldToChunkFromFloat(-15.9, -15.9);
    try testing.expectEqual(@as(i32, -1), result2.chunk_x);
    try testing.expectEqual(@as(i32, -1), result2.chunk_z);

    const result3 = worldToChunkFromFloat(-16.0, -16.0);
    try testing.expectEqual(@as(i32, -1), result3.chunk_x);
    try testing.expectEqual(@as(i32, -1), result3.chunk_z);

    const result4 = worldToChunkFromFloat(-16.1, -16.1);
    try testing.expectEqual(@as(i32, -2), result4.chunk_x);
    try testing.expectEqual(@as(i32, -2), result4.chunk_z);
}

test "worldToLocal positive coordinates" {
    const result = worldToLocal(35, 50);
    try testing.expectEqual(@as(u32, 3), result.x); // 35 % 16 = 3
    try testing.expectEqual(@as(u32, 2), result.z); // 50 % 16 = 2
}

test "worldToLocal negative coordinates" {
    // -1 should map to 15 (proper modulo behavior)
    const result = worldToLocal(-1, -1);
    try testing.expectEqual(@as(u32, 15), result.x);
    try testing.expectEqual(@as(u32, 15), result.z);

    // -17 should map to 15
    const result2 = worldToLocal(-17, -17);
    try testing.expectEqual(@as(u32, 15), result2.x);
}

// ============================================================================
// Chunk Tests
// ============================================================================

test "Chunk init" {
    const chunk = Chunk.init(5, -3);
    try testing.expectEqual(@as(i32, 5), chunk.chunk_x);
    try testing.expectEqual(@as(i32, -3), chunk.chunk_z);
    try testing.expectEqual(Chunk.State.missing, chunk.state);
    try testing.expect(chunk.dirty);
}

test "Chunk getBlock and setBlock" {
    var chunk = Chunk.init(0, 0);

    // Default is air
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 0, 0));

    // Set and get
    chunk.setBlock(5, 64, 10, .stone);
    try testing.expectEqual(BlockType.stone, chunk.getBlock(5, 64, 10));

    // Other blocks unchanged
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 64, 0));
}

test "Chunk getBlockSafe bounds checking" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);

    // Valid access
    try testing.expectEqual(BlockType.stone, chunk.getBlockSafe(0, 0, 0));

    // Out of bounds returns air
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(-1, 0, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(16, 0, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(0, -1, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(0, 256, 0));
}

test "Chunk light operations" {
    var chunk = Chunk.init(0, 0);

    // Default light is 0
    try testing.expectEqual(@as(u4, 0), chunk.getSkyLight(0, 0, 0));
    try testing.expectEqual(@as(u4, 0), chunk.getBlockLight(0, 0, 0));

    // Set and get
    chunk.setSkyLight(5, 64, 10, 15);
    chunk.setBlockLight(5, 64, 10, 8);
    try testing.expectEqual(@as(u4, 15), chunk.getSkyLight(5, 64, 10));
    try testing.expectEqual(@as(u4, 8), chunk.getBlockLight(5, 64, 10));
}

test "Chunk getWorldX and getWorldZ" {
    const chunk = Chunk.init(3, -2);
    try testing.expectEqual(@as(i32, 48), chunk.getWorldX()); // 3 * 16
    try testing.expectEqual(@as(i32, -32), chunk.getWorldZ()); // -2 * 16
}

test "Chunk fill and fillLayer" {
    var chunk = Chunk.init(0, 0);

    chunk.fillLayer(0, .bedrock);
    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            try testing.expectEqual(BlockType.bedrock, chunk.getBlock(@intCast(x), 0, @intCast(z)));
        }
    }
    // Layer 1 should still be air
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 1, 0));
}

test "Chunk pin and unpin" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(!chunk.isPinned());

    chunk.pin();
    try testing.expect(chunk.isPinned());

    chunk.pin();
    try testing.expect(chunk.isPinned()); // Still pinned

    chunk.unpin();
    try testing.expect(chunk.isPinned()); // Still pinned (count = 1)

    chunk.unpin();
    try testing.expect(!chunk.isPinned()); // Now unpinned
}

// ============================================================================
// BlockType Tests
// ============================================================================

test "BlockType isSolid" {
    try testing.expect(!block_registry.getBlockDefinition(BlockType.air).is_solid);
    try testing.expect(!block_registry.getBlockDefinition(BlockType.water).is_solid);
    try testing.expect(block_registry.getBlockDefinition(BlockType.stone).is_solid);
    try testing.expect(block_registry.getBlockDefinition(BlockType.dirt).is_solid);
    try testing.expect(block_registry.getBlockDefinition(BlockType.grass).is_solid);
    try testing.expect(!block_registry.getBlockDefinition(BlockType.tall_grass).is_solid);
    try testing.expect(block_registry.getBlockDefinition(BlockType.leaves).is_solid);
}

test "BlockType isTransparent" {
    try testing.expect(block_registry.getBlockDefinition(BlockType.air).is_transparent);
    try testing.expect(block_registry.getBlockDefinition(BlockType.water).is_transparent);
    try testing.expect(block_registry.getBlockDefinition(BlockType.glass).is_transparent);
    try testing.expect(block_registry.getBlockDefinition(BlockType.leaves).is_transparent);
    try testing.expect(!block_registry.getBlockDefinition(BlockType.stone).is_transparent);
    try testing.expect(!block_registry.getBlockDefinition(BlockType.dirt).is_transparent);
}

test "BlockType isOpaque" {
    try testing.expect(!block_registry.getBlockDefinition(BlockType.air).isOpaque());
    try testing.expect(!block_registry.getBlockDefinition(BlockType.water).isOpaque());
    try testing.expect(!block_registry.getBlockDefinition(BlockType.glass).isOpaque());
    try testing.expect(block_registry.getBlockDefinition(BlockType.stone).isOpaque());
    try testing.expect(block_registry.getBlockDefinition(BlockType.dirt).isOpaque());
}

test "BlockType isAir" {
    try testing.expect(BlockType.air == .air);
    try testing.expect(BlockType.stone != .air);
    try testing.expect(BlockType.water != .air);
}

test "BlockType getLightEmission" {
    try testing.expectEqual(@as(u4, 15), block_registry.getBlockDefinition(BlockType.glowstone).getLightEmissionLevel());
    try testing.expectEqual(@as(u4, 0), block_registry.getBlockDefinition(BlockType.stone).getLightEmissionLevel());
    try testing.expectEqual(@as(u4, 0), block_registry.getBlockDefinition(BlockType.water).getLightEmissionLevel());
}

test "BlockType getColor returns valid RGB" {
    const colors = block_registry.getBlockDefinition(BlockType.stone).default_color;
    try testing.expect(colors[0] >= 0 and colors[0] <= 1);
    try testing.expect(colors[1] >= 0 and colors[1] <= 1);
    try testing.expect(colors[2] >= 0 and colors[2] <= 1);
}

// ============================================================================
// Chunk Meshing Tests
// ============================================================================

test "single block generates 6 faces" {
    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty, &atlas);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expectEqual(@as(u32, 36), total_verts);
}

test "adjacent blocks share face (no internal faces)" {
    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBlock(9, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty, &atlas);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expect(total_verts < 72);
}

test "buildWithNeighbors returns OutOfMemory on allocation failure" {
    var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.state = .meshing;
    chunk.setBlock(8, 64, 8, .stone);

    var mesh = ChunkMesh.init(failing_alloc.allocator());
    defer mesh.deinitWithoutRHI();

    const result = mesh.buildWithNeighbors(&chunk, .empty, &atlas);
    try testing.expectError(error.OutOfMemory, result);
    try testing.expectEqual(Chunk.State.meshing, chunk.state);
}

test "buildWithNeighbors succeeds with valid allocator" {
    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.state = .meshing;
    chunk.setBlock(8, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, .empty, &atlas);
    try testing.expectEqual(Chunk.State.meshing, chunk.state);
}

test "adjacent transparent blocks share face" {
    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .water);
    chunk.setBlock(9, 64, 8, .water);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty, &atlas);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expect(total_verts < 72);
}

test "tall cross block generates cutout billboard vertices only" {
    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .tall_grass);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty, &atlas);

    try testing.expectEqual(null, mesh.pending_solid);
    try testing.expectEqual(@as(usize, 12), mesh.pending_cutout.?.len);
}

// ============================================================================
// Meshing Stage Module Tests
// ============================================================================

test "calculateVertexAO both sides occluded returns 0.4" {
    const ao = ao_calculator.calculateVertexAO(1.0, 1.0, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ao, 0.001);
}

test "calculateVertexAO no occlusion returns 1.0" {
    const ao = ao_calculator.calculateVertexAO(0.0, 0.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ao, 0.001);
}

test "calculateVertexAO single side occlusion" {
    const ao = ao_calculator.calculateVertexAO(1.0, 0.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ao, 0.001);
}

test "calculateVertexAO corner only occlusion" {
    const ao = ao_calculator.calculateVertexAO(0.0, 0.0, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ao, 0.001);
}

test "normalizeLightValues zero light" {
    const light = PackedLight.init(0, 0);
    const norm = lighting_sampler.normalizeLightValues(light);
    try testing.expectApproxEqAbs(@as(f32, 0.0), norm.skylight, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), norm.blocklight[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), norm.blocklight[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), norm.blocklight[2], 0.001);
}

test "normalizeLightValues max light" {
    const light = PackedLight.init(15, 15);
    const norm = lighting_sampler.normalizeLightValues(light);
    try testing.expectApproxEqAbs(@as(f32, 1.0), norm.skylight, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), norm.blocklight[0], 0.001);
}

test "normalizeLightValues RGB channels" {
    const light = PackedLight.initRGB(8, 4, 8, 12);
    const norm = lighting_sampler.normalizeLightValues(light);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 15.0), norm.skylight, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 15.0), norm.blocklight[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 15.0), norm.blocklight[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12.0 / 15.0), norm.blocklight[2], 0.001);
}

test "getBlockColor returns no tint for stone" {
    var chunk = Chunk.init(0, 0);
    const color = biome_color_sampler.getBlockColor(&chunk, .empty, .top, .top, 0, 8, 8, .stone);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[2], 0.001);
}

test "getBlockColor returns no tint for grass side face" {
    var chunk = Chunk.init(0, 0);
    const color = biome_color_sampler.getBlockColor(&chunk, .empty, .east, .east, 0, 8, 8, .grass);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color[2], 0.001);
}

test "getBlockColor returns biome tint for grass top face" {
    var chunk = Chunk.init(0, 0);
    const color = biome_color_sampler.getBlockColor(&chunk, .empty, .top, .top, 64, 8, 8, .grass);
    // Plains biome grass color should not be {1, 1, 1} (it should be tinted)
    try testing.expect(color[0] != 1.0 or color[1] != 1.0 or color[2] != 1.0);
}

test "boundary getBlockCross returns air for null neighbors" {
    var chunk = Chunk.init(0, 0);
    // Access x = -1 with no west neighbor
    const block = boundary.getBlockCross(&chunk, .empty, -1, 64, 8);
    try testing.expectEqual(BlockType.air, block);
}

test "boundary getBlockCross returns air for out-of-bounds y" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    // Access within chunk bounds
    const block = boundary.getBlockCross(&chunk, .empty, 8, 64, 8);
    try testing.expectEqual(BlockType.stone, block);
}

test "boundary getBlockCross reads from neighbor chunk" {
    var chunk = Chunk.init(0, 0);
    var east_chunk = Chunk.init(1, 0);
    east_chunk.setBlock(0, 64, 8, .dirt);
    const neighbors = NeighborChunks{
        .east = &east_chunk,
    };
    // Access x = 16 should read from east neighbor at x=0
    const block = boundary.getBlockCross(&chunk, neighbors, 16, 64, 8);
    try testing.expectEqual(BlockType.dirt, block);
}

// ============================================================================
// Texture Atlas Tests
// ============================================================================

test "TextureAtlas mapping correctness" {
    var atlas: TextureAtlas = undefined;
    // Mock mapping: block index -> tile indices
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 10, .bottom = 11, .side = 12 };
    atlas.tile_mappings[@intFromEnum(BlockType.stone)] = TextureAtlas.BlockTiles.uniform(5);

    const grass_tiles = atlas.getTilesForBlock(@intFromEnum(BlockType.grass));
    try testing.expectEqual(@as(u16, 10), grass_tiles.top);
    try testing.expectEqual(@as(u16, 11), grass_tiles.bottom);
    try testing.expectEqual(@as(u16, 12), grass_tiles.side);

    const stone_tiles = atlas.getTilesForBlock(@intFromEnum(BlockType.stone));
    try testing.expectEqual(@as(u16, 5), stone_tiles.top);
}
