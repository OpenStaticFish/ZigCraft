//! Chunk mesh orchestrator — coordinates meshing stages and manages GPU lifecycle.
//!
//! Vertices are built per-subchunk via the greedy mesher, then merged into
//! single solid/cutout/fluid buffers for minimal draw calls. Meshing logic is
//! delegated to modules in `meshing/`.

const std = @import("std");
const sync = @import("sync");
const log = @import("engine-core").log;

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;
const BlockType = world_core.BlockType;
const RenderShape = world_core.RenderShape;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_mod = @import("engine-rhi");
const RenderContext = rhi_mod.RenderContext;
const Vertex = rhi_mod.Vertex;
const chunk_alloc_mod = @import("chunk_allocator.zig");
const GlobalVertexAllocator = chunk_alloc_mod.GlobalVertexAllocator;
const VertexAllocation = chunk_alloc_mod.VertexAllocation;

// Meshing stage modules
const greedy_mesher = @import("meshing/greedy_mesher.zig");
const cross_mesher = @import("meshing/cross_mesher.zig");
const flat_quad_mesher = @import("meshing/flat_quad_mesher.zig");
const tall_cross_mesher = @import("meshing/tall_cross_mesher.zig");
const wall_attached_mesher = @import("meshing/wall_attached_mesher.zig");
const custom_mesh_mesher = @import("meshing/custom_mesh_mesher.zig");
const boundary = @import("meshing/boundary.zig");

const MesherPass = enum { solid, cutout };
const MesherFn = *const fn (std.mem.Allocator, *const Chunk, NeighborChunks, u32, *std.ArrayListUnmanaged(Vertex), *const TextureAtlas) anyerror!void;
const ShapeMesher = struct {
    shape: RenderShape,
    pass: MesherPass,
    mesh: MesherFn,
};

const SHAPE_MESHERS = [_]ShapeMesher{
    .{ .shape = .cross, .pass = .cutout, .mesh = cross_mesher.meshCrossBlocks },
    .{ .shape = .flat_quad, .pass = .cutout, .mesh = flat_quad_mesher.meshFlatQuadBlocks },
    .{ .shape = .tall_cross, .pass = .cutout, .mesh = tall_cross_mesher.meshTallCrossBlocks },
    .{ .shape = .wall_attached, .pass = .cutout, .mesh = wall_attached_mesher.meshWallAttachedBlocks },
    .{ .shape = .custom_mesh, .pass = .solid, .mesh = custom_mesh_mesher.meshCustomMeshBlocks },
};

// Re-export public types for external consumers
pub const NeighborChunks = boundary.NeighborChunks;
pub const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;
pub const NUM_SUBCHUNKS = boundary.NUM_SUBCHUNKS;

pub const Pass = enum {
    solid,
    cutout,
    fluid,
};

/// Merged chunk mesh with single solid/cutout/fluid buffers for minimal draw calls.
/// Subchunk data is only used during mesh building, then merged.
pub const ChunkMesh = struct {
    // Merged GPU allocations from GlobalVertexAllocator
    solid_allocation: ?VertexAllocation = null,
    cutout_allocation: ?VertexAllocation = null,
    fluid_allocation: ?VertexAllocation = null,

    ready: bool = false,

    allocator: std.mem.Allocator,
    mutex: sync.Mutex,

    // Pending merged vertex data (built on worker thread, uploaded on main thread)
    pending_solid: ?[]Vertex = null,
    pending_cutout: ?[]Vertex = null,
    pending_fluid: ?[]Vertex = null,

    // Temporary per-subchunk data during building (not stored after merge)
    subchunk_solid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_cutout: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_fluid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,

    // Diagnostic: count of vertices with tile_id == 0 (white)
    diag_tile0_count: u32 = 0,
    diag_total_verts: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ChunkMesh {
        return .{
            .allocator = allocator,
            .mutex = .{},
        };
    }

    // Must be called on main thread
    pub fn deinit(self: *ChunkMesh, allocator: *GlobalVertexAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.solid_allocation) |alloc| allocator.free(alloc);
        if (self.cutout_allocation) |alloc| allocator.free(alloc);
        if (self.fluid_allocation) |alloc| allocator.free(alloc);
        self.solid_allocation = null;
        self.cutout_allocation = null;
        self.fluid_allocation = null;

        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        for (0..NUM_SUBCHUNKS) |i| {
            if (self.subchunk_solid[i]) |p| self.allocator.free(p);
            if (self.subchunk_cutout[i]) |p| self.allocator.free(p);
            if (self.subchunk_fluid[i]) |p| self.allocator.free(p);
        }
    }

    pub fn deinitWithoutRHI(self: *ChunkMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        for (0..NUM_SUBCHUNKS) |i| {
            if (self.subchunk_solid[i]) |p| self.allocator.free(p);
            if (self.subchunk_cutout[i]) |p| self.allocator.free(p);
            if (self.subchunk_fluid[i]) |p| self.allocator.free(p);
        }
    }

    /// Build the full chunk mesh from chunk data and neighbors.
    /// Delegates greedy meshing to the meshing stage modules.
    pub fn buildWithNeighbors(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, atlas: *const TextureAtlas) !void {
        // Reusable scratch buffers owned for the whole chunk build. Previously
        // each subchunk allocated three fresh vertex ArrayLists plus the mesher
        // allocated a 256-entry mask per slice (~816 mask allocs + 48 vertex
        // list grow sequences per chunk). Pooling here collapses that to one
        // mask allocation and three vertex-list grow sequences per chunk.
        var solid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer solid_verts.deinit(self.allocator);
        var cutout_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer cutout_verts.deinit(self.allocator);
        var fluid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer fluid_verts.deinit(self.allocator);

        const mask = try self.allocator.alloc(?greedy_mesher.FaceKey, 16 * 16);
        defer self.allocator.free(mask);

        // Conservative starting points to avoid repeated growth during the
        // common chunk-build burst. These are retained only for this build; the
        // final pending buffers are committed once below.
        try solid_verts.ensureTotalCapacity(self.allocator, 8192);
        try cutout_verts.ensureTotalCapacity(self.allocator, 2048);
        try fluid_verts.ensureTotalCapacity(self.allocator, 1024);

        // Build each subchunk separately for slicing, but append all vertices
        // directly into chunk-wide buffers. This removes the old per-subchunk
        // dupes and merge pass (~96 heap ops and several large memcpys/chunk).
        for (0..NUM_SUBCHUNKS) |i| {
            try self.buildSubchunk(chunk, neighbors, @intCast(i), atlas, mask, &solid_verts, &cutout_verts, &fluid_verts);
        }

        try self.commitPendingVertices(solid_verts.items, cutout_verts.items, fluid_verts.items);
    }

    fn buildSubchunk(
        self: *ChunkMesh,
        chunk: *const Chunk,
        neighbors: NeighborChunks,
        si: u32,
        atlas: *const TextureAtlas,
        mask: []?greedy_mesher.FaceKey,
        solid_verts: *std.ArrayListUnmanaged(Vertex),
        cutout_verts: *std.ArrayListUnmanaged(Vertex),
        fluid_verts: *std.ArrayListUnmanaged(Vertex),
    ) !void {
        const y0: i32 = @intCast(si * SUBCHUNK_SIZE);
        const y1: i32 = y0 + SUBCHUNK_SIZE;

        // Mesh horizontal slices (top/bottom faces). The loop iterates 17 boundaries
        // per subchunk (sy in [y0, y1] inclusive), mirroring the sx/sz loops below.
        // This is correct, NOT an off-by-one: greedy_mesher.meshSlice uses
        // isEmittingSubchunk(.top, sy - 1, ...) to assign each boundary face to the
        // subchunk that owns the solid block, so no geometry is duplicated.
        //
        // The topmost iteration (sy = y1) is the boundary between the highest block
        // of this subchunk (y = y1 - 1) and the block above. For interior subchunks
        // that block belongs to the next subchunk; for the topmost subchunk
        // (si = NUM_SUBCHUNKS - 1) it is the world-ceiling boundary at y = CHUNK_SIZE_Y.
        // Dropping this iteration (e.g. `sy < y1`) loses the top face of the highest
        // cube in every subchunk — see chunk_mesh_tests "emits top face for cube at
        // subchunk boundary".
        var sy: i32 = y0;
        while (sy <= y1) : (sy += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .top, sy, si, solid_verts, cutout_verts, fluid_verts, atlas, mask);
        }
        // Mesh east/west face slices
        var sx: i32 = 0;
        while (sx <= CHUNK_SIZE_X) : (sx += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .east, sx, si, solid_verts, cutout_verts, fluid_verts, atlas, mask);
        }
        // Mesh south/north face slices
        var sz: i32 = 0;
        while (sz <= CHUNK_SIZE_Z) : (sz += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .south, sz, si, solid_verts, cutout_verts, fluid_verts, atlas, mask);
        }

        // Mesh non-cube shapes (plants, attached quads, and custom solid geometry)
        for (SHAPE_MESHERS) |entry| {
            _ = entry.shape;
            const verts = switch (entry.pass) {
                .solid => solid_verts,
                .cutout => cutout_verts,
            };
            try entry.mesh(self.allocator, chunk, neighbors, si, verts, atlas);
        }
    }

    /// Commit chunk-wide meshing output to pending buffers consumed by upload().
    /// Called once after all subchunks have appended into the shared lists.
    fn commitPendingVertices(self: *ChunkMesh, solid: []const Vertex, cutout: []const Vertex, fluid: []const Vertex) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free old pending data
        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        self.pending_solid = if (solid.len > 0) try self.allocator.dupe(Vertex, solid) else null;
        self.pending_cutout = if (cutout.len > 0) try self.allocator.dupe(Vertex, cutout) else null;
        self.pending_fluid = if (fluid.len > 0) try self.allocator.dupe(Vertex, fluid) else null;

        var tile0: u32 = 0;
        var total: u32 = 0;
        for ([_]?[]Vertex{ self.pending_solid, self.pending_cutout, self.pending_fluid }) |opt| {
            if (opt) |verts| {
                total += @intCast(verts.len);
                for (verts) |v| {
                    const tid: u16 = @intCast(v.packed_meta & 0xFFFF);
                    if (tid == 0) tile0 += 1;
                }
            }
        }
        self.diag_tile0_count = tile0;
        self.diag_total_verts = total;
    }

    pub fn upload(self: *ChunkMesh, allocator: *GlobalVertexAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_solid = self.solid_allocation;
        const old_cutout = self.cutout_allocation;
        const old_fluid = self.fluid_allocation;
        const had_old_allocations = old_solid != null or old_cutout != null or old_fluid != null;

        const solid_count: u32 = if (self.pending_solid) |v| @intCast(v.len) else 0;
        const cutout_count: u32 = if (self.pending_cutout) |v| @intCast(v.len) else 0;
        const fluid_count: u32 = if (self.pending_fluid) |v| @intCast(v.len) else 0;
        const total_count = solid_count + cutout_count + fluid_count;

        var new_solid: ?VertexAllocation = null;
        var new_cutout: ?VertexAllocation = null;
        var new_fluid: ?VertexAllocation = null;
        var alloc_ok = true;

        packed_upload: {
            if (total_count > 0) {
                const combined = self.allocator.alloc(Vertex, total_count) catch {
                    alloc_ok = false;
                    break :packed_upload;
                };
                defer self.allocator.free(combined);

                var offset: usize = 0;
                if (self.pending_solid) |v| {
                    @memcpy(combined[offset..][0..v.len], v);
                    offset += v.len;
                }
                if (self.pending_cutout) |v| {
                    @memcpy(combined[offset..][0..v.len], v);
                    offset += v.len;
                }
                if (self.pending_fluid) |v| {
                    @memcpy(combined[offset..][0..v.len], v);
                }

                const packed_allocs = allocator.allocatePacked(solid_count, cutout_count, fluid_count, combined) catch {
                    alloc_ok = false;
                    break :packed_upload;
                };
                new_solid = packed_allocs.solid;
                new_cutout = packed_allocs.cutout;
                new_fluid = packed_allocs.fluid;
            }
        }

        if (!alloc_ok) fallback_upload: {
            if (new_solid) |a| allocator.free(a);
            if (new_cutout) |a| allocator.free(a);
            if (new_fluid) |a| allocator.free(a);
            new_solid = null;
            new_cutout = null;
            new_fluid = null;
            alloc_ok = true;

            if (self.pending_solid) |v| {
                new_solid = allocator.allocate(v) catch {
                    alloc_ok = false;
                    break :fallback_upload;
                };
            }
            if (self.pending_cutout) |v| {
                new_cutout = allocator.allocate(v) catch {
                    alloc_ok = false;
                    break :fallback_upload;
                };
            }
            if (self.pending_fluid) |v| {
                new_fluid = allocator.allocate(v) catch {
                    alloc_ok = false;
                    break :fallback_upload;
                };
            }
        }

        if (alloc_ok) {
            if (self.pending_solid) |v| self.allocator.free(v);
            if (self.pending_cutout) |v| self.allocator.free(v);
            if (self.pending_fluid) |v| self.allocator.free(v);
            self.pending_solid = null;
            self.pending_cutout = null;
            self.pending_fluid = null;

            if (old_solid) |a| allocator.free(a);
            if (old_cutout) |a| allocator.free(a);
            if (old_fluid) |a| allocator.free(a);
            self.solid_allocation = new_solid;
            self.cutout_allocation = new_cutout;
            self.fluid_allocation = new_fluid;
            self.ready = true;
        } else {
            if (new_solid) |a| allocator.free(a);
            if (new_cutout) |a| allocator.free(a);
            if (new_fluid) |a| allocator.free(a);
            self.solid_allocation = old_solid;
            self.cutout_allocation = old_cutout;
            self.fluid_allocation = old_fluid;
            self.ready = had_old_allocations;
        }
    }

    /// Replaces all GPU allocations with externally produced vertex ranges.
    /// Used by the GPU mesher after copying compute output into the megabuffer.
    pub fn replaceAllocations(
        self: *ChunkMesh,
        allocator: *GlobalVertexAllocator,
        solid: ?VertexAllocation,
        cutout: ?VertexAllocation,
        fluid: ?VertexAllocation,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_solid = self.solid_allocation;
        const old_cutout = self.cutout_allocation;
        const old_fluid = self.fluid_allocation;

        const freeing_allocs = old_solid != null or old_cutout != null or old_fluid != null;
        const setting_allocs = solid != null or cutout != null or fluid != null;
        if (freeing_allocs and !setting_allocs) {
            log.log.warn("REPLACE_FREE: freeing allocations without replacement (underground/empty re-mesh)", .{});
        }

        self.solid_allocation = solid;
        self.cutout_allocation = cutout;
        self.fluid_allocation = fluid;
        self.ready = true;

        if (old_solid) |a| allocator.free(a);
        if (old_cutout) |a| allocator.free(a);
        if (old_fluid) |a| allocator.free(a);
    }

    /// Draw the chunk mesh with a single draw call per pass.
    pub fn draw(self: *const ChunkMesh, ctx: RenderContext, pass: Pass) void {
        if (!self.ready) return;

        switch (pass) {
            .solid => {
                if (self.solid_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .cutout => {
                if (self.cutout_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .fluid => {
                if (self.fluid_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
        }
    }
};
