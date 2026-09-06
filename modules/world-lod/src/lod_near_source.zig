//! Exact horizontal ownership for chunk-derived, one-block near LOD columns.
//! Capture only stable final chunk contents; the manager owns locking, lifetime,
//! coordinates, provenance, and invalidation of the resulting snapshot.

const std = @import("std");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const LODSimplifiedData = world_core.LODSimplifiedData;
const LODColumnProvenance = world_core.LODColumnProvenance;
const LODMaterialLayers = world_core.LODMaterialLayers;
const LODWaterState = world_core.LODWaterState;
const LODLightingHint = world_core.LODLightingHint;
const LODVegetationHint = world_core.LODVegetationHint;
const LODVerticalSpan = world_core.LODVerticalSpan;
const biome_color_provider = @import("biome_color_provider.zig");

pub const NearChunkSummary = struct {
    const Column = struct {
        // Zero top is explicitly empty; u16 preserves the top face at Y=256.
        terrain_top: u16 = 0,
        water_min: u16 = world_core.CHUNK_SIZE_Y,
        water_top: u16 = 0,
        log_min: u16 = world_core.CHUNK_SIZE_Y,
        log_top: u16 = 0,
        leaf_min: u16 = world_core.CHUNK_SIZE_Y,
        leaf_top: u16 = 0,
        layers: LODMaterialLayers = LODMaterialLayers.default(.air),
        trunk: BlockType = .air,
        leaves: BlockType = .air,
        biome: world_core.BiomeId = .plains,
        // Terrain, water, log/root/stem, and leaf/cap top-face samples.
        lights: [4]world_core.PackedLight = @splat(.{}),
    };

    columns: [world_core.CHUNK_SIZE_X * world_core.CHUNK_SIZE_Z]Column,

    /// Scans every final block once in storage order, independent of cached
    /// heightmaps. Log/leaf species are the highest actual block of each kind.
    /// Water/log/leaf envelopes include gaps, with inclusive minima and
    /// exclusive maxima. Water depth is its envelope thickness, not a guessed
    /// fill from terrain. No terrain is represented by zero top and air layers.
    /// Roots/mushroom stems use the log envelope; mushroom caps use the canopy
    /// envelope with their actual materials (mesh predicates must accept them).
    pub fn capture(chunk: *const world_core.Chunk) NearChunkSummary {
        var summary: NearChunkSummary = .{ .columns = @splat(.{}) };
        for (0..world_core.CHUNK_SIZE_Y) |y| {
            for (&summary.columns, 0..) |*column, i| {
                const block = chunk.blocks[y * summary.columns.len + i];
                const top: u16 = @intCast(y + 1);
                switch (block) {
                    .water => {
                        column.water_min = @min(column.water_min, @as(u16, @intCast(y)));
                        column.water_top = top;
                    },
                    .wood, .mangrove_log, .jungle_log, .acacia_log, .birch_log, .spruce_log, .mangrove_roots, .mushroom_stem => {
                        column.log_min = @min(column.log_min, @as(u16, @intCast(y)));
                        column.log_top = top;
                        column.trunk = block;
                    },
                    .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .red_mushroom_block, .brown_mushroom_block => {
                        column.leaf_min = @min(column.leaf_min, @as(u16, @intCast(y)));
                        column.leaf_top = top;
                        column.leaves = block;
                    },
                    else => {
                        const definition = world_core.getBlockDefinition(block);
                        if (!definition.is_solid or definition.is_fluid or definition.render_shape != .cube) continue;
                        // Actual highest/previous/lowest terrain materials, not
                        // biome guesses or vegetation immediately below a face.
                        if (column.terrain_top == 0) column.layers.foundation = block;
                        column.layers.subsurface = if (column.terrain_top == 0) block else column.layers.surface;
                        column.layers.surface = block;
                        column.terrain_top = top;
                    },
                }
            }
        }
        for (&summary.columns, 0..) |*column, i| {
            column.biome = chunk.biomes[i];
            const x: i32 = @intCast(i % world_core.CHUNK_SIZE_X);
            const z: i32 = @intCast(i / world_core.CHUNK_SIZE_X);
            const tops = [_]u16{ column.terrain_top, column.water_top, column.log_top, column.leaf_top };
            for (&column.lights, tops) |*light, top| {
                // Y=256 is open sky, not the light inside the topmost block.
                light.* = chunk.getLightSafe(x, top, z);
            }
        }
        return summary;
    }

    /// Applies only exact interior columns (never the positive edge sample).
    /// Rejects missing span storage and grids other than one block per cell.
    /// Returns changed columns, including provenance-only upgrades; identical
    /// replays and lower-authority writes leave all destination data untouched.
    pub fn apply(
        self: *const NearChunkSummary,
        data: *LODSimplifiedData,
        chunk_x: i32,
        chunk_z: i32,
        region_min_x: i32,
        region_min_z: i32,
        region_size_blocks: i32,
        provenance: LODColumnProvenance,
    ) u32 {
        if (!data.hasVerticalSpans() or data.width <= 1 or region_size_blocks <= 0) return 0;
        if (data.width - 1 != @as(u32, @intCast(region_size_blocks))) return 0;
        // Widen before multiplication/subtraction, including rejected chunks.
        const offset_x = @as(i64, chunk_x) * world_core.CHUNK_SIZE_X - region_min_x;
        const offset_z = @as(i64, chunk_z) * world_core.CHUNK_SIZE_Z - region_min_z;
        var changed: u32 = 0;
        for (self.columns, 0..) |column, i| {
            const x = offset_x + @as(i64, @intCast(i % world_core.CHUNK_SIZE_X));
            const z = offset_z + @as(i64, @intCast(i / world_core.CHUNK_SIZE_X));
            if (x < 0 or z < 0 or x >= region_size_blocks or z >= region_size_blocks) continue;
            const gx: u32 = @intCast(x);
            const gz: u32 = @intCast(z);
            const idx = gz * data.width + gx;
            if (!provenance.canOverwrite(data.provenance[idx])) continue;

            const height: f32 = @floatFromInt(column.terrain_top);
            const color = biome_color_provider.getBiomeColor(column.biome);
            const water: LODWaterState = if (column.water_top > 0) .{
                .is_surface = true,
                .surface_height = @floatFromInt(column.water_top),
                .depth = @floatFromInt(column.water_top - column.water_min),
                .coverage = 1.0,
            } else LODWaterState.empty;
            const lighting: LODLightingHint = .{
                .sky_light = column.lights[0].getSkyLight(),
                .block_light = column.lights[0].getBlockLight(),
                .ambient_occlusion = 1.0,
            };
            const vegetation: LODVegetationHint = .{
                .tree_coverage = if (column.leaf_top > 0) 1.0 else 0.0,
                .avg_tree_height = @floatFromInt(@max(column.log_top, column.leaf_top) -| column.terrain_top),
                .offset_x = 0.0,
                .offset_z = 0.0,
                .trunk = column.trunk,
                .leaves = column.leaves,
            };
            var spans: [4]LODVerticalSpan = undefined;
            var count: u8 = 0;
            const minima = [_]u16{ 0, column.water_min, column.log_min, column.leaf_min };
            const maxima = [_]u16{ column.terrain_top, column.water_top, column.log_top, column.leaf_top };
            const materials = [_]BlockType{ column.layers.surface, .water, column.trunk, column.leaves };
            for (minima, maxima, materials, 0..) |min, max, material, kind| {
                if (max == 0) continue;
                spans[count] = .{
                    .min_height = @floatFromInt(min),
                    .max_height = @floatFromInt(max),
                    .biome = column.biome,
                    .material_layers = if (kind == 0) column.layers else LODMaterialLayers.default(material),
                    .color = color,
                    .water = if (kind == 1) water else LODWaterState.empty,
                    .lighting = .{
                        .sky_light = column.lights[kind].getSkyLight(),
                        .block_light = column.lights[kind].getBlockLight(),
                        .ambient_occlusion = 1.0,
                    },
                    .vegetation = if (kind >= 2) vegetation else LODVegetationHint.empty,
                };
                count += 1;
            }

            var same = data.provenance[idx] == provenance and
                data.heightmap[idx] == height and data.biomes[idx] == column.biome and
                data.top_blocks[idx] == column.layers.surface and data.colors[idx] == color and
                std.meta.eql(data.material_layers[idx], column.layers) and
                std.meta.eql(data.water[idx], water) and std.meta.eql(data.lighting[idx], lighting) and
                std.meta.eql(data.vegetation[idx], vegetation) and data.verticalSpanCount(gx, gz) == count;
            if (same) {
                for (spans[0..count], 0..) |span, span_index| {
                    if (!std.meta.eql(data.getVerticalSpan(gx, gz, @intCast(span_index)).?, span)) {
                        same = false;
                        break;
                    }
                }
            }
            if (same) continue;

            data.setColumn(gx, gz, height, column.biome, column.layers, color, water, lighting, vegetation);
            // setColumn seeds a span even for air; remove it before replacing
            // the full active span list, including explicit empty columns.
            data.clearVerticalSpans(gx, gz);
            for (spans[0..count], 0..) |span, span_index| {
                _ = data.setVerticalSpan(gx, gz, @intCast(span_index), span);
            }
            data.setColumnProvenance(gx, gz, provenance);
            changed += 1;
        }
        return changed;
    }
};

const testing = std.testing;

test "NearChunkSummary captures final terrain faces at y0 and y255 and excludes decorations" {
    try testing.expect(@sizeOf(NearChunkSummary) < 32 * 1024);
    var chunk = world_core.Chunk.init(99, -99);
    chunk.setBlock(0, 0, 0, .bedrock);
    chunk.setBlock(1, 255, 0, .snow_block);
    chunk.setLight(1, 255, 0, world_core.PackedLight.init(0, 9));
    chunk.setBlock(2, 0, 0, .stone);
    chunk.setBlock(2, 1, 0, .dirt);
    chunk.setBlock(2, 2, 0, .grass);
    const decorations = [_]BlockType{ .tall_grass, .flower_red, .flower_yellow, .dead_bush, .acacia_sapling, .bamboo, .vine, .torch, .snow_layer, .seagrass, .kelp, .seaweed, .coral_fan, .tall_seagrass, .stone_slab, .stone_stairs, .lava };
    for (decorations, 0..) |block, y| chunk.setBlock(2, @intCast(y + 3), 0, block);
    chunk.setBlock(3, 7, 0, .glass);
    chunk.setBiome(2, 0, .forest);
    chunk.setLight(2, 3, 0, world_core.PackedLight.init(12, 7));
    @memset(&chunk.heightmap, 100);
    const summary = NearChunkSummary.capture(&chunk);
    chunk.setBlock(0, 0, 0, .air); // The snapshot must not retain the chunk.
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer data.deinit();
    try testing.expectEqual(@as(u32, 256), summary.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(f32, 1), data.getHeight(0, 0));
    try testing.expectEqual(@as(f32, 256), data.getHeight(1, 0));
    try testing.expectEqual(@as(f32, 3), data.getHeight(2, 0));
    try testing.expectEqual(@as(f32, 8), data.getHeight(3, 0));
    try testing.expectEqual(LODMaterialLayers{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, data.material_layers[2]);
    try testing.expectEqual(world_core.BiomeId.forest, data.biomes[2]);
    try testing.expectEqual(@as(u8, 12), data.lighting[2].sky_light);
    try testing.expectEqual(@as(u8, 7), data.lighting[2].block_light);
    try testing.expectEqual(@as(f32, 0), data.getVerticalSpan(0, 0, 0).?.min_height);
    try testing.expectEqual(@as(f32, 1), data.getVerticalSpan(0, 0, 0).?.max_height);
    try testing.expectEqual(@as(f32, 256), data.getVerticalSpan(1, 0, 0).?.max_height);
    try testing.expectEqual(LODLightingHint.daylight, data.lighting[1]);
    try testing.expectEqual(LODLightingHint.daylight, data.getVerticalSpan(1, 0, 0).?.lighting);
}

test "NearChunkSummary preserves water bounds and all four spans with canopy above water" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 4, 0, .sand);
    for (5..9) |y| chunk.setBlock(0, @intCast(y), 0, .water);
    for (10..13) |y| chunk.setBlock(0, @intCast(y), 0, .mangrove_log);
    for (40..43) |y| chunk.setBlock(0, @intCast(y), 0, .mangrove_leaves);
    chunk.setBlock(1, 0, 0, .water);
    chunk.setBlock(2, 255, 0, .water);
    chunk.setBlock(3, 8, 0, .water);
    chunk.setBlock(3, 40, 0, .birch_leaves);
    chunk.setLight(0, 5, 0, world_core.PackedLight.init(2, 1));
    chunk.setLight(0, 9, 0, world_core.PackedLight.init(4, 2));
    chunk.setLight(0, 13, 0, world_core.PackedLight.init(9, 4));
    chunk.setLight(0, 43, 0, world_core.PackedLight.init(14, 6));
    chunk.setLight(3, 41, 0, world_core.PackedLight.init(13, 8));
    const summary = NearChunkSummary.capture(&chunk);
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod1);
    defer data.deinit();
    try testing.expectEqual(@as(u32, 256), summary.apply(&data, 0, 0, 0, 0, 64, .chunk_derived));
    try testing.expectEqual(@as(u8, 4), data.verticalSpanCount(0, 0));
    try testing.expectEqual(@as(f32, 9), data.water[0].surface_height);
    try testing.expectEqual(@as(f32, 4), data.water[0].depth);
    try testing.expectEqual(@as(f32, 1), data.vegetation[0].tree_coverage);
    const minima = [_]f32{ 0, 5, 10, 40 };
    const maxima = [_]f32{ 5, 9, 13, 43 };
    const materials = [_]BlockType{ .sand, .water, .mangrove_log, .mangrove_leaves };
    const sky_lights = [_]u8{ 2, 4, 9, 14 };
    const block_lights = [_]u8{ 1, 2, 4, 6 };
    for (minima, maxima, materials, 0..) |min, max, material, i| {
        const span = data.getVerticalSpan(0, 0, @intCast(i)).?;
        try testing.expectEqual(min, span.min_height);
        try testing.expectEqual(max, span.max_height);
        try testing.expectEqual(material, span.material_layers.surface);
        try testing.expectEqual(i == 1, span.water.is_surface);
        try testing.expectEqual(sky_lights[i], span.lighting.sky_light);
        try testing.expectEqual(block_lights[i], span.lighting.block_light);
    }
    for (1..3) |x| {
        try testing.expectEqual(BlockType.air, data.top_blocks[x]);
        try testing.expectEqual(@as(f32, 0), data.heightmap[x]);
        try testing.expectEqual(@as(f32, 1), data.water[x].depth);
        try testing.expectEqual(@as(u8, 1), data.verticalSpanCount(@intCast(x), 0));
    }
    try testing.expectEqual(@as(f32, 1), data.water[1].surface_height);
    try testing.expectEqual(@as(f32, 256), data.water[2].surface_height);
    try testing.expectEqual(BlockType.air, data.top_blocks[3]);
    try testing.expectEqual(@as(f32, 0), data.heightmap[3]);
    try testing.expectEqual(@as(u8, 2), data.verticalSpanCount(3, 0));
    try testing.expectEqual(BlockType.air, data.vegetation[3].trunk);
    try testing.expectEqual(BlockType.birch_leaves, data.vegetation[3].leaves);
    try testing.expectEqual(@as(f32, 1), data.vegetation[3].tree_coverage);
    try testing.expectEqual(@as(f32, 8), data.getVerticalSpan(3, 0, 0).?.min_height);
    try testing.expectEqual(BlockType.water, data.getVerticalSpan(3, 0, 0).?.material_layers.surface);
    try testing.expectEqual(@as(f32, 40), data.getVerticalSpan(3, 0, 1).?.min_height);
    try testing.expectEqual(@as(f32, 41), data.getVerticalSpan(3, 0, 1).?.max_height);
    try testing.expectEqual(BlockType.birch_leaves, data.getVerticalSpan(3, 0, 1).?.material_layers.surface);
    try testing.expectEqual(@as(u8, 0), data.lighting[3].sky_light);
    try testing.expectEqual(@as(u8, 13), data.getVerticalSpan(3, 0, 1).?.lighting.sky_light);
    try testing.expectEqual(@as(u8, 8), data.getVerticalSpan(3, 0, 1).?.lighting.block_light);
    try testing.expectEqual(LODLightingHint.daylight, data.getVerticalSpan(2, 0, 0).?.lighting);
    chunk.setLight(3, 41, 0, world_core.PackedLight.init(11, 5));
    const relit = NearChunkSummary.capture(&chunk);
    try testing.expectEqual(@as(u32, 1), relit.apply(&data, 0, 0, 0, 0, 64, .chunk_derived));
    try testing.expectEqual(@as(u8, 11), data.getVerticalSpan(3, 0, 1).?.lighting.sky_light);
    try testing.expectEqual(@as(u8, 5), data.getVerticalSpan(3, 0, 1).?.lighting.block_light);
    try testing.expectEqual(@as(u32, 0), relit.apply(&data, 0, 0, 0, 0, 64, .chunk_derived));
}

test "NearChunkSummary retains tall leaf-only and log-only envelopes and actual species" {
    var chunk = world_core.Chunk.init(0, 0);
    const logs = [_]BlockType{ .wood, .mangrove_log, .jungle_log, .acacia_log, .birch_log, .spruce_log };
    const leaves = [_]BlockType{ .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves };
    for (logs, leaves, 0..) |log, leaf, x| {
        chunk.setBlock(@intCast(x), 80, 0, leaf);
        chunk.setBlock(@intCast(x), 255, 0, leaf);
        chunk.setBlock(@intCast(x), 0, 1, log);
        chunk.setBlock(@intCast(x), 100, 1, log);
    }
    // Mixed species use the highest actual block, not a paired-species guess.
    chunk.setBlock(6, 30, 0, .birch_log);
    chunk.setBlock(6, 31, 0, .spruce_log);
    chunk.setBlock(6, 40, 0, .jungle_leaves);
    chunk.setBlock(6, 41, 0, .acacia_leaves);
    const summary = NearChunkSummary.capture(&chunk);
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer data.deinit();
    _ = summary.apply(&data, 0, 0, 0, 0, 32, .chunk_derived);
    for (logs, leaves, 0..) |log, leaf, x| {
        const gx: u32 = @intCast(x);
        const crown = data.getVerticalSpan(gx, 0, 0).?;
        try testing.expectEqual(@as(u8, 1), data.verticalSpanCount(gx, 0));
        try testing.expectEqual(@as(f32, 80), crown.min_height);
        try testing.expectEqual(@as(f32, 256), crown.max_height);
        try testing.expectEqual(leaf, crown.material_layers.surface);
        try testing.expectEqual(LODLightingHint.daylight, crown.lighting);
        try testing.expectEqual(BlockType.air, data.top_blocks[x]);
        try testing.expectEqual(BlockType.air, data.vegetation[x].trunk);
        try testing.expectEqual(leaf, data.vegetation[x].leaves);
        try testing.expectEqual(@as(f32, 1), data.vegetation[x].tree_coverage);
        try testing.expectEqual(@as(f32, 256), data.vegetation[x].avg_tree_height);
        const trunk = data.getVerticalSpan(gx, 1, 0).?;
        try testing.expectEqual(@as(u8, 1), data.verticalSpanCount(gx, 1));
        try testing.expectEqual(@as(f32, 0), trunk.min_height);
        try testing.expectEqual(@as(f32, 101), trunk.max_height);
        try testing.expectEqual(log, trunk.material_layers.surface);
        const idx = x + data.width;
        try testing.expectEqual(BlockType.air, data.top_blocks[idx]);
        try testing.expectEqual(log, data.vegetation[idx].trunk);
        try testing.expectEqual(BlockType.air, data.vegetation[idx].leaves);
        try testing.expectEqual(@as(f32, 0), data.vegetation[idx].tree_coverage);
    }
    try testing.expectEqual(BlockType.spruce_log, data.vegetation[6].trunk);
    try testing.expectEqual(BlockType.acacia_leaves, data.vegetation[6].leaves);
}

test "NearChunkSummary roots and mushrooms preserve structure envelopes without terrain pillars" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 2, 0, .mud);
    chunk.setBlock(0, 7, 0, .mangrove_roots);
    chunk.setBlock(0, 8, 0, .mangrove_roots);
    chunk.setBlock(1, 20, 0, .mushroom_stem);
    chunk.setBlock(1, 21, 0, .mushroom_stem);
    chunk.setBlock(1, 40, 0, .red_mushroom_block);
    chunk.setBlock(2, 70, 0, .brown_mushroom_block);
    chunk.setLight(0, 9, 0, world_core.PackedLight.init(7, 2));
    chunk.setLight(1, 22, 0, world_core.PackedLight.init(8, 3));
    chunk.setLight(1, 41, 0, world_core.PackedLight.init(12, 4));
    chunk.setLight(2, 71, 0, world_core.PackedLight.init(14, 5));
    const summary = NearChunkSummary.capture(&chunk);
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer data.deinit();
    try testing.expectEqual(@as(u32, 256), summary.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(f32, 3), data.heightmap[0]);
    try testing.expectEqual(BlockType.mud, data.top_blocks[0]);
    try testing.expectEqual(@as(f32, 3), data.getVerticalSpan(0, 0, 0).?.max_height);
    try testing.expectEqual(@as(u8, 2), data.verticalSpanCount(0, 0));
    const root = data.getVerticalSpan(0, 0, 1).?;
    try testing.expectEqual(BlockType.mangrove_roots, root.material_layers.surface);
    try testing.expectEqual(@as(f32, 7), root.min_height);
    try testing.expectEqual(@as(f32, 9), root.max_height);
    try testing.expectEqual(@as(u8, 7), root.lighting.sky_light);
    try testing.expectEqual(BlockType.mangrove_roots, data.vegetation[0].trunk);
    try testing.expectEqual(@as(f32, 0), data.vegetation[0].tree_coverage);
    for (1..3) |x| {
        try testing.expectEqual(@as(f32, 0), data.heightmap[x]);
        try testing.expectEqual(BlockType.air, data.top_blocks[x]);
        try testing.expectEqual(@as(f32, 1), data.vegetation[x].tree_coverage);
    }
    try testing.expectEqual(@as(u8, 2), data.verticalSpanCount(1, 0));
    const stem = data.getVerticalSpan(1, 0, 0).?;
    try testing.expectEqual(BlockType.mushroom_stem, stem.material_layers.surface);
    try testing.expectEqual(@as(f32, 20), stem.min_height);
    try testing.expectEqual(@as(f32, 22), stem.max_height);
    try testing.expectEqual(@as(u8, 8), stem.lighting.sky_light);
    try testing.expectEqual(BlockType.mushroom_stem, data.vegetation[1].trunk);
    const red_cap = data.getVerticalSpan(1, 0, 1).?;
    try testing.expectEqual(BlockType.red_mushroom_block, red_cap.material_layers.surface);
    try testing.expectEqual(@as(f32, 40), red_cap.min_height);
    try testing.expectEqual(@as(f32, 41), red_cap.max_height);
    try testing.expectEqual(@as(u8, 12), red_cap.lighting.sky_light);
    try testing.expectEqual(@as(u8, 1), data.verticalSpanCount(2, 0));
    const brown_cap = data.getVerticalSpan(2, 0, 0).?;
    try testing.expectEqual(BlockType.brown_mushroom_block, brown_cap.material_layers.surface);
    try testing.expectEqual(@as(f32, 70), brown_cap.min_height);
    try testing.expectEqual(@as(f32, 71), brown_cap.max_height);
    try testing.expectEqual(@as(u8, 14), brown_cap.lighting.sky_light);
    try testing.expectEqual(BlockType.air, data.vegetation[2].trunk);
    try testing.expectEqual(BlockType.brown_mushroom_block, data.vegetation[2].leaves);
    try testing.expectEqual(@as(u32, 0), summary.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
}

test "NearChunkSummary clears empty columns and counts only actual changes with provenance ordering" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    chunk.setBlock(0, 1, 0, .water);
    chunk.setBlock(0, 2, 0, .wood);
    chunk.setBlock(0, 3, 0, .leaves);
    const original = NearChunkSummary.capture(&chunk);
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer data.deinit();
    try testing.expectEqual(@as(u32, 256), original.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(u32, 0), original.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    // A span-only discrepancy must be repaired and counted.
    var span = data.getVerticalSpan(0, 0, 3).?;
    span.min_height = 2;
    try testing.expect(data.setVerticalSpan(0, 0, 3, span));
    try testing.expectEqual(@as(u32, 1), original.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    chunk.setBlock(1, 0, 0, .dirt);
    const updated = NearChunkSummary.capture(&chunk);
    try testing.expectEqual(@as(u32, 1), updated.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    @memset(&chunk.blocks, .air);
    const empty = NearChunkSummary.capture(&chunk);
    try testing.expectEqual(@as(u32, 0), empty.apply(&data, 0, 0, 0, 0, 32, .worldgen));
    try testing.expectEqual(@as(u8, 4), data.verticalSpanCount(0, 0));
    try testing.expectEqual(@as(u32, 2), empty.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(f32, 0), data.heightmap[0]);
    try testing.expectEqual(BlockType.air, data.top_blocks[0]);
    try testing.expectEqual(LODMaterialLayers.default(.air), data.material_layers[0]);
    try testing.expectEqual(LODWaterState.empty, data.water[0]);
    try testing.expectEqual(LODVegetationHint.empty, data.vegetation[0]);
    try testing.expectEqual(@as(u8, 0), data.verticalSpanCount(0, 0));
    try testing.expectEqual(@as(u32, 0), empty.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(u32, 256), empty.apply(&data, 0, 0, 0, 0, 32, .edited));
    try testing.expectEqual(@as(u32, 0), original.apply(&data, 0, 0, 0, 0, 32, .chunk_derived));
    try testing.expectEqual(@as(u32, 0), empty.apply(&data, 0, 0, 0, 0, 32, .edited));
}

test "NearChunkSummary rejects out-of-region chunks reduced grids and missing spans" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    const summary = NearChunkSummary.capture(&chunk);
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer data.deinit();
    const outside = [_][2]i32{ .{ -1, 0 }, .{ 0, -1 }, .{ 2, 0 }, .{ 0, 2 }, .{ std.math.minInt(i32), std.math.maxInt(i32) } };
    for (outside) |coords| try testing.expectEqual(@as(u32, 0), summary.apply(&data, coords[0], coords[1], 0, 0, 32, .edited));
    try testing.expectEqual(@as(u32, 0), summary.apply(&data, 0, 0, 0, 0, 0, .edited));
    try testing.expectEqual(@as(u32, 0), summary.apply(&data, 0, 0, 0, 0, -32, .edited));
    for (data.provenance) |p| try testing.expectEqual(LODColumnProvenance.worldgen, p);
    for (data.vertical_span_counts.?) |count| try testing.expectEqual(@as(u8, 0), count);
    var reduced = try LODSimplifiedData.initWithVerticalSpansSampleDensity(testing.allocator, .lod1, 0.5);
    defer reduced.deinit();
    try testing.expectEqual(@as(u32, 0), summary.apply(&reduced, 0, 0, 0, 0, 64, .edited));
    for (reduced.provenance) |p| try testing.expectEqual(LODColumnProvenance.worldgen, p);
    var no_spans = try LODSimplifiedData.init(testing.allocator, .lod0);
    defer no_spans.deinit();
    try testing.expectEqual(@as(u32, 0), summary.apply(&no_spans, 0, 0, 0, 0, 32, .edited));
    for (no_spans.provenance) |p| try testing.expectEqual(LODColumnProvenance.worldgen, p);
    // Partial overlap writes only the exact 8x8 interior, not clamped borders.
    try testing.expectEqual(@as(u32, 64), summary.apply(&data, 0, 0, 8, 8, 32, .chunk_derived));
    try testing.expectEqual(LODColumnProvenance.chunk_derived, data.getColumnProvenance(7, 7));
    try testing.expectEqual(LODColumnProvenance.worldgen, data.getColumnProvenance(8, 7));
    try testing.expectEqual(LODColumnProvenance.worldgen, data.getColumnProvenance(7, 8));
}

test "NearChunkSummary adjacent chunk application is order independent including negative coordinates" {
    var chunk = world_core.Chunk.init(0, 0);
    @memset(&chunk.blocks, .stone);
    const stone = NearChunkSummary.capture(&chunk);
    @memset(&chunk.blocks, .sand);
    const sand = NearChunkSummary.capture(&chunk);
    const origins = [_]i32{ 0, -32 };
    for (origins) |origin| {
        var forward = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
        defer forward.deinit();
        var reverse = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
        defer reverse.deinit();
        const base = @divFloor(origin, 16);
        for (0..4) |i| {
            const a = if (i % 2 == 0) &stone else &sand;
            try testing.expectEqual(@as(u32, 256), a.apply(&forward, base + @as(i32, @intCast(i % 2)), base + @as(i32, @intCast(i / 2)), origin, origin, 32, .chunk_derived));
            const j = 3 - i;
            const b = if (j % 2 == 0) &stone else &sand;
            try testing.expectEqual(@as(u32, 256), b.apply(&reverse, base + @as(i32, @intCast(j % 2)), base + @as(i32, @intCast(j / 2)), origin, origin, 32, .chunk_derived));
        }
        inline for (.{ "heightmap", "biomes", "top_blocks", "colors", "material_layers", "water", "lighting", "vegetation", "provenance" }) |field| {
            for (@field(forward, field), @field(reverse, field)) |a, b| try testing.expectEqualDeep(a, b);
        }
        for (0..forward.width) |z| {
            for (0..forward.width) |x| {
                const gx: u32 = @intCast(x);
                const gz: u32 = @intCast(z);
                const count = forward.verticalSpanCount(gx, gz);
                try testing.expectEqual(count, reverse.verticalSpanCount(gx, gz));
                for (0..count) |i| try testing.expectEqualDeep(forward.getVerticalSpan(gx, gz, @intCast(i)).?, reverse.getVerticalSpan(gx, gz, @intCast(i)).?);
                if (x == 32 or z == 32) {
                    try testing.expectEqual(LODColumnProvenance.worldgen, forward.getColumnProvenance(gx, gz));
                    try testing.expectEqual(@as(u8, 0), count);
                } else {
                    try testing.expectEqual(LODColumnProvenance.chunk_derived, forward.getColumnProvenance(gx, gz));
                    try testing.expectEqual(if (x < 16) BlockType.stone else BlockType.sand, forward.top_blocks[z * forward.width + x]);
                    try testing.expectEqual(@as(u8, 1), count);
                }
            }
        }
    }
}
