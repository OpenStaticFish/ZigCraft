const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const BlockType = @import("block.zig").BlockType;

pub const ChunkMesh = struct {
    vertices: []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ChunkMesh) void {
        self.allocator.free(self.vertices);
    }
};

const FaceDir = enum { Right, Left, Top, Bottom, Front, Back };

pub fn generateMesh(allocator: std.mem.Allocator, chunk: *const Chunk) !ChunkMesh {
    var vertices = std.ArrayList(f32).empty;
    errdefer vertices.deinit(allocator);

    // We sweep over 3 dimensions
    // d=0: X axis (Faces Right/Left, Slice is YZ)
    // d=1: Y axis (Faces Top/Bottom, Slice is XZ)
    // d=2: Z axis (Faces Front/Back, Slice is XY)

    const dims = [3]usize{ chunk_mod.CHUNK_SIZE_X, chunk_mod.CHUNK_SIZE_Y, chunk_mod.CHUNK_SIZE_Z };

    // Temporary mask for the current slice
    // Max slice size is 256 * 16 = 4096. We can allocate this once.
    const max_slice_area = @max(chunk_mod.CHUNK_SIZE_X * chunk_mod.CHUNK_SIZE_Y, @max(chunk_mod.CHUNK_SIZE_Y * chunk_mod.CHUNK_SIZE_Z, chunk_mod.CHUNK_SIZE_X * chunk_mod.CHUNK_SIZE_Z));
    var mask = try allocator.alloc(?BlockType, max_slice_area);
    defer allocator.free(mask);

    for (0..3) |d| { // Axis
        const u = (d + 1) % 3; // 1st orth dimension
        const v = (d + 2) % 3; // 2nd orth dimension

        // Removed unused constants x and q

        // We need to iterate from -1 to dim limits to catch all faces
        // But our logic uses 0..dim and checks neighbor.
        // Let's use the standard loop:
        // iterate q[d] from -1 to dims[d]

        // wait, simpler:
        // iterate coordinate 'i' along axis 'd'
        // determine "forward face" (at i, looking +) and "backward face" (at i, looking -)

        // Let's stick to:
        // Forward Face (Normal +1): Block at `i` is Solid, Block at `i+1` is Air. Face is at `i+1` boundary.
        // Backward Face (Normal -1): Block at `i` is Solid, Block at `i-1` is Air. Face is at `i` boundary.

        // To support greedy meshing, we process one "slice of faces" at a time.
        // A slice of faces exists between layer `i` and `i-1`.

        // Iterating `i` from 0 to dims[d] (inclusive limits? No, faces are at boundaries)
        // Boundaries are 0, 1, ..., dims[d]
        // Face at boundary `i` separates block `i-1` and `i`.

        var i: usize = 0;
        while (i <= dims[d]) : (i += 1) {
            var q_pos = [3]usize{ 0, 0, 0 };
            q_pos[d] = 1;

            // 1. Generate Mask for this slice `i`
            var n: usize = 0;

            var j: usize = 0;
            while (j < dims[u]) : (j += 1) {
                var k: usize = 0;
                while (k < dims[v]) : (k += 1) {
                    // Coordinates in 3D
                    // We are at boundary `i` along axis `d`.
                    // Current voxel is (j, k) in (u, v) plane.

                    // Construct 3D coords for "block at this side" and "block at that side"
                    var pos = [3]usize{ 0, 0, 0 };
                    pos[u] = j;
                    pos[v] = k;
                    pos[d] = i;

                    // Block at i (current)
                    const b_curr = if (i < dims[d]) chunk.getBlock(pos[0], pos[1], pos[2]) else block_mod.Block{ .type = .Air };

                    // Block at i-1 (previous)
                    var pos_prev = pos;
                    // Careful with usize underflow.
                    const b_prev = if (i > 0) blk: {
                        pos_prev[d] = i - 1;
                        break :blk chunk.getBlock(pos_prev[0], pos_prev[1], pos_prev[2]);
                    } else block_mod.Block{ .type = .Air };

                    const curr_active = b_curr.isActive();
                    const prev_active = b_prev.isActive();

                    // Logic:
                    // If prev is solid and curr is air -> Face pointing +d (Right/Top/Front)
                    // If curr is solid and prev is air -> Face pointing -d (Left/Bottom/Back)
                    // If both solid or both air -> No face (invisible)

                    // But we can't put both into the same mask because they are different faces.
                    // Greedy meshing usually handles one direction at a time or uses a mask that distinguishes.
                    // Let's do 2 passes or use a mask with direction info?
                    // Or simpler: standard loop usually does forward face and back face check separately.

                    // Let's simplify: We only mesh the faces pointing in +d direction here?
                    // If we iterate d=0..2, and only check +d faces?
                    // No, we need +d and -d.

                    // Let's assume we want to find faces pointing towards +d (Normal +1)
                    // These occur when b_prev is Solid and b_curr is Air.

                    // And faces pointing towards -d (Normal -1)
                    // These occur when b_curr is Solid and b_prev is Air.

                    // The mask will store the BlockType of the face.
                    // Since a quad can't be both "front facing" and "back facing" at the same time (same location),
                    // we effectively iterate twice per slice? Or just handle one direction?
                    // Most greedy implementations iterate 6 directions or handle back-face culling implicitly.

                    // Let's stick to the "compare active state" approach but handle directions.
                    // We will run the greedy mesher TWICE for each slice `i`: once for +d faces, once for -d faces.
                    // That ensures we don't merge a front-face with a back-face.

                    mask[n] = null;
                    // This loop populates mask for +d faces
                    if (prev_active and !curr_active) {
                        mask[n] = b_prev.type;
                    }
                    n += 1;
                }
            }

            try greedyMeshPlane(allocator, &vertices, mask, dims[u], dims[v], dims[d], i, d, u, v, true);

            // Now populate mask for -d faces
            n = 0;
            j = 0;
            while (j < dims[u]) : (j += 1) {
                var k: usize = 0;
                while (k < dims[v]) : (k += 1) {
                    var pos = [3]usize{ 0, 0, 0 };
                    pos[u] = j;
                    pos[v] = k;
                    pos[d] = i;

                    const b_curr = if (i < dims[d]) chunk.getBlock(pos[0], pos[1], pos[2]) else block_mod.Block{ .type = .Air };
                    const b_prev = if (i > 0) blk: {
                        var p = pos;
                        p[d] = i - 1;
                        break :blk chunk.getBlock(p[0], p[1], p[2]);
                    } else block_mod.Block{ .type = .Air };

                    const curr_active = b_curr.isActive();
                    const prev_active = b_prev.isActive();

                    mask[n] = null;
                    if (curr_active and !prev_active) {
                        mask[n] = b_curr.type;
                    }
                    n += 1;
                }
            }
            try greedyMeshPlane(allocator, &vertices, mask, dims[u], dims[v], dims[d], i, d, u, v, false);
        }
    }

    // Safety check for empty mesh
    if (vertices.items.len == 0) {
        return ChunkMesh{
            .vertices = &[_]f32{},
            .allocator = allocator,
        };
    }

    return ChunkMesh{
        .vertices = try vertices.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const block_mod = @import("block.zig");

fn greedyMeshPlane(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayList(f32),
    mask: []?BlockType,
    dim_u: usize,
    dim_v: usize,
    dim_d: usize,
    i: usize, // depth along d
    d: usize, // axis index (0, 1, 2)
    u: usize, // axis index
    v: usize, // axis index
    forward: bool, // true if Normal is +1 (prev->curr), false if Normal -1 (curr->prev)
) !void {
    _ = dim_d; // unused
    var j: usize = 0;
    var n: usize = 0;

    while (j < dim_u) : (j += 1) {
        var k: usize = 0;
        while (k < dim_v) { // Note: k is incremented inside

            // Compute index in mask
            // mask was filled with j outer, k inner -> n = j * dim_v + k
            n = j * dim_v + k;

            if (mask[n] != null) {
                const type_val = mask[n].?;
                var width: usize = 1;
                var height: usize = 1;

                // Compute width (along K/V axis)
                while (k + width < dim_v and mask[n + width] != null and mask[n + width].? == type_val) {
                    width += 1;
                }

                // Compute height (along J/U axis)
                var h_valid = true;
                while (j + height < dim_u and h_valid) {
                    // Check this row
                    for (0..width) |w| {
                        const idx = (j + height) * dim_v + k + w;
                        if (mask[idx] == null or mask[idx].? != type_val) {
                            h_valid = false;
                            break;
                        }
                    }
                    if (h_valid) height += 1;
                }

                // Add Quad
                try addQuad(allocator, vertices, j, k, i, height, width, // Note: J is "height" in this 2D mapping, K is "width"
                    d, u, v, forward, type_val);

                // Clear mask
                for (0..height) |h| {
                    for (0..width) |w| {
                        mask[(j + h) * dim_v + k + w] = null;
                    }
                }

                k += width;
            } else {
                k += 1;
            }
        }
    }
}

fn addQuad(allocator: std.mem.Allocator, list: *std.ArrayList(f32), u_pos: usize, v_pos: usize, d_pos: usize, u_len: usize, v_len: usize, d_axis: usize, u_axis: usize, v_axis: usize, forward: bool, btype: BlockType) !void {
    const color = getColor(btype);
    const r = color[0];
    const g = color[1];
    const b = color[2];

    // Coordinates
    // The quad is in the plane defined by (u_pos, v_pos) extending by (u_len, v_len).
    // The depth is d_pos.

    // We need to map these "u, v, d" back to "x, y, z".
    // axis indices are d_axis, u_axis, v_axis.

    // Vertices of the quad (in u,v local space):
    // (0, 0), (u_len, 0), (u_len, v_len), (0, v_len)
    // Offset by (u_pos, v_pos).

    var v0 = [3]f32{ 0, 0, 0 };
    var v1 = [3]f32{ 0, 0, 0 };
    var v2 = [3]f32{ 0, 0, 0 };
    var v3 = [3]f32{ 0, 0, 0 };

    // Helper to set coords
    const set = struct {
        fn func(vec: *[3]f32, da: usize, ua: usize, va: usize, dv: f32, uv: f32, vv: f32) void {
            vec[da] = dv;
            vec[ua] = uv;
            vec[va] = vv;
        }
    }.func;

    // d coordinate is fixed.
    const fd = @as(f32, @floatFromInt(d_pos));

    // u, v coordinates
    const fu = @as(f32, @floatFromInt(u_pos));
    const fv = @as(f32, @floatFromInt(v_pos));
    const fu_len = @as(f32, @floatFromInt(u_len));
    const fv_len = @as(f32, @floatFromInt(v_len));

    // Construct the 4 corners
    // Corner 0: u, v
    set(&v0, d_axis, u_axis, v_axis, fd, fu, fv);
    // Corner 1: u, v + len
    set(&v1, d_axis, u_axis, v_axis, fd, fu, fv + fv_len);
    // Corner 2: u + len, v + len
    set(&v2, d_axis, u_axis, v_axis, fd, fu + fu_len, fv + fv_len);
    // Corner 3: u + len, v
    set(&v3, d_axis, u_axis, v_axis, fd, fu + fu_len, fv);

    // Winding order depends on 'forward'
    // If forward (Normal +1): Counter-Clockwise relative to camera outside?
    // Let's deduce.
    // Standard OpenGL CCW.
    // Forward face (+d): (0,0) -> (0,1) -> (1,1) -> (1,0) ??
    // Let's look at Phase 3 implementation for +Z (Front):
    // (0,0,1) -> (1,0,1) -> (1,1,1)...

    // It's easier to just emit 2 triangles.
    // If forward (normal points to +d):
    //   We want the normal to point POSITIVE.
    //   Quad in plane U-V.
    //   U is axis (d+1)%3, V is (d+2)%3. Right-hand rule: U x V = D.
    //   So (0,0) -> (1,0) -> (1,1) -> (0,1) should produce normal +D.
    //   Let's map that to our v0..v3 indices.
    //   v0=(u,v), v1=(u, v+len), v2=(u+len, v+len), v3=(u+len, v)
    //   Wait, v1 is (u, v+len)? That's moving along V axis.
    //   v3 is (u+len, v)? That's moving along U axis.
    //   So v0 -> v3 is +U. v0 -> v1 is +V.
    //   (v3 - v0) x (v1 - v0) = U x V = +D.
    //   So Loop: v0 -> v3 -> v1 ? No, v0, v3, v2, v1 ?
    //   Quad: v0(0,0), v3(1,0), v2(1,1), v1(0,1)
    //   Tri 1: v0, v3, v2.
    //   Tri 2: v0, v2, v1.

    if (forward) {
        // Normal +D
        // v0 -> v3 -> v2
        try list.appendSlice(allocator, &.{ v0[0], v0[1], v0[2], r, g, b });
        try list.appendSlice(allocator, &.{ v3[0], v3[1], v3[2], r, g, b });
        try list.appendSlice(allocator, &.{ v2[0], v2[1], v2[2], r, g, b });

        // v0 -> v2 -> v1
        try list.appendSlice(allocator, &.{ v0[0], v0[1], v0[2], r, g, b });
        try list.appendSlice(allocator, &.{ v2[0], v2[1], v2[2], r, g, b });
        try list.appendSlice(allocator, &.{ v1[0], v1[1], v1[2], r, g, b });
    } else {
        // Normal -D
        // Reverse winding
        // v0 -> v2 -> v3
        try list.appendSlice(allocator, &.{ v0[0], v0[1], v0[2], r, g, b });
        try list.appendSlice(allocator, &.{ v2[0], v2[1], v2[2], r, g, b });
        try list.appendSlice(allocator, &.{ v3[0], v3[1], v3[2], r, g, b });

        // v0 -> v1 -> v2
        try list.appendSlice(allocator, &.{ v0[0], v0[1], v0[2], r, g, b });
        try list.appendSlice(allocator, &.{ v1[0], v1[1], v1[2], r, g, b });
        try list.appendSlice(allocator, &.{ v2[0], v2[1], v2[2], r, g, b });
    }
}

fn getColor(btype: BlockType) [3]f32 {
    return switch (btype) {
        .Grass => .{ 0.1, 0.8, 0.1 },
        .Dirt => .{ 0.5, 0.3, 0.1 },
        .Stone => .{ 0.5, 0.5, 0.5 },
        .Air => .{ 1.0, 0.0, 1.0 }, // Should not happen
        _ => .{ 1.0, 0.0, 0.0 }, // Handle potential corruption
    };
}
