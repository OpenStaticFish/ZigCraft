const std = @import("std");
const testing = std.testing;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const OverworldGenerator = @import("overworld_generator.zig").OverworldGenerator;
const StandardDecorationProvider = @import("decoration_registry.zig").StandardDecorationProvider;
const terrain_shape = @import("terrain_shape_generator.zig");
const ChunkSummary = world_core.lod_scene.ChunkSummary;

// Seed 12345: water/transition, schematic foliage, and a steep wooded transition.
const positions = [_][2]i32{ .{ -32, -32 }, .{ 4, -32 }, .{ -136, -512 } };

fn expectSameChunk(expected: *const Chunk, actual: *const Chunk) !void {
    try testing.expect(expected.generated and actual.generated);
    try testing.expectEqualSlices(world_core.BlockType, &expected.blocks, &actual.blocks);
    try testing.expectEqualSlices(world_core.BiomeId, &expected.biomes, &actual.biomes);
    try testing.expectEqualSlices(i16, &expected.heightmap, &actual.heightmap);
    try testing.expectEqualSlices(world_core.PackedLight, &expected.light, &actual.light);
    var expected_summary = try ChunkSummary.capture(testing.allocator, expected);
    defer expected_summary.deinit();
    var actual_summary = try ChunkSummary.capture(testing.allocator, actual);
    defer actual_summary.deinit();
    try expected_summary.validate();
    try actual_summary.validate();
    try testing.expectEqual(expected_summary.fingerprint(), actual_summary.fingerprint());
    try testing.expectEqualDeep(expected_summary.columns, actual_summary.columns);
    try testing.expectEqualDeep(expected_summary.runs, actual_summary.runs);
}

test "summary equivalence full chunks survive warm caches and recentering" {
    var gen = OverworldGenerator.init(12345, testing.allocator, StandardDecorationProvider.provider());
    defer gen.deinit();
    for (positions, 0..) |pos, fixture| {
        const wx = pos[0] * 16;
        const wz = pos[1] * 16;
        _ = gen.maybeRecenterCache(wx, wz);
        var expected = Chunk.init(pos[0], pos[1]);
        try gen.generator().generate(&expected, null);
        try testing.expect(gen.classification_cache.has(wx, wz));

        // Guard the fixtures against silently degenerating into plain heightfields.
        if (fixture == 0) try testing.expect(std.mem.indexOfScalar(world_core.BlockType, &expected.blocks, .water) != null);
        if (fixture == 1) {
            try testing.expect(std.mem.indexOfScalar(world_core.BlockType, &expected.blocks, .spruce_log) != null);
            try testing.expect(std.mem.indexOfScalar(world_core.BlockType, &expected.blocks, .spruce_leaves) != null);
        }
        if (fixture == 2) {
            var phase: terrain_shape.ChunkPhaseData = undefined;
            try testing.expect(gen.terrain_shape.prepareChunkPhaseData(&phase, wx, wz, null));
            try testing.expect(for (phase.biome_blends) |blend| {
                if (blend > 0) break true;
            } else false);
            try testing.expect(for (phase.slopes, phase.surface_heights) |slope, height| {
                if (slope >= 5 and height > 64) break true;
            } else false);
        }

        var actual = Chunk.init(pos[0], pos[1]);
        try gen.generator().generate(&actual, null);
        try expectSameChunk(&expected, &actual);

        // Still inside cache coverage, but outside the old 256-block transition gate.
        try testing.expect(gen.maybeRecenterCache(wx + 768, wz));
        try testing.expect(gen.classification_cache.contains(wx, wz));
        try testing.expect(!gen.classification_cache.has(wx, wz));
        var neighbor = Chunk.init(pos[0] + 1, pos[1]);
        try gen.generate(&neighbor, null);
        _ = gen.getMapSampleReduced(@floatFromInt(wx), @floatFromInt(wz), 0);
        actual = Chunk.init(pos[0], pos[1]);
        try gen.generator().generate(&actual, null);
        try testing.expectEqual(wx + 768, gen.cache_center_x);
        try expectSameChunk(&expected, &actual);

        try testing.expect(gen.maybeRecenterCache(wx + 4096, wz));
        try testing.expect(!gen.classification_cache.contains(wx, wz));
        actual = Chunk.init(pos[0], pos[1]);
        try gen.generator().generate(&actual, null);
        try testing.expectEqual(wx, gen.cache_center_x);
        try expectSameChunk(&expected, &actual);
    }
}

test "summary equivalence full chunks are independent of generation order" {
    var forward = OverworldGenerator.init(12345, testing.allocator, StandardDecorationProvider.provider());
    defer forward.deinit();
    var reverse = OverworldGenerator.init(12345, testing.allocator, StandardDecorationProvider.provider());
    defer reverse.deinit();
    const expected = try testing.allocator.alloc(Chunk, positions.len);
    defer testing.allocator.free(expected);
    for (positions, expected) |pos, *chunk| {
        chunk.* = Chunk.init(pos[0], pos[1]);
        try forward.generate(chunk, null);
    }
    for (0..positions.len) |i| {
        const index = positions.len - 1 - i;
        const pos = positions[index];
        var actual = Chunk.init(pos[0], pos[1]);
        try reverse.generate(&actual, null);
        try expectSameChunk(&expected[index], &actual);
    }
}

test "summary equivalence provisional LOD ignores classification availability" {
    var gen = OverworldGenerator.init(12345, testing.allocator, StandardDecorationProvider.provider());
    defer gen.deinit();
    for (positions) |pos| {
        var expected = try world_core.LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 17);
        defer expected.deinit();
        var actual = try world_core.LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 17);
        defer actual.deinit();
        const region_size: i32 = @intCast(world_core.regionSizeBlocks(.lod0));
        const rx = @divFloor(pos[0] * 16, region_size);
        const rz = @divFloor(pos[1] * 16, region_size);
        try testing.expect(gen.maybeRecenterCache(pos[0] * 16 + 4096, pos[1] * 16));
        gen.generateHeightmapOnly(&expected, rx, rz, .lod0, null);
        var chunk = Chunk.init(pos[0], pos[1]);
        try gen.generate(&chunk, null);
        try testing.expect(gen.classification_cache.has(pos[0] * 16, pos[1] * 16));
        for (0..2) |state| {
            if (state == 1) try testing.expect(gen.maybeRecenterCache(pos[0] * 16 + 768, pos[1] * 16));
            gen.generateHeightmapOnly(&actual, rx, rz, .lod0, null);
            inline for (.{ "heightmap", "biomes", "top_blocks", "colors", "material_layers", "water", "lighting", "vegetation", "provenance" }) |field| {
                try testing.expectEqualDeep(@field(expected, field), @field(actual, field));
            }
        }
    }
}
