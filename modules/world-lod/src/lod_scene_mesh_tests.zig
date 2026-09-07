//! Canonical scene geometry tests use supplied grids, independently of projection.
const std = @import("std");
const testing = std.testing;
const core = @import("world-core");
const SceneGrid = core.lod_scene.SceneGrid;
const SceneSpan = core.lod_scene.SceneSpan;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const CompactLODTile = @import("lod_tile.zig").CompactLODTile;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi = @import("engine-rhi");
const Vertex = rhi.Vertex;

fn testAtlas() TextureAtlas {
    var atlas: TextureAtlas = undefined;
    for (&atlas.tile_mappings, 0..) |*tiles, i| {
        tiles.* = .{ .top = @intCast(i * 3 + 1), .bottom = @intCast(i * 3 + 2), .side = @intCast(i * 3 + 3) };
    }
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1)} ** core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{.{ .top = 0x804020, .bottom = 0x204080, .side = 0x408020 }} ** core.MAX_BLOCK_TYPES;
    return atlas;
}

fn span(block: core.BlockType, min: f32, max: f32) SceneSpan {
    return .{ .min_y = min, .max_y = max, .block = block, .biome = .forest, .light = core.PackedLight.init(15, 0) };
}

fn airHalo(grid: *SceneGrid) !void {
    const width: i32 = @intCast(grid.width);
    var i: i32 = 0;
    while (i < width) : (i += 1) {
        for ([_][2]i32{ .{ -1, i }, .{ width, i }, .{ i, -1 }, .{ i, width } }) |p| {
            try grid.appendColumn(p[0], p[1], &.{}, grid.cell_size * grid.cell_size, grid.cell_size * grid.cell_size, false);
        }
    }
}

fn faceArea(vertices: []const Vertex, normal: [3]f32) f32 {
    return faceAreaAtPlane(vertices, normal, null);
}

// Plane is the signed distance along the supplied axis-aligned normal.
fn faceAreaAtPlane(vertices: []const Vertex, normal: [3]f32, plane: ?f32) f32 {
    const packed_normal = rhi.encodeNormal(normal);
    var area: f32 = 0;
    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        if (vertices[i].normal != packed_normal) continue;
        const a = vertices[i].pos;
        if (plane) |distance| {
            if (a[0] * normal[0] + a[1] * normal[1] + a[2] * normal[2] != distance) continue;
        }
        const b = vertices[i + 1].pos;
        const c = vertices[i + 2].pos;
        const cross = [3]f32{
            (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
            (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
            (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]),
        };
        // Signed area also catches winding that contradicts the encoded normal.
        area += (cross[0] * normal[0] + cross[1] * normal[1] + cross[2] * normal[2]) * 0.5;
    }
    return area;
}

test "canonical scene captured strata retain caves roof floors and face materials at every LOD" {
    var chunk = core.Chunk.init(-2, -3);
    for (0..4) |y| chunk.setBlock(0, @intCast(y), 0, .stone);
    for (4..7) |y| chunk.setBlock(0, @intCast(y), 0, .dirt);
    chunk.setBlock(0, 7, 0, .grass);
    for (12..14) |y| chunk.setBlock(0, @intCast(y), 0, .stone);
    var summary = try core.lod_scene.ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    const atlas = testAtlas();
    for ([_]core.LODLevel{ .lod0, .lod1, .lod2, .lod3, .lod4 }, [_]u32{ 1, 2, 4, 8, 16 }) |lod, cell| {
        var grid = try SceneGrid.init(testing.allocator, -32, -48, cell, 1);
        defer grid.deinit();
        var projected: [4]SceneSpan = undefined;
        try testing.expectEqual(projected.len, summary.column(0, 0).len);
        for (summary.column(0, 0), &projected) |run, *out| {
            out.* = span(run.block, @floatFromInt(run.min_y), @floatFromInt(run.max_y));
            out.light = run.light_top;
            out.light_bottom = run.light_bottom;
        }
        try grid.appendColumn(0, 0, &projected, cell * cell, cell * cell, false);
        try airHalo(&grid);
        var mesh = LODMesh.init(testing.allocator, lod);
        defer mesh.clearRetiredState();
        try mesh.buildFromSceneGrid(&grid, &atlas);
        const vertices = mesh.pending_vertices.?;
        try testing.expectEqual(@as(usize, 114), vertices.len);
        try testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
        const area: f32 = @floatFromInt(cell * cell);
        try testing.expectEqual(2 * area, faceArea(vertices, .{ 0, 1, 0 }));
        try testing.expectEqual(area, faceArea(vertices, .{ 0, -1, 0 }));
        for (vertices) |vertex| {
            const tile: u16 = @truncate(vertex.packed_meta);
            if (vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 })) {
                try testing.expect(vertex.pos[1] == 8 or vertex.pos[1] == 14);
            } else if (vertex.normal == rhi.encodeNormal(.{ 0, -1, 0 })) {
                try testing.expectEqual(@as(f32, 12), vertex.pos[1]);
                try testing.expectEqual(atlas.getTilesForBlock(@intFromEnum(core.BlockType.stone)).bottom, tile);
                try testing.expectEqual(rhi.encodeColor(.{ 32.0 / 255.0, 64.0 / 255.0, 128.0 / 255.0 }), vertex.color);
            } else if (tile == atlas.getTilesForBlock(@intFromEnum(core.BlockType.grass)).side) {
                try testing.expect(vertex.pos[1] >= 7 and vertex.pos[1] <= 8);
            } else if (tile == atlas.getTilesForBlock(@intFromEnum(core.BlockType.dirt)).side) {
                try testing.expect(vertex.pos[1] >= 4 and vertex.pos[1] <= 7);
            }
        }
    }
}

test "canonical scene all simplified entry points use attached grid and embedded origin" {
    const atlas = testAtlas();
    for ([_]core.LODLevel{ .lod0, .lod1, .lod2, .lod3, .lod4 }) |lod| {
        var source = try core.LODSimplifiedData.init(testing.allocator, lod);
        defer source.deinit();
        const grid = try testing.allocator.create(SceneGrid);
        grid.* = try SceneGrid.init(testing.allocator, -13, -29, 2, 1);
        source.scene_grid = grid;
        try grid.appendColumn(0, 0, &.{span(.stone, 20, 21)}, 4, 4, false);
        try airHalo(grid);
        var expected = LODMesh.init(testing.allocator, lod);
        defer expected.clearRetiredState();
        try expected.buildFromSceneGrid(grid, &atlas);
        for (0..4) |entry| {
            var mesh = LODMesh.init(testing.allocator, lod);
            defer mesh.clearRetiredState();
            switch (entry) {
                0 => try mesh.buildFromSimplifiedData(&source, 100, 100, &atlas),
                1 => try mesh.buildFromNearSimplifiedData(&source, 100, 100, &atlas),
                2 => try mesh.buildFromColumnSpans(&source, 100, 100, &atlas),
                else => try mesh.buildFromSimplifiedDataWithQEM(&source, 100, 100, 1, 0, &atlas),
            }
            try testing.expectEqualDeep(expected.pending_vertices.?, mesh.pending_vertices.?);
        }
        for (expected.pending_vertices.?) |vertex| {
            if (vertex.normal != rhi.encodeNormal(.{ 0, 1, 0 })) continue;
            try testing.expectEqual(@as(f16, @floatCast(243 + vertex.pos[0])), vertex.uv[0]);
            try testing.expectEqual(@as(f16, @floatCast(227 + vertex.pos[2])), vertex.uv[1]);
        }
    }
}

test "canonical scene four negative-origin halo edges retain faces without published topology" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, -64, -64, 4, 1);
    defer grid.deinit();
    try grid.appendColumn(0, 0, &.{span(.stone, 0, 16)}, 16, 16, false);
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }, 0..) |p, i| {
        try grid.appendColumn(p[0], p[1], &.{ span(.dirt, 0, 4), span(.stone, 8, 12) }, if (i == 0) 0 else 16, 16, i == 0);
    }
    var mesh = LODMesh.init(testing.allocator, .lod4);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(usize, 30), mesh.pending_vertices.?.len);
    for ([_][3]f32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } }) |normal| {
        try testing.expectEqual(@as(f32, 64), faceArea(mesh.pending_vertices.?, normal));
    }
    for (mesh.pending_vertices.?) |vertex| {
        try testing.expect(vertex.pos[0] >= 0 and vertex.pos[0] <= 4);
        try testing.expect(vertex.pos[2] >= 0 and vertex.pos[2] <= 4);
        try testing.expect(vertex.pos[1] == 0 or vertex.pos[1] == 16);
    }
    // With no evidence only a bounded top handoff is emitted, not a wall to zero.
    var unknown = try SceneGrid.init(testing.allocator, -64, -64, 4, 1);
    defer unknown.deinit();
    try unknown.appendColumn(0, 0, &.{ span(.stone, 0, 14), span(.grass, 14, 16) }, 16, 16, false);
    try mesh.buildFromSceneGrid(&unknown, &atlas);
    for (mesh.pending_vertices.?) |vertex| try testing.expect(vertex.pos[1] >= 12);

    var steps = try SceneGrid.init(testing.allocator, -8, -8, 4, 2);
    defer steps.deinit();
    for (0..2) |z| {
        try steps.appendColumn(0, @intCast(z), &.{ span(.stone, 0, 4), span(.grass, 4, 5) }, 16, 16, false);
        try steps.appendColumn(1, @intCast(z), &.{ span(.stone, 0, 2), span(.dirt, 2, 3) }, 16, 16, false);
    }
    try airHalo(&steps);
    try mesh.buildFromSceneGrid(&steps, &atlas);
    try testing.expectEqual(@as(f32, 64), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 40), faceArea(mesh.pending_vertices.?, .{ 1, 0, 0 }));
    for (mesh.pending_vertices.?) |vertex| {
        if (vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 })) try testing.expect(vertex.pos[1] == 3 or vertex.pos[1] == 5);
        const tile: u16 = @truncate(vertex.packed_meta);
        if (tile == atlas.getTilesForBlock(@intFromEnum(core.BlockType.grass)).side) try testing.expect(vertex.pos[1] >= 4);
    }
}

test "canonical scene partial footprints keep area and only clip neighbors meeting the shared edge" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, -8, -8, 4, 1);
    defer grid.deinit();
    var partial = span(.birch_leaves, 10, 12);
    partial.coverage = 0.25;
    partial.center_x = 1;
    partial.center_z = 0;
    try grid.appendColumn(0, 0, &.{partial}, 16, 16, false);
    var neighbor = span(.stone, 10, 12);
    neighbor.coverage = 0.25;
    neighbor.center_x = 0.5; // Does not touch the shared west edge.
    try grid.appendColumn(1, 0, &.{neighbor}, 16, 16, false);
    var mesh = LODMesh.init(testing.allocator, .lod4);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(f32, 4), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 4), faceArea(mesh.pending_vertices.?, .{ 1, 0, 0 }));
    for (mesh.pending_vertices.?) |vertex| {
        try testing.expect(vertex.pos[0] >= 2 and vertex.pos[0] <= 4);
        try testing.expect(vertex.pos[2] >= 0 and vertex.pos[2] <= 2);
        try testing.expectEqual(Vertex.LOD_TILE_ID, @as(u16, @truncate(vertex.packed_meta)));
    }
    grid.spans.items[1].center_x = 0; // Shared edge, but covers only Z=1..2.
    try mesh.buildFromSceneGrid(&grid, &atlas);
    // Even touching source halo geometry cannot certify published coverage.
    try testing.expectEqual(@as(f32, 4), faceArea(mesh.pending_vertices.?, .{ 1, 0, 0 }));
    try testing.expectEqual(@as(f32, 4), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    // A same-column partial roof removes only its footprint from the lower top.
    var layered = try SceneGrid.init(testing.allocator, 0, 0, 4, 1);
    defer layered.deinit();
    var roof = span(.dirt, 12, 13);
    roof.coverage = 0.25;
    try layered.appendColumn(0, 0, &.{ span(.stone, 10, 12), roof }, 16, 16, false);
    try airHalo(&layered);
    try mesh.buildFromSceneGrid(&layered, &atlas);
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, -1, 0 }));
    // Overlapping projected canopy and wood must prefer opaque material even
    // when the canopy arrived first, without discarding its remaining area.
    layered.spans.items[0].block = .leaves;
    layered.spans.items[1].block = .wood;
    layered.spans.items[1].min_y = 10;
    layered.spans.items[1].max_y = 12;
    try mesh.buildFromSceneGrid(&layered, &atlas);
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, -1, 0 }));
}

test "canonical scene exact tile retains all boundary faces beside published fallback geometry" {
    const atlas = testAtlas();
    const directions = [_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    const normals = [_][3]f32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
    for (directions, normals) |direction, normal| {
        // Old/lower, provisional, coarser, and inset neighbor representations.
        for (0..4) |case| {
            var exact = try SceneGrid.init(testing.allocator, -16, -16, 1, 2);
            defer exact.deinit();
            for (0..2) |z| {
                for (0..2) |x| try exact.appendColumn(@intCast(x), @intCast(z), &.{span(.stone, 20, 22)}, 1, 1, false);
            }
            for (0..2) |i| {
                const along: i32 = @intCast(i);
                const x = if (direction[0] < 0) -1 else if (direction[0] > 0) 2 else along;
                const z = if (direction[1] < 0) -1 else if (direction[1] > 0) 2 else along;
                try exact.appendColumn(x, z, &.{span(.stone, 0, 64)}, if (case == 1) 0 else 1, 1, case == 1);
                for ([_][2]i32{ .{ -1, along }, .{ 2, along }, .{ along, -1 }, .{ along, 2 } }) |p| {
                    if (p[0] == x and p[1] == z) continue;
                    try exact.appendColumn(p[0], p[1], &.{}, 1, 1, false);
                }
            }
            var fallback = try SceneGrid.init(testing.allocator, -16 + direction[0] * 2, -16 + direction[1] * 2, 2, 1);
            defer fallback.deinit();
            var neighbor = span(.stone, 0, if (case == 0) 10 else if (case == 1) 19 else if (case == 2) 21 else 22);
            if (case == 3) neighbor.coverage = 0.25;
            try fallback.appendColumn(0, 0, &.{neighbor}, if (case == 1) 0 else 4, 4, case == 1);
            try airHalo(&fallback);
            var fallback_mesh = LODMesh.init(testing.allocator, .lod2);
            defer fallback_mesh.clearRetiredState();
            try fallback_mesh.buildFromSceneGrid(&fallback, &atlas);
            try testing.expectEqual(@as(f32, if (case == 3) 1 else 4), faceArea(fallback_mesh.pending_vertices.?, .{ 0, 1, 0 }));
            var mesh = LODMesh.init(testing.allocator, .lod0);
            defer mesh.clearRetiredState();
            try mesh.buildFromSceneGrid(&exact, &atlas);
            // The source halo fills this entire face, but the actual fallback
            // does not. Retain the exact wall, without extending any skirt.
            const plane: f32 = if (direction[0] > 0 or direction[1] > 0) 2 else 0;
            try testing.expectEqual(@as(f32, 4), faceAreaAtPlane(mesh.pending_vertices.?, normal, plane));
            try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
            for (mesh.pending_vertices.?) |vertex| try testing.expect(vertex.pos[1] == 20 or vertex.pos[1] == 22);
        }
    }
}

test "canonical scene interior partial occlusion still clips only shared footprint" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, -8, -8, 4, 2);
    defer grid.deinit();
    var leaf = span(.birch_leaves, 10, 12);
    leaf.coverage = 0.25;
    leaf.center_x = 1;
    leaf.center_z = 0;
    try grid.appendColumn(0, 0, &.{leaf}, 16, 16, false);
    var neighbor = span(.stone, 10, 12);
    neighbor.coverage = 0.25;
    try grid.appendColumn(1, 0, &.{neighbor}, 16, 16, false);
    var mesh = LODMesh.init(testing.allocator, .lod1);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(f32, 4), faceAreaAtPlane(mesh.pending_vertices.?, .{ 1, 0, 0 }, 4));
    grid.spans.items[1].center_x = 0;
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(f32, 2), faceAreaAtPlane(mesh.pending_vertices.?, .{ 1, 0, 0 }, 4));
    grid.spans.items[1].coverage = 1;
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(f32, 0), faceAreaAtPlane(mesh.pending_vertices.?, .{ 1, 0, 0 }, 4));
}

test "canonical scene exact leaves keep atlas UV winding and greedy coverage while coarse canopies are flat" {
    var atlas = testAtlas();
    for ([_]core.BlockType{ .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves }) |block| {
        atlas.tile_mappings[@intFromEnum(block)] = .{ .top = 21, .bottom = 22, .side = 23 };
        for ([_]u32{ 1, 2 }) |cell| {
            var grid = try SceneGrid.init(testing.allocator, -16, -32, cell, 2);
            defer grid.deinit();
            for (0..2) |z| {
                for (0..2) |x| try grid.appendColumn(@intCast(x), @intCast(z), &.{span(block, 20, 22)}, cell * cell, cell * cell, false);
            }
            try airHalo(&grid);
            // Atlas identity is based on exact cell size, not the nominal LOD.
            var mesh = LODMesh.init(testing.allocator, .lod4);
            defer mesh.clearRetiredState();
            try mesh.buildFromSceneGrid(&grid, &atlas);
            try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
            for ([_][3]f32{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } }) |normal| {
                const expected_area: f32 = @floatFromInt(if (normal[1] != 0) 4 * cell * cell else 4 * cell);
                try testing.expectEqual(expected_area, faceArea(mesh.pending_vertices.?, normal));
            }
            for (mesh.pending_vertices.?) |vertex| {
                const top = vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 });
                const bottom = vertex.normal == rhi.encodeNormal(.{ 0, -1, 0 });
                const x_side = vertex.normal == rhi.encodeNormal(.{ 1, 0, 0 }) or vertex.normal == rhi.encodeNormal(.{ -1, 0, 0 });
                const tile: u16 = if (cell != 1) Vertex.LOD_TILE_ID else if (top) 21 else if (bottom) 22 else 23;
                try testing.expectEqual(tile, @as(u16, @truncate(vertex.packed_meta)));
                const expected_uv: [2]f32 = if (top or bottom)
                    .{ 240 + vertex.pos[0], 224 + vertex.pos[2] }
                else if (x_side)
                    .{ 224 + vertex.pos[2], vertex.pos[1] }
                else
                    .{ 240 + vertex.pos[0], vertex.pos[1] };
                try testing.expectEqual(@as(f16, @floatCast(expected_uv[0])), vertex.uv[0]);
                try testing.expectEqual(@as(f16, @floatCast(expected_uv[1])), vertex.uv[1]);
            }
        }
    }
}

test "canonical scene terrain shader cutout contract is outside the RGB distance fade" {
    // Source-level guard, not a GPU sampling test: even at/after the 128-block
    // fade endpoint (including 129), atlas alpha must precede the detail gate.
    const source = try @import("fs").cwd().readFileAlloc("assets/shaders/vulkan/terrain.frag", testing.allocator, 128 * 1024);
    defer testing.allocator.free(source);
    const start = std.mem.indexOf(u8, source, "if (isLOD && global.lighting.y > 0.5 && vTileID >= 0 && vTileID < 256) {") orelse return error.MissingAtlasCutoutGuard;
    const end = std.mem.indexOfPos(u8, source, start, "} else if (!isLOD") orelse return error.MissingFullDetailBranch;
    const lod = source[start..end];
    const detail = std.mem.indexOf(u8, lod, "if (textureDetail > 0.0) {") orelse return error.MissingRGBDetailGuard;
    const coverage = lod[0..detail];
    try testing.expect(std.mem.indexOf(u8, coverage, "vec4 texColor = texture(uTexture, uv);") != null);
    try testing.expect(std.mem.indexOf(u8, coverage, "if (texColor.a < 0.1) discard;") != null);
    try testing.expect(std.mem.indexOf(u8, coverage, "outputAlpha = texColor.a;") != null);
    try testing.expect(std.mem.indexOf(u8, coverage, "textureDetail") == null);
    try testing.expect(std.mem.indexOf(u8, lod[detail..], "outputAlpha") == null);
    try testing.expect(std.mem.indexOf(u8, lod[detail..], "albedo = mix(vColor, detailColor, textureDetail);") != null);
    const full_detail = source[end..];
    try testing.expect(std.mem.indexOf(u8, full_detail, "if (texColor.a < 0.1) discard;") != null);
    try testing.expect(std.mem.indexOf(u8, full_detail, "outputAlpha = texColor.a;") != null);
}

test "canonical scene actual foliage roots mushrooms and multiple water levels retain separate lights" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    var water = span(.water, 5, 6);
    water.light = core.PackedLight.initRGB(3, 1, 7, 12);
    var upper_water = span(.water, 15, 16);
    upper_water.light = core.PackedLight.initRGB(8, 4, 2, 1);
    try grid.appendColumn(0, 0, &.{ span(.mangrove_roots, 1, 2), water, span(.spruce_leaves, 8, 9), span(.red_mushroom_block, 11, 12), upper_water }, 1, 1, false);
    try airHalo(&grid);
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(u32, 108), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 72), mesh.water_vertex_count);
    try testing.expectEqual(@as(usize, 108 * @sizeOf(Vertex)), mesh.water_vertex_offset);
    for (mesh.pending_vertices.?[0..mesh.opaque_vertex_count]) |vertex| {
        const block: core.BlockType = if (vertex.pos[1] <= 2) .mangrove_roots else if (vertex.pos[1] <= 9) .spruce_leaves else .red_mushroom_block;
        const tiles = atlas.getTilesForBlock(@intFromEnum(block));
        const tile = if (vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 })) tiles.top else if (vertex.normal == rhi.encodeNormal(.{ 0, -1, 0 })) tiles.bottom else tiles.side;
        try testing.expectEqual(tile, @as(u16, @truncate(vertex.packed_meta)));
        try testing.expectEqual(rhi.encodeMeta(tile, 1, 1), vertex.packed_meta);
        try testing.expectEqual(@as(u32, 0), vertex.blocklight);
    }
    for (mesh.pending_vertices.?[mesh.opaque_vertex_count..]) |vertex| {
        const lower = vertex.pos[1] <= 6;
        const tile: u16 = @truncate(vertex.packed_meta);
        const horizontal = vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 }) or vertex.normal == rhi.encodeNormal(.{ 0, -1, 0 });
        try testing.expectEqual(rhi.encodeMeta(tile, if (!horizontal) 1 else if (lower) 3.0 / 15.0 else 8.0 / 15.0, 1), vertex.packed_meta);
        try testing.expectEqual(rhi.encodeBlocklight(if (lower) .{ 1.0 / 15.0, 7.0 / 15.0, 12.0 / 15.0 } else .{ 4.0 / 15.0, 2.0 / 15.0, 1.0 / 15.0 }, false), vertex.blocklight);
    }
}

test "canonical scene cross and tall-cross roots match cutout geometry without coarse walls" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    var flowers = span(.flower_red, 40, 42); // Two roots in one source RLE run.
    flowers.light = core.PackedLight.initRGB(9, 2, 5, 11);
    var tall = span(.tall_grass, 255, 256);
    tall.light = core.PackedLight.initRGB(7, 1, 3, 4);
    try grid.appendColumn(0, 0, &.{ flowers, tall }, 1, 1, false);
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    const vertices = mesh.pending_vertices.?;
    try testing.expectEqual(@as(usize, 36), vertices.len);
    try testing.expectEqual(@as(u32, 36), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);

    const flower_tile = atlas.getTilesForBlock(@intFromEnum(core.BlockType.flower_red)).side;
    const tall_tile = atlas.getTilesForBlock(@intFromEnum(core.BlockType.tall_grass)).side;
    // The non-white side average is baked into LOD vColor. terrain.frag divides
    // it back out for detail, yielding the full-detail texture * tint result.
    const tall_color = rhi.encodeColor(.{
        0.20 * 0.18 * (64.0 / 255.0),
        0.70 * 0.64 * (128.0 / 255.0),
        0.14 * 0.16 * (32.0 / 255.0),
    });
    const diagonal_normals = [_]u32{
        rhi.encodeNormal(.{ -1.0 / @sqrt(@as(f32, 2)), 0, 1.0 / @sqrt(@as(f32, 2)) }),
        rhi.encodeNormal(.{ -1.0 / @sqrt(@as(f32, 2)), 0, -1.0 / @sqrt(@as(f32, 2)) }),
    };
    var flower_vertices: usize = 0;
    var tall_vertices: usize = 0;
    var first_tall: ?Vertex = null;
    for (vertices) |vertex| {
        const tile: u16 = @truncate(vertex.packed_meta);
        try testing.expect(vertex.uv[0] == 0 or vertex.uv[0] == 1);
        try testing.expect(vertex.uv[1] == 0 or vertex.uv[1] == 1);
        if (tile == flower_tile) {
            flower_vertices += 1;
            try testing.expect(vertex.pos[1] >= 40 and vertex.pos[1] <= 42);
            try testing.expectEqual(rhi.encodeMeta(flower_tile, 9.0 / 15.0, 1), vertex.packed_meta);
            try testing.expectEqual(rhi.encodeBlocklight(.{ 2.0 / 15.0, 5.0 / 15.0, 11.0 / 15.0 }, false), vertex.blocklight);
        } else {
            try testing.expectEqual(tall_tile, tile);
            tall_vertices += 1;
            first_tall = first_tall orelse vertex;
            try testing.expect(vertex.pos[1] == 255 or vertex.pos[1] == 257);
            try testing.expectEqual(tall_color, vertex.color);
            try testing.expectEqual(rhi.encodeMeta(tall_tile, 7.0 / 15.0, 1), vertex.packed_meta);
            try testing.expectEqual(rhi.encodeBlocklight(.{ 1.0 / 15.0, 3.0 / 15.0, 4.0 / 15.0 }, false), vertex.blocklight);
        }
        try testing.expect(vertex.normal == diagonal_normals[0] or vertex.normal == diagonal_normals[1]);
    }
    try testing.expectEqual(@as(usize, 24), flower_vertices);
    try testing.expectEqual(@as(usize, 12), tall_vertices);
    // Assert the actual packed LOD vertex retains the tile average during the
    // color-fade path, and the terrain shader's detail reconstruction restores
    // the full-detail texture * default-color * biome-tint contract.
    const packed_vertex = first_tall.?;
    const vertex_color = [3]f32{
        @as(f32, @floatFromInt(packed_vertex.color & 0xff)) / 255.0,
        @as(f32, @floatFromInt((packed_vertex.color >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((packed_vertex.color >> 16) & 0xff)) / 255.0,
    };
    const source_color = [3]f32{ 0.20 * 0.18, 0.70 * 0.64, 0.14 * 0.16 };
    const tile_average = [3]f32{ 64.0 / 255.0, 128.0 / 255.0, 32.0 / 255.0 };
    const texel = [3]f32{ 0.75, 0.25, 0.50 };
    for (vertex_color, source_color, tile_average, texel) |fade, source, average, texture| {
        try testing.expectApproxEqAbs(source * average, fade, 1.0 / 255.0);
        try testing.expectApproxEqAbs(source * texture, texture * (fade / average), 0.02);
    }

    // Coarse source vegetation keeps its category, but one representative is
    // bounded to a block footprint rather than becoming a 4-block billboard.
    var coarse = try SceneGrid.init(testing.allocator, 0, 0, 4, 1);
    defer coarse.deinit();
    var dense = span(.tall_grass, 20, 21);
    dense.coverage = 1;
    dense.center_x = 0.5;
    dense.center_z = 0.5;
    try coarse.appendColumn(0, 0, &.{dense}, 16, 16, true);
    try mesh.buildFromSceneGrid(&coarse, &atlas);
    try testing.expectEqual(@as(usize, 12), mesh.pending_vertices.?.len);
    for (mesh.pending_vertices.?) |vertex| {
        try testing.expect(vertex.pos[0] >= 1.5 and vertex.pos[0] <= 2.5);
        try testing.expect(vertex.pos[2] >= 1.5 and vertex.pos[2] <= 2.5);
        try testing.expect(vertex.pos[1] == 20 or vertex.pos[1] == 22);
    }
}

test "canonical scene known empty coverage survives payload transfer but legacy and unknown air do not cover" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    try grid.appendColumn(0, 0, &.{}, 1, 1, false);
    var mesh = LODMesh.init(testing.allocator, .lod2);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(usize, 0), mesh.pending_vertices.?.len);
    try testing.expect(mesh.canonical_empty_coverage);
    try testing.expect(!mesh.isCoverageReady());
    var payload = mesh.takePendingCpuBuild();
    mesh.clearRetiredState();
    mesh.restorePendingCpuBuild(&payload);
    mesh.markEmptyUploadedUnlocked();
    try testing.expect(mesh.isCoverageReady());
    try testing.expect(!mesh.isRenderable());
    mesh.clearRetiredState();
    mesh.markEmptyUploadedUnlocked();
    try testing.expect(!mesh.isCoverageReady());
    grid.columnInfo(0, 0).known_area = 0;
    try mesh.buildFromSceneGrid(&grid, &atlas);
    mesh.markEmptyUploadedUnlocked();
    try testing.expect(!mesh.isCoverageReady());
}

test "canonical scene compact rejection preserves source for expanded fallback and rejects legacy forests" {
    const atlas = testAtlas();
    var source = try core.LODSimplifiedData.init(testing.allocator, .lod4);
    defer source.deinit();
    const grid = try testing.allocator.create(SceneGrid);
    grid.* = try SceneGrid.init(testing.allocator, -128, -128, 8, 1);
    source.scene_grid = grid;
    const leaf = span(.birch_leaves, 10, 14);
    try grid.appendColumn(0, 0, &.{leaf}, 64, 64, false);
    var mesh = LODMesh.init(testing.allocator, .lod4);
    defer mesh.clearRetiredState();
    try testing.expectEqual(CompactLODTile.Support.canonical_scene, CompactLODTile.support(&source, .lod4));
    try testing.expectError(error.UnsupportedSourceFeatures, mesh.buildCompactTile(&source));
    try testing.expect(source.scene_grid == grid);
    try testing.expectEqualDeep(leaf, grid.column(0, 0)[0]);
    try mesh.buildFromSimplifiedData(&source, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
    try testing.expect(!mesh.compact);
    var legacy = try core.LODSimplifiedData.init(testing.allocator, .lod4);
    defer legacy.deinit();
    legacy.vegetation[0] = .{ .tree_coverage = 0.01, .avg_tree_height = 8, .offset_x = 0, .offset_z = 0, .trunk = .wood, .leaves = .leaves };
    try testing.expectEqual(CompactLODTile.Support.vegetation_topology, CompactLODTile.support(&legacy, .lod4));
    try testing.expectError(error.UnsupportedSourceFeatures, mesh.buildCompactTile(&legacy));
    try testing.expectEqual(@as(f32, 0.01), legacy.vegetation[0].tree_coverage);
    try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
}

test "canonical scene allocation failure preserves pending draw state and pressure fallback" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    try grid.appendColumn(0, 0, &.{span(.stone, 1, 2)}, 1, 1, false);
    try airHalo(&grid);
    // Exercise every allocation, including the final replacement payload.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var mesh = LODMesh.init(testing.allocator, .lod1);
        defer mesh.clearRetiredState();
        try mesh.buildFromSceneGrid(&grid, &atlas);
        mesh.setDrawState(.{ .buffer_handle = 7, .vertex_count = 36, .capacity = 64, .ready = true });
        mesh.dedicated_upload_fallback = true;
        const old = mesh.pending_vertices.?;
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        mesh.allocator = failing.allocator();
        const result = mesh.buildFromSceneGrid(&grid, &atlas);
        mesh.allocator = testing.allocator;
        if (result) |_| break else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(mesh.pending_vertices.?.ptr == old.ptr);
            try testing.expectEqual(@as(u32, 36), mesh.opaque_vertex_count);
            try testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
            try testing.expectEqual(@as(usize, 36 * @sizeOf(Vertex)), mesh.water_vertex_offset);
            try testing.expectEqual(@as(rhi.BufferHandle, 7), mesh.buffer_handle);
            try testing.expect(mesh.isRenderable());
            try testing.expect(mesh.usesDedicatedUploadFallback());
        }
    }
    try testing.expect(fail_index > 0);
}

fn expectFaceLight(vertex: Vertex, channels: [4]f32) !void {
    const tile: u16 = @truncate(vertex.packed_meta);
    try testing.expectEqual(rhi.encodeMeta(tile, channels[0] / 15.0, 1), vertex.packed_meta);
    try testing.expectEqual(rhi.encodeBlocklight(.{ channels[1] / 15.0, channels[2] / 15.0, channels[3] / 15.0 }, false), vertex.blocklight);
}

test "canonical scene face lighting keeps sunny caps dark undersides and water boundaries separate" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    var grass = span(.grass, 4, 5);
    grass.light_bottom = core.PackedLight.init(0, 0);
    var water = span(.water, 8, 9);
    water.light = core.PackedLight.initRGB(3, 1, 7, 12);
    water.light_bottom = core.PackedLight.initRGB(1, 4, 2, 6);
    var roof = span(.stone, 12, 14);
    roof.light_bottom = core.PackedLight.init(0, 0);
    try grid.appendColumn(0, 0, &.{ grass, water, roof }, 1, 1, false);
    try airHalo(&grid);
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    var caps: usize = 0;
    for (mesh.pending_vertices.?) |vertex| {
        const top = vertex.normal == rhi.encodeNormal(.{ 0, 1, 0 });
        const bottom = vertex.normal == rhi.encodeNormal(.{ 0, -1, 0 });
        if (!top and !bottom) continue;
        caps += 1;
        if (vertex.pos[1] <= 5 or vertex.pos[1] >= 12) {
            try expectFaceLight(vertex, if (top) .{ 15, 0, 0, 0 } else .{ 0, 0, 0, 0 });
        } else {
            try expectFaceLight(vertex, if (top) .{ 3, 1, 7, 12 } else .{ 1, 4, 2, 6 });
        }
    }
    try testing.expectEqual(@as(usize, 36), caps);
    try testing.expectEqual(@as(u32, 72), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 36), mesh.water_vertex_count);
}

test "canonical scene face lighting follows neighboring cliff air and dark cave gaps not buried strata" {
    const atlas = testAtlas();
    for ([_]u32{ 1, 4, 16 }) |cell| {
        var grid = try SceneGrid.init(testing.allocator, -32, -32, cell, 1);
        defer grid.deinit();
        const area = cell * cell;
        var stone = span(.stone, 0, 16);
        stone.light = core.PackedLight.init(0, 0);
        stone.light_bottom = stone.light;
        var dirt = span(.dirt, 16, 17);
        dirt.light = stone.light;
        dirt.light_bottom = stone.light;
        var grass = span(.grass, 17, 18);
        grass.light_bottom = stone.light;
        try grid.appendColumn(0, 0, &.{ stone, dirt, grass }, area, area, false);
        var floor = span(.stone, 0, 4);
        floor.light = core.PackedLight.initRGB(15, 2, 5, 9);
        try grid.appendColumn(1, 0, &.{floor}, area, area, false);
        floor.light = core.PackedLight.init(0, 0);
        var roof = span(.stone, 20, 24);
        roof.light_bottom = core.PackedLight.init(0, 0);
        try grid.appendColumn(-1, 0, &.{ floor, roof }, area, area, false);
        floor.light = core.PackedLight.initRGB(0, 2, 4, 6);
        roof.light_bottom = core.PackedLight.initRGB(12, 14, 10, 0);
        try grid.appendColumn(0, -1, &.{ floor, roof }, area, area, false);
        try grid.appendColumn(0, 1, &.{}, area, area, false);
        var mesh = LODMesh.init(testing.allocator, .lod4);
        defer mesh.clearRetiredState();
        try mesh.buildFromSceneGrid(&grid, &atlas);
        var checked = [_]usize{0} ** 4;
        for (mesh.pending_vertices.?) |vertex| {
            const tile: u16 = @truncate(vertex.packed_meta);
            if (tile != atlas.getTilesForBlock(@intFromEnum(core.BlockType.stone)).side) continue;
            try testing.expectEqual(rhi.encodeColor(.{ 64.0 / 255.0, 128.0 / 255.0, 32.0 / 255.0 }), vertex.color);
            if (vertex.normal == rhi.encodeNormal(.{ 1, 0, 0 })) {
                checked[0] += 1;
                try expectFaceLight(vertex, .{ 15, 2, 5, 9 });
            } else if (vertex.normal == rhi.encodeNormal(.{ -1, 0, 0 })) {
                checked[1] += 1;
                try expectFaceLight(vertex, .{ 0, 0, 0, 0 });
            } else if (vertex.normal == rhi.encodeNormal(.{ 0, 0, -1 })) {
                checked[2] += 1;
                try expectFaceLight(vertex, if (vertex.pos[1] == 0) .{ 0, 2, 4, 6 } else .{ 9, 11, 8.5, 1.5 });
            } else {
                checked[3] += 1;
                try expectFaceLight(vertex, .{ 15, 0, 0, 0 });
            }
        }
        for (checked) |count| try testing.expectEqual(@as(usize, 6), count);
    }
}

test "canonical scene face lighting interpolates transparent neighbors and respects provisional estimates" {
    const atlas = testAtlas();
    for ([_]core.BlockType{ .water, .birch_leaves }) |medium| {
        var grid = try SceneGrid.init(testing.allocator, 0, 0, 4, 1);
        defer grid.deinit();
        var stone = span(.stone, 5, 15);
        stone.light = core.PackedLight.init(0, 0);
        stone.light_bottom = stone.light;
        try grid.appendColumn(0, 0, &.{stone}, 16, 16, false);
        var neighbor = span(medium, 0, 20);
        neighbor.light = core.PackedLight.initRGB(10, 10, 12, 14);
        neighbor.light_bottom = core.PackedLight.initRGB(0, 0, 2, 4);
        try grid.appendColumn(1, 0, &.{neighbor}, 16, 16, false);
        var estimate = span(.stone, 0, 4);
        estimate.light = core.PackedLight.initRGB(6, 8, 3, 1);
        try grid.appendColumn(-1, 0, &.{estimate}, 0, 16, true);
        try grid.appendColumn(0, -1, &.{}, 0, 16, true);
        try grid.appendColumn(0, 1, &.{}, 16, 16, false);
        var mesh = LODMesh.init(testing.allocator, .lod2);
        defer mesh.clearRetiredState();
        try mesh.buildFromSceneGrid(&grid, &atlas);
        const original = try testing.allocator.dupe(Vertex, mesh.pending_vertices.?);
        defer testing.allocator.free(original);
        var checked = [_]usize{0} ** 4;
        for (original) |vertex| {
            if (vertex.normal == rhi.encodeNormal(.{ 1, 0, 0 })) {
                checked[0] += 1;
                try expectFaceLight(vertex, if (vertex.pos[1] == 5) .{ 2.5, 2.5, 4.5, 6.5 } else .{ 7.5, 7.5, 9.5, 11.5 });
            } else if (vertex.normal == rhi.encodeNormal(.{ -1, 0, 0 })) {
                checked[1] += 1;
                try expectFaceLight(vertex, .{ 6, 8, 3, 1 });
            } else if (vertex.normal == rhi.encodeNormal(.{ 0, 0, -1 })) {
                checked[2] += 1;
                try expectFaceLight(vertex, .{ 0, 0, 0, 0 });
            } else if (vertex.normal == rhi.encodeNormal(.{ 0, 0, 1 })) {
                checked[3] += 1;
                try expectFaceLight(vertex, .{ 15, 0, 0, 0 });
            }
        }
        for (checked) |count| try testing.expectEqual(@as(usize, 6), count);
        grid.spans.items[1].light = core.PackedLight.initRGB(1, 2, 3, 4);
        try mesh.buildFromSceneGrid(&grid, &atlas);
        try testing.expectEqual(original.len, mesh.pending_vertices.?.len);
        for (original, mesh.pending_vertices.?) |before, after| {
            try testing.expectEqualDeep(before.pos, after.pos);
            try testing.expectEqualDeep(before.uv, after.uv);
            try testing.expectEqual(before.normal, after.normal);
            try testing.expectEqual(before.color, after.color);
            try testing.expectEqual(@as(u16, @truncate(before.packed_meta)), @as(u16, @truncate(after.packed_meta)));
        }
        // An inset halo footprint is not evidence for air at the shared edge.
        grid.spans.items[1].coverage = 0.25;
        try mesh.buildFromSceneGrid(&grid, &atlas);
        var inset_sides: usize = 0;
        for (mesh.pending_vertices.?) |vertex| {
            if (vertex.normal != rhi.encodeNormal(.{ 1, 0, 0 })) continue;
            inset_sides += 1;
            try expectFaceLight(vertex, .{ 0, 0, 0, 0 });
        }
        try testing.expectEqual(@as(usize, 6), inset_sides);
    }
}

test "canonical scene greedy flat and unmergeable grids stay below the existing CPU quota" {
    const BudgetAllocator = @import("lod_budget_allocator.zig").BudgetAllocator;
    for ([_]u32{ 256, 128 }, 0..) |width, case| {
        var atlas = testAtlas();
        // Identical atlas appearance must not erase semantic material boundaries.
        atlas.tile_mappings[@intFromEnum(core.BlockType.dirt)] = atlas.tile_mappings[@intFromEnum(core.BlockType.stone)];
        var grid = try SceneGrid.init(testing.allocator, -256, -256, 1, width);
        defer grid.deinit();
        const end: i32 = @intCast(width);
        var z: i32 = -1;
        while (z <= end) : (z += 1) {
            var x: i32 = -1;
            while (x <= end) : (x += 1) {
                try grid.appendColumn(x, z, &.{span(if (case == 1 and @mod(x + z, 2) == 1) .dirt else .stone, 0, 64)}, 1, 1, false);
            }
        }
        const quota = try BudgetAllocator.init(testing.allocator, BudgetAllocator.default_quota_bytes);
        defer quota.release();
        var mesh = LODMesh.init(quota.allocator(), .lod1);
        defer mesh.clearRetiredState();
        try mesh.buildFromSceneGrid(&grid, &atlas);
        const cells: usize = @as(usize, width) * width;
        const expected_vertices: usize = if (case == 0) 30 else (cells + 4 * width) * 6;
        try testing.expectEqual(expected_vertices, mesh.pending_vertices.?.len);
        try testing.expectEqual(@as(f32, @floatFromInt(cells)), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
        for (mesh.pending_vertices.?) |vertex| {
            if (vertex.normal != rhi.encodeNormal(.{ 0, 1, 0 })) continue;
            try testing.expectEqual(@as(f16, @floatCast(vertex.pos[0])), vertex.uv[0]);
            try testing.expectEqual(@as(f16, @floatCast(vertex.pos[2])), vertex.uv[1]);
        }
        const snapshot = quota.snapshot();
        const output_bytes = expected_vertices * @sizeOf(Vertex);
        const old_min_peak = cells * 6 * @sizeOf(Vertex) * 2;
        try testing.expectEqual(output_bytes, snapshot.used);
        try testing.expect(snapshot.peak < BudgetAllocator.default_quota_bytes);
        try testing.expect(snapshot.peak < old_min_peak);
        if (case == 0) try testing.expect(snapshot.peak < old_min_peak / 2);
        std.debug.print("canonical mesh metrics: {s} width={} input_faces={} output_faces={} output_bytes={} peak_bytes={} old_min_peak_bytes={}\n", .{
            if (case == 0) "flat" else "checkerboard", width, cells, expected_vertices / 6, output_bytes, snapshot.peak, old_min_peak,
        });
    }
}

test "canonical scene greedy exposed cliff retains three material bands" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, -16, -16, 2, 8);
    defer grid.deinit();
    const layers = [_]SceneSpan{ span(.stone, 0, 8), span(.dirt, 8, 10), span(.grass, 10, 11) };
    var z: i32 = -1;
    while (z <= 8) : (z += 1) {
        var x: i32 = -1;
        while (x <= 8) : (x += 1) {
            try grid.appendColumn(x, z, if (x == 8) &.{} else &layers, 4, 4, false);
        }
    }
    var mesh = LODMesh.init(testing.allocator, .lod1);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    try testing.expectEqual(@as(usize, 78), mesh.pending_vertices.?.len);
    try testing.expectEqual(@as(f32, 256), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 176), faceArea(mesh.pending_vertices.?, .{ 1, 0, 0 }));
    var counts = [_]usize{0} ** 3;
    for (mesh.pending_vertices.?) |vertex| {
        if (vertex.normal != rhi.encodeNormal(.{ 1, 0, 0 })) continue;
        try testing.expectEqual(@as(f32, 16), vertex.pos[0]);
        const tile: u16 = @truncate(vertex.packed_meta);
        var matched = false;
        for (layers, 0..) |layer, i| {
            if (tile != atlas.getTilesForBlock(@intFromEnum(layer.block)).side) continue;
            matched = true;
            counts[i] += 1;
            try testing.expect(vertex.pos[1] == layer.min_y or vertex.pos[1] == layer.max_y);
        }
        try testing.expect(matched);
    }
    for (counts) |count| try testing.expectEqual(@as(usize, 6), count);
}

test "canonical scene greedy preserves holes partial footprints and separate water levels" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 3);
    defer grid.deinit();
    var leaf = span(.birch_leaves, 4, 5);
    leaf.coverage = 0.25;
    var water = span(.water, 7, 8);
    water.coverage = 0.25;
    var upper_water = water;
    upper_water.min_y = 10;
    upper_water.max_y = 11;
    for (0..3) |z| {
        for (0..3) |x| {
            const layers = [_]SceneSpan{ span(.stone, 0, 2), leaf, water, upper_water };
            try grid.appendColumn(@intCast(x), @intCast(z), if (x == 1 and z == 1) &.{} else &layers, 1, 1, false);
        }
    }
    try airHalo(&grid);
    var mesh = LODMesh.init(testing.allocator, .lod1);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    const terrain = mesh.pending_vertices.?[0..mesh.opaque_vertex_count];
    const fluid = mesh.pending_vertices.?[mesh.opaque_vertex_count..];
    try testing.expectEqual(@as(f32, 10), faceArea(terrain, .{ 0, 1, 0 })); // 8 ground + 8 quarter canopies.
    try testing.expectEqual(@as(f32, 2), faceArea(terrain, .{ 0, -1, 0 }));
    try testing.expectEqual(@as(f32, 4), faceArea(fluid, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(u32, 8 * 2 * 36), mesh.water_vertex_count);
    try testing.expectEqual(@as(usize, mesh.opaque_vertex_count) * @sizeOf(Vertex), mesh.water_vertex_offset);
    var cap_count: usize = 0;
    var i: usize = 0;
    while (i < mesh.pending_vertices.?.len) : (i += 6) {
        const quad = mesh.pending_vertices.?[i..][0..6];
        if (quad[0].normal != rhi.encodeNormal(.{ 0, 1, 0 })) continue;
        var min = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var max = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        for (quad) |vertex| {
            min[0] = @min(min[0], vertex.pos[0]);
            min[1] = @min(min[1], vertex.pos[2]);
            max[0] = @max(max[0], vertex.pos[0]);
            max[1] = @max(max[1], vertex.pos[2]);
        }
        try testing.expect(!(min[0] < 1.5 and max[0] > 1.5 and min[1] < 1.5 and max[1] > 1.5));
        if (quad[0].pos[1] > 2) {
            cap_count += 1;
            try testing.expectEqual(@as(f32, 0.5), max[0] - min[0]);
            try testing.expectEqual(@as(f32, 0.5), max[1] - min[1]);
        }
    }
    try testing.expectEqual(@as(usize, 8 * 3), cap_count);
}

test "canonical scene greedy never merges nonuniform RGB side lighting" {
    const atlas = testAtlas();
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 4);
    defer grid.deinit();
    var stone = span(.stone, 1, 2);
    stone.light = core.PackedLight.initRGB(0, 0, 0, 15);
    stone.light_bottom = core.PackedLight.initRGB(0, 15, 0, 0);
    for (0..4) |z| {
        for (0..4) |x| try grid.appendColumn(@intCast(x), @intCast(z), &.{stone}, 1, 1, false);
    }
    try airHalo(&grid);
    var mesh = LODMesh.init(testing.allocator, .lod1);
    defer mesh.clearRetiredState();
    try mesh.buildFromSceneGrid(&grid, &atlas);
    // One merged top, one merged bottom, but four original quads per side.
    try testing.expectEqual(@as(usize, 18 * 6), mesh.pending_vertices.?.len);
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(f32, 16), faceArea(mesh.pending_vertices.?, .{ 0, -1, 0 }));
    for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } }) |normal| {
        var count: usize = 0;
        for (mesh.pending_vertices.?) |vertex| {
            if (vertex.normal != rhi.encodeNormal(normal)) continue;
            count += 1;
            try expectFaceLight(vertex, if (vertex.pos[1] == 1) .{ 15, 15, 0, 0 } else .{ 15, 0, 0, 15 });
        }
        try testing.expectEqual(@as(usize, 24), count);
        try testing.expectEqual(@as(f32, 4), faceArea(mesh.pending_vertices.?, normal));
    }
}
