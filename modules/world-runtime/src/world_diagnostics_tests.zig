const std = @import("std");
const testing = std.testing;

const diagnostics_mod = @import("world_diagnostics.zig");
const world_core = @import("world-core");
const world_meshing = @import("world-meshing");

fn makeChunkData(allocator: std.mem.Allocator, cx: i32, cz: i32) world_meshing.ChunkData {
    // These diagnostics tests never allocate mesh-owned buffers. Some tests set
    // fake allocation metadata only, so calling ChunkMesh.deinit would require a
    // real GlobalVertexAllocator for buffers that do not exist.
    return .{
        .chunk = world_core.Chunk.init(cx, cz),
        .render = .{ .mesh = world_meshing.ChunkMesh.init(allocator) },
    };
}

fn deinitChunkData(data: *world_meshing.ChunkData) void {
    data.render.mesh.deinitWithoutRHI();
}

fn mockRegionGetenv(name: [:0]const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ZIGCRAFT_DIAGNOSE_REGION")) return "-3,-2,4,5";
    return null;
}

fn mockEmptyGetenv(name: [:0]const u8) ?[]const u8 {
    _ = name;
    return null;
}

test "CpuCullDiagnostics starts with zero counters" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    try testing.expectEqual(@as(u32, 0), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 0), diagnostics.not_in_storage);
    try testing.expectEqual(@as(u32, 0), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(u32, 0), diagnostics.frustum_culled);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_zero_verts);
}

test "CpuCullDiagnostics initFromEnv reads diagnose region" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics.initFromEnv(mockRegionGetenv);

    try testing.expect(diagnostics.diag_region_enabled);
    try testing.expectEqual(@as(i32, -3), diagnostics.diag_min_x);
    try testing.expectEqual(@as(i32, -2), diagnostics.diag_min_z);
    try testing.expectEqual(@as(i32, 4), diagnostics.diag_max_x);
    try testing.expectEqual(@as(i32, 5), diagnostics.diag_max_z);
}

test "CpuCullDiagnostics initFromEnv stays disabled without diagnose region" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics.initFromEnv(mockEmptyGetenv);

    try testing.expect(!diagnostics.diag_region_enabled);
}

test "CpuCullDiagnostics applyRegionString enables region diagnostics" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.applyRegionString("-4,2,8,16");

    try testing.expect(diagnostics.diag_region_enabled);
    try testing.expectEqual(@as(i32, -4), diagnostics.diag_min_x);
    try testing.expectEqual(@as(i32, 2), diagnostics.diag_min_z);
    try testing.expectEqual(@as(i32, 8), diagnostics.diag_max_x);
    try testing.expectEqual(@as(i32, 16), diagnostics.diag_max_z);
}

test "CpuCullDiagnostics applyRegionString defaults invalid coordinates to zero" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.applyRegionString("bad,1,nope,3");

    try testing.expect(diagnostics.diag_region_enabled);
    try testing.expectEqual(@as(i32, 0), diagnostics.diag_min_x);
    try testing.expectEqual(@as(i32, 1), diagnostics.diag_min_z);
    try testing.expectEqual(@as(i32, 0), diagnostics.diag_max_x);
    try testing.expectEqual(@as(i32, 3), diagnostics.diag_max_z);
}

test "CpuCullDiagnostics applyRegionString handles partial coordinates" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.applyRegionString("5,6");

    try testing.expect(diagnostics.diag_region_enabled);
    try testing.expectEqual(@as(i32, 5), diagnostics.diag_min_x);
    try testing.expectEqual(@as(i32, 6), diagnostics.diag_min_z);
    try testing.expectEqual(@as(i32, 0), diagnostics.diag_max_x);
    try testing.expectEqual(@as(i32, 0), diagnostics.diag_max_z);
}

test "recordFrustumCulled increments frustum counter" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordFrustumCulled();
    diagnostics.recordFrustumCulled();

    try testing.expectEqual(@as(u32, 2), diagnostics.frustum_culled);
}

test "recordNotRenderable tracks missing chunks inside render circle" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotRenderable(3, 4, 25, 5);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 1), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(i32, 3), diagnostics.missing_cx);
    try testing.expectEqual(@as(i32, 4), diagnostics.missing_cz);
}

test "recordNotRenderable ignores missing chunks outside render circle" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotRenderable(6, 0, 36, 5);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 0), diagnostics.missing_in_circle);
}

test "recordNotInStorage tracks storage misses independently" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotInStorage(-2, 1, 5, 3);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_in_storage);
    try testing.expectEqual(@as(u32, 1), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(i32, -2), diagnostics.missing_cx);
    try testing.expectEqual(@as(i32, 1), diagnostics.missing_cz);
}

test "recordVisible records first visible chunk without mesh" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 7, -3);
    defer deinitChunkData(&data);

    diagnostics.recordVisible(7, -3, &data);
    diagnostics.recordVisible(8, -4, &data);

    try testing.expectEqual(@as(u32, 2), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(i32, 7), diagnostics.first_no_mesh_cx);
    try testing.expectEqual(@as(i32, -3), diagnostics.first_no_mesh_cz);
}

test "recordVisible records first allocated mesh with zero vertices" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 0, 0);
    defer deinitChunkData(&data);
    data.render.mesh.solid_allocation = .{ .offset = 0, .count = 0, .handle = 1 };

    diagnostics.recordVisible(11, 12, &data);

    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 1), diagnostics.visible_zero_verts);
    try testing.expectEqual(@as(i32, 11), diagnostics.first_zero_verts_cx);
    try testing.expectEqual(@as(i32, 12), diagnostics.first_zero_verts_cz);
}

test "recordVisible does not flag chunks with vertices" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 0, 0);
    defer deinitChunkData(&data);
    data.render.mesh.solid_allocation = .{ .offset = 0, .count = 12, .handle = 1 };

    diagnostics.recordVisible(1, 2, &data);

    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_zero_verts);
}

test "frameSummary computes logged CPU cull totals" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics{
        .visible_no_mesh = 2,
        .visible_zero_verts = 1,
        .frustum_culled = 3,
        .not_renderable = 4,
        .not_in_storage = 5,
        .missing_in_circle = 6,
    };

    const summary = diagnostics.frameSummary(9);

    try testing.expectEqual(@as(usize, 9), summary.visible_count);
    try testing.expectEqual(@as(usize, 7), summary.with_mesh);
    try testing.expectEqual(@as(u32, 2), summary.no_mesh);
    try testing.expectEqual(@as(u32, 1), summary.zero_verts);
    try testing.expectEqual(@as(u32, 3), summary.frustum_culled);
    try testing.expectEqual(@as(u32, 4), summary.not_renderable);
    try testing.expectEqual(@as(u32, 5), summary.not_in_storage);
    try testing.expectEqual(@as(u32, 6), summary.missing_in_circle);
}

test "collectBoundarySummary reports renderable stored and missing boundary chunks" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var storage = world_meshing.ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    var missing_text: [256]u8 = undefined;

    const renderable = try storage.getOrCreate(1, 0);
    renderable.render.mesh.solid_allocation = .{ .offset = 0, .count = 24, .handle = 1 };
    const no_mesh = try storage.getOrCreate(0, 1);
    no_mesh.render.mesh.ready = false;

    const summary = diagnostics.collectBoundarySummary(&storage, 0, 0, 1, &missing_text);

    try testing.expectEqual(@as(u32, 1), summary.renderable);
    try testing.expectEqual(@as(u32, 4), summary.missing);
    try testing.expect(std.mem.indexOf(u8, summary.missing_text, "(0,-1)!") != null);
    try testing.expect(std.mem.indexOf(u8, summary.missing_text, "(-1,0)!") != null);
    try testing.expect(std.mem.indexOf(u8, summary.missing_text, "(0,0)!") != null);
    try testing.expect(std.mem.indexOf(u8, summary.missing_text, "(0,1) ") != null);
}

test "logFrame handles periodic summary with empty storage" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{
        .visible_no_mesh = 1,
        .visible_zero_verts = 1,
        .frustum_culled = 2,
        .not_renderable = 3,
        .not_in_storage = 4,
    };
    var storage = world_meshing.ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    diagnostics.logFrame(&storage, 2, 0, 0, 1, 300, 0);
}

test "logFrame handles missing chunk detail with and without storage entry" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{
        .missing_in_circle = 1,
        .missing_cx = 1,
        .missing_cz = 0,
    };
    var storage = world_meshing.ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    diagnostics.logFrame(&storage, 0, 0, 0, 1, 60, 0);

    const stored = try storage.getOrCreate(1, 0);
    stored.chunk.state = .renderable;
    stored.render.mesh.solid_allocation = .{ .offset = 0, .count = 12, .handle = 1 };

    diagnostics.logFrame(&storage, 1, 0, 0, 1, 60, 0);
}

test "logFrame boundary traversal handles mixed stored and missing chunks" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var storage = world_meshing.ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const renderable = try storage.getOrCreate(1, 0);
    renderable.render.mesh.solid_allocation = .{ .offset = 0, .count = 24, .handle = 1 };
    const no_mesh = try storage.getOrCreate(0, 1);
    no_mesh.render.mesh.ready = false;

    diagnostics.logFrame(&storage, 2, 0, 0, 1, 300, 0);
}
