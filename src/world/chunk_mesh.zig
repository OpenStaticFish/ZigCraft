//! Chunk mesh generation with Greedy Meshing and Subchunks.

const std = @import("std");

const Chunk = @import("chunk.zig").Chunk;
const PackedLight = @import("chunk.zig").PackedLight;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("block.zig").BlockType;
const Face = @import("block.zig").Face;
const ALL_FACES = @import("block.zig").ALL_FACES;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const biome_mod = @import("worldgen/biome.zig");
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const Vertex = rhi_mod.Vertex;
const BufferHandle = rhi_mod.BufferHandle;

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
    solid_handle: BufferHandle = 0,
    count_solid: u32 = 0,
    capacity_solid: u32 = 0,

    fluid_handle: BufferHandle = 0,
    count_fluid: u32 = 0,
    capacity_fluid: u32 = 0,

    ready: bool = false,

    pub fn deinit(self: *SubChunkMesh, rhi: RHI) void {
        if (self.solid_handle != 0) rhi.destroyBuffer(self.solid_handle);
        if (self.fluid_handle != 0) rhi.destroyBuffer(self.fluid_handle);
    }
};

pub const ChunkMesh = struct {
    subchunks: [NUM_SUBCHUNKS]SubChunkMesh,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pending_solid: [NUM_SUBCHUNKS]?[]Vertex,
    pending_fluid: [NUM_SUBCHUNKS]?[]Vertex,

    pub fn init(allocator: std.mem.Allocator) ChunkMesh {
        var self: ChunkMesh = .{
            .subchunks = undefined,
            .allocator = allocator,
            .mutex = .{},
            .pending_solid = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
            .pending_fluid = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
        };
        for (0..NUM_SUBCHUNKS) |i| {
            self.subchunks[i] = .{
                .solid_handle = 0,
                .count_solid = 0,
                .capacity_solid = 0,
                .fluid_handle = 0,
                .count_fluid = 0,
                .capacity_fluid = 0,
                .ready = false,
            };
        }
        return self;
    }

    // Must be called on main thread or wherever RHI context is valid
    pub fn deinit(self: *ChunkMesh, rhi: RHI) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..NUM_SUBCHUNKS) |i| {
            self.subchunks[i].deinit(rhi);
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
        var solid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer solid_verts.deinit(self.allocator);
        var fluid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer fluid_verts.deinit(self.allocator);

        const y0: i32 = @intCast(si * SUBCHUNK_SIZE);
        const y1: i32 = y0 + SUBCHUNK_SIZE;

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
        self.pending_solid[si] = if (solid_verts.items.len > 0) try self.allocator.dupe(Vertex, solid_verts.items) else null;
        self.pending_fluid[si] = if (fluid_verts.items.len > 0) try self.allocator.dupe(Vertex, fluid_verts.items) else null;
    }

    const FaceKey = struct {
        block: BlockType,
        side: bool,
        light: PackedLight,
        color: [3]f32,
    };

    fn meshSlice(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, si: u32, solid_list: *std.ArrayListUnmanaged(Vertex), fluid_list: *std.ArrayListUnmanaged(Vertex)) !void {
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

                const b1_emits = b1.isSolid() or (b1 == .water and b2 != .water);
                const b2_emits = b2.isSolid() or (b2 == .water and b1 != .water);

                if (isEmittingSubchunk(axis, s - 1, u, v, y_min, y_max) and b1_emits and !b2.occludes(b1, axis)) {
                    const light = getLightAtBoundary(chunk, neighbors, axis, s, u, v, si);
                    const color = getBlockColor(chunk, neighbors, axis, s - 1, u, v, si, b1);
                    mask[u + v * du] = .{ .block = b1, .side = true, .light = light, .color = color };
                } else if (isEmittingSubchunk(axis, s, u, v, y_min, y_max) and b2_emits and !b1.occludes(b2, axis)) {
                    const light = getLightAtBoundary(chunk, neighbors, axis, s - 1, u, v, si);
                    const color = getBlockColor(chunk, neighbors, axis, s, u, v, si, b2);
                    mask[u + v * du] = .{ .block = b2, .side = false, .light = light, .color = color };
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
                    const sky_diff = @as(i8, @intCast(nxt.light.sky_light)) - @as(i8, @intCast(k.light.sky_light));
                    const block_diff = @as(i8, @intCast(nxt.light.block_light)) - @as(i8, @intCast(k.light.block_light));
                    if (@abs(sky_diff) > 1 or @abs(block_diff) > 1) break;

                    const diff_r = @abs(nxt.color[0] - k.color[0]);
                    const diff_g = @abs(nxt.color[1] - k.color[1]);
                    const diff_b = @abs(nxt.color[2] - k.color[2]);
                    if (diff_r > 0.02 or diff_g > 0.02 or diff_b > 0.02) break;
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
                        const sky_diff = @as(i8, @intCast(nxt.light.sky_light)) - @as(i8, @intCast(k.light.sky_light));
                        const block_diff = @as(i8, @intCast(nxt.light.block_light)) - @as(i8, @intCast(k.light.block_light));
                        if (@abs(sky_diff) > 1 or @abs(block_diff) > 1) break :outer;

                        const diff_r = @abs(nxt.color[0] - k.color[0]);
                        const diff_g = @abs(nxt.color[1] - k.color[1]);
                        const diff_b = @abs(nxt.color[2] - k.color[2]);
                        if (diff_r > 0.02 or diff_g > 0.02 or diff_b > 0.02) break :outer;
                    }
                    height += 1;
                }

                const target = if (k.block.isTransparent() and k.block != .leaves) fluid_list else solid_list;
                try addGreedyFace(self.allocator, target, axis, s, su, sv, width, height, k.block, k.side, si, k.light, k.color);

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

    /// Upload pending mesh data to the GPU.
    ///
    /// ## Buffer Reuse Strategy
    /// Buffers are reused when possible to avoid GPU sync points:
    /// - If new data fits in existing buffer capacity, only the data is updated
    /// - If capacity is exceeded, buffer is reallocated to next power-of-2 size
    /// - Minimum allocation is 1KB to reduce small reallocations
    ///
    /// This approach balances memory usage with reallocation frequency.
    /// A full ring buffer would be more efficient for frequently-changing meshes,
    /// but chunk meshes change infrequently after initial generation.
    pub fn upload(self: *ChunkMesh, rhi: RHI) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..NUM_SUBCHUNKS) |si| {
            if (self.pending_solid[si]) |v| {
                const bytes = std.mem.sliceAsBytes(v);
                // Reuse buffer if capacity is sufficient; otherwise reallocate
                if (bytes.len > self.subchunks[si].capacity_solid) {
                    if (self.subchunks[si].solid_handle != 0) {
                        rhi.destroyBuffer(self.subchunks[si].solid_handle);
                    }
                    var new_cap = std.math.ceilPowerOfTwo(usize, bytes.len) catch bytes.len;
                    if (new_cap < 1024) new_cap = 1024;
                    self.subchunks[si].solid_handle = rhi.createBuffer(new_cap, .vertex);
                    self.subchunks[si].capacity_solid = @intCast(new_cap);
                }
                rhi.uploadBuffer(self.subchunks[si].solid_handle, bytes);

                self.subchunks[si].count_solid = @intCast(v.len);
                self.allocator.free(v);
                self.pending_solid[si] = null;
                self.subchunks[si].ready = true;
            }
            if (self.pending_fluid[si]) |v| {
                const bytes = std.mem.sliceAsBytes(v);
                if (bytes.len > self.subchunks[si].capacity_fluid) {
                    if (self.subchunks[si].fluid_handle != 0) {
                        rhi.destroyBuffer(self.subchunks[si].fluid_handle);
                    }
                    var new_cap = std.math.ceilPowerOfTwo(usize, bytes.len) catch bytes.len;
                    if (new_cap < 1024) new_cap = 1024;
                    self.subchunks[si].fluid_handle = rhi.createBuffer(new_cap, .vertex);
                    self.subchunks[si].capacity_fluid = @intCast(new_cap);
                }
                rhi.uploadBuffer(self.subchunks[si].fluid_handle, bytes);

                self.subchunks[si].count_fluid = @intCast(v.len);
                self.allocator.free(v);
                self.pending_fluid[si] = null;
                self.subchunks[si].ready = true;
            }
        }
    }

    pub fn draw(self: *const ChunkMesh, rhi: RHI, pass: Pass) void {
        for (self.subchunks) |s| {
            if (!s.ready) continue;
            if (pass == .solid and s.count_solid > 0) {
                rhi.draw(s.solid_handle, s.count_solid, .triangles);
            } else if (pass == .fluid and s.count_fluid > 0) {
                rhi.draw(s.fluid_handle, s.count_fluid, .triangles);
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

fn getLightAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32) PackedLight {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => chunk.getLightSafe(@intCast(u), s, @intCast(v)),
        .east => getLightCross(chunk, neighbors, s, y_off + @as(i32, @intCast(u)), @intCast(v)),
        .south => getLightCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s),
        else => unreachable,
    };
}

fn getLightCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) PackedLight {
    const MAX_LIGHT = @import("chunk.zig").MAX_LIGHT;
    if (y >= CHUNK_SIZE_Y) return PackedLight.init(MAX_LIGHT, 0);
    if (y < 0) return PackedLight.init(0, 0);

    if (x < 0) return if (neighbors.west) |w| w.getLightSafe(CHUNK_SIZE_X - 1, y, z) else PackedLight.init(MAX_LIGHT, 0);
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getLightSafe(0, y, z) else PackedLight.init(MAX_LIGHT, 0);
    if (z < 0) return if (neighbors.north) |n| n.getLightSafe(x, y, CHUNK_SIZE_Z - 1) else PackedLight.init(MAX_LIGHT, 0);
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getLightSafe(x, y, 0) else PackedLight.init(MAX_LIGHT, 0);
    return chunk.getLightSafe(x, y, z);
}

fn addGreedyFace(allocator: std.mem.Allocator, verts: *std.ArrayListUnmanaged(Vertex), axis: Face, s: i32, u: u32, v: u32, w: u32, h: u32, block: BlockType, forward: bool, si: u32, light: PackedLight, tint: [3]f32) !void {
    const face = if (forward) axis else switch (axis) {
        .top => Face.bottom,
        .east => Face.west,
        .south => Face.north,
        else => unreachable,
    };
    const base_col = block.getFaceColor(face);
    const col = [3]f32{ base_col[0] * tint[0], base_col[1] * tint[1], base_col[2] * tint[2] };
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
    const sky_norm = @as(f32, @floatFromInt(light.getSkyLight())) / 15.0;
    const block_norm = @as(f32, @floatFromInt(light.getBlockLight())) / 15.0;

    for (idxs) |i| {
        try verts.append(allocator, Vertex{
            .pos = p[i],
            .color = col,
            .normal = nf,
            .uv = uv[i],
            .tile_id = tid,
            .skylight = sky_norm,
            .blocklight = block_norm,
        });
    }
}

fn getBiomeAt(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, z: i32) biome_mod.BiomeId {
    if (x < 0) {
        if (z >= 0 and z < CHUNK_SIZE_Z) {
            if (neighbors.west) |w| return w.getBiome(CHUNK_SIZE_X - 1, @intCast(z));
        }
        return chunk.getBiome(0, @intCast(std.math.clamp(z, 0, CHUNK_SIZE_Z - 1)));
    }
    if (x >= CHUNK_SIZE_X) {
        if (z >= 0 and z < CHUNK_SIZE_Z) {
            if (neighbors.east) |e| return e.getBiome(0, @intCast(z));
        }
        return chunk.getBiome(CHUNK_SIZE_X - 1, @intCast(std.math.clamp(z, 0, CHUNK_SIZE_Z - 1)));
    }
    if (z < 0) {
        if (neighbors.north) |n| return n.getBiome(@intCast(x), CHUNK_SIZE_Z - 1);
        return chunk.getBiome(@intCast(x), 0);
    }
    if (z >= CHUNK_SIZE_Z) {
        if (neighbors.south) |s| return s.getBiome(@intCast(x), 0);
        return chunk.getBiome(@intCast(x), CHUNK_SIZE_Z - 1);
    }
    return chunk.getBiome(@intCast(x), @intCast(z));
}

fn getBlockColor(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32, block: BlockType) [3]f32 {
    if (block != .grass and block != .leaves and block != .water) return .{ 1.0, 1.0, 1.0 };

    var x: i32 = 0;
    var z: i32 = 0;
    _ = si;

    switch (axis) {
        .top => {
            x = @intCast(u);
            z = @intCast(v);
        },
        .east => {
            x = s;
            z = @intCast(v);
        },
        .south => {
            x = @intCast(u);
            z = s;
        },
        else => {
            x = @intCast(u);
            z = @intCast(v);
        },
    }

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    var count: f32 = 0;

    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oz: i32 = -1;
        while (oz <= 1) : (oz += 1) {
            const biome_id = getBiomeAt(chunk, neighbors, x + ox, z + oz);
            const def = biome_mod.getBiomeDefinition(biome_id);
            const col = switch (block) {
                .grass => def.colors.grass,
                .leaves => def.colors.foliage,
                .water => def.colors.water,
                else => .{ 1.0, 1.0, 1.0 },
            };
            r += col[0];
            g += col[1];
            b += col[2];
            count += 1.0;
        }
    }

    return .{ r / count, g / count, b / count };
}
