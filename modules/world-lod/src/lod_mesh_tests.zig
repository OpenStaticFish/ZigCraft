//! Tests for LOD mesh generation.

const std = @import("std");
const mesh_mod = @import("lod_mesh.zig");
const geom = @import("lod_geometry.zig");
const world_core = @import("world-core");
const biome_mod = @import("biome_color_provider.zig");
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const BufferUsage = rhi_types.BufferUsage;
const RhiError = rhi_types.RhiError;
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;

const LODMesh = mesh_mod.LODMesh;
const LODMeshResources = mesh_mod.LODMeshResources;
const CompactLODPool = @import("lod_compact_pool.zig").CompactLODPool;
const TileEdge = @import("lod_tile.zig").TileEdge;
const TILE_EDGE_MASK = @import("lod_tile.zig").TILE_EDGE_MASK;
const MAX_STAGING_UPDATE_BYTES = mesh_mod.MAX_STAGING_UPDATE_BYTES;
const getCellSize = mesh_mod.getCellSize;
const updateBufferChunked = mesh_mod.updateBufferChunked;

const LODColumnSpan = geom.LODColumnSpan;
const LODTextureFace = geom.LODTextureFace;
const addExposedSpanFace = geom.addExposedSpanFace;
const addTreeCanopyColumn = geom.addTreeCanopyColumn;
const applyTextureLuminance = geom.applyTextureLuminance;
const blockForLODQuad = geom.blockForLODQuad;
const buildFullDetailHeightmapMesh = geom.buildFullDetailHeightmapMesh;
const collectColumnSpans = geom.collectColumnSpans;
const makeLODVertex = geom.makeLODVertex;
const quantizedCellSurfaceHeight = geom.quantizedCellSurfaceHeight;
const quantizedCellTerrainHeight = geom.quantizedCellTerrainHeight;
const quantizedWaterSurfaceHeightForCell = geom.quantizedWaterSurfaceHeightForCell;
const representativeVegetationForLOD = geom.representativeVegetationForLOD;

// Tests
fn testResources() LODMeshResources {
    const Mock = struct {
        fn createBuffer(_: *anyopaque, _: usize, _: BufferUsage) RhiError!BufferHandle {
            return 1;
        }
        fn uploadBuffer(_: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {}
        fn updateBuffer(_: *anyopaque, _: BufferHandle, _: usize, _: []const u8) RhiError!void {}
        fn destroyBuffer(_: *anyopaque, _: BufferHandle) void {}
        fn waitIdle(_: *anyopaque) void {}

        const vtable = LODMeshResources.VTable{
            .createBuffer = createBuffer,
            .uploadBuffer = uploadBuffer,
            .updateBuffer = updateBuffer,
            .destroyBuffer = destroyBuffer,
            .waitIdle = waitIdle,
        };
    };
    return .{ .ptr = undefined, .vtable = &Mock.vtable };
}

test "LODMesh initialization" {
    const allocator = std.testing.allocator;
    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try std.testing.expectEqual(LODLevel.lod1, mesh.lod_level);
    try std.testing.expectEqual(@as(u32, 0), mesh.vertex_count);
    try std.testing.expect(!mesh.ready);
}

test "compact late neighbor keeps a resident fallback edge skirted" {
    const allocator = std.testing.allocator;
    var left_source = try LODSimplifiedData.init(allocator, .lod4);
    defer left_source.deinit();
    var right_source = try LODSimplifiedData.init(allocator, .lod4);
    defer right_source.deinit();
    right_source.setHeight(0, 3, 88.0);

    var left = LODMesh.init(allocator, .lod4);
    var pool = CompactLODPool.init(allocator);
    defer {
        // `CompactLODPool` owns the shared storage handle. Do not call the
        // generic mesh deinit while that handle is still attached.
        left.clearRetiredState();
        pool.deinit(testResources());
    }
    try left.buildCompactTile(&left_source);

    // The pool owns the immutable GPU range and releases the CPU payload. A
    // neighbor arriving later must not make the old fallback apron seamless.
    try pool.upload(&left, testResources());
    try std.testing.expect(left.compact_tile == null);
    var late_right = LODMesh.init(allocator, .lod4);
    defer late_right.deinit(testResources());
    try late_right.buildCompactTile(&right_source);

    try std.testing.expect(!left.patchCompactNeighbor(.east, &late_right));
    try std.testing.expect(!left.compactEdgeIsSeamless(.east));
    try std.testing.expectEqual(TILE_EDGE_MASK, left.compactSkirtMask());
}

test "compact eviction reload does not retain a stale seam claim" {
    const allocator = std.testing.allocator;
    var left_source = try LODSimplifiedData.init(allocator, .lod4);
    defer left_source.deinit();
    var right_source = try LODSimplifiedData.init(allocator, .lod4);
    defer right_source.deinit();

    var left = LODMesh.init(allocator, .lod4);
    defer left.deinit(testResources());
    var right = LODMesh.init(allocator, .lod4);
    defer right.deinit(testResources());
    try left.buildCompactTile(&left_source);
    try right.buildCompactTile(&right_source);
    try std.testing.expect(left.patchCompactNeighbor(.east, &right));
    try std.testing.expect(left.compactEdgeIsSeamless(.east));

    // Retiring the old range and rebuilding from a reloaded source starts with
    // no authority. The edge becomes seamless only after a fresh pre-upload
    // neighbor patch, never by inheriting the former resident metadata.
    left.clearRetiredState();
    try left.buildCompactTile(&left_source);
    try std.testing.expect(!left.compactEdgeIsSeamless(.east));
    try std.testing.expectEqual(TILE_EDGE_MASK, left.compactSkirtMask());
    try std.testing.expect(left.patchCompactNeighbor(.east, &right));
    try std.testing.expect(left.compactEdgeIsSeamless(.east));
}

test "compact differing LOD edges remain non-seamless and skirted" {
    const allocator = std.testing.allocator;
    var fine_source = try LODSimplifiedData.init(allocator, .lod3);
    defer fine_source.deinit();
    var coarse_source = try LODSimplifiedData.init(allocator, .lod4);
    defer coarse_source.deinit();

    var fine = LODMesh.init(allocator, .lod3);
    defer fine.deinit(testResources());
    var coarse = LODMesh.init(allocator, .lod4);
    defer coarse.deinit(testResources());
    try fine.buildCompactTile(&fine_source);
    try coarse.buildCompactTile(&coarse_source);

    try std.testing.expect(!fine.patchCompactNeighbor(TileEdge.east, &coarse));
    try std.testing.expect(!fine.compactEdgeIsSeamless(.east));
    try std.testing.expectEqual(TILE_EDGE_MASK, fine.compactSkirtMask());
}

test "getCellSize" {
    try std.testing.expectEqual(@as(u32, 1), getCellSize(.lod0));
    try std.testing.expectEqual(@as(u32, 1), getCellSize(.lod1));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod2));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod3));
    // The 512-block horizon region uses 65 samples (64 cells).
    try std.testing.expectEqual(@as(u32, 8), getCellSize(.lod4));
}

test "buildFromSimplifiedData keeps distant heightfields voxel stepped" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);
    data.setHeight(0, 0, 64.0);
    data.setHeight(1, 0, 70.0);
    data.setHeight(0, 1, 66.0);
    data.setHeight(1, 1, 72.0);

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len >= 6);

    var top_vertices_at_base_height: usize = 0;
    for (verts[0..6]) |v| {
        if (v.pos[1] == 64.0) top_vertices_at_base_height += 1;
    }

    try std.testing.expectEqual(@as(usize, 6), top_vertices_at_base_height);
}

test "buildFullDetailHeightmapMesh spans full LOD region" {
    const allocator = std.testing.allocator;

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xFFFFFF)} ** world_core.MAX_BLOCK_TYPES;

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    const cell_count: usize = @intCast(data.width * data.width);
    var i: usize = 0;
    while (i < cell_count) : (i += 1) {
        data.heightmap[i] = 0.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .air;
        data.colors[i] = 0;
    }

    const mesh = try buildFullDetailHeightmapMesh(allocator, .lod3, &data, 32, 64, &atlas);
    defer {
        allocator.free(mesh.vertices);
        allocator.free(mesh.indices);
    }

    var max_x: f32 = 0.0;
    var max_z: f32 = 0.0;
    for (mesh.vertices) |v| {
        max_x = @max(max_x, v.pos[0]);
        max_z = @max(max_z, v.pos[2]);
    }

    try std.testing.expectEqual(@as(f32, 256.0), max_x);
    try std.testing.expectEqual(@as(f32, 256.0), max_z);
    try std.testing.expectEqual(@as(f32, 32.0), @as(f32, mesh.vertices[0].uv[0]));
    try std.testing.expectEqual(@as(f32, 64.0), @as(f32, mesh.vertices[0].uv[1]));
}

fn vertexTileId(v: Vertex) u16 {
    return @intCast(v.packed_meta & 0xFFFF);
}

fn vertexRgb(v: Vertex) u32 {
    const r = v.color & 0xFF;
    const g = (v.color >> 8) & 0xFF;
    const b = (v.color >> 16) & 0xFF;
    return (r << 16) | (g << 8) | b;
}

fn linearizeTestRgb(color: u32) u32 {
    const r = linearizeTestChannel(@intCast((color >> 16) & 0xFF));
    const g = linearizeTestChannel(@intCast((color >> 8) & 0xFF));
    const b = linearizeTestChannel(@intCast(color & 0xFF));
    return (r << 16) | (g << 8) | b;
}

fn linearizeTestChannel(value: u8) u32 {
    const c = @as(f32, @floatFromInt(value)) / 255.0;
    const linear = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    return @intFromFloat(@round(std.math.clamp(linear * 255.0, 0.0, 255.0)));
}

test "updateBufferChunked bounds individual staging updates" {
    const Mock = struct {
        calls: u32 = 0,
        max_len: usize = 0,
        total_len: usize = 0,

        fn createBuffer(_: *anyopaque, _: usize, _: BufferUsage) RhiError!BufferHandle {
            return 1;
        }

        fn uploadBuffer(_: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {}

        fn updateBuffer(ptr: *anyopaque, _: BufferHandle, _: usize, data: []const u8) RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.max_len = @max(self.max_len, data.len);
            self.total_len += data.len;
        }

        fn destroyBuffer(_: *anyopaque, _: BufferHandle) void {}
        fn waitIdle(_: *anyopaque) void {}

        const vtable = LODMeshResources.VTable{
            .createBuffer = createBuffer,
            .uploadBuffer = uploadBuffer,
            .updateBuffer = updateBuffer,
            .destroyBuffer = destroyBuffer,
            .waitIdle = waitIdle,
        };
    };

    const allocator = std.testing.allocator;
    const len = MAX_STAGING_UPDATE_BYTES + 17;
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memset(data, 0xAB);

    var mock = Mock{};
    try updateBufferChunked(.{ .ptr = &mock, .vtable = &Mock.vtable }, 1, 128, data);

    try std.testing.expectEqual(@as(u32, 2), mock.calls);
    try std.testing.expect(mock.max_len <= MAX_STAGING_UPDATE_BYTES);
    try std.testing.expectEqual(len, mock.total_len);
}

fn testAtlas(allocator: std.mem.Allocator) TextureAtlas {
    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** world_core.MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.dirt)] = .{ .top = 25, .bottom = 25, .side = 26 };
    atlas.tile_mappings[@intFromEnum(BlockType.stone)] = .{ .top = 31, .bottom = 31, .side = 32 };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 51, .bottom = 52, .side = 55 };
    atlas.tile_mappings[@intFromEnum(BlockType.water)] = .{ .top = 41, .bottom = 41, .side = 42 };
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 62, .bottom = 62, .side = 63 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x7FBF5A), .bottom = linearizeTestRgb(0x8A5A35), .side = linearizeTestRgb(0x6A8F42) };
    atlas.tile_colors[@intFromEnum(BlockType.dirt)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x8A5A35));
    atlas.tile_colors[@intFromEnum(BlockType.stone)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x777777));
    atlas.tile_colors[@intFromEnum(BlockType.sand)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0xD8C76D));
    atlas.tile_colors[@intFromEnum(BlockType.water)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x3366CC));
    atlas.tile_colors[@intFromEnum(BlockType.wood)] = .{ .top = linearizeTestRgb(0x7B5A32), .bottom = linearizeTestRgb(0x7B5A32), .side = linearizeTestRgb(0x6B4428) };
    atlas.tile_colors[@intFromEnum(BlockType.leaves)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x4C8F38));
    return atlas;
}

fn fillColumnSpanData(data: *LODSimplifiedData, block: BlockType, height: f32, color: u32) void {
    for (0..data.width * data.width) |i| {
        data.heightmap[i] = height;
        data.biomes[i] = .plains;
        data.top_blocks[i] = block;
        data.colors[i] = color;
        data.material_layers[i] = .{ .surface = block, .subsurface = block, .foundation = block };
        data.lighting[i] = world_core.LODLightingHint.daylight;
    }
}

fn testSpan(min_height: f32, max_height: f32, block: BlockType, color: u32) world_core.LODVerticalSpan {
    return .{
        .min_height = min_height,
        .max_height = max_height,
        .biome = .plains,
        .material_layers = .{ .surface = block, .subsurface = block, .foundation = block },
        .color = color,
        .water = world_core.LODWaterState.empty,
        .lighting = world_core.LODLightingHint.daylight,
        .vegetation = world_core.LODVegetationHint.empty,
    };
}

test "buildFromColumnSpans falls back to heightfield without span data" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);

    var heightfield_mesh = LODMesh.init(allocator, .lod2);
    defer heightfield_mesh.deinit(testResources());
    try heightfield_mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    var span_mesh = LODMesh.init(allocator, .lod2);
    defer span_mesh.deinit(testResources());
    try span_mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const heightfield_verts = heightfield_mesh.pending_vertices orelse return error.TestExpectedEqual;
    const span_verts = span_mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(heightfield_verts.len, span_verts.len);
}

test "buildFromColumnSpans emits side faces for steep span terrain" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .stone, 64.0, 0x808080);
    data.clearVerticalSpans(0, 0);
    data.clearVerticalSpans(1, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(50.0, 96.0, .stone, 0x808080)));
    try std.testing.expect(data.setVerticalSpan(1, 0, 0, testSpan(50.0, 64.0, .stone, 0x808080)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_cliff_side = false;
    for (verts) |v| {
        if (vertexTileId(v) == 32 and v.pos[1] >= 95.0) {
            found_cliff_side = true;
            break;
        }
    }
    try std.testing.expect(found_cliff_side);
}

test "addExposedSpanFace suppresses unknown region border walls" {
    const allocator = std.testing.allocator;

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    defer vertices.deinit(allocator);

    try addExposedSpanFace(
        allocator,
        &vertices,
        &data,
        0,
        0,
        null,
        0,
        .lod2,
        .{ .min_height = 0.0, .max_height = 64.0, .block = .stone, .color = 0x808080, .ambient_occlusion = 1.0 },
        0.0,
        0.0,
        8.0,
        0x808080,
        32,
        .west,
        0,
        0,
    );

    try std.testing.expectEqual(@as(usize, 0), vertices.items.len);
}

test "buildFromColumnSpans adds water as a separate span" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(45.0, 60.0, .sand, 0xD8C76D)));
    // Two wet corners qualify cell (0, 0); the neighboring cell has only one.
    for ([_]usize{ 0, 1 }) |idx| {
        data.water[idx] = .{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 1.0 };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expect(mesh.water_vertex_count > 0);
    try std.testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);
    try std.testing.expectEqual(mesh.opaque_vertex_count * @sizeOf(Vertex), mesh.water_vertex_offset);

    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
    }

    var found_water = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) {
            found_water = true;
            break;
        }
    }
    try std.testing.expect(found_water);
}

test "collectColumnSpans synthesizes local material seafloor under ocean water" {
    const allocator = std.testing.allocator;

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 58.0;
        data.biomes[i] = .ocean;
        data.top_blocks[i] = .water;
        data.colors[i] = 0x3355AA;
        data.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        data.water[i] = .{ .is_surface = true, .surface_height = 64.0, .depth = 6.0, .coverage = 1.0 };
        data.lighting[i] = world_core.LODLightingHint.daylight;
    }

    var spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
    const count = collectColumnSpans(&data, 0, 0, .lod2, &spans);

    var found_seafloor = false;
    var found_water = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (spans[i].block == .sand) {
            found_seafloor = true;
            try std.testing.expectEqual(@as(f32, 50.0), spans[i].min_height);
            try std.testing.expectEqual(@as(f32, 58.0), spans[i].max_height);
            try std.testing.expect(spans[i].color != 0x3355AA);
        }
        if (spans[i].block == .water) found_water = true;
    }

    try std.testing.expect(found_seafloor);
    try std.testing.expect(found_water);
}

test "buildFromSimplifiedData separates heightfield water from opaque terrain" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);

    const water_points = [_]u32{ 0, 1, data.width, data.width + 1 };
    for (water_points) |idx| {
        data.water[idx] = .{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 1.0 };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expect(mesh.water_vertex_count > 0);
    try std.testing.expectEqual(mesh.opaque_vertex_count * @sizeOf(Vertex), mesh.water_vertex_offset);

    var found_seafloor = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
        if (vertexTileId(v) == 51 and v.pos[1] == 60.0) found_seafloor = true;
    }
    try std.testing.expect(found_seafloor);

    var found_water = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) {
            found_water = true;
            break;
        }
    }
    try std.testing.expect(found_water);
}

test "coarse heightfield water ignores isolated deep wet corner" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.water[0] = .{ .is_surface = true, .surface_height = 63.0, .depth = 8.0, .coverage = 1.0 };

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);

    var found_surface_sand = false;
    var found_depressed_sand = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
        if (vertexTileId(v) == 51 and v.pos[1] == 60.0) found_surface_sand = true;
        if (vertexTileId(v) == 51 and v.pos[1] < 60.0) found_depressed_sand = true;
    }

    try std.testing.expect(found_surface_sand);
    try std.testing.expect(!found_depressed_sand);
}

test "coarse span water ignores isolated low-coverage water span" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(45.0, 60.0, .sand, 0xD8C76D)));

    const water_state = world_core.LODWaterState{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 0.2 };
    data.water[0] = water_state;
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, .{
        .min_height = 60.0,
        .max_height = 63.0,
        .biome = .plains,
        .material_layers = .{ .surface = .water, .subsurface = .water, .foundation = .sand },
        .color = 0x3366CC,
        .water = water_state,
        .lighting = world_core.LODLightingHint.daylight,
        .vegetation = world_core.LODVegetationHint.empty,
    }));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
    }
}

test "buildFromColumnSpans skips empty columns while exposing neighbors" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);
    data.clearVerticalSpans(0, 0);
    data.clearVerticalSpans(1, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(50.0, 64.0, .grass, 0x3A7D42)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var side_count: usize = 0;
    for (verts) |v| {
        if (vertexTileId(v) == 24) side_count += 1;
    }
    try std.testing.expect(side_count >= 6);
}

test "buildFromColumnSpans sorts representative spans by height" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .stone, 64.0, 0x808080);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(80.0, 90.0, .stone, 0x808080)));
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, testSpan(40.0, 55.0, .dirt, 0x6B4A2B)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_lower_top = false;
    var found_upper_top = false;
    for (verts) |v| {
        if (vertexTileId(v) == 25 and v.pos[1] == 55.0) found_lower_top = true;
        if (vertexTileId(v) == 31 and v.pos[1] == 90.0) found_upper_top = true;
    }
    try std.testing.expect(found_lower_top);
    try std.testing.expect(found_upper_top);
}

test "buildFromColumnSpans keeps LOD2 canopy spans detached" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x2D591A);

    for (0..data.width * data.width) |i| {
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(0.0, 64.0, .grass, 0x2D591A)));
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, testSpan(66.0, 71.0, .leaves, 0x24941F)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_folded = false;
    var found_detached = false;
    var found_compact_canopy = false;
    for (verts) |v| {
        if (v.pos[1] == 68.0 and vertexTileId(v) == Vertex.LOD_TILE_ID) found_folded = true;
        if (v.pos[1] == 71.0) found_detached = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[0] > 0.0 and v.pos[0] < 4.0) found_compact_canopy = true;
    }
    try std.testing.expect(!found_folded);
    try std.testing.expect(found_detached);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromColumnSpans omits canopy from water cells" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);

    const water_points = [_]u32{ 0, 1, data.width, data.width + 1 };
    for (water_points) |idx| {
        data.water[idx] = .{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 1.0 };
    }
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(0.0, 60.0, .sand, 0xD8C76D)));
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, testSpan(62.0, 68.0, .leaves, 0x24941F)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.water_vertex_count > 0);
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 70);
    }
}

test "buildFromSimplifiedData renders LOD3 tree columns" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 62, .bottom = 62, .side = 63 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x2D591A);
    data.vegetation[0] = .{
        .tree_coverage = 1.0,
        .avg_tree_height = 8.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_trunk_side = false;
    var found_canopy = false;
    var found_compact_canopy = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 63 and v.pos[1] > 64.0) found_trunk_side = true;
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] >= 72.0) found_canopy = true;
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] >= 72.0 and v.pos[0] > 0.0 and v.pos[0] < 8.0) found_compact_canopy = true;
    }

    try std.testing.expect(found_trunk_side);
    try std.testing.expect(found_canopy);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromSimplifiedData uses atlas tiles and world-scaled UVs" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 32, 64, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    try std.testing.expectEqual(@as(u16, 23), vertexTileId(verts[0]));
    try std.testing.expectEqual(@as(f32, 32.0), @as(f32, verts[0].uv[0]));
    try std.testing.expectEqual(@as(f32, 64.0), @as(f32, verts[0].uv[1]));

    var found_top_tile = false;
    var found_side_tile = false;
    for (verts) |v| {
        const tile_id = vertexTileId(v);
        try std.testing.expect(tile_id == 23 or tile_id == 24);
        if (tile_id == 23) found_top_tile = true;
        if (tile_id == 24) found_side_tile = true;
    }
    try std.testing.expect(found_top_tile);
    try std.testing.expect(found_side_tile);
}

test "buildFromSimplifiedData uses texture average for non-tint LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 31, .bottom = 0, .side = 0 };
    atlas.tile_colors[@intFromEnum(BlockType.sand)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0xC2A85E));

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .beach;
        data.top_blocks[i] = .sand;
        data.colors[i] = 0xD8C76D;
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var top_tile_count: usize = 0;
    for (verts) |v| {
        const tile_id = vertexTileId(v);
        try std.testing.expect(tile_id == 31 or tile_id == Vertex.LOD_TILE_ID);
        if (tile_id == 31) {
            top_tile_count += 1;
            try std.testing.expectEqual(linearizeTestRgb(0xC2A85E), vertexRgb(v));
        }
    }
    try std.testing.expect(top_tile_count > 0);
}

test "buildFromSimplifiedData keeps texture averages stable across world origins" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 64.0, 0xD8C76D);

    const expected = linearizeTestRgb(0xD8C76D);
    const origins = [_][2]i32{
        .{ 0, 0 },
        .{ 37, -91 },
        .{ -256, 513 },
        .{ 1024, 33 },
    };

    for (origins) |origin| {
        var mesh = LODMesh.init(allocator, .lod2);
        defer mesh.deinit(testResources());

        try mesh.buildFromSimplifiedData(&data, origin[0], origin[1], &atlas);

        const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
        var checked_top = false;
        for (verts) |v| {
            if (vertexTileId(v) == 51) {
                checked_top = true;
                try std.testing.expectEqual(expected, vertexRgb(v));
            }
        }
        try std.testing.expect(checked_top);
    }
}

test "buildFromSimplifiedData falls back to LOD tile for unmapped top blocks" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    for (verts) |v| try std.testing.expectEqual(@as(u16, Vertex.LOD_TILE_ID), vertexTileId(v));
}

test "buildFromSimplifiedData separates sufficiently covered mixed water cells from seafloor" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.water)] = .{ .top = 41, .bottom = 41, .side = 42 };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 51, .bottom = 52, .side = 55 };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 63.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }
    // Half of the first coarse cell is wet. A single wet corner must not flood it.
    for ([_]usize{ 0, 1 }) |idx| {
        data.heightmap[idx] = 55.0;
        data.top_blocks[idx] = .water;
        data.water[idx] = .{
            .is_surface = true,
            .surface_height = 63.0,
            .depth = 8.0,
            .coverage = 1.0,
        };
        data.material_layers[idx] = .{
            .surface = .water,
            .subsurface = .sand,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var found_seafloor_top = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 51 and v.pos[1] == 55.0) found_seafloor_top = true;
        try std.testing.expect(vertexTileId(v) != 41);
    }
    try std.testing.expect(found_seafloor_top);
    try std.testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);

    var found_water_top = false;
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) found_water_top = true;
    }
    try std.testing.expect(found_water_top);

    var found_floor_side = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 55) {
            found_floor_side = true;
            break;
        }
    }
    try std.testing.expect(found_floor_side);
}

test "blockForLODQuad uses representative non-water surface" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    data.material_layers[1].surface = .stone;
    data.material_layers[data.width].surface = .stone;
    data.material_layers[data.width + 1].surface = .stone;

    try std.testing.expectEqual(BlockType.stone, blockForLODQuad(&data, 0, 0));
}

test "coarse cell terrain height uses source sample instead of corner mean" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 96.0;
    }
    data.setHeight(0, 0, 64.0);

    try std.testing.expectEqual(@as(f32, 64.0), quantizedCellTerrainHeight(&data, 0, 0));
    try std.testing.expectEqual(@as(f32, 64.0), quantizedCellSurfaceHeight(&data, 0, 0));
}

test "LOD boundary height retains its authoritative source sample" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| data.heightmap[i] = 10.0;
    data.setHeight(0, 1, 100.0);

    try std.testing.expectEqual(@as(f32, 100.0), quantizedCellSurfaceHeight(&data, 0, 1));
}

test "representativeVegetationForLOD aggregates sparse coarse coverage" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    data.vegetation[0] = .{
        .tree_coverage = 0.1,
        .avg_tree_height = 7.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    const vegetation = representativeVegetationForLOD(&data, 0, 0, .lod2);
    try std.testing.expectEqual(@as(f32, 0.025), vegetation.tree_coverage);
    try std.testing.expect(vegetation.avg_tree_height >= 7.0);
}

test "representativeVegetationForLOD suppresses subpixel horizon foliage" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod4);
    defer data.deinit();
    data.vegetation[0] = .{ .tree_coverage = 0.1, .avg_tree_height = 8.0, .offset_x = 0.0, .offset_z = 0.0, .trunk = .wood, .leaves = .leaves };

    const vegetation = representativeVegetationForLOD(&data, 0, 0, .lod4);
    try std.testing.expectEqual(@as(f32, 0.0), vegetation.tree_coverage);
    try std.testing.expectEqual(BlockType.air, vegetation.leaves);
}

test "buildFromSimplifiedData retains atlas material with averaged color for far LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x3A7D42;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);
    // Terrain retains its atlas material; the draw mask selects color-only LOD shading.
    try std.testing.expectEqual(@as(u16, 23), vertexTileId(verts[0]));
    // Linear atlas (55, 134, 30) * packed plains tint (56, 184, 41) / 255.
    try std.testing.expectEqual(@as(u32, 0x0C6105), vertexRgb(verts[0]));
}

test "CompactLODTile preserves source RGB channel order for expanded vertex parity" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    const cases = [_]struct { source: u32, rgb: u32, channels: [3]f32 }{
        .{ .source = 0xFF0000, .rgb = 0xFF0000, .channels = .{ 1.0, 0.0, 0.0 } },
        .{ .source = 0x0000FF, .rgb = 0x0000FF, .channels = .{ 0.0, 0.0, 1.0 } },
        .{ .source = 0xA5123456, .rgb = 0x123456, .channels = .{ 18.0 / 255.0, 52.0 / 255.0, 86.0 / 255.0 } },
    };
    for (cases, 0..) |case, i| data.colors[i] = case.source;

    var tile = try @import("lod_tile.zig").CompactLODTile.initFromSimplified(allocator, .lod3, &data);
    defer tile.deinit();
    for (cases, 0..) |case, i| {
        const sample = tile.sample(@intCast(i), 0) orelse return error.TestExpectedEqual;
        // GLSL's third uvec4 lane holds source RGB at bits 5..28, not Vertex ABGR.
        const word = std.mem.readInt(u32, sample.bytes[8..12], .little);
        try std.testing.expectEqual(case.rgb, (word >> 5) & 0xFFFFFF);
        const color = sample.decode().color;
        const channels = [3]f32{ geom.unpackR(color), geom.unpackG(color), geom.unpackB(color) };
        try std.testing.expectEqualDeep(case.channels, channels);
        const vertex = makeLODVertex(.{ 0, 0, 0 }, channels, .{ 0, 1, 0 }, .{ 0, 0 }, Vertex.LOD_TILE_ID);
        try std.testing.expectEqual(case.rgb, vertexRgb(vertex));
    }
}

test "applyTextureLuminance preserves tint magnitude including black and neutral tints" {
    var atlas = testAtlas(std.testing.allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = TextureAtlas.BlockTileColor.uniform(0x804020);

    // Expected channels are round(atlas_byte * tint_byte / 255), independently
    // of biome selection, sRGB conversion, or the production multiply helper.
    const cases = [_]struct { tint: u32, expected: u32 }{
        .{ .tint = 0x000000, .expected = 0x000000 },
        .{ .tint = 0x808080, .expected = 0x402010 },
        .{ .tint = 0x808078, .expected = 0x40200F },
        .{ .tint = 0x4080C0, .expected = 0x202018 },
        .{ .tint = 0xFFFFFF, .expected = 0x804020 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, applyTextureLuminance(case.tint, .grass, .top, &atlas));
    }
}

test "applyTextureLuminance leaves untinted atlas faces and water unchanged" {
    var atlas = testAtlas(std.testing.allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = 0x804020, .side = 0x123456, .bottom = 0x654321 };
    atlas.tile_colors[@intFromEnum(BlockType.stone)] = TextureAtlas.BlockTileColor.uniform(0x2468AC);
    atlas.tile_colors[@intFromEnum(BlockType.water)] = TextureAtlas.BlockTileColor.uniform(0x804020);

    try std.testing.expectEqual(@as(u32, 0x123456), applyTextureLuminance(0x4080C0, .grass, .side, &atlas));
    try std.testing.expectEqual(@as(u32, 0x654321), applyTextureLuminance(0x4080C0, .grass, .bottom, &atlas));
    for ([_]LODTextureFace{ .top, .side, .bottom }) |face| {
        try std.testing.expectEqual(@as(u32, 0x2468AC), applyTextureLuminance(0x4080C0, .stone, face, &atlas));
        try std.testing.expectEqual(@as(u32, 0x4080C0), applyTextureLuminance(0x4080C0, .water, face, &atlas));
    }
}

test "buildFromSimplifiedData tints atlas average for grass tops" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x3A7D42;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    // round((55, 134, 30) * (56, 184, 41) / 255), without tint normalization.
    try std.testing.expectEqual(@as(u32, 0x0C6105), vertexRgb(verts[0]));
}

test "buildFromSimplifiedData uses chunk grass tint for grass tops" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0xFFFFFF;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    // Chunk plains grass is (0.22, 0.72, 0.16), packed as (56, 184, 41).
    // Linear atlas (55, 134, 30) times that tint rounds to (12, 97, 5).
    try std.testing.expectEqual(@as(u32, 0x0C6105), vertexRgb(verts[0]));
}

test "addTreeCanopyColumn uses chunk foliage tint" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.leaves)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x4C8F38));

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
    }

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    defer vertices.deinit(allocator);
    const vegetation: world_core.LODVegetationHint = .{
        .tree_coverage = 0.35,
        .avg_tree_height = 8.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    try addTreeCanopyColumn(allocator, &vertices, &data, 0, 0, .lod2, 0.0, 0.0, 8.0, 64.0, 67.0, 72.0, vegetation, &atlas, 0, 0);

    try std.testing.expect(vertices.items.len >= 6);
    // Chunk forest foliage (0.12, 0.52, 0.12) packs to (31, 133, 31).
    // Linear atlas (18, 70, 10) times that tint rounds to (2, 37, 1).
    for (vertices.items[0..6]) |v| {
        try std.testing.expectEqual(@as(u32, 0x022501), vertexRgb(v));
    }
}

test "buildFromSimplifiedData uses single source sample for fine LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 96.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0xFFFFFF;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }
    data.heightmap[0] = 64.0;
    data.colors[0] = 0x123456;

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);
    try std.testing.expectEqual(@as(f32, 64.0), verts[0].pos[1]);
    // The white atlas preserves the packed chunk plains grass tint.
    try std.testing.expectEqual(@as(u32, 0x38B829), vertexRgb(verts[0]));
}

test "buildFromSimplifiedData keeps mixed water cells on one flat surface" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 58.0;
        data.biomes[i] = .ocean;
        data.top_blocks[i] = .sand;
        data.colors[i] = 0x3355AA;
        data.material_layers[i] = .{ .surface = .sand, .subsurface = .sand, .foundation = .stone };
        data.water[i] = .{ .is_surface = true, .surface_height = 63.0, .depth = 5.0, .coverage = 1.0 };
    }
    data.water[0].surface_height = 62.0;
    data.water[1].surface_height = 64.0;
    data.water[data.width].surface_height = 63.0;
    data.water[data.width + 1].surface_height = 63.0;

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    try std.testing.expect(water_start < verts.len);
    for (verts[water_start .. water_start + 6]) |v| {
        try std.testing.expectEqual(@as(f32, 64.0), v.pos[1]);
    }
}

test "adjacent ocean regions normalize water tops to shared sea level" {
    const allocator = std.testing.allocator;

    var left = try LODSimplifiedData.init(allocator, .lod2);
    defer left.deinit();
    var right = try LODSimplifiedData.init(allocator, .lod2);
    defer right.deinit();

    for (0..left.width * left.width) |i| {
        left.heightmap[i] = 58.0;
        left.biomes[i] = .ocean;
        left.top_blocks[i] = .water;
        left.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        left.water[i] = .{ .is_surface = true, .surface_height = 62.0, .depth = 4.0, .coverage = 1.0 };

        right.heightmap[i] = 58.0;
        right.biomes[i] = .ocean;
        right.top_blocks[i] = .water;
        right.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        right.water[i] = .{ .is_surface = true, .surface_height = 63.0, .depth = 5.0, .coverage = 1.0 };
    }

    try std.testing.expectEqual(@as(f32, 64.0), quantizedWaterSurfaceHeightForCell(&left, left.width - 2, 0, .lod2));
    try std.testing.expectEqual(@as(f32, 64.0), quantizedWaterSurfaceHeightForCell(&right, 0, 0, .lod2));
}

test "buildFromSimplifiedData renders voxel tree columns for fine vegetation hints" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 71, .bottom = 71, .side = 72 };

    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x2D591A;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_leaf_column_top = false;
    for (verts) |v| {
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] == 71.0 and vertexRgb(v) != 0xFFFFFF) {
            found_leaf_column_top = true;
            break;
        }
    }
    try std.testing.expect(found_leaf_column_top);
}

test "buildFromSimplifiedData renders far vegetation as separate tree silhouettes" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.init(allocator, .lod4);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x2D591A;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }

    var mesh = LODMesh.init(allocator, .lod4);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_ground_top = false;
    var found_canopy_top = false;
    var found_compact_canopy = false;
    // Linear grass atlas (54, 133, 26) * forest grass tint (46, 163, 41) / 255.
    // Linear leaf atlas (18, 70, 10) * forest foliage tint (31, 133, 31) / 255.
    for (verts) |v| {
        if (v.pos[1] == 64.0 and vertexTileId(v) == 23 and vertexRgb(v) == 0x0A5504) found_ground_top = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and vertexRgb(v) == 0x022501) found_canopy_top = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[0] > 0.0 and v.pos[0] < 8.0) found_compact_canopy = true;
    }
    try std.testing.expect(found_ground_top);
    try std.testing.expect(found_canopy_top);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromSimplifiedData adds internal faces for steep LOD height deltas" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.stone)] = .{ .top = 11, .bottom = 12, .side = 13 };

    var flat_data = try LODSimplifiedData.init(allocator, .lod3);
    defer flat_data.deinit();
    var cliff_data = try LODSimplifiedData.init(allocator, .lod3);
    defer cliff_data.deinit();

    for (0..flat_data.width * flat_data.width) |i| {
        flat_data.heightmap[i] = 64.0;
        flat_data.biomes[i] = .mountains;
        flat_data.top_blocks[i] = .stone;
        flat_data.colors[i] = 0x808080;
        flat_data.material_layers[i] = .{
            .surface = .stone,
            .subsurface = .stone,
            .foundation = .stone,
        };
        cliff_data.heightmap[i] = flat_data.heightmap[i];
        cliff_data.biomes[i] = flat_data.biomes[i];
        cliff_data.top_blocks[i] = flat_data.top_blocks[i];
        cliff_data.colors[i] = flat_data.colors[i];
        cliff_data.material_layers[i] = flat_data.material_layers[i];
    }

    cliff_data.setHeight(15, 15, 96.0);
    cliff_data.setHeight(16, 15, 96.0);
    cliff_data.setHeight(15, 16, 96.0);
    cliff_data.setHeight(16, 16, 96.0);

    var flat_mesh = LODMesh.init(allocator, .lod3);
    defer flat_mesh.deinit(testResources());
    try flat_mesh.buildFromSimplifiedData(&flat_data, 0, 0, &atlas);
    const flat_verts = flat_mesh.pending_vertices orelse return error.TestExpectedEqual;

    var cliff_mesh = LODMesh.init(allocator, .lod3);
    defer cliff_mesh.deinit(testResources());
    try cliff_mesh.buildFromSimplifiedData(&cliff_data, 0, 0, &atlas);
    const cliff_verts = cliff_mesh.pending_vertices orelse return error.TestExpectedEqual;

    try std.testing.expect(cliff_verts.len > flat_verts.len);
}

test "buildFromHeightmap uses biome atlas tiles" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    const width: u32 = 4;
    const count = width * width;
    const heightmap = [_]f32{64.0} ** count;
    const biomes = [_]BiomeId{.plains} ** count;

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromHeightmap(&heightmap, &biomes, width, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var found_top_tile = false;
    for (verts) |v| {
        if (vertexTileId(v) == 23) {
            found_top_tile = true;
            break;
        }
    }
    try std.testing.expect(found_top_tile);
}
