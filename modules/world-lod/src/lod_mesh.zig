//! LOD Mesh generation for distant terrain rendering.
//!
//! LOD meshes are simplified versions of chunk meshes. Region size, grid
//! detail, and span-vs-heightfield behavior are selected by runtime settings.
//!
//! Key simplifications:
//! - No greedy meshing (simple quads per grid cell)
//! - No lighting calculations
//! - Fluid vertices are split into a separate water range for WaterPass
//! - Biome colors averaged per cell

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const world_core = @import("world-core");
const BiomeId = world_core.BiomeId;
const biome_mod = @import("biome_color_provider.zig");
const BlockType = world_core.BlockType;
const SceneGrid = world_core.lod_scene.SceneGrid;
const SceneSpan = world_core.lod_scene.SceneSpan;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const RhiError = rhi_types.RhiError;
const QuadricSimplifier = @import("world-meshing").meshing.quadric_simplifier.QuadricSimplifier;
const log = @import("engine-core").log;

test {
    _ = @import("lod_scene_mesh_tests.zig");
}

/// Chunk-derived and edited source columns can contain cave and overhang spans
/// surrounded by worldgen-only samples. Rendering those partial underground
/// intervals at a streaming boundary exposes a giant terrain cross-section.
/// Their authoritative surface height remains safe for the heightfield path.
pub fn canBuildColumnSpans(data: *const LODSimplifiedData) bool {
    return data.hasVerticalSpans() and !data.hasNonWorldgenColumns();
}

test "setPendingFromIndexed resets stale LOD draw ranges" {
    var mesh = LODMesh.init(std.testing.allocator, .lod2);
    defer if (mesh.pending_vertices) |pending| std.testing.allocator.free(pending);
    mesh.opaque_vertex_count = 24;
    mesh.water_vertex_offset = 24 * @sizeOf(Vertex);
    mesh.water_vertex_count = 6;
    const source = [_]Vertex{
        geom.makeLODVertex(.{ 0, 1, 0 }, .{ 1, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0 }, Vertex.LOD_TILE_ID),
        geom.makeLODVertex(.{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 0, 1, 0 }, .{ 1, 0 }, Vertex.LOD_TILE_ID),
        geom.makeLODVertex(.{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 1 }, Vertex.LOD_TILE_ID),
    };
    try mesh.setPendingFromIndexed(&source, &.{ 0, 1, 2 });
    try std.testing.expectEqualSlices(Vertex, &source, mesh.pending_vertices.?);
    try std.testing.expectEqual(@as(u32, 3), mesh.opaque_vertex_count);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(Vertex)), mesh.water_vertex_offset);
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
}

/// Only the near one-block source contract carries measured vegetation envelopes.
fn isNearSourceGrid(data: *const LODSimplifiedData, lod: LODLevel) bool {
    return (lod == .lod0 or lod == .lod1) and
        data.width == lod_chunk.regionSizeBlocks(lod) + 1 and data.hasVerticalSpans();
}

fn isNearVegetation(block: BlockType) bool {
    return isLeafBlock(block) or switch (block) {
        .wood,
        .mangrove_log,
        .jungle_log,
        .acacia_log,
        .birch_log,
        .spruce_log,
        .mangrove_roots,
        .mushroom_stem,
        .red_mushroom_block,
        .brown_mushroom_block,
        => true,
        else => false,
    };
}

const NearColumnSpan = struct {
    min_height: f32,
    max_height: f32,
    block: BlockType,
    color: u32,
    lighting: world_core.LODLightingHint,
};

/// Ignore underground source intervals: terrain remains a scalar heightfield.
fn collectNearSolidSpans(data: *const LODSimplifiedData, gx: u32, gz: u32, out: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]NearColumnSpan) usize {
    const idx = gx + gz * data.width;
    var count: usize = 0;
    const ground = data.material_layers[idx].surface;
    if (ground != .air) {
        out[count] = .{
            .min_height = 0,
            .max_height = data.heightmap[idx],
            .block = ground,
            .color = data.colors[idx],
            .lighting = data.lighting[idx],
        };
        count += 1;
    }
    var i: u8 = 0;
    while (i < data.verticalSpanCount(gx, gz)) : (i += 1) {
        const raw = data.getVerticalSpan(gx, gz, i) orelse continue;
        const block = geom.representativeSpanBlock(raw.material_layers);
        if (!isNearVegetation(block) or raw.max_height <= raw.min_height) continue;
        out[count] = .{
            .min_height = raw.min_height,
            .max_height = raw.max_height,
            .block = block,
            .color = raw.color,
            .lighting = raw.lighting,
        };
        count += 1;
    }
    return count;
}

fn applyNearLighting(vertices: []Vertex, lighting: world_core.LODLightingHint) void {
    const skylight = @as(f32, @floatFromInt(lighting.sky_light)) / 15.0;
    // The source hint retains intensity only, not RGB block-light channels.
    const blocklight = @as(f32, @floatFromInt(lighting.block_light)) / 15.0;
    const packed_blocklight = rhi_types.encodeBlocklight(.{ blocklight, blocklight, blocklight }, false);
    for (vertices) |*vertex| {
        vertex.packed_meta = rhi_types.encodeMeta(@truncate(vertex.packed_meta), skylight, lighting.ambient_occlusion);
        vertex.blocklight = packed_blocklight;
    }
}
const lod_seam = @import("lod_seam.zig");
const resources_mod = @import("lod_mesh_resources.zig");
const geom = @import("lod_geometry.zig");
const CompactLODTile = @import("lod_tile.zig").CompactLODTile;
const CompactTileEdge = @import("lod_tile.zig").TileEdge;

pub const EdgeDir = lod_seam.EdgeDir;
pub const SeamConfig = lod_seam.SeamConfig;
pub const stitchEdge = lod_seam.stitchEdge;
pub const LODMeshResources = resources_mod.LODMeshResources;
pub const LODMeshRenderContext = resources_mod.LODMeshRenderContext;
pub const MAX_STAGING_UPDATE_BYTES = resources_mod.MAX_STAGING_UPDATE_BYTES;
pub const updateBufferChunked = resources_mod.updateBufferChunked;
pub const uploadBufferChunked = resources_mod.uploadBufferChunked;
const LODRenderLayer = @import("lod_upload_queue.zig").LODRenderLayer;

const FullDetailMesh = geom.FullDetailMesh;
const buildFullDetailHeightmapMesh = geom.buildFullDetailHeightmapMesh;
const addTopFaceQuad = geom.addTopFaceQuad;
const addBottomFaceQuad = geom.addBottomFaceQuad;
const addSideFaceQuad = geom.addSideFaceQuad;
const addSteppedHeightfieldSides = geom.addSteppedHeightfieldSides;
const addExposedSpanFaces = geom.addExposedSpanFaces;
const addTreeColumn = geom.addTreeColumn;
const addTreeCanopyColumn = geom.addTreeCanopyColumn;
const averageColor = geom.averageColor;
const ambientOcclusionForLOD = geom.ambientOcclusionForLOD;
const applyColorBrightness = geom.applyColorBrightness;
const applyTextureLuminance = geom.applyTextureLuminance;
const blockForLODQuad = geom.blockForLODQuad;
const cellColorForLOD = geom.cellColorForLOD;
const collectColumnSpans = geom.collectColumnSpans;
const foldedCanopyColumnForLOD = geom.foldedCanopyColumnForLOD;
const getLodSideTile = geom.getLodSideTile;
const getLodTopColor = geom.getLodTopColor;
const getLodTopTile = geom.getLodTopTile;
const isLeafBlock = geom.isLeafBlock;
const isLODWaterCellForLOD = geom.isLODWaterCellForLOD;
const LODColumnSpan = geom.LODColumnSpan;
const LOD_TREE_COVERAGE_THRESHOLD = geom.LOD_TREE_COVERAGE_THRESHOLD;
const packBlockDefaultColor = geom.packBlockDefaultColor;
const quantizedCellVisualTerrainHeightForLOD = geom.quantizedCellVisualTerrainHeightForLOD;
const quantizedWaterSurfaceHeightForCell = geom.quantizedWaterSurfaceHeightForCell;
const quantizedWaterSurfaceHeightForSpan = geom.quantizedWaterSurfaceHeightForSpan;
const representativeVegetationForLOD = geom.representativeVegetationForLOD;
const selectCellMaterial = geom.selectCellMaterial;
const shouldRenderLODTree = geom.shouldRenderLODTree;
const terrainBlockForLODQuadForLOD = geom.terrainBlockForLODQuadForLOD;
const tintColorForLodFace = geom.tintColorForLodFace;
const unpackB = geom.unpackB;
const unpackG = geom.unpackG;
const unpackR = geom.unpackR;

const SceneBox = struct {
    min: [3]f32,
    max: [3]f32,

    fn fromSpan(span: SceneSpan, gx: i32, gz: i32, cell_size: u32) SceneBox {
        const size: f32 = @floatFromInt(cell_size);
        const extent = @sqrt(span.coverage);
        const x = (@as(f32, @floatFromInt(gx)) + std.math.clamp(span.center_x - extent * 0.5, 0, 1 - extent)) * size;
        const z = (@as(f32, @floatFromInt(gz)) + std.math.clamp(span.center_z - extent * 0.5, 0, 1 - extent)) * size;
        // Clamped faces share the exact coarse-cell edge, including fractional
        // coverage whose square root cannot be represented exactly.
        const max_x = if (span.center_x + extent * 0.5 >= 1) @as(f32, @floatFromInt(gx + 1)) * size else x + extent * size;
        const max_z = if (span.center_z + extent * 0.5 >= 1) @as(f32, @floatFromInt(gz + 1)) * size else z + extent * size;
        return .{ .min = .{ x, span.min_y, z }, .max = .{ max_x, span.max_y, max_z } };
    }
};

fn scenePlantHeight(block: BlockType) ?f32 {
    return switch (world_core.getBlockDefinition(block).render_shape) {
        .cross => 1,
        .tall_cross => 2,
        else => null,
    };
}

/// `terrain.frag` reconstructs detailed LOD atlas color by dividing `vColor`
/// by the tile average. Keep that average in the vertex albedo so the detailed
/// path resolves to the same texture * default-color * biome-tint as CPU mesh.
fn scenePlantColor(span: SceneSpan, atlas: *const TextureAtlas) [3]f32 {
    const definition = world_core.getBlockDefinition(span.block);
    const tint = if (definition.is_tintable) biome_mod.getBiomeColors(span.biome).grass else [3]f32{ 1, 1, 1 };
    const source = [3]f32{
        definition.default_color[0] * tint[0],
        definition.default_color[1] * tint[1],
        definition.default_color[2] * tint[2],
    };
    if (geom.averageTextureColorForFace(span.block, .side, atlas)) |average| {
        return .{ source[0] * unpackR(average), source[1] * unpackG(average), source[2] * unpackB(average) };
    }
    const factor = std.math.clamp(atlas.getLuminanceForBlock(@intFromEnum(span.block)).side, 0.18, 1.0);
    return .{ source[0] * factor, source[1] * factor, source[2] * factor };
}

/// Mirrors the full-detail cross mesh: one cull-none diagonal quad per plane.
/// The projection emits one coarse representative per Y band; exact RLE spans
/// retain one root per source Y. Both use a bounded footprint, never a billboard
/// widened to the whole grass-covered cell.
fn appendScenePlantRoots(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), span: SceneSpan, gx: i32, gz: i32, cell_size: u32, atlas: *const TextureAtlas) !void {
    const height = scenePlantHeight(span.block) orelse return;
    const cell: f32 = @floatFromInt(cell_size);
    const footprint = @min(cell, 1);
    const center_x = (@as(f32, @floatFromInt(gx)) + span.center_x) * cell;
    const center_z = (@as(f32, @floatFromInt(gz)) + span.center_z) * cell;
    const min_x = std.math.clamp(center_x - footprint * 0.5, @as(f32, @floatFromInt(gx)) * cell, @as(f32, @floatFromInt(gx + 1)) * cell - footprint);
    const min_z = std.math.clamp(center_z - footprint * 0.5, @as(f32, @floatFromInt(gz)) * cell, @as(f32, @floatFromInt(gz + 1)) * cell - footprint);
    const color = scenePlantColor(span, atlas);
    const light = sceneLightChannels(span.light);
    const tile: u16 = @intCast(atlas.getTilesForBlock(@intFromEnum(span.block)).side);
    const first_y: u16 = @intFromFloat(span.min_y);
    const past_last_y: u16 = @intFromFloat(span.max_y);
    var root_y = first_y;
    while (root_y < past_last_y) : (root_y += 1) {
        const y: f32 = @floatFromInt(root_y);
        const planes = [_][2][3]f32{
            .{ .{ min_x, y, min_z }, .{ min_x + footprint, y + height, min_z + footprint } },
            .{ .{ min_x + footprint, y, min_z }, .{ min_x, y + height, min_z + footprint } },
        };
        for (planes) |plane| {
            const p0 = plane[0];
            const p1 = plane[1];
            const dx = p1[0] - p0[0];
            const dz = p1[2] - p0[2];
            const length = @sqrt(dx * dx + dz * dz);
            const normal = [3]f32{ -dz / length, 0, dx / length };
            const quad = [_][3]f32{
                .{ p0[0], p0[1], p0[2] },
                .{ p1[0], p0[1], p1[2] },
                .{ p1[0], p1[1], p1[2] },
                .{ p0[0], p1[1], p0[2] },
            };
            const indices = [_]usize{ 0, 1, 2, 0, 2, 3 };
            const uv = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
            for (indices) |index| try vertices.append(allocator, Vertex.init(quad[index], color, normal, uv[index], tile, light[0], .{ light[1], light[2], light[3] }, 1));
        }
    }
}

const SceneRect = struct {
    min: [2]f32,
    max: [2]f32,
};

/// CPU-only intermediate: keep material identity even when atlas colors/tiles
/// coincide. Nonuniform corner lighting is retained exactly and never merged.
const SceneFace = struct {
    plane: f32,
    rect: SceneRect,
    color: u32,
    meta: [4]u32,
    blocklight: [4]u32,
    block: BlockType,
    axis: u2,
    positive: bool,
    uniform: bool,

    fn mergeAxis(self: SceneFace, pass: usize) usize {
        // X-normal sides have (Y,Z) rectangle axes; merge Z before Y.
        return if (self.axis == 0) 1 - pass else pass;
    }

    fn sameSurface(a: SceneFace, b: SceneFace) bool {
        return a.axis == b.axis and a.positive == b.positive and a.plane == b.plane and
            a.block == b.block and a.color == b.color and
            std.mem.eql(u32, &a.meta, &b.meta) and std.mem.eql(u32, &a.blocklight, &b.blocklight);
    }

    fn lessThan(pass: usize, a: SceneFace, b: SceneFace) bool {
        if (a.axis != b.axis) return a.axis < b.axis;
        if (a.positive != b.positive) return !a.positive;
        if (a.plane != b.plane) return a.plane < b.plane;
        if (a.block != b.block) return @intFromEnum(a.block) < @intFromEnum(b.block);
        if (a.color != b.color) return a.color < b.color;
        for (a.meta, b.meta) |left, right| {
            if (left != right) return left < right;
        }
        for (a.blocklight, b.blocklight) |left, right| {
            if (left != right) return left < right;
        }
        const along = a.mergeAxis(pass);
        const across = 1 - along;
        const left = [4]f32{ a.rect.min[across], a.rect.max[across], a.rect.min[along], a.rect.max[along] };
        const right = [4]f32{ b.rect.min[across], b.rect.max[across], b.rect.min[along], b.rect.max[along] };
        for (left, right) |x, y| {
            if (x != y) return x < y;
        }
        return false;
    }
};

comptime {
    std.debug.assert(@sizeOf(SceneFace) == 60);
}

/// Two bounded O(n log n), allocation-free passes. Exact transverse extents and
/// touching edges ensure merging cannot fill holes, overlaps, or partial cells.
fn mergeSceneFaces(faces: *std.ArrayListUnmanaged(SceneFace)) void {
    for (0..2) |pass| {
        std.sort.heap(SceneFace, faces.items, pass, SceneFace.lessThan);
        var count: usize = 0;
        for (faces.items) |face| {
            if (count > 0 and face.uniform) {
                const previous = &faces.items[count - 1];
                const along = face.mergeAxis(pass);
                const across = 1 - along;
                if (previous.uniform and SceneFace.sameSurface(previous.*, face) and
                    previous.rect.min[across] == face.rect.min[across] and previous.rect.max[across] == face.rect.max[across] and
                    previous.rect.max[along] == face.rect.min[along])
                {
                    previous.rect.max[along] = face.rect.max[along];
                    continue;
                }
            }
            faces.items[count] = face;
            count += 1;
        }
        faces.items.len = count;
    }
}

fn sceneLightChannels(light: world_core.PackedLight) [4]f32 {
    return .{
        @as(f32, @floatFromInt(light.sky_light)) / 15.0,
        @as(f32, @floatFromInt(light.block_light_r)) / 15.0,
        @as(f32, @floatFromInt(light.block_light_g)) / 15.0,
        @as(f32, @floatFromInt(light.block_light_b)) / 15.0,
    };
}

fn interpolateSceneLight(bottom: world_core.PackedLight, top: world_core.PackedLight, amount: f32) [4]f32 {
    const low = [4]u4{ bottom.sky_light, bottom.block_light_r, bottom.block_light_g, bottom.block_light_b };
    const high = [4]u4{ top.sky_light, top.block_light_r, top.block_light_g, top.block_light_b };
    var result: [4]f32 = undefined;
    for (&result, low, high) |*value, a, b| {
        const lower: f32 = @floatFromInt(a);
        const upper: f32 = @floatFromInt(b);
        value.* = (lower + (upper - lower) * std.math.clamp(amount, 0, 1)) / 15.0;
    }
    return result;
}

/// Sample the air immediately outside a side, not the light buried at this
/// material run's top. The horizontal probe stays inside the exposed rectangle
/// so a clipped corner cannot accidentally sample the adjacent occluding solid.
fn sceneSideLight(data: *const SceneGrid, gx: i32, gz: i32, span_index: usize, nx: i32, nz: i32, axis: usize, positive: bool, probe: [3]f32) [4]f32 {
    const own = data.column(gx, gz)[span_index];
    const tangent: usize = if (axis == 0) 2 else 0;
    var lower: ?SceneSpan = null;
    var upper: ?SceneSpan = null;
    var transparent: ?SceneSpan = null;
    for (data.column(nx, nz), 0..) |other, i| {
        if (nx == gx and nz == gz and i == span_index) continue;
        const box = SceneBox.fromSpan(other, nx, nz, data.cell_size);
        const outside = if (positive) box.min[axis] <= probe[axis] and box.max[axis] > probe[axis] else box.min[axis] < probe[axis] and box.max[axis] >= probe[axis];
        if (!outside or probe[tangent] < box.min[tangent] or probe[tangent] > box.max[tangent]) continue;
        if (other.max_y <= probe[1]) {
            if (lower == null or other.max_y > lower.?.max_y) lower = other;
        } else if (other.min_y >= probe[1]) {
            if (upper == null or other.min_y < upper.?.min_y) upper = other;
        } else if (!world_core.block_registry.getBlockDefinition(other.block).isFullCubeOccluder()) {
            if (transparent == null or other.max_y - other.min_y < transparent.?.max_y - transparent.?.min_y) transparent = other;
        }
    }
    var light: [4]f32 = .{ 0, 0, 0, 0 };
    if (transparent) |medium| {
        light = interpolateSceneLight(medium.light_bottom orelse medium.light, medium.light, (probe[1] - medium.min_y) / (medium.max_y - medium.min_y));
    } else if (lower != null and upper != null) {
        const floor = lower.?;
        const ceiling = upper.?;
        if (ceiling.min_y > floor.max_y) {
            light = interpolateSceneLight(floor.light, ceiling.light_bottom orelse ceiling.light, (probe[1] - floor.max_y) / (ceiling.min_y - floor.max_y));
        } else {
            light = sceneLightChannels(floor.light);
            for (&light, sceneLightChannels(ceiling.light_bottom orelse ceiling.light)) |*value, channel| value.* = @max(value.*, channel);
        }
    } else if (lower) |floor| {
        light = sceneLightChannels(floor.light);
    } else if (upper) |ceiling| {
        light = sceneLightChannels(ceiling.light_bottom orelse ceiling.light);
    } else {
        const info = data.columns[@as(usize, @intCast(nz + 1)) * (data.width + 2) + @as(usize, @intCast(nx + 1))];
        if (data.column(nx, nz).len == 0 and info.total_area > 0 and info.known_area == info.total_area and !info.approximate) light[0] = 1;
    }

    // Only an exposed run boundary at this endpoint contributes its own light.
    // A sunny roof top must not brighten a cave wall or its dark underside.
    if (probe[1] == own.min_y or probe[1] == own.max_y) {
        const top = probe[1] == own.max_y;
        var visible = top or own.min_y > 0;
        for (data.column(gx, gz), 0..) |other, i| {
            if (i == span_index) continue;
            if (!world_core.block_registry.getBlockDefinition(other.block).isFullCubeOccluder() and other.block != own.block) continue;
            const box = SceneBox.fromSpan(other, gx, gz, data.cell_size);
            if (probe[0] < box.min[0] or probe[0] > box.max[0] or probe[2] < box.min[2] or probe[2] > box.max[2]) continue;
            if (if (top) other.min_y <= probe[1] and other.max_y > probe[1] else other.min_y < probe[1] and other.max_y >= probe[1]) visible = false;
        }
        if (visible) {
            const boundary = sceneLightChannels(if (top) own.light else own.light_bottom orelse own.light);
            for (&light, boundary) |*value, channel| value.* = @max(value.*, channel);
        }
    }
    return light;
}

/// Retain uncovered horizontal strips as well as Y gaps: a partial neighbor
/// must not erase a whole face just because its height overlaps.
fn subtractSceneRect(allocator: std.mem.Allocator, exposed: *std.ArrayListUnmanaged(SceneRect), cover: SceneRect) !void {
    var i: usize = 0;
    while (i < exposed.items.len) {
        const rect = exposed.items[i];
        const min = [2]f32{ @max(rect.min[0], cover.min[0]), @max(rect.min[1], cover.min[1]) };
        const max = [2]f32{ @min(rect.max[0], cover.max[0]), @min(rect.max[1], cover.max[1]) };
        if (min[0] >= max[0] or min[1] >= max[1]) {
            i += 1;
            continue;
        }
        _ = exposed.swapRemove(i);
        const strips = [_]SceneRect{
            .{ .min = rect.min, .max = .{ min[0], rect.max[1] } },
            .{ .min = .{ max[0], rect.min[1] }, .max = rect.max },
            .{ .min = .{ min[0], rect.min[1] }, .max = .{ max[0], min[1] } },
            .{ .min = .{ min[0], max[1] }, .max = .{ max[0], rect.max[1] } },
        };
        for (strips) |strip| {
            if (strip.min[0] < strip.max[0] and strip.min[1] < strip.max[1]) try exposed.append(allocator, strip);
        }
    }
}

/// Size of each LOD mesh grid cell in blocks
pub fn getCellSize(lod: LODLevel) u32 {
    return LODSimplifiedData.getCellSizeBlocks(lod);
}

/// LOD Mesh for a single LOD region
pub const LODMesh = struct {
    /// `drawCompactLOD` currently reports a bool, so transient render-graph
    /// readiness and a rejected backend submission share one result. Retrying
    /// several frames preserves compact residency during pipeline/descriptor
    /// warmup while still bounding a genuine persistent failure.
    pub const COMPACT_BACKEND_FAILURE_LIMIT: u8 = 8;
    pub const DrawRange = struct {
        offset: usize,
        count: u32,
    };

    pub const DrawState = struct {
        buffer_handle: BufferHandle = 0,
        vertex_offset: usize = 0,
        vertex_count: u32 = 0,
        capacity: u32 = 0,
        pooled: bool = false,
        ready: bool = false,

        pub const empty: DrawState = .{};
    };

    /// CPU geometry prepared for an expanded upload.  Keeping this payload
    /// separately movable lets a compact-to-CPU transition retain the compact
    /// representation until CPU generation has definitely succeeded.
    pub const PendingCpuBuild = struct {
        vertices: ?[]Vertex = null,
        opaque_vertex_count: u32 = 0,
        water_vertex_offset: usize = 0,
        water_vertex_count: u32 = 0,
        canonical_empty_coverage: bool = false,
    };

    pub const MemorySnapshot = struct {
        capacity_bytes: usize,
        pending_upload_bytes: usize,
        pooled: bool,
        compact: bool,
        vertex_count: u32,
    };

    /// GPU buffer handle
    buffer_handle: BufferHandle = 0,
    /// Number of vertices
    vertex_count: u32 = 0,
    /// Number of opaque terrain vertices at the start of the buffer.
    opaque_vertex_count: u32 = 0,
    /// Byte offset from `vertex_offset` to translucent LOD water vertices.
    water_vertex_offset: usize = 0,
    /// Number of translucent LOD water vertices.
    water_vertex_count: u32 = 0,
    /// Buffer capacity (vertices)
    capacity: u32 = 0,
    /// Byte offset inside the vertex buffer. Non-zero when backed by a shared LOD pool.
    vertex_offset: usize = 0,
    /// True when buffer_handle is owned by a shared LOD vertex pool.
    pooled: bool = false,
    /// Pressure-selected upload strategy, sticky for this mesh's lifetime.
    dedicated_upload_fallback: bool = false,
    /// Pending vertices to upload
    pending_vertices: ?[]Vertex = null,
    /// Present only while a compact tile awaits GPU upload.  The pool owns the
    /// post-upload representation, so this is never an expanded Vertex array.
    compact_tile: ?CompactLODTile = null,
    /// Same-level authoritative compact aprons. This metadata survives release
    /// of `compact_tile` after upload, so a resident tile never claims a
    /// seamless edge merely because its fallback apron happened to be local.
    compact_neighbor_apron_mask: u8 = 0,
    compact: bool = false,
    compact_sample_offset: u32 = 0,
    compact_sample_bytes: usize = 0,
    compact_index_count: u32 = 0,
    compact_tile_width: u32 = 0,
    compact_has_water: bool = false,
    compact_draw_failed: bool = false,
    compact_backend_draw_failures: u8 = 0,
    /// Immutable source identity captured when this representation was built.
    /// Recovery uses it to reject a late render failure from a superseded mesh.
    source_job_token: u32 = 0,
    source_revision: u32 = 0,
    /// Allocator
    allocator: std.mem.Allocator,
    allocator_owner: ?struct {
        ptr: *anyopaque,
        release_fn: *const fn (*anyopaque) void,
        parent_allocator: std.mem.Allocator,
    } = null,
    /// Mutex for thread safety
    mutex: sync.Mutex = .{},
    /// LOD level
    lod_level: LODLevel,
    /// Ready for rendering
    ready: bool = false,
    /// Only a successfully built, known-air canonical interior covers without draws.
    canonical_empty_coverage: bool = false,

    pub fn init(allocator: std.mem.Allocator, lod: LODLevel) LODMesh {
        return .{
            .allocator = allocator,
            .lod_level = lod,
        };
    }

    pub fn isRenderable(self: *const LODMesh) bool {
        return self.ready and self.vertex_count > 0;
    }

    pub fn isCoverageReady(self: *const LODMesh) bool {
        return self.ready and (self.isRenderable() or self.canonical_empty_coverage);
    }

    pub fn isReady(self: *const LODMesh) bool {
        return self.ready;
    }

    pub fn isPooled(self: *const LODMesh) bool {
        return self.pooled;
    }

    pub fn usesDedicatedUploadFallback(self: *LODMesh) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dedicated_upload_fallback;
    }
    /// Representation selection is serialized by the LOD manager/renderer.
    /// Code outside that invariant must hold `mutex` before reading `compact`.
    pub fn isCompact(self: *const LODMesh) bool {
        return self.compact;
    }

    pub fn compactDrawFailed(self: *LODMesh) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.compact_draw_failed;
    }

    pub fn markCompactDrawFailed(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.compact_draw_failed = true;
        self.ready = false;
    }

    /// A backend failure is only terminal after a bounded retry budget.
    /// Resource/descriptor availability is handled separately by the renderer
    /// and never calls this method.
    pub fn noteCompactBackendDrawFailure(self: *LODMesh) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.compact_backend_draw_failures +|= 1;
        if (self.compact_backend_draw_failures < COMPACT_BACKEND_FAILURE_LIMIT) return false;
        self.compact_draw_failed = true;
        self.ready = false;
        return true;
    }

    /// A confirmed backend submission makes earlier failures irrelevant: only
    /// consecutive failures may retire an otherwise healthy compact mesh.
    /// Transient resource unavailability intentionally does not call this.
    pub fn resetCompactBackendDrawFailures(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.compact_backend_draw_failures = 0;
    }

    /// A manager-owned mesh build records the source identity before it can be
    /// rendered. The render thread only marks failure; it never owns recovery.
    pub fn setSourceIdentity(self: *LODMesh, job_token: u32, source_revision: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.source_job_token = job_token;
        self.source_revision = source_revision;
    }

    pub fn compactDrawFailureMatches(self: *LODMesh, job_token: u32, source_revision: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.compact_draw_failed and self.compact and
            self.source_job_token == job_token and self.source_revision == source_revision;
    }

    /// A bit is set only when the corresponding same-level apron was copied
    /// before upload. Missing and cross-LOD neighbors intentionally remain
    /// invalid; the shader uses the complementary skirt mask for those edges.
    pub fn compactApronMask(self: *LODMesh) u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.compact_neighbor_apron_mask;
    }

    pub fn compactSkirtMask(self: *LODMesh) u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return (~self.compact_neighbor_apron_mask) & @import("lod_tile.zig").TILE_EDGE_MASK;
    }

    pub fn compactEdgeIsSeamless(self: *LODMesh, edge: CompactTileEdge) bool {
        return (self.compactApronMask() & @import("lod_tile.zig").edgeMask(edge)) != 0;
    }

    pub fn patchCompactNeighbor(self: *LODMesh, edge: CompactTileEdge, neighbor: *LODMesh) bool {
        if (self == neighbor) return false;
        const self_first = @intFromPtr(self) < @intFromPtr(neighbor);
        const first = if (self_first) self else neighbor;
        const second = if (self_first) neighbor else self;
        first.mutex.lock();
        defer first.mutex.unlock();
        second.mutex.lock();
        defer second.mutex.unlock();
        const tile = if (self.compact_tile) |*value| value else return false;
        const neighbor_tile = if (neighbor.compact_tile) |*value| value else return false;
        tile.applyNeighborApron(edge, neighbor_tile) catch return false;
        const opposite: CompactTileEdge = switch (edge) {
            .west => .east,
            .east => .west,
            .north => .south,
            .south => .north,
        };
        neighbor_tile.applyNeighborApron(opposite, tile) catch return false;
        self.compact_neighbor_apron_mask = tile.neighbor_apron_mask;
        neighbor.compact_neighbor_apron_mask = neighbor_tile.neighbor_apron_mask;
        return true;
    }

    /// True when replacing this mesh must first retire renderer-owned storage.
    /// A remesh may replace either an uploaded representation or source data
    /// awaiting upload; both cases must discard the old representation first.
    pub fn hasRepresentation(self: *LODMesh) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.compact or self.buffer_handle != 0 or self.pooled or
            self.pending_vertices != null or self.capacity != 0 or self.ready;
    }

    pub fn bufferHandle(self: *const LODMesh) BufferHandle {
        return self.buffer_handle;
    }

    pub fn vertexOffset(self: *const LODMesh) usize {
        return self.vertex_offset;
    }

    pub fn vertexCount(self: *const LODMesh) u32 {
        return self.vertex_count;
    }

    pub fn lodLevel(self: *const LODMesh) LODLevel {
        return self.lod_level;
    }

    pub fn byteSize(self: *const LODMesh) usize {
        return @as(usize, self.capacity) * @sizeOf(Vertex);
    }

    pub fn drawRange(self: *const LODMesh, layer: LODRenderLayer) ?DrawRange {
        if (!self.ready) return null;
        if (self.compact) return switch (layer) {
            .terrain => if (self.compact_index_count > 0) .{ .offset = 0, .count = self.compact_index_count } else null,
            .fluid => if (self.compact_has_water and self.compact_index_count > 0) .{ .offset = 0, .count = self.compact_index_count } else null,
        };
        if (self.buffer_handle == 0) return null;
        return switch (layer) {
            .terrain => if (self.opaque_vertex_count > 0)
                .{ .offset = 0, .count = self.opaque_vertex_count }
            else if (self.water_vertex_count == 0 and self.vertex_count > 0)
                .{ .offset = 0, .count = self.vertex_count }
            else
                null,
            .fluid => if (self.water_vertex_count > 0)
                .{ .offset = self.water_vertex_offset, .count = self.water_vertex_count }
            else
                null,
        };
    }

    pub fn firstVertex(self: *const LODMesh, range: DrawRange) u32 {
        return @intCast((self.vertex_offset + range.offset) / @sizeOf(Vertex));
    }

    pub fn setDrawStateUnlocked(self: *LODMesh, state: DrawState) void {
        self.buffer_handle = state.buffer_handle;
        self.vertex_offset = state.vertex_offset;
        self.vertex_count = state.vertex_count;
        self.capacity = state.capacity;
        self.pooled = state.pooled;
        self.ready = state.ready;
    }

    pub fn setDrawState(self: *LODMesh, state: DrawState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.setDrawStateUnlocked(state);
    }

    pub fn clearDrawStateUnlocked(self: *LODMesh) void {
        self.setDrawStateUnlocked(.empty);
        self.canonical_empty_coverage = false;
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;
    }

    pub fn markEmptyUploadedUnlocked(self: *LODMesh) void {
        const canonical_empty = self.canonical_empty_coverage;
        self.clearDrawStateUnlocked();
        self.canonical_empty_coverage = canonical_empty;
        self.ready = true;
    }

    pub fn setBufferHandleUnlocked(self: *LODMesh, handle: BufferHandle) void {
        self.buffer_handle = handle;
    }

    pub fn setPoolLocationUnlocked(self: *LODMesh, handle: BufferHandle, offset: usize) void {
        self.buffer_handle = handle;
        self.vertex_offset = offset;
    }

    pub fn setUploaded(self: *LODMesh, vertex_count: u32, opaque_vertex_count: u32) void {
        self.vertex_count = vertex_count;
        self.opaque_vertex_count = opaque_vertex_count;
        self.ready = true;
    }

    pub fn pendingVerticesForTest(self: *const LODMesh) ?[]Vertex {
        return self.pending_vertices;
    }

    /// Detaches a successfully built expanded payload before compact GPU
    /// storage is retired. `LODGPUBridge.destroy` deliberately clears pending
    /// vertices, so the caller must carry this payload across that callback.
    pub fn takePendingCpuBuild(self: *LODMesh) PendingCpuBuild {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = PendingCpuBuild{
            .vertices = self.pending_vertices,
            .opaque_vertex_count = self.opaque_vertex_count,
            .water_vertex_offset = self.water_vertex_offset,
            .water_vertex_count = self.water_vertex_count,
            .canonical_empty_coverage = self.canonical_empty_coverage,
        };
        self.pending_vertices = null;
        return result;
    }

    /// Publishes a detached expanded payload after the former compact storage
    /// has been retired. This cannot allocate, so a successful CPU build never
    /// becomes an empty mesh during retirement.
    pub fn restorePendingCpuBuild(self: *LODMesh, build: *PendingCpuBuild) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(!self.compact);
        std.debug.assert(self.pending_vertices == null);
        self.opaque_vertex_count = build.opaque_vertex_count;
        self.water_vertex_offset = build.water_vertex_offset;
        self.water_vertex_count = build.water_vertex_count;
        self.canonical_empty_coverage = build.canonical_empty_coverage;
        self.pending_vertices = build.vertices;
        build.* = .{};
    }

    pub fn deinit(self: *LODMesh, resources: LODMeshResources) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pooled) {
            std.debug.assert(false);
            return;
        }

        if (self.buffer_handle != 0 and !self.pooled) {
            resources.destroyBuffer(self.buffer_handle);
        }
        self.buffer_handle = 0;
        self.vertex_offset = 0;
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;
        self.pooled = false;
        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
        if (self.compact_tile) |*tile| tile.deinit();
        self.compact_tile = null;
        self.compact_neighbor_apron_mask = 0;
        self.compact = false;
        self.compact_sample_offset = 0;
        self.compact_sample_bytes = 0;
        self.compact_index_count = 0;
        self.compact_tile_width = 0;
        self.compact_has_water = false;
        self.compact_draw_failed = false;
        self.compact_backend_draw_failures = 0;
        self.ready = false;
        self.canonical_empty_coverage = false;
        self.releaseAllocatorOwner();
    }

    /// Caller owns the mesh exclusively or holds its mutex. Pool destruction
    /// retires GPU storage separately; its manager calls this before destroying
    /// the parent-allocated mesh object. Repeated release is harmless.
    pub fn releaseAllocatorOwner(self: *LODMesh) void {
        const owner = self.allocator_owner orelse return;
        std.debug.assert(self.pending_vertices == null and self.compact_tile == null);
        self.allocator_owner = null;
        self.allocator = owner.parent_allocator;
        owner.release_fn(owner.ptr);
    }

    pub fn buildCompactTile(self: *LODMesh, data: *const LODSimplifiedData) !void {
        const tile = try CompactLODTile.initFromSimplified(self.allocator, self.lod_level, data);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.compact_tile) |*old| old.deinit();
        self.compact_tile = tile;
        self.canonical_empty_coverage = false;
        self.compact_neighbor_apron_mask = 0;
        self.compact = true;
        const cells = (data.width - 1) * (data.width - 1);
        self.compact_index_count = cells * 6;
        self.compact_tile_width = data.width;
        self.compact_has_water = false;
        for (data.water) |water| {
            if (water.is_surface and water.coverage > 0.001) {
                self.compact_has_water = true;
                break;
            }
        }
        self.compact_draw_failed = false;
        self.compact_backend_draw_failures = 0;
        self.ready = false;
    }

    /// Releases a compact source tile once its samples have been uploaded.
    /// `compact_neighbor_apron_mask` deliberately remains: resident data has no
    /// mutable CPU payload, so a later neighbor must remain a skirted,
    /// non-seamless edge rather than triggering an unsafe in-place GPU patch.
    pub fn releasePendingCompactTile(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.compact_tile) |*tile| tile.deinit();
        self.compact_tile = null;
    }

    /// Clears compact-only state after its range has been retired by the
    /// renderer, or when it never reached the renderer. This is deliberately
    /// separate from `releasePendingCompactTile`: a CPU fallback must not leave
    /// `compact` set, otherwise the normal vertex uploader will re-enter the
    /// compact path with stale offsets.
    pub fn clearCompactState(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.compact_tile) |*tile| tile.deinit();
        self.compact_tile = null;
        self.compact_neighbor_apron_mask = 0;
        self.compact = false;
        self.compact_sample_offset = 0;
        self.compact_sample_bytes = 0;
        self.compact_index_count = 0;
        self.compact_tile_width = 0;
        self.compact_has_water = false;
        self.compact_draw_failed = false;
        self.compact_backend_draw_failures = 0;
        self.buffer_handle = 0;
        self.vertex_count = 0;
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;
        self.vertex_offset = 0;
        self.capacity = 0;
        self.pooled = false;
        self.ready = false;
        self.canonical_empty_coverage = false;
    }

    /// Idempotent cleanup after the renderer has retired/destroyed the GPU
    /// object. This also makes lightweight test bridges safe: they need not
    /// duplicate representation bookkeeping merely to exercise a remesh.
    pub fn clearRetiredState(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_vertices) |pending| self.allocator.free(pending);
        self.pending_vertices = null;
        if (self.compact_tile) |*tile| tile.deinit();
        self.compact_tile = null;
        self.compact_neighbor_apron_mask = 0;
        self.clearDrawStateUnlocked();
        self.compact = false;
        self.compact_sample_offset = 0;
        self.compact_sample_bytes = 0;
        self.compact_index_count = 0;
        self.compact_tile_width = 0;
        self.compact_has_water = false;
        self.compact_draw_failed = false;
        self.compact_backend_draw_failures = 0;
    }

    pub fn clearPendingVertices(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
    }

    pub fn pendingUploadBytes(self: *LODMesh) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.compact_tile) |tile| return std.mem.sliceAsBytes(tile.samples).len;
        const pending = self.pending_vertices orelse return 0;
        return std.mem.sliceAsBytes(pending).len;
    }

    /// Atomically snapshots the storage that this mesh currently owns or uses.
    /// Pooled capacity is an allocation within the renderer-owned pool, not a
    /// separate GPU buffer.
    pub fn memorySnapshot(self: *LODMesh) MemorySnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .capacity_bytes = self.byteSize(),
            .pending_upload_bytes = if (self.compact_tile) |tile|
                std.mem.sliceAsBytes(tile.samples).len
            else if (self.pending_vertices) |pending|
                std.mem.sliceAsBytes(pending).len
            else
                0,
            .pooled = self.pooled,
            .compact = self.compact,
            .vertex_count = self.vertex_count,
        };
    }

    /// Scene columns are already projected footprints, never endpoint samples.
    /// Build off to the side so allocation failure cannot disturb a live fallback.
    pub fn buildFromSceneGrid(self: *LODMesh, data: *const SceneGrid, atlas: *const TextureAtlas) !void {
        var faces = std.ArrayListUnmanaged(SceneFace).empty;
        defer faces.deinit(self.allocator);
        var plants = std.ArrayListUnmanaged(Vertex).empty;
        defer plants.deinit(self.allocator);
        var water_faces = std.ArrayListUnmanaged(SceneFace).empty;
        defer water_faces.deinit(self.allocator);
        var exposed = std.ArrayListUnmanaged(SceneRect).empty;
        defer exposed.deinit(self.allocator);
        var known_empty = true;
        const width: i32 = @intCast(data.width);
        var gz: i32 = 0;
        while (gz < width) : (gz += 1) {
            var gx: i32 = 0;
            while (gx < width) : (gx += 1) {
                const spans = data.column(gx, gz);
                const info = data.columns[@as(usize, @intCast(gz + 1)) * (data.width + 2) + @as(usize, @intCast(gx + 1))];
                known_empty = known_empty and spans.len == 0 and info.total_area > 0 and info.known_area == info.total_area and !info.approximate;
                var terrain_top: f32 = 0;
                for (spans) |span| {
                    if (world_core.block_registry.getBlockDefinition(span.block).isFullCubeOccluder() and !isNearVegetation(span.block)) terrain_top = @max(terrain_top, span.max_y);
                }
                for (spans, 0..) |span, span_index| {
                    if (scenePlantHeight(span.block) != null) {
                        try appendScenePlantRoots(self.allocator, &plants, span, gx, gz, data.cell_size, atlas);
                        continue;
                    }
                    const box = SceneBox.fromSpan(span, gx, gz, data.cell_size);
                    const target = if (span.block == .water) &water_faces else &faces;
                    const tiles = atlas.getTilesForBlock(@intFromEnum(span.block));
                    // Cyclic in-plane axes have cross(u, v) == positive axis.
                    for (0..3) |axis| {
                        const u = (axis + 1) % 3;
                        const v = (axis + 2) % 3;
                        for ([_]bool{ false, true }) |positive| {
                            if (axis == 1 and !positive and span.min_y == 0) continue;
                            const plane = if (positive) box.max[axis] else box.min[axis];
                            const face: geom.LODTextureFace = if (axis != 1) .side else if (positive) .top else .bottom;
                            var rect = SceneRect{ .min = .{ box.min[u], box.min[v] }, .max = .{ box.max[u], box.max[v] } };
                            var nx = gx;
                            var nz = gz;
                            if (axis == 0) nx += if (positive) @as(i32, 1) else -1;
                            if (axis == 2) nz += if (positive) @as(i32, 1) else -1;
                            const cell_edge = @as(f32, @floatFromInt((if (axis == 0) gx else gz) + @as(i32, if (positive) 1 else 0))) * @as(f32, @floatFromInt(data.cell_size));
                            const meets_edge = axis != 1 and plane == cell_edge;
                            const region_boundary = meets_edge and (nx < 0 or nz < 0 or nx == width or nz == width);
                            if (region_boundary) {
                                const halo = data.columns[@as(usize, @intCast(nz + 1)) * (data.width + 2) + @as(usize, @intCast(nx + 1))];
                                // Approximate halo spans are evidence too. Only wholly
                                // unknown edges need a short handoff, never a wall to Y=0.
                                if (halo.known_area == 0 and data.column(nx, nz).len == 0 and world_core.block_registry.getBlockDefinition(span.block).isFullCubeOccluder() and !isNearVegetation(span.block)) {
                                    const floor = terrain_top - std.math.clamp(@as(f32, @floatFromInt(data.cell_size)), 1, 8);
                                    if (u == 1) rect.min[0] = @max(rect.min[0], floor);
                                    if (v == 1) rect.min[1] = @max(rect.min[1], floor);
                                }
                            }
                            exposed.clearRetainingCapacity();
                            if (rect.min[0] >= rect.max[0] or rect.min[1] >= rect.max[1]) continue;
                            try exposed.append(self.allocator, rect);
                            // Source halo spans do not describe the published neighbor:
                            // it may still be an older, coarser, or inset fallback. Until
                            // compatible published topology is supplied, retain boundary
                            // faces; only this mesh's interior can safely occlude them.
                            const neighbor_spans: []const SceneSpan = if (meets_edge and !region_boundary) data.column(nx, nz) else &.{};
                            for ([_][]const SceneSpan{ spans, neighbor_spans }, 0..) |occluders, group| {
                                for (occluders, 0..) |other, other_index| {
                                    if (group == 0 and other_index == span_index) continue;
                                    const definition = world_core.block_registry.getBlockDefinition(other.block);
                                    if (!definition.isFullCubeOccluder() and other.block != span.block) continue;
                                    const other_box = SceneBox.fromSpan(other, if (group == 0) gx else nx, if (group == 0) gz else nz, data.cell_size);
                                    const extends_outward = if (positive)
                                        other_box.min[axis] <= plane and other_box.max[axis] > plane
                                    else
                                        other_box.min[axis] < plane and other_box.max[axis] >= plane;
                                    const wins_tie = (definition.isFullCubeOccluder() and !world_core.block_registry.getBlockDefinition(span.block).isFullCubeOccluder()) or other_index < span_index;
                                    const coincident = group == 0 and wins_tie and
                                        (if (positive) other_box.max[axis] == plane else other_box.min[axis] == plane);
                                    if (!extends_outward and !coincident) continue;
                                    try subtractSceneRect(self.allocator, &exposed, .{ .min = .{ other_box.min[u], other_box.min[v] }, .max = .{ other_box.max[u], other_box.max[v] } });
                                }
                            }
                            const atlas_tile = switch (face) {
                                .top => tiles.top,
                                .side => tiles.side,
                                .bottom => tiles.bottom,
                            };
                            const tile = if (atlas_tile == 0 or (data.cell_size != 1 and isLeafBlock(span.block))) Vertex.LOD_TILE_ID else atlas_tile;
                            const tint = if (geom.shouldTintLodFace(span.block, face)) biome_mod.getBlockTintColor(span.biome, span.block) else packBlockDefaultColor(span.block, 0xFFFFFF);
                            const albedo = applyTextureLuminance(tint, span.block, face, atlas);
                            // Albedo is atlas average * tint only. Normals drive shading;
                            // captured light and neutral AO are encoded once, not baked.
                            const color = rhi_types.encodeColor(.{ unpackR(albedo), unpackG(albedo), unpackB(albedo) });
                            for (exposed.items) |piece| {
                                var record = SceneFace{
                                    .plane = plane,
                                    .rect = piece,
                                    .color = color,
                                    .meta = undefined,
                                    .blocklight = undefined,
                                    .block = span.block,
                                    .axis = @intCast(axis),
                                    .positive = positive,
                                    .uniform = true,
                                };
                                for ([_][2]f32{ piece.min, .{ piece.max[0], piece.min[1] }, piece.max, .{ piece.min[0], piece.max[1] } }, 0..) |point, i| {
                                    var pos: [3]f32 = undefined;
                                    pos[axis] = plane;
                                    pos[u] = point[0];
                                    pos[v] = point[1];
                                    var probe = pos;
                                    if (axis != 1) {
                                        const tangent: usize = if (axis == 0) 2 else 0;
                                        const horizontal: usize = if (u == tangent) 0 else 1;
                                        probe[tangent] = (piece.min[horizontal] + piece.max[horizontal]) * 0.5;
                                    }
                                    const light = if (axis == 1)
                                        sceneLightChannels(if (positive) span.light else span.light_bottom orelse span.light)
                                    else
                                        sceneSideLight(data, gx, gz, span_index, if (meets_edge) nx else gx, if (meets_edge) nz else gz, axis, positive, probe);
                                    record.meta[i] = rhi_types.encodeMeta(tile, light[0], 1);
                                    record.blocklight[i] = rhi_types.encodeBlocklight(.{ light[1], light[2], light[3] }, false);
                                    if (record.meta[i] != record.meta[0] or record.blocklight[i] != record.blocklight[0]) record.uniform = false;
                                }
                                try target.append(self.allocator, record);
                            }
                        }
                    }
                }
            }
        }
        mergeSceneFaces(&faces);
        mergeSceneFaces(&water_faces);
        const opaque_count = faces.items.len * 6 + plants.items.len;
        const water_count = water_faces.items.len * 6;
        const total_count = opaque_count + water_count;
        const pending = try self.allocator.alloc(Vertex, total_count);
        var next: usize = 0;
        for (faces.items) |face| {
            const axis: usize = face.axis;
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            var normal = [3]f32{ 0, 0, 0 };
            normal[axis] = if (face.positive) 1 else -1;
            const packed_normal = rhi_types.encodeNormal(normal);
            var quad: [4]Vertex = undefined;
            for ([_][2]f32{ face.rect.min, .{ face.rect.max[0], face.rect.min[1] }, face.rect.max, .{ face.rect.min[0], face.rect.max[1] } }, 0..) |point, i| {
                var pos: [3]f32 = undefined;
                pos[axis] = face.plane;
                pos[u] = point[0];
                pos[v] = point[1];
                const uv = if (axis == 1) geom.topFaceUV(pos, data.origin_x, data.origin_z) else geom.sideFaceUV(pos, if (axis == 0) .east else .north, data.origin_x, data.origin_z);
                quad[i] = .{
                    .pos = pos,
                    .color = face.color,
                    .normal = packed_normal,
                    .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
                    .packed_meta = face.meta[i],
                    .blocklight = face.blocklight[i],
                };
            }
            const indices: [6]usize = if (face.positive) .{ 0, 1, 2, 0, 2, 3 } else .{ 0, 2, 1, 0, 3, 2 };
            for (indices) |i| {
                pending[next] = quad[i];
                next += 1;
            }
        }
        for (plants.items) |vertex| {
            pending[next] = vertex;
            next += 1;
        }
        for (water_faces.items) |face| {
            const axis: usize = face.axis;
            const u = (axis + 1) % 3;
            const v = (axis + 2) % 3;
            var normal = [3]f32{ 0, 0, 0 };
            normal[axis] = if (face.positive) 1 else -1;
            const packed_normal = rhi_types.encodeNormal(normal);
            var quad: [4]Vertex = undefined;
            for ([_][2]f32{ face.rect.min, .{ face.rect.max[0], face.rect.min[1] }, face.rect.max, .{ face.rect.min[0], face.rect.max[1] } }, 0..) |point, i| {
                var pos: [3]f32 = undefined;
                pos[axis] = face.plane;
                pos[u] = point[0];
                pos[v] = point[1];
                const uv = if (axis == 1) geom.topFaceUV(pos, data.origin_x, data.origin_z) else geom.sideFaceUV(pos, if (axis == 0) .east else .north, data.origin_x, data.origin_z);
                quad[i] = .{
                    .pos = pos,
                    .color = face.color,
                    .normal = packed_normal,
                    .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
                    .packed_meta = face.meta[i],
                    .blocklight = face.blocklight[i],
                };
            }
            const indices: [6]usize = if (face.positive) .{ 0, 1, 2, 0, 2, 3 } else .{ 0, 2, 1, 0, 3, 2 };
            for (indices) |i| {
                pending[next] = quad[i];
                next += 1;
            }
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_vertices) |old| self.allocator.free(old);
        self.pending_vertices = pending;
        self.opaque_vertex_count = @intCast(opaque_count);
        self.water_vertex_offset = opaque_count * @sizeOf(Vertex);
        self.water_vertex_count = @intCast(water_count);
        self.canonical_empty_coverage = known_empty and total_count == 0;
    }

    /// Build mesh from simplified LOD data (heightmap-based)
    pub fn buildFromSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        return self.buildSimplifiedData(data, world_x, world_z, atlas, @import("engine-core").envFlag("ZIGCRAFT_LOD_NEAR_SOURCE", false));
    }

    /// Explicit opt-in for the near1-block source contract, without process env.
    /// Worldgen columns and grids other than one-block LOD0/1 retain legacy behavior.
    pub fn buildFromNearSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        return self.buildSimplifiedData(data, world_x, world_z, atlas, true);
    }

    fn buildSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas, enable_near_source: bool) !void {
        if (data.scene_grid) |grid| return self.buildFromSceneGrid(grid, atlas);
        if (data.width < 2) return error.EmptyData;
        const near_source = enable_near_source and isNearSourceGrid(data, self.lod_level);

        const region_size: f32 = @floatFromInt(lod_chunk.regionSizeBlocks(self.lod_level));
        const cell_size = region_size / @as(f32, @floatFromInt(data.width - 1));

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);
        var water_vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer water_vertices.deinit(self.allocator);

        var gz: u32 = 0;
        while (gz + 1 < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx + 1 < data.width) : (gx += 1) {
                if (near_source and data.getColumnProvenance(gx, gz) != .worldgen) {
                    try self.addNearSourceColumn(&vertices, &water_vertices, data, gx, gz, atlas, world_x, world_z);
                    continue;
                }
                const cell_color = cellColorForLOD(data, gx, gz, self.lod_level);
                const lit_cell_color = applyColorBrightness(cell_color, ambientOcclusionForLOD(data, gx, gz, self.lod_level));
                const wx = @as(f32, @floatFromInt(gx)) * cell_size;
                const wz = @as(f32, @floatFromInt(gz)) * cell_size;
                const size = cell_size;

                const is_water_cell = isLODWaterCellForLOD(data, gx, gz, self.lod_level);
                const base_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, self.lod_level);
                const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, self.lod_level, is_water_cell);
                const folded_canopy = foldedCanopyColumnForLOD(data, gx, gz, self.lod_level, base_height, base_block, is_water_cell);
                const top_block = if (folded_canopy) |folded| folded.block else base_block;
                const column_height = if (folded_canopy) |folded| folded.height else base_height;
                const top_tile = if (folded_canopy != null) Vertex.LOD_TILE_ID else getLodTopTile(top_block, atlas);
                const side_tile = if (folded_canopy != null) Vertex.LOD_TILE_ID else getLodSideTile(top_block, atlas);
                const base_top_color = if (folded_canopy) |folded|
                    applyColorBrightness(folded.color, ambientOcclusionForLOD(data, gx, gz, self.lod_level))
                else
                    getLodTopColor(top_block, top_tile, lit_cell_color);
                const top_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, top_block, .top, base_top_color), top_block, .top, atlas);
                const side_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, top_block, .side, base_top_color), top_block, .side, atlas);

                try addTopFaceQuad(self.allocator, &vertices, wx, column_height, wz, size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                try addSteppedHeightfieldSides(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, size, column_height, side_color, side_tile, world_x, world_z);

                if (is_water_cell) {
                    const water_height = quantizedWaterSurfaceHeightForCell(data, gx, gz, self.lod_level);
                    if (water_height > column_height + 0.01) {
                        const water_tile = getLodTopTile(.water, atlas);
                        const water_color = tintColorForLodFace(data, gx, gz, self.lod_level, .water, .top, packBlockDefaultColor(.water, 0x3366CC));
                        try addTopFaceQuad(self.allocator, &water_vertices, wx, water_height, wz, size, unpackR(water_color), unpackG(water_color), unpackB(water_color), water_tile, world_x, world_z);
                    }
                }

                if (folded_canopy == null and !is_water_cell and shouldRenderLODTree(top_block)) {
                    const vegetation = representativeVegetationForLOD(data, gx, gz, self.lod_level);
                    if (vegetation.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD) {
                        try addTreeColumn(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, size, column_height, vegetation, atlas, world_x, world_z);
                    }
                }
            }
        }

        const opaque_count = vertices.items.len;
        const water_count = water_vertices.items.len;
        const total_count = opaque_count + water_count;
        var pending: ?[]Vertex = null;
        // A zero-length payload explicitly clears an uploaded mesh on upload.
        if (total_count > 0 or near_source) {
            const allocated = try self.allocator.alloc(Vertex, total_count);
            pending = allocated;
            errdefer self.allocator.free(allocated);
            @memcpy(allocated[0..opaque_count], vertices.items);
            @memcpy(allocated[opaque_count..total_count], water_vertices.items);
        }

        // Allocate and populate before touching the live mesh. A failed CPU
        // fallback must leave its compact representation exactly retryable.
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_vertices) |old| self.allocator.free(old);
        self.opaque_vertex_count = @intCast(opaque_count);
        self.water_vertex_offset = opaque_count * @sizeOf(Vertex);
        self.water_vertex_count = @intCast(water_count);
        self.pending_vertices = pending;
        self.canonical_empty_coverage = false;
    }

    fn addNearSourceColumn(self: *LODMesh, vertices: *std.ArrayListUnmanaged(Vertex), water_vertices: *std.ArrayListUnmanaged(Vertex), data: *const LODSimplifiedData, gx: u32, gz: u32, atlas: *const TextureAtlas, world_x: i32, world_z: i32) !void {
        const wx: f32 = @floatFromInt(gx);
        const wz: f32 = @floatFromInt(gz);
        const idx = gx + gz * data.width;
        var spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]NearColumnSpan = undefined;
        const count = collectNearSolidSpans(data, gx, gz, &spans);
        const neighbors = [_]struct { x: i32, z: i32, dir: geom.FaceDir }{
            .{ .x = @as(i32, @intCast(gx)) - 1, .z = @intCast(gz), .dir = .west },
            .{ .x = @as(i32, @intCast(gx)) + 1, .z = @intCast(gz), .dir = .east },
            .{ .x = @intCast(gx), .z = @as(i32, @intCast(gz)) - 1, .dir = .north },
            .{ .x = @intCast(gx), .z = @as(i32, @intCast(gz)) + 1, .dir = .south },
        };
        for (spans[0..count], 0..) |span, span_index| {
            const vertex_start = vertices.items.len;
            const terrain = span_index == 0 and data.material_layers[idx].surface != .air;
            const top_tile = getLodTopTile(span.block, atlas);
            const side_tile = getLodSideTile(span.block, atlas);
            const atlas_bottom_tile = atlas.getTilesForBlock(@intFromEnum(span.block)).bottom;
            const bottom_tile = if (isLeafBlock(span.block) or atlas_bottom_tile == 0) Vertex.LOD_TILE_ID else atlas_bottom_tile;
            // AO is encoded in metadata below, not baked into albedo as well.
            const top_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .top, getLodTopColor(span.block, top_tile, span.color)), span.block, .top, atlas);
            const side_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .side, span.color), span.block, .side, atlas);
            const bottom_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .bottom, span.color), span.block, .bottom, atlas);
            var covered_top = false;
            var covered_bottom = terrain or span.min_height <= 0;
            for (spans[0..count], 0..) |other, other_index| {
                if (other_index == span_index) continue;
                const other_wins_tie = (other_index == 0 and data.material_layers[idx].surface != .air) or
                    (isLeafBlock(span.block) and !isLeafBlock(other.block)) or
                    (isLeafBlock(span.block) == isLeafBlock(other.block) and other_index < span_index);
                covered_top = covered_top or (other.min_height <= span.max_height and other.max_height > span.max_height) or
                    (other_wins_tie and other.max_height == span.max_height and other.min_height < span.max_height);
                covered_bottom = covered_bottom or (other.min_height < span.min_height and other.max_height >= span.min_height) or
                    (other_wins_tie and other.min_height == span.min_height and other.max_height > span.min_height);
            }
            if (!covered_top) try addTopFaceQuad(self.allocator, vertices, wx, span.max_height, wz, 1, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
            if (!covered_bottom) try addBottomFaceQuad(self.allocator, vertices, wx, span.min_height, wz, 1, unpackR(bottom_color) * 0.5, unpackG(bottom_color) * 0.5, unpackB(bottom_color) * 0.5, bottom_tile, world_x, world_z);

            for (neighbors) |neighbor| {
                // The positive edge is a real sample, even when still advisory;
                // it is excluded from emitted cells, not neighbor heights.
                const in_bounds = neighbor.x >= 0 and neighbor.z >= 0 and neighbor.x < data.width and neighbor.z < data.width;
                var neighbor_height: ?f32 = null;
                var neighbor_spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]NearColumnSpan = undefined;
                var neighbor_count: usize = 0;
                if (in_bounds) {
                    const nx: u32 = @intCast(neighbor.x);
                    const nz: u32 = @intCast(neighbor.z);
                    if (data.getColumnProvenance(nx, nz) != .worldgen) {
                        const ni = nx + nz * data.width;
                        neighbor_height = if (data.material_layers[ni].surface == .air) 0 else data.heightmap[ni];
                        neighbor_count = collectNearSolidSpans(data, nx, nz, &neighbor_spans);
                    } else {
                        neighbor_height = geom.quantizedVisualColumnHeightForLOD(data, nx, nz, self.lod_level);
                    }
                }
                if (terrain) {
                    // Source layers have no thicknesses; retain the surface
                    // material on cliffs rather than inventing layer depths.
                    // Without a negative-edge apron, cover only the one-block
                    // top-face handoff mismatch, never a deep cross-section.
                    const bottom = neighbor_height orelse @max(0, span.max_height - 1);
                    try geom.addHeightfieldSide(self.allocator, vertices, wx, wz, 1, span.max_height, bottom, side_color, side_tile, neighbor.dir, world_x, world_z);
                    continue;
                }
                var exposed: [world_core.MAX_LOD_VERTICAL_SPANS + 1]geom.HeightInterval = undefined;
                var exposed_count: usize = 1;
                exposed[0] = .{ .min_height = span.min_height, .max_height = span.max_height };
                // Envelopes can overlap within one column. Ground and logs
                // take precedence over leaves to avoid coplanar side faces.
                for (spans[0..count], 0..) |other, other_index| {
                    if (other_index == span_index) continue;
                    const other_terrain = other_index == 0 and data.material_layers[idx].surface != .air;
                    if (other_terrain or (isLeafBlock(span.block) and !isLeafBlock(other.block))) {
                        geom.subtractCoveredInterval(&exposed, &exposed_count, other.min_height, other.max_height);
                    }
                }
                if (neighbor_height) |height| geom.subtractCoveredInterval(&exposed, &exposed_count, 0, height);
                for (neighbor_spans[0..neighbor_count]) |other| {
                    geom.subtractCoveredInterval(&exposed, &exposed_count, other.min_height, other.max_height);
                }
                const brightness = geom.heightfieldSideBrightness(neighbor.dir);
                for (exposed[0..exposed_count]) |interval| {
                    try addSideFaceQuad(self.allocator, vertices, wx, interval.max_height, wz, 1, interval.min_height, unpackR(side_color) * brightness, unpackG(side_color) * brightness, unpackB(side_color) * brightness, neighbor.dir, side_tile, world_x, world_z);
                }
            }
            applyNearLighting(vertices.items[vertex_start..], span.lighting);
        }
        const water = data.water[idx];
        if (water.is_surface and water.coverage > 0 and (data.material_layers[idx].surface == .air or water.surface_height > data.heightmap[idx])) {
            const vertex_start = water_vertices.items.len;
            const color = tintColorForLodFace(data, gx, gz, self.lod_level, .water, .top, packBlockDefaultColor(.water, 0x3366CC));
            try addTopFaceQuad(self.allocator, water_vertices, wx, water.surface_height, wz, 1, unpackR(color), unpackG(color), unpackB(color), getLodTopTile(.water, atlas), world_x, world_z);
            applyNearLighting(water_vertices.items[vertex_start..], data.lighting[idx]);
        }
    }

    /// Build mesh from rich LOD column/span data, falling back to the stable heightfield path
    /// when spans are not available. This is intentionally exposed as a test/config hook.
    pub fn buildFromColumnSpans(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        if (data.scene_grid) |grid| return self.buildFromSceneGrid(grid, atlas);
        if (data.width < 2) return error.EmptyData;
        if (!canBuildColumnSpans(data)) return self.buildFromSimplifiedData(data, world_x, world_z, atlas);

        const region_size: f32 = @floatFromInt(lod_chunk.regionSizeBlocks(self.lod_level));
        const cell_size = region_size / @as(f32, @floatFromInt(data.width - 1));

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);
        var water_vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer water_vertices.deinit(self.allocator);

        var found_span = false;
        var gz: u32 = 0;
        while (gz + 1 < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx + 1 < data.width) : (gx += 1) {
                var spans_buf: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
                const span_count = collectColumnSpans(data, gx, gz, self.lod_level, &spans_buf);
                if (span_count == 0) continue;
                found_span = true;

                const wx = @as(f32, @floatFromInt(gx)) * cell_size;
                const wz = @as(f32, @floatFromInt(gz)) * cell_size;

                var span_index: usize = 0;
                while (span_index < span_count) : (span_index += 1) {
                    const span = spans_buf[span_index];
                    const top_tile = getLodTopTile(span.block, atlas);
                    const side_tile = getLodSideTile(span.block, atlas);
                    const span_color = applyColorBrightness(span.color, span.ambient_occlusion);
                    const lit_color = if (span.block == .water)
                        tintColorForLodFace(data, gx, gz, self.lod_level, .water, .side, span_color)
                    else
                        applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .side, span_color), span.block, .side, atlas);
                    const top_color = if (span.block == .water)
                        tintColorForLodFace(data, gx, gz, self.lod_level, .water, .top, packBlockDefaultColor(.water, 0x3366CC))
                    else
                        getLodTopColor(span.block, top_tile, applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .top, span_color), span.block, .top, atlas));

                    if (span.block == .water) {
                        const water_height = quantizedWaterSurfaceHeightForSpan(data, gx, gz, self.lod_level, span.max_height);
                        try addTopFaceQuad(self.allocator, &water_vertices, wx, water_height, wz, cell_size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                        continue;
                    }

                    if (isLeafBlock(span.block)) {
                        const tree_is_water_cell = isLODWaterCellForLOD(data, gx, gz, self.lod_level);
                        if (tree_is_water_cell) continue;
                        var vegetation = representativeVegetationForLOD(data, gx, gz, self.lod_level);
                        if (vegetation.leaves == .air) vegetation.leaves = span.block;
                        if (vegetation.tree_coverage < LOD_TREE_COVERAGE_THRESHOLD) vegetation.tree_coverage = LOD_TREE_COVERAGE_THRESHOLD;
                        if (vegetation.avg_tree_height < 2.0) vegetation.avg_tree_height = @max(2.0, span.max_height - span.min_height);
                        const tree_base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, self.lod_level, tree_is_water_cell);
                        try addTreeCanopyColumn(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, cell_size, tree_base_height, span.min_height, span.max_height, vegetation, atlas, world_x, world_z);
                        continue;
                    }

                    try addTopFaceQuad(self.allocator, &vertices, wx, span.max_height, wz, cell_size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                    try addExposedSpanFaces(self.allocator, &vertices, data, gx, gz, self.lod_level, span, wx, wz, cell_size, lit_color, side_tile, world_x, world_z);

                    // Floating span (overhang): there is open air below this
                    // span's floor, so add a downward-facing bottom quad.
                    const supported_from_below = if (span_index == 0)
                        span.min_height <= 0.01
                    else
                        spans_buf[span_index - 1].max_height >= span.min_height - 0.01;
                    if (!supported_from_below) {
                        try addBottomFaceQuad(self.allocator, &vertices, wx, span.min_height, wz, cell_size, unpackR(lit_color) * 0.5, unpackG(lit_color) * 0.5, unpackB(lit_color) * 0.5, side_tile, world_x, world_z);
                    }
                }
            }
        }

        if (!found_span) return self.buildFromSimplifiedData(data, world_x, world_z, atlas);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        const opaque_count = vertices.items.len;
        const water_count = water_vertices.items.len;
        const total_count = opaque_count + water_count;
        self.opaque_vertex_count = @intCast(opaque_count);
        self.canonical_empty_coverage = false;
        self.water_vertex_offset = opaque_count * @sizeOf(Vertex);
        self.water_vertex_count = @intCast(water_count);

        if (total_count > 0) {
            const pending = try self.allocator.alloc(Vertex, total_count);
            @memcpy(pending[0..opaque_count], vertices.items);
            @memcpy(pending[opaque_count..total_count], water_vertices.items);
            self.pending_vertices = pending;
        } else {
            self.pending_vertices = null;
        }
    }

    /// Build mesh from simplified LOD data using QEM decimation.
    /// Generates a full-detail heightmap mesh first, then simplifies via quadric error metrics.
    /// Falls back to naive `buildFromSimplifiedData` if QEM input is too small or fails.
    pub fn buildFromSimplifiedDataWithQEM(
        self: *LODMesh,
        data: *const LODSimplifiedData,
        world_x: i32,
        world_z: i32,
        target_triangles: u32,
        min_input_triangles: u32,
        atlas: *const TextureAtlas,
    ) !void {
        if (data.scene_grid) |grid| return self.buildFromSceneGrid(grid, atlas);
        const full_mesh = buildFullDetailHeightmapMesh(self.allocator, self.lod_level, data, world_x, world_z, atlas) catch |err| {
            log.log.warn("LOD{} full-detail mesh build failed, falling back: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
        defer {
            self.allocator.free(full_mesh.vertices);
            self.allocator.free(full_mesh.indices);
        }

        if (full_mesh.indices.len % 3 != 0) {
            log.log.warn("LOD{} mesh has invalid index count {}, falling back", .{ @intFromEnum(self.lod_level), full_mesh.indices.len });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }
        const input_triangles: u32 = @intCast(full_mesh.indices.len / 3);
        if (input_triangles < min_input_triangles) {
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }

        // No simplification needed — target already meets or exceeds input
        if (target_triangles >= input_triangles) {
            try self.setPendingFromIndexed(full_mesh.vertices, full_mesh.indices);
            return;
        }
        const effective_target = target_triangles;

        const simplified = QuadricSimplifier.simplify(
            self.allocator,
            full_mesh.vertices,
            full_mesh.indices,
            effective_target,
        ) catch |err| {
            log.log.warn("LOD{} QEM simplification failed, falling back to naive: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
        defer {
            self.allocator.free(simplified.vertices);
            self.allocator.free(simplified.indices);
        }

        if (simplified.indices.len == 0) {
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }

        log.log.trace("LOD{} QEM: {} -> {} triangles (error={d:.2})", .{
            @intFromEnum(self.lod_level),
            simplified.original_triangle_count,
            simplified.simplified_triangle_count,
            simplified.error_estimate,
        });

        self.setPendingFromIndexed(simplified.vertices, simplified.indices) catch |err| {
            log.log.warn("LOD{} failed to expand simplified mesh, falling back: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
    }

    /// Convert indexed triangle mesh to non-indexed vertex list and store as pending.
    fn setPendingFromIndexed(self: *LODMesh, vertices: []const Vertex, indices: []const u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;

        self.canonical_empty_coverage = false;
        if (indices.len == 0) return;

        const expanded = try self.allocator.alloc(Vertex, indices.len);
        errdefer self.allocator.free(expanded);
        for (expanded, 0..) |*dst, i| {
            const idx = indices[i];
            if (idx >= vertices.len) return error.InvalidIndex;
            dst.* = vertices[idx];
        }
        self.pending_vertices = expanded;
        self.opaque_vertex_count = @intCast(expanded.len);
        self.water_vertex_offset = expanded.len * @sizeOf(Vertex);
        self.water_vertex_count = 0;
    }

    /// Build mesh from full chunk heightmap data
    pub fn buildFromHeightmap(
        self: *LODMesh,
        heightmap: []const f32,
        biomes: []const BiomeId,
        width: u32,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        const cell_size = getCellSize(self.lod_level);

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);

        var gz: u32 = 0;
        while (gz < width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx < width) : (gx += 1) {
                const idx = gx + gz * width;
                const height = heightmap[idx];
                const biome = biomes[idx];
                const surface_block = biome.getSurfaceBlock();
                const color = applyTextureLuminance(biome_mod.getBiomeColor(biome), surface_block, .top, atlas);
                const side_color = applyTextureLuminance(biome_mod.getBiomeColor(biome), surface_block, .side, atlas);

                const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
                const sr: f32 = @as(f32, @floatFromInt((side_color >> 16) & 0xFF)) / 255.0;
                const sg: f32 = @as(f32, @floatFromInt((side_color >> 8) & 0xFF)) / 255.0;
                const sb: f32 = @as(f32, @floatFromInt(side_color & 0xFF)) / 255.0;

                const wx: f32 = @floatFromInt(gx * cell_size);
                const wz: f32 = @floatFromInt(gz * cell_size);
                const wy: f32 = height;
                const size: f32 = @floatFromInt(cell_size);

                const tiles = atlas.getTilesForBlock(@intFromEnum(surface_block));

                try addTopFaceQuad(self.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                // Add skirts
                const skirt_depth = size * 4.0;
                if (gx == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.6, sg * 0.6, sb * 0.6, .west, tiles.side, world_x, world_z);
                }
                if (gx == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.6, sg * 0.6, sb * 0.6, .east, tiles.side, world_x, world_z);
                }
                if (gz == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.7, sg * 0.7, sb * 0.7, .north, tiles.side, world_x, world_z);
                }
                if (gz == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.7, sg * 0.7, sb * 0.7, .south, tiles.side, world_x, world_z);
                }

                // Side faces for height differences
                if (gx > 0) {
                    const nh = heightmap[(gx - 1) + gz * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, sr * 0.7, sg * 0.7, sb * 0.7, .west, tiles.side, world_x, world_z);
                    }
                }
                if (gz > 0) {
                    const nh = heightmap[gx + (gz - 1) * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, sr * 0.8, sg * 0.8, sb * 0.8, .north, tiles.side, world_x, world_z);
                    }
                }
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        self.canonical_empty_coverage = false;
        if (vertices.items.len > 0) {
            self.pending_vertices = try self.allocator.dupe(Vertex, vertices.items);
            self.opaque_vertex_count = @intCast(vertices.items.len);
            self.water_vertex_offset = self.opaque_vertex_count * @sizeOf(Vertex);
            self.water_vertex_count = 0;
        } else {
            self.pending_vertices = null;
            self.opaque_vertex_count = 0;
            self.water_vertex_offset = 0;
            self.water_vertex_count = 0;
        }
    }

    /// Upload pending vertices to GPU
    pub fn upload(self: *LODMesh, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pooled) return error.InvalidState;

        const pending = self.pending_vertices orelse {
            self.ready = self.ready or self.buffer_handle != 0;
            return;
        };

        if (pending.len == 0) {
            if (self.buffer_handle != 0 and !self.pooled) {
                resources.destroyBuffer(self.buffer_handle);
            }
            self.buffer_handle = 0;
            self.vertex_count = 0;
            self.opaque_vertex_count = 0;
            self.water_vertex_offset = 0;
            self.water_vertex_count = 0;
            self.capacity = 0;
            self.vertex_offset = 0;
            self.pooled = false;
            self.allocator.free(pending);
            self.pending_vertices = null;
            self.ready = true;
            return;
        }

        const data_size = pending.len * @sizeOf(Vertex);
        const needed_capacity = @max(1024, std.math.ceilPowerOfTwo(usize, data_size) catch data_size);

        var upload_handle = self.buffer_handle;
        var new_handle: BufferHandle = 0;

        // Create or resize buffer. Keep the old buffer renderable until the
        // replacement upload succeeds, then retire it through the RHI.
        if (self.buffer_handle == 0 or needed_capacity > self.capacity * @sizeOf(Vertex)) {
            new_handle = try resources.createBuffer(needed_capacity, .vertex);
            upload_handle = new_handle;
        }
        errdefer if (new_handle != 0) resources.destroyBuffer(new_handle);

        // Upload data
        try uploadBufferChunked(resources, upload_handle, std.mem.sliceAsBytes(pending));
        if (new_handle != 0) {
            const old_handle = self.buffer_handle;
            self.buffer_handle = new_handle;
            self.capacity = @intCast(needed_capacity / @sizeOf(Vertex));
            self.vertex_offset = 0;
            self.pooled = false;
            if (old_handle != 0 and !self.pooled) {
                resources.destroyBuffer(old_handle);
            }
        }
        self.vertex_count = @intCast(pending.len);
        if (self.opaque_vertex_count == 0 and self.water_vertex_count == 0) {
            self.opaque_vertex_count = self.vertex_count;
        }

        self.allocator.free(pending);
        self.pending_vertices = null;
        self.ready = true;
    }

    /// Draw the LOD mesh
    pub fn draw(self: *const LODMesh, render_ctx: LODMeshRenderContext) void {
        if (!self.ready or self.buffer_handle == 0 or self.vertex_count == 0) return;
        render_ctx.drawOffset(self.buffer_handle, self.vertex_count, .triangles, self.vertex_offset);
    }
};

test "chunk-derived span sources use the stable heightfield fallback" {
    var data = try LODSimplifiedData.initWithVerticalSpans(std.testing.allocator, .lod2);
    defer data.deinit();

    try std.testing.expect(canBuildColumnSpans(&data));
    data.setColumnProvenance(0, 0, .chunk_derived);
    try std.testing.expect(!canBuildColumnSpans(&data));
}

test {
    _ = @import("lod_near_mesh_tests.zig");
}

/// LOD Mesh Builder - builds meshes for LOD regions
pub const LODMeshBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LODMeshBuilder {
        return .{ .allocator = allocator };
    }

    /// Build LOD1 mesh from 2x2 chunk heightmaps
    pub fn buildLOD1(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        heightmaps: [4][]const f32, // NW, NE, SW, SE chunks
        biomes: [4][]const BiomeId,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        const chunk_size: u32 = 16;
        const cell_size: u32 = 2; // LOD1 = 2x scale
        const grid_per_chunk = chunk_size / cell_size; // 8 cells per chunk

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(mesh.allocator);

        // Process each of the 4 chunks
        const chunk_offsets = [4][2]i32{
            .{ 0, 0 }, // NW
            .{ 16, 0 }, // NE
            .{ 0, 16 }, // SW
            .{ 16, 16 }, // SE
        };

        for (chunk_offsets, 0..) |offset, chunk_idx| {
            const heightmap = heightmaps[chunk_idx];
            const biome_data = biomes[chunk_idx];

            var gz: u32 = 0;
            while (gz < grid_per_chunk) : (gz += 1) {
                var gx: u32 = 0;
                while (gx < grid_per_chunk) : (gx += 1) {
                    // Sample center of each cell
                    const sample_x = gx * cell_size + cell_size / 2;
                    const sample_z = gz * cell_size + cell_size / 2;
                    const idx = sample_x + sample_z * chunk_size;

                    if (idx >= heightmap.len) continue;

                    const height = heightmap[idx];
                    const biome = biome_data[idx];
                    const color = biome_mod.getBiomeColor(biome);
                    const tiles = atlas.getTilesForBlock(@intFromEnum(biome.getSurfaceBlock()));

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset[0] + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset[1] + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, tiles.side, world_x, world_z);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, tiles.side, world_x, world_z);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, tiles.side, world_x, world_z);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, tiles.side, world_x, world_z);
                }
            }
        }

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        if (mesh.pending_vertices) |p| {
            mesh.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            mesh.pending_vertices = try mesh.allocator.dupe(Vertex, vertices.items);
        } else {
            mesh.pending_vertices = null;
        }
    }

    /// Build LOD2 mesh from 4x4 chunk heightmaps
    pub fn buildLOD2(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        heightmaps: [16][]const f32,
        biomes_data: [16][]const BiomeId,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        const chunk_size: u32 = 16;
        const cell_size: u32 = 4; // LOD2 = 4x scale
        const grid_per_chunk = chunk_size / cell_size; // 4 cells per chunk

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(mesh.allocator);

        // 4x4 grid of chunks
        for (0..16) |chunk_idx| {
            const cx: i32 = @intCast(chunk_idx % 4);
            const cz: i32 = @intCast(chunk_idx / 4);
            const offset_x = cx * @as(i32, chunk_size);
            const offset_z = cz * @as(i32, chunk_size);

            const heightmap = heightmaps[chunk_idx];
            const biome_data = biomes_data[chunk_idx];

            var gz: u32 = 0;
            while (gz < grid_per_chunk) : (gz += 1) {
                var gx: u32 = 0;
                while (gx < grid_per_chunk) : (gx += 1) {
                    const sample_x = gx * cell_size + cell_size / 2;
                    const sample_z = gz * cell_size + cell_size / 2;
                    const idx = sample_x + sample_z * chunk_size;

                    if (idx >= heightmap.len) continue;

                    const height = heightmap[idx];
                    const biome = biome_data[idx];
                    const color = biome_mod.getBiomeColor(biome);
                    const tiles = atlas.getTilesForBlock(@intFromEnum(biome.getSurfaceBlock()));

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset_x + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset_z + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, tiles.side, world_x, world_z);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, tiles.side, world_x, world_z);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, tiles.side, world_x, world_z);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, tiles.side, world_x, world_z);
                }
            }
        }

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        if (mesh.pending_vertices) |p| {
            mesh.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            mesh.pending_vertices = try mesh.allocator.dupe(Vertex, vertices.items);
        } else {
            mesh.pending_vertices = null;
        }
    }

    /// Build LOD3 mesh from simplified heightmap data
    pub fn buildLOD3(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        data: *const LODSimplifiedData,
        region_world_x: i32,
        region_world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        try mesh.buildFromSimplifiedData(data, region_world_x, region_world_z, atlas);
    }
};
