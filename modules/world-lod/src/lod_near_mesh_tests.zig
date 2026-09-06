//! Reference expanded meshes for the opt-in near1-block source contract.
const std = @import("std");
const testing = std.testing;
const world_core = @import("world-core");
const mesh_mod = @import("lod_mesh.zig");
const geom = @import("lod_geometry.zig");
const LODMesh = mesh_mod.LODMesh;
const LODSimplifiedData = world_core.LODSimplifiedData;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi = @import("engine-rhi");

fn testAtlas() TextureAtlas {
    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = testing.allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** world_core.MAX_BLOCK_TYPES,
    };
    for ([_]world_core.BlockType{ .grass, .water, .wood, .birch_log, .spruce_log }) |block| {
        atlas.tile_mappings[@intFromEnum(block)] = TextureAtlas.BlockTiles.uniform(@intFromEnum(block) + 1);
    }
    return atlas;
}

fn emptyNearData(lod: world_core.LODLevel) !LODSimplifiedData {
    const data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, lod);
    @memset(data.provenance, .edited);
    return data;
}

fn span(bottom: f32, top: f32, block: world_core.BlockType) world_core.LODVerticalSpan {
    return .{
        .min_height = bottom,
        .max_height = top,
        .biome = .plains,
        .material_layers = world_core.LODMaterialLayers.default(block),
        .color = geom.packBlockDefaultColor(block, 0x557733),
        .water = world_core.LODWaterState.empty,
        .lighting = world_core.LODLightingHint.daylight,
        .vegetation = world_core.LODVegetationHint.empty,
    };
}

fn testResources(destroyed: *u32) mesh_mod.LODMeshResources {
    const Mock = struct {
        fn create(_: *anyopaque, _: usize, _: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
            return 1;
        }
        fn upload(_: *anyopaque, _: rhi.BufferHandle, _: []const u8) rhi.RhiError!void {}
        fn update(_: *anyopaque, _: rhi.BufferHandle, _: usize, _: []const u8) rhi.RhiError!void {}
        fn destroy(ptr: *anyopaque, _: rhi.BufferHandle) void {
            const count: *u32 = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
        fn wait(_: *anyopaque) void {}
        const vtable = mesh_mod.LODMeshResources.VTable{
            .createBuffer = create,
            .uploadBuffer = upload,
            .updateBuffer = update,
            .destroyBuffer = destroy,
            .waitIdle = wait,
        };
    };
    return .{ .ptr = destroyed, .vtable = &Mock.vtable };
}

test "near mesh preserves leaf-only and log-only measured one-block envelopes" {
    var atlas = testAtlas();
    for ([_]world_core.LODLevel{ .lod0, .lod1 }) |lod| {
        var data = try emptyNearData(lod);
        defer data.deinit();
        var mesh = LODMesh.init(testing.allocator, lod);
        defer mesh.clearPendingVertices();
        for ([_]world_core.BlockType{ .birch_leaves, .spruce_leaves, .birch_log, .spruce_log }) |block| {
            try testing.expect(data.setVerticalSpan(2, 3, 0, span(80, 81, block)));
            // Stale advisory hints must not invent a trunk or enlarge the envelope.
            data.vegetation[2 + 3 * data.width] = .{ .tree_coverage = 1, .avg_tree_height = 40, .offset_x = 0.5, .offset_z = 0.5, .trunk = .wood, .leaves = .leaves };
            try mesh.buildFromNearSimplifiedData(&data, -64, -32, &atlas);
            const vertices = mesh.pending_vertices orelse return error.TestExpectedEqual;
            try testing.expectEqual(@as(usize, 36), vertices.len);
            for (vertices) |v| {
                try testing.expect(v.pos[0] == 2 or v.pos[0] == 3);
                try testing.expect(v.pos[2] == 3 or v.pos[2] == 4);
                try testing.expect(v.pos[1] == 80 or v.pos[1] == 81);
                const tile: u16 = @truncate(v.packed_meta);
                try testing.expectEqual(geom.getLodSideTile(block, &atlas), tile);
            }
            const expected_color = geom.applyTextureLuminance(geom.tintColorForLodFace(&data, 2, 3, lod, block, .top, geom.getLodTopColor(block, geom.getLodTopTile(block, &atlas), span(80, 81, block).color)), block, .top, &atlas);
            try testing.expectEqual(rhi.encodeColor(.{ geom.unpackR(expected_color), geom.unpackG(expected_color), geom.unpackB(expected_color) }), vertices[0].color);
        }
    }
}

test "near mesh water does not suppress canopy or shift measured ground" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    const idx = 2 + 2 * data.width;
    data.heightmap[idx] = 63;
    data.material_layers[idx] = world_core.LODMaterialLayers.default(.grass);
    data.water[idx] = .{ .is_surface = true, .surface_height = 65.5, .depth = 10, .coverage = 1 };
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(0, 63, .grass)));
    try testing.expect(data.setVerticalSpan(2, 2, 1, span(64, 70, .birch_leaves)));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    const vertices = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 66), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);
    for (vertices[0..6]) |v| try testing.expectEqual(@as(f32, 63), v.pos[1]);
    for (vertices[30..66]) |v| try testing.expect(v.pos[1] == 64 or v.pos[1] == 70);
    for (vertices[66..]) |v| try testing.expectEqual(@as(f32, 65.5), v.pos[1]);
}

test "near mesh subtracts adjacent canopy intervals without internal faces" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(70, 75, .leaves)));
    try testing.expect(data.setVerticalSpan(3, 2, 0, span(72, 73, .birch_leaves)));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    const vertices = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var shared_vertices: usize = 0;
    for (vertices) |v| {
        if (v.pos[0] != 3 or v.normal != rhi.encodeNormal(.{ 1, 0, 0 })) continue;
        shared_vertices += 1;
        try testing.expect(v.pos[1] <= 72 or v.pos[1] >= 73);
    }
    try testing.expectEqual(@as(usize, 12), shared_vertices);
    for (vertices) |v| {
        try testing.expect(v.pos[0] != 3 or v.normal != rhi.encodeNormal(.{ -1, 0, 0 }));
    }
    try testing.expect(data.setVerticalSpan(3, 2, 0, span(70, 75, .birch_leaves)));
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 60), mesh.pending_vertices.?.len);
}

test "near authoritative empty clears an uploaded mesh and remains ready" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    var destroyed: u32 = 0;
    const resources = testResources(&destroyed);
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.deinit(resources);
    try mesh.upload(resources);
    try testing.expect(!mesh.isReady());
    try testing.expect(data.setVerticalSpan(0, 0, 0, span(80, 81, .leaves)));
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try mesh.upload(resources);
    try testing.expect(mesh.isRenderable());
    data.clearVerticalSpans(0, 0);
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 0), mesh.pending_vertices.?.len);
    try mesh.upload(resources);
    try testing.expectEqual(@as(u32, 1), destroyed);
    try testing.expect(mesh.isReady());
    try testing.expect(!mesh.isRenderable());
    try testing.expectEqual(@as(u32, 0), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
    try testing.expect(mesh.pending_vertices == null);
    try mesh.upload(resources);
    try testing.expect(mesh.isReady());
    try testing.expect(!mesh.isRenderable());
    try testing.expectEqual(@as(u32, 1), destroyed);

    try testing.expect(data.setVerticalSpan(0, 0, 0, span(90, 91, .birch_log)));
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try mesh.upload(resources);
    try testing.expect(mesh.isRenderable());
    try testing.expectEqual(@as(u32, 36), mesh.vertex_count);
    try testing.expectEqual(@as(u32, 36), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 1), destroyed);
    try mesh.upload(resources);
    try testing.expect(mesh.isRenderable());
    try testing.expectEqual(@as(u32, 36), mesh.vertex_count);
}

test "near log underside uses distinct atlas bottom tile and albedo" {
    var atlas = testAtlas();
    atlas.tile_mappings[@intFromEnum(world_core.BlockType.birch_log)] = .{ .top = 101, .bottom = 102, .side = 103 };
    atlas.tile_colors[@intFromEnum(world_core.BlockType.birch_log)] = .{ .top = 0x224466, .bottom = 0x88AA44, .side = 0x663322 };
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(70, 71, .birch_log)));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
    var bottom_vertices: usize = 0;
    var top_vertices: usize = 0;
    var side_vertices: usize = 0;
    for (mesh.pending_vertices.?) |v| {
        const tile: u16 = @truncate(v.packed_meta);
        if (v.normal == rhi.encodeNormal(.{ 0, -1, 0 })) {
            bottom_vertices += 1;
            try testing.expectEqual(@as(u16, 102), tile);
            try testing.expectEqual(@as(f32, 70), v.pos[1]);
            try testing.expectEqual(rhi.encodeColor(.{ 68.0 / 255.0, 85.0 / 255.0, 34.0 / 255.0 }), v.color);
        } else if (v.normal == rhi.encodeNormal(.{ 0, 1, 0 })) {
            top_vertices += 1;
            try testing.expectEqual(@as(u16, 101), tile);
            try testing.expectEqual(@as(f32, 71), v.pos[1]);
            try testing.expectEqual(rhi.encodeColor(.{ 34.0 / 255.0, 68.0 / 255.0, 102.0 / 255.0 }), v.color);
        } else {
            side_vertices += 1;
            try testing.expectEqual(@as(u16, 103), tile);
        }
    }
    try testing.expectEqual(@as(usize, 6), bottom_vertices);
    try testing.expectEqual(@as(usize, 6), top_vertices);
    try testing.expectEqual(@as(usize, 24), side_vertices);
}

test "near mesh encodes captured span lighting without baking AO into albedo" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    const idx = 2 + 2 * data.width;
    data.heightmap[idx] = 10;
    data.material_layers[idx] = world_core.LODMaterialLayers.default(.grass);
    data.colors[idx] = 0x557733;
    data.lighting[idx] = .{ .sky_light = 0, .block_light = 3, .ambient_occlusion = 0.25 };
    data.water[idx] = .{ .is_surface = true, .surface_height = 12, .depth = 2, .coverage = 1 };
    var trunk = span(20, 21, .birch_log);
    trunk.lighting = .{ .sky_light = 7, .block_light = 9, .ambient_occlusion = 0.5 };
    var leaves = span(30, 31, .birch_leaves);
    leaves.lighting = .{ .sky_light = 15, .block_light = 15, .ambient_occlusion = 0.75 };
    try testing.expect(data.setVerticalSpan(2, 2, 0, trunk));
    try testing.expect(data.setVerticalSpan(2, 2, 1, leaves));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    const captured = try testing.allocator.dupe(rhi.Vertex, mesh.pending_vertices.?);
    defer testing.allocator.free(captured);
    try testing.expectEqual(@as(u32, 102), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);
    for ([_]struct { start: usize, end: usize, meta: u32, blocklight: u32 }{
        .{ .start = 0, .end = 30, .meta = 0x40000000, .blocklight = 0x00333333 },
        .{ .start = 30, .end = 66, .meta = 0x80770000, .blocklight = 0x00999999 },
        .{ .start = 66, .end = 102, .meta = 0xBFFF0000, .blocklight = 0x00FFFFFF },
        .{ .start = 102, .end = 108, .meta = 0x40000000, .blocklight = 0x00333333 },
    }) |range| {
        for (captured[range.start..range.end]) |v| {
            try testing.expectEqual(range.meta, v.packed_meta & 0xFFFF0000);
            try testing.expectEqual(range.blocklight, v.blocklight);
        }
    }
    data.lighting[idx] = world_core.LODLightingHint.daylight;
    trunk.lighting = world_core.LODLightingHint.daylight;
    leaves.lighting = world_core.LODLightingHint.daylight;
    try testing.expect(data.setVerticalSpan(2, 2, 0, trunk));
    try testing.expect(data.setVerticalSpan(2, 2, 1, leaves));
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(captured.len, mesh.pending_vertices.?.len);
    for (captured, mesh.pending_vertices.?) |before, after| {
        try testing.expectEqual(before.color, after.color);
        try testing.expectEqual(@as(u16, @truncate(before.packed_meta)), @as(u16, @truncate(after.packed_meta)));
        try testing.expectEqual(@as(u32, 0xFFFF0000), after.packed_meta & 0xFFFF0000);
        try testing.expectEqual(@as(u32, 0), after.blocklight);
    }
}

test "near mesh overlapping log and leaf envelopes have no coplanar sides" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(70, 74, .birch_log)));
    try testing.expect(data.setVerticalSpan(2, 2, 1, span(72, 76, .birch_leaves)));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 60), mesh.pending_vertices.?.len);
    for (mesh.pending_vertices.?) |v| {
        const tile: u16 = @truncate(v.packed_meta);
        if (tile == rhi.Vertex.LOD_TILE_ID) try testing.expect(v.pos[1] == 74 or v.pos[1] == 76);
    }
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(70, 76, .birch_log)));
    try testing.expect(data.setVerticalSpan(2, 2, 1, span(70, 76, .birch_leaves)));
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 36), mesh.pending_vertices.?.len);
    for (mesh.pending_vertices.?) |v| {
        try testing.expectEqual(geom.getLodSideTile(.birch_log, &atlas), @as(u16, @truncate(v.packed_meta)));
    }
}

test "near mesh ignores underground cave and overhang spans" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    const idx = 2 + 2 * data.width;
    data.heightmap[idx] = 64;
    data.material_layers[idx] = world_core.LODMaterialLayers.default(.grass);
    try testing.expect(data.setVerticalSpan(2, 2, 0, span(0, 30, .stone)));
    try testing.expect(data.setVerticalSpan(2, 2, 1, span(40, 64, .dirt)));
    try testing.expect(data.setVerticalSpan(2, 2, 2, span(80, 90, .stone)));
    try testing.expect(!mesh_mod.canBuildColumnSpans(&data));
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(usize, 30), mesh.pending_vertices.?.len);
    for (mesh.pending_vertices.?) |v| try testing.expect(v.pos[1] == 0 or v.pos[1] == 64);
}

test "near terrain unknown edges have only one-block handoff skirts" {
    var atlas = testAtlas();
    for ([_]world_core.LODLevel{ .lod0, .lod1 }) |lod| {
        var data = try emptyNearData(lod);
        defer data.deinit();
        @memset(data.heightmap, 80);
        @memset(data.material_layers, world_core.LODMaterialLayers.default(.grass));
        var mesh = LODMesh.init(testing.allocator, lod);
        defer mesh.clearPendingVertices();
        try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
        var west_vertices: usize = 0;
        var north_vertices: usize = 0;
        for (mesh.pending_vertices.?) |v| {
            try testing.expect(v.pos[1] == 79 or v.pos[1] == 80);
            if (v.normal == rhi.encodeNormal(.{ 0, 1, 0 })) {
                try testing.expectEqual(@as(f32, 80), v.pos[1]);
            } else if (v.normal == rhi.encodeNormal(.{ -1, 0, 0 })) {
                west_vertices += 1;
                try testing.expectEqual(@as(f32, 0), v.pos[0]);
            } else if (v.normal == rhi.encodeNormal(.{ 0, 0, -1 })) {
                north_vertices += 1;
                try testing.expectEqual(@as(f32, 0), v.pos[2]);
            } else return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, (data.width - 1) * 6), west_vertices);
        try testing.expectEqual(@as(usize, (data.width - 1) * 6), north_vertices);
    }
}

test "near terrain uses advisory positive edge heights without clamping real differences" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod1);
    defer data.deinit();
    @memset(data.heightmap, 80);
    @memset(data.material_layers, world_core.LODMaterialLayers.default(.grass));
    const edge = data.width - 1;
    const edge_pos: f32 = @floatFromInt(edge);
    var mesh = LODMesh.init(testing.allocator, .lod1);
    defer mesh.clearPendingVertices();
    // Include a drop larger than the old skirt: known differences must not
    // silently become bounded skirts just because they are at a region edge.
    for ([_]f32{ 80, 74, 30, 84 }) |height| {
        for (0..data.width) |i| {
            const coord: u32 = @intCast(i);
            data.setHeight(edge, coord, height);
            data.setHeight(coord, edge, height);
            data.setColumnProvenance(edge, coord, .worldgen);
            data.setColumnProvenance(coord, edge, .worldgen);
        }
        try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
        var east_vertices: usize = 0;
        var south_vertices: usize = 0;
        var floor_vertices: usize = 0;
        for (mesh.pending_vertices.?) |v| {
            if (v.normal == rhi.encodeNormal(.{ 1, 0, 0 })) {
                east_vertices += 1;
                try testing.expectEqual(edge_pos, v.pos[0]);
            } else if (v.normal == rhi.encodeNormal(.{ 0, 0, 1 })) {
                south_vertices += 1;
                try testing.expectEqual(edge_pos, v.pos[2]);
            } else continue;
            try testing.expect(v.pos[1] == height or v.pos[1] == 80);
            if (v.pos[1] == height) floor_vertices += 1;
        }
        const expected: usize = if (height < 80) edge * 6 else 0;
        try testing.expectEqual(expected, east_vertices);
        try testing.expectEqual(expected, south_vertices);
        try testing.expectEqual(expected, floor_vertices);
    }
}

test "near terrain preserves tall interior measured cliffs" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    @memset(data.material_layers, world_core.LODMaterialLayers.default(.grass));
    const split = (data.width - 1) / 2;
    for (0..data.width) |z| {
        for (0..data.width) |x| data.heightmap[x + z * data.width] = if (x < split) 80 else 30;
    }
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    var cliff_vertices: usize = 0;
    var bottom_vertices: usize = 0;
    for (mesh.pending_vertices.?) |v| {
        if (v.normal != rhi.encodeNormal(.{ 1, 0, 0 })) continue;
        cliff_vertices += 1;
        try testing.expectEqual(@as(f32, @floatFromInt(split)), v.pos[0]);
        try testing.expect(v.pos[1] == 30 or v.pos[1] == 80);
        if (v.pos[1] == 30) bottom_vertices += 1;
    }
    try testing.expectEqual(@as(usize, (data.width - 1) * 6), cliff_vertices);
    try testing.expectEqual(cliff_vertices / 2, bottom_vertices);
}

test "near water-only region edges never invent opaque ground or skirts" {
    var atlas = testAtlas();
    var data = try emptyNearData(.lod0);
    defer data.deinit();
    const edge = data.width - 2;
    for ([_][2]u32{ .{ 0, 0 }, .{ edge, edge } }) |cell| {
        const idx = cell[0] + cell[1] * data.width;
        // An air scalar material is authoritative even with a stale height.
        data.heightmap[idx] = 90;
        data.water[idx] = .{ .is_surface = true, .surface_height = 64, .depth = 4, .coverage = 1 };
        var water_span = span(60, 64, .water);
        water_span.water = data.water[idx];
        try testing.expect(data.setVerticalSpan(cell[0], cell[1], 0, water_span));
    }
    var mesh = LODMesh.init(testing.allocator, .lod0);
    defer mesh.clearPendingVertices();
    try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
    try testing.expectEqual(@as(u32, 0), mesh.opaque_vertex_count);
    try testing.expectEqual(@as(u32, 12), mesh.water_vertex_count);
    for (mesh.pending_vertices.?) |v| {
        try testing.expectEqual(@as(f32, 64), v.pos[1]);
        try testing.expectEqual(rhi.encodeNormal(.{ 0, 1, 0 }), v.normal);
        try testing.expectEqual(geom.getLodTopTile(.water, &atlas), @as(u16, @truncate(v.packed_meta)));
    }
}

test "near mesh preserves advisory worldgen and rejects coarse measured spans" {
    var atlas = testAtlas();
    for ([_]struct { lod: world_core.LODLevel, width: u32, provenance: world_core.LODColumnProvenance }{
        .{ .lod = .lod0, .width = 33, .provenance = .worldgen },
        .{ .lod = .lod0, .width = 17, .provenance = .chunk_derived },
        .{ .lod = .lod1, .width = 33, .provenance = .edited },
        .{ .lod = .lod2, .width = 129, .provenance = .edited },
    }) |case| {
        var data = try LODSimplifiedData.initWithVerticalSpansGridSize(testing.allocator, case.lod, case.width);
        defer data.deinit();
        @memset(data.heightmap, 64);
        @memset(data.material_layers, world_core.LODMaterialLayers.default(.grass));
        data.setColumnProvenance(0, 0, case.provenance);
        data.vegetation[0] = .{ .tree_coverage = 1, .avg_tree_height = 8, .offset_x = 0.5, .offset_z = 0.5, .trunk = .wood, .leaves = .leaves };
        try testing.expect(data.setVerticalSpan(0, 0, 0, span(90, 100, .leaves)));
        var mesh = LODMesh.init(testing.allocator, case.lod);
        defer mesh.clearPendingVertices();
        try mesh.buildFromNearSimplifiedData(&data, 0, 0, &atlas);
        var canopy_vertices: usize = 0;
        for (mesh.pending_vertices.?) |v| {
            try testing.expect(v.pos[1] < 90);
            if (v.pos[1] > 64) canopy_vertices += 1;
        }
        try testing.expect(canopy_vertices > 0);
        if (case.provenance != .worldgen) try testing.expect(!mesh_mod.canBuildColumnSpans(&data));
    }
}

test "near mesh consumes real chunk capture at exact negative-region footprints" {
    const NearChunkSummary = @import("lod_near_source.zig").NearChunkSummary;
    var atlas = testAtlas();
    var chunk = world_core.Chunk.init(-1, -1);
    chunk.setBlock(2, 63, 3, .grass);
    for (64..67) |y| chunk.setBlock(2, @intCast(y), 3, .water);
    chunk.setBlock(2, 80, 3, .birch_log);
    chunk.setBlock(2, 82, 3, .birch_log);
    chunk.setBlock(2, 90, 3, .birch_leaves);
    chunk.setBlock(2, 91, 3, .birch_leaves);
    chunk.setBlock(4, 120, 3, .spruce_leaves);
    chunk.setBlock(6, 200, 3, .spruce_log);
    @memset(&chunk.light, world_core.PackedLight.init(7, 9));
    const captured = NearChunkSummary.capture(&chunk);
    for ([_]world_core.LODLevel{ .lod0, .lod1 }) |lod| {
        var data = try emptyNearData(lod);
        defer data.deinit();
        const region_size: i32 = @intCast(world_core.regionSizeBlocks(lod));
        try testing.expect(captured.apply(&data, -1, -1, -region_size, -region_size, region_size, .edited) > 0);
        var mesh = LODMesh.init(testing.allocator, lod);
        defer mesh.clearPendingVertices();
        try mesh.buildFromNearSimplifiedData(&data, -region_size, -region_size, &atlas);
        try testing.expectEqual(@as(u32, 174), mesh.opaque_vertex_count);
        try testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);
        const vertices = mesh.pending_vertices.?;
        for (vertices) |v| {
            try testing.expectEqual(@as(u32, 0xFF770000), v.packed_meta & 0xFFFF0000);
            try testing.expectEqual(@as(u32, 0x00999999), v.blocklight);
        }
        const offset: f32 = @floatFromInt(region_size - world_core.CHUNK_SIZE_X);
        var ground_top: usize = 0;
        var birch_log: usize = 0;
        var spruce_log: usize = 0;
        var leaves: usize = 0;
        for (vertices[0..mesh.opaque_vertex_count]) |v| {
            try testing.expect(v.pos[0] >= offset + 2 and v.pos[0] <= offset + 7);
            try testing.expect(v.pos[2] >= offset + 3 and v.pos[2] <= offset + 4);
            const tile: u16 = @truncate(v.packed_meta);
            if (tile == geom.getLodTopTile(.grass, &atlas) and v.normal == rhi.encodeNormal(.{ 0, 1, 0 })) {
                ground_top += 1;
                try testing.expectEqual(@as(f32, 64), v.pos[1]);
            } else if (tile == geom.getLodSideTile(.birch_log, &atlas)) {
                birch_log += 1;
                try testing.expect(v.pos[1] == 80 or v.pos[1] == 83);
            } else if (tile == geom.getLodSideTile(.spruce_log, &atlas)) {
                spruce_log += 1;
                try testing.expect(v.pos[1] == 200 or v.pos[1] == 201);
            } else if (tile == rhi.Vertex.LOD_TILE_ID) {
                leaves += 1;
                if (v.pos[0] <= offset + 3) {
                    try testing.expect(v.pos[1] == 90 or v.pos[1] == 92);
                } else {
                    try testing.expect(v.pos[1] == 120 or v.pos[1] == 121);
                }
            }
        }
        try testing.expectEqual(@as(usize, 6), ground_top);
        try testing.expectEqual(@as(usize, 36), birch_log);
        try testing.expectEqual(@as(usize, 36), spruce_log);
        try testing.expectEqual(@as(usize, 72), leaves);
        for (vertices[mesh.opaque_vertex_count..]) |v| try testing.expectEqual(@as(f32, 67), v.pos[1]);
    }
}
