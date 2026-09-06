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
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const RhiError = rhi_types.RhiError;
const QuadricSimplifier = @import("world-meshing").meshing.quadric_simplifier.QuadricSimplifier;
const log = @import("engine-core").log;

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
    /// Mutex for thread safety
    mutex: sync.Mutex = .{},
    /// LOD level
    lod_level: LODLevel,
    /// Ready for rendering
    ready: bool = false,

    pub fn init(allocator: std.mem.Allocator, lod: LODLevel) LODMesh {
        return .{
            .allocator = allocator,
            .lod_level = lod,
        };
    }

    pub fn isRenderable(self: *const LODMesh) bool {
        return self.ready and self.vertex_count > 0;
    }

    pub fn isReady(self: *const LODMesh) bool {
        return self.ready;
    }

    pub fn isPooled(self: *const LODMesh) bool {
        return self.pooled;
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
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;
    }

    pub fn markEmptyUploadedUnlocked(self: *LODMesh) void {
        self.clearDrawStateUnlocked();
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
    }

    pub fn buildCompactTile(self: *LODMesh, data: *const LODSimplifiedData) !void {
        const tile = try CompactLODTile.initFromSimplified(self.allocator, self.lod_level, data);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.compact_tile) |*old| old.deinit();
        self.compact_tile = tile;
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
