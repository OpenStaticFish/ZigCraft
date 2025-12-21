//! Chunk mesh generation with Greedy Meshing and Subchunks.

const std = @import("std");
const c = @import("../c.zig").c;

const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("block.zig").BlockType;
const Face = @import("block.zig").Face;
const ALL_FACES = @import("block.zig").ALL_FACES;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;

pub const SUBCHUNK_SIZE = 16;
pub const NUM_SUBCHUNKS = 16;

pub const Pass = enum {
    solid,
    fluid,
};

pub const NeighborChunks = struct {
    north: ?*const Chunk = null,
    south: ?*const Chunk = null,
    east: ?*const Chunk = null,
    west: ?*const Chunk = null,

    pub const empty = NeighborChunks{
        .north = null,
        .south = null,
        .east = null,
        .west = null,
    };
};

pub const SubChunkMesh = struct {
    vao_solid: c.GLuint = 0,
    vbo_solid: c.GLuint = 0,
    count_solid: u32 = 0,

    vao_fluid: c.GLuint = 0,
    vbo_fluid: c.GLuint = 0,
    count_fluid: u32 = 0,

    ready: bool = false,

    pub fn deinit(self: *SubChunkMesh) void {
        if (self.vao_solid != 0) c.glDeleteVertexArrays().?(1, &self.vao_solid);
        if (self.vbo_solid != 0) c.glDeleteBuffers().?(1, &self.vbo_solid);
        if (self.vao_fluid != 0) c.glDeleteVertexArrays().?(1, &self.vao_fluid);
        if (self.vbo_fluid != 0) c.glDeleteBuffers().?(1, &self.vbo_fluid);
    }
};

pub const ChunkMesh = struct {
    subchunks: [NUM_SUBCHUNKS]SubChunkMesh,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pending_solid: [NUM_SUBCHUNKS]?[]f32,
    pending_fluid: [NUM_SUBCHUNKS]?[]f32,

    pub fn init(allocator: std.mem.Allocator) ChunkMesh {
        var self: ChunkMesh = .{
            .subchunks = undefined,
            .allocator = allocator,
            .mutex = .{},
            .pending_solid = [_]?[]f32{null} ** NUM_SUBCHUNKS,
            .pending_fluid = [_]?[]f32{null} ** NUM_SUBCHUNKS,
        };
        for (0..NUM_SUBCHUNKS) |i| {
            self.subchunks[i] = .{
                .vao_solid = 0,
                .vbo_solid = 0,
                .count_solid = 0,
                .vao_fluid = 0,
                .vbo_fluid = 0,
                .count_fluid = 0,
                .ready = false,
            };
        }
        return self;
    }

    pub fn deinit(self: *ChunkMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..NUM_SUBCHUNKS) |i| {
            self.subchunks[i].deinit();
            if (self.pending_solid[i]) |p| self.allocator.free(p);
            if (self.pending_fluid[i]) |p| self.allocator.free(p);
        }
    }

    pub fn buildWithNeighbors(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks) !void {
        for (0..NUM_SUBCHUNKS) |i| {
            try self.buildSubchunk(chunk, neighbors, @intCast(i));
        }
    }

    fn buildSubchunk(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, si: u32) !void {
        var solid_verts = std.ArrayListUnmanaged(f32).empty;
        defer solid_verts.deinit(self.allocator);
        var fluid_verts = std.ArrayListUnmanaged(f32).empty;
        defer fluid_verts.deinit(self.allocator);

        const y0: i32 = @intCast(si * SUBCHUNK_SIZE);
        const y1: i32 = y0 + SUBCHUNK_SIZE;
        // Meshes now use chunk-local coordinates (0-16 range)
        // World offset is applied at render time via model matrix for floating origin

        var sy: i32 = y0;
        while (sy <= y1) : (sy += 1) {
            try self.meshSlice(chunk, neighbors, .top, sy, si, &solid_verts, &fluid_verts);
        }
        var sx: i32 = 0;
        while (sx <= CHUNK_SIZE_X) : (sx += 1) {
            try self.meshSlice(chunk, neighbors, .east, sx, si, &solid_verts, &fluid_verts);
        }
        var sz: i32 = 0;
        while (sz <= CHUNK_SIZE_Z) : (sz += 1) {
            try self.meshSlice(chunk, neighbors, .south, sz, si, &solid_verts, &fluid_verts);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_solid[si]) |p| self.allocator.free(p);
        if (self.pending_fluid[si]) |p| self.allocator.free(p);
        self.pending_solid[si] = if (solid_verts.items.len > 0) try self.allocator.dupe(f32, solid_verts.items) else null;
        self.pending_fluid[si] = if (fluid_verts.items.len > 0) try self.allocator.dupe(f32, fluid_verts.items) else null;
    }

    const FaceKey = struct {
        block: BlockType,
        side: bool,
    };

    fn meshSlice(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, si: u32, solid_list: *std.ArrayListUnmanaged(f32), fluid_list: *std.ArrayListUnmanaged(f32)) !void {
        const du: u32 = 16;
        const dv: u32 = 16;
        var mask = try self.allocator.alloc(?FaceKey, du * dv);
        defer self.allocator.free(mask);
        @memset(mask, null);

        var v: u32 = 0;
        while (v < dv) : (v += 1) {
            var u: u32 = 0;
            while (u < du) : (u += 1) {
                const res = getBlocksAtBoundary(chunk, neighbors, axis, s, u, v, si);
                const b1 = res[0];
                const b2 = res[1];

                const y_min: i32 = @intCast(si * SUBCHUNK_SIZE);
                const y_max: i32 = y_min + SUBCHUNK_SIZE;

                // Check if b1 should emit a face (solid blocks OR water facing non-water)
                const b1_emits = b1.isSolid() or (b1 == .water and b2 != .water);
                const b2_emits = b2.isSolid() or (b2 == .water and b1 != .water);

                if (isEmittingSubchunk(axis, s - 1, u, v, y_min, y_max) and b1_emits and !b2.occludes(b1, axis)) {
                    mask[u + v * du] = .{ .block = b1, .side = true };
                } else if (isEmittingSubchunk(axis, s, u, v, y_min, y_max) and b2_emits and !b1.occludes(b2, axis)) {
                    mask[u + v * du] = .{ .block = b2, .side = false };
                }
            }
        }

        var sv: u32 = 0;
        while (sv < dv) : (sv += 1) {
            var su: u32 = 0;
            while (su < du) : (su += 1) {
                const k_opt = mask[su + sv * du];
                if (k_opt == null) continue;
                const k = k_opt.?;

                var width: u32 = 1;
                while (su + width < du) : (width += 1) {
                    const nxt_opt = mask[su + width + sv * du];
                    if (nxt_opt == null) break;
                    const nxt = nxt_opt.?;
                    if (nxt.block != k.block or nxt.side != k.side) break;
                }
                var height: u32 = 1;
                var dvh: u32 = 1;
                outer: while (sv + dvh < dv) : (dvh += 1) {
                    var duw: u32 = 0;
                    while (duw < width) : (duw += 1) {
                        const nxt_opt = mask[su + duw + (sv + dvh) * du];
                        if (nxt_opt == null) break :outer;
                        const nxt = nxt_opt.?;
                        if (nxt.block != k.block or nxt.side != k.side) break :outer;
                    }
                    height += 1;
                }

                const target = if (k.block.isTransparent() and k.block != .leaves) fluid_list else solid_list;
                try addGreedyFace(self.allocator, target, axis, s, su, sv, width, height, k.block, k.side, si);

                var dy: u32 = 0;
                while (dy < height) : (dy += 1) {
                    var dx: u32 = 0;
                    while (dx < width) : (dx += 1) {
                        mask[su + dx + (sv + dy) * du] = null;
                    }
                }
                su += width - 1;
            }
        }
    }

    pub fn upload(self: *ChunkMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..NUM_SUBCHUNKS) |si| {
            if (self.pending_solid[si]) |v| {
                setupBuffers(&self.subchunks[si].vao_solid, &self.subchunks[si].vbo_solid, v);
                self.subchunks[si].count_solid = @intCast(v.len / 12);
                self.allocator.free(v);
                self.pending_solid[si] = null;
                self.subchunks[si].ready = true;
            }
            if (self.pending_fluid[si]) |v| {
                setupBuffers(&self.subchunks[si].vao_fluid, &self.subchunks[si].vbo_fluid, v);
                self.subchunks[si].count_fluid = @intCast(v.len / 12);
                self.allocator.free(v);
                self.pending_fluid[si] = null;
                self.subchunks[si].ready = true;
            }
        }
    }

    pub fn draw(self: *const ChunkMesh, pass: Pass) void {
        for (self.subchunks) |s| {
            if (!s.ready) continue;
            if (pass == .solid and s.count_solid > 0) {
                c.glBindVertexArray().?(s.vao_solid);
                c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(s.count_solid));
            } else if (pass == .fluid and s.count_fluid > 0) {
                c.glBindVertexArray().?(s.vao_fluid);
                c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(s.count_fluid));
            }
        }
    }
};

fn isEmittingSubchunk(axis: Face, s: i32, u: u32, v: u32, y_min: i32, y_max: i32) bool {
    const y: i32 = switch (axis) {
        .top => s,
        .east => @as(i32, @intCast(u)) + y_min,
        .south => @as(i32, @intCast(v)) + y_min,
        else => unreachable,
    };
    return y >= y_min and y < y_max;
}

fn getBlocksAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32) [2]BlockType {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => .{ chunk.getBlockSafe(@intCast(u), s - 1, @intCast(v)), chunk.getBlockSafe(@intCast(u), s, @intCast(v)) },
        .east => .{
            getBlockCross(chunk, neighbors, s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
            getBlockCross(chunk, neighbors, s, y_off + @as(i32, @intCast(u)), @intCast(v)),
        },
        .south => .{
            getBlockCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s - 1),
            getBlockCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s),
        },
        else => unreachable,
    };
}

fn getBlockCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) BlockType {
    if (x < 0) return if (neighbors.west) |w| w.getBlockSafe(CHUNK_SIZE_X - 1, y, z) else .air;
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getBlockSafe(0, y, z) else .air;
    if (z < 0) return if (neighbors.north) |n| n.getBlockSafe(x, y, CHUNK_SIZE_Z - 1) else .air;
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getBlockSafe(x, y, 0) else .air;
    return chunk.getBlockSafe(x, y, z);
}

fn addGreedyFace(allocator: std.mem.Allocator, verts: *std.ArrayListUnmanaged(f32), axis: Face, s: i32, u: u32, v: u32, w: u32, h: u32, block: BlockType, forward: bool, si: u32) !void {
    const face = if (forward) axis else switch (axis) {
        .top => Face.bottom,
        .east => Face.west,
        .south => Face.north,
        else => unreachable,
    };
    const col = block.getFaceColor(face);
    const norm = face.getNormal();
    const nf = [3]f32{ @floatFromInt(norm[0]), @floatFromInt(norm[1]), @floatFromInt(norm[2]) };
    const tiles = TextureAtlas.getTilesForBlock(@intFromEnum(block));
    const tid: f32 = @floatFromInt(switch (face) {
        .top => tiles.top,
        .bottom => tiles.bottom,
        else => tiles.side,
    });
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const sf: f32 = @floatFromInt(s);
    const uf: f32 = @floatFromInt(u);
    const vf: f32 = @floatFromInt(v);
    // Use chunk-local coordinates (0-16 range) for floating origin rendering
    var p: [4][3]f32 = undefined;
    var uv: [4][2]f32 = undefined;
    if (axis == .top) {
        const y = sf;
        if (forward) {
            p[0] = .{ uf, y, vf + hf };
            p[1] = .{ uf + wf, y, vf + hf };
            p[2] = .{ uf + wf, y, vf };
            p[3] = .{ uf, y, vf };
            uv = [4][2]f32{ .{ 0, hf }, .{ wf, hf }, .{ wf, 0 }, .{ 0, 0 } };
        } else {
            p[0] = .{ uf, y, vf };
            p[1] = .{ uf + wf, y, vf };
            p[2] = .{ uf + wf, y, vf + hf };
            p[3] = .{ uf, y, vf + hf };
            uv = [4][2]f32{ .{ 0, 0 }, .{ wf, 0 }, .{ wf, hf }, .{ 0, hf } };
        }
    } else if (axis == .east) {
        const x = sf;
        const y0: f32 = @floatFromInt(si * SUBCHUNK_SIZE);
        if (forward) {
            p[0] = .{ x, y0 + uf, vf + hf };
            p[1] = .{ x, y0 + uf, vf };
            p[2] = .{ x, y0 + uf + wf, vf };
            p[3] = .{ x, y0 + uf + wf, vf + hf };
            uv = [4][2]f32{ .{ hf, 0 }, .{ 0, 0 }, .{ 0, wf }, .{ hf, wf } };
        } else {
            p[0] = .{ x, y0 + uf, vf };
            p[1] = .{ x, y0 + uf, vf + hf };
            p[2] = .{ x, y0 + uf + wf, vf + hf };
            p[3] = .{ x, y0 + uf + wf, vf };
            uv = [4][2]f32{ .{ 0, 0 }, .{ hf, 0 }, .{ hf, wf }, .{ 0, wf } };
        }
    } else {
        const z = sf;
        const y0: f32 = @floatFromInt(si * SUBCHUNK_SIZE);
        if (forward) {
            p[0] = .{ uf, y0 + vf, z };
            p[1] = .{ uf + wf, y0 + vf, z };
            p[2] = .{ uf + wf, y0 + vf + hf, z };
            p[3] = .{ uf, y0 + vf + hf, z };
            uv = [4][2]f32{ .{ 0, 0 }, .{ wf, 0 }, .{ wf, hf }, .{ 0, hf } };
        } else {
            p[0] = .{ uf + wf, y0 + vf, z };
            p[1] = .{ uf, y0 + vf, z };
            p[2] = .{ uf, y0 + vf + hf, z };
            p[3] = .{ uf + wf, y0 + vf + hf, z };
            uv = [4][2]f32{ .{ wf, 0 }, .{ 0, 0 }, .{ 0, hf }, .{ wf, hf } };
        }
    }
    const idxs = [_]usize{ 0, 1, 2, 0, 2, 3 };
    for (idxs) |i| {
        try verts.append(allocator, p[i][0]);
        try verts.append(allocator, p[i][1]);
        try verts.append(allocator, p[i][2]);
        try verts.append(allocator, col[0]);
        try verts.append(allocator, col[1]);
        try verts.append(allocator, col[2]);
        try verts.append(allocator, nf[0]);
        try verts.append(allocator, nf[1]);
        try verts.append(allocator, nf[2]);
        try verts.append(allocator, uv[i][0]);
        try verts.append(allocator, uv[i][1]);
        try verts.append(allocator, tid);
    }
}

fn setupBuffers(vao_ptr: *c.GLuint, vbo_ptr: *c.GLuint, vertices: []const f32) void {
    if (vao_ptr.* == 0) c.glGenVertexArrays().?(1, vao_ptr);
    if (vbo_ptr.* == 0) c.glGenBuffers().?(1, vbo_ptr);
    c.glBindVertexArray().?(vao_ptr.*);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, vbo_ptr.*);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @intCast(vertices.len * @sizeOf(f32)), vertices.ptr, c.GL_STATIC_DRAW);
    const stride: c.GLsizei = 12 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 3, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glEnableVertexAttribArray().?(0);
    c.glVertexAttribPointer().?(1, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(3 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(1);
    c.glVertexAttribPointer().?(2, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(6 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(2);
    c.glVertexAttribPointer().?(3, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(9 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(3);
    c.glVertexAttribPointer().?(4, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(11 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(4);
    c.glBindVertexArray().?(0);
}
