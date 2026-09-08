const std = @import("std");

const rhi = @import("engine-rhi");
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const cloud_interface = @import("cloud_interface.zig");

const CLOUD_SIZE: f32 = 32.0;
const MESH_REBUILD_DISTANCE: f32 = 2.5;
const NOISE_BOUND: f32 = 1.0 + 0.5 + 0.25;
const MAX_FLAT_RADIUS: u16 = 62;
const MAX_3D_RADIUS: u16 = 25;

pub const CloudConfig = cloud_interface.CloudConfig;
pub const ICloudSystem = cloud_interface.ICloudSystem;

pub const CloudSystem = struct {
    allocator: std.mem.Allocator,
    resources: rhi.ResourceManager,
    config: CloudConfig,
    vertices: std.ArrayListUnmanaged(rhi.Vertex) = .empty,
    grid: std.ArrayListUnmanaged(bool) = .empty,
    vertex_buffer: rhi.BufferHandle = rhi.InvalidBufferHandle,
    vertex_buffer_capacity: usize = 0,
    mesh_origin_x: f32 = 0.0,
    mesh_origin_z: f32 = 0.0,
    mesh_camera_pos: Vec3 = Vec3.zero,
    origin_x: f32 = 0.0,
    origin_z: f32 = 0.0,
    last_noise_center_x: i32 = std.math.minInt(i32),
    last_noise_center_z: i32 = std.math.minInt(i32),
    mesh_valid: bool = false,
    gpu_valid: bool = false,
    vertex_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, resources: rhi.ResourceManager, config: CloudConfig) !*CloudSystem {
        const self = try allocator.create(CloudSystem);
        self.* = .{ .allocator = allocator, .resources = resources, .config = normalizedConfig(config) };
        errdefer allocator.destroy(self);
        const capacity = maxCloudVertexBytes();
        self.vertex_buffer = try resources.createBuffer(capacity, .vertex);
        self.vertex_buffer_capacity = capacity;
        return self;
    }

    pub fn deinit(self: *CloudSystem) void {
        if (self.vertex_buffer != rhi.InvalidBufferHandle) self.resources.destroyBuffer(self.vertex_buffer);
        self.vertices.deinit(self.allocator);
        self.grid.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setConfig(self: *CloudSystem, config: CloudConfig) void {
        const next = normalizedConfig(config);
        if (self.config.radius != next.radius or self.config.density != next.density or self.config.enable_3d != next.enable_3d or self.config.thickness != next.thickness or self.config.height != next.height or self.config.seed != next.seed) {
            self.mesh_valid = false;
            self.gpu_valid = false;
        }
        self.config = next;
    }

    pub fn step(self: *CloudSystem, dt: f32) void {
        self.origin_x += dt * self.config.speed_x;
        self.origin_z += dt * self.config.speed_z;
    }

    pub fn render(self: *CloudSystem, ctx: rhi.RenderContext, camera_pos: Vec3) !void {
        if (!self.config.enabled or self.config.density <= 0.0) return;
        try self.updateMesh(camera_pos);
        self.uploadMesh() catch |err| switch (err) {
            error.OutOfMemory, error.PendingCopyOverflow => return,
            else => return err,
        };
        if (self.vertex_count == 0) return;
        ctx.setTerrainPipelineBound(false);
        const smooth_offset = Vec3.init(
            (self.origin_x - self.mesh_origin_x) - (camera_pos.x - self.mesh_camera_pos.x),
            -(camera_pos.y - self.mesh_camera_pos.y),
            (self.origin_z - self.mesh_origin_z) - (camera_pos.z - self.mesh_camera_pos.z),
        );
        ctx.setModelMatrix(Mat4.translate(smooth_offset), Vec3.one);
        ctx.drawOffset(self.vertex_buffer, self.vertex_count, .triangles, 0);
        // Force OpaquePass to rebind terrain state after clouds use the same pipeline.
        ctx.setTerrainPipelineBound(false);
    }

    pub fn renderShadow(self: *CloudSystem, ctx: rhi.RenderContext, camera_pos: Vec3) !void {
        if (!self.config.enabled or self.config.density <= 0.0 or self.vertex_count == 0 or !self.gpu_valid) return;
        try self.updateMesh(camera_pos);
        self.uploadMesh() catch |err| switch (err) {
            error.OutOfMemory, error.PendingCopyOverflow => return,
            else => return err,
        };
        const smooth_offset = Vec3.init(
            (self.origin_x - self.mesh_origin_x) - (camera_pos.x - self.mesh_camera_pos.x),
            -(camera_pos.y - self.mesh_camera_pos.y),
            (self.origin_z - self.mesh_origin_z) - (camera_pos.z - self.mesh_camera_pos.z),
        );
        ctx.setModelMatrix(Mat4.translate(smooth_offset), Vec3.one);
        ctx.drawOffset(self.vertex_buffer, self.vertex_count, .triangles, 0);
    }

    pub fn interface(self: *CloudSystem) ICloudSystem {
        return .{ .ptr = self, .vtable = &INTERFACE_VTABLE };
    }

    fn updateMesh(self: *CloudSystem, camera_pos: Vec3) !void {
        const center_x: i32 = @intFromFloat(@floor((camera_pos.x - self.origin_x) / CLOUD_SIZE));
        const center_z: i32 = @intFromFloat(@floor((camera_pos.z - self.origin_z) / CLOUD_SIZE));
        const dx = self.origin_x - self.mesh_origin_x;
        const dz = self.origin_z - self.mesh_origin_z;
        const moved = @sqrt(dx * dx + dz * dz) >= MESH_REBUILD_DISTANCE;
        if (self.mesh_valid and !moved and center_x == self.last_noise_center_x and center_z == self.last_noise_center_z) return;

        const radius = self.config.radius;
        const side = @as(usize, radius) * 2;
        try self.grid.resize(self.allocator, side * side);

        var next_vertices: std.ArrayListUnmanaged(rhi.Vertex) = .empty;
        errdefer next_vertices.deinit(self.allocator);

        const radius_i: i32 = @intCast(radius);
        var z: i32 = -radius_i;
        while (z < radius_i) : (z += 1) {
            var x: i32 = -radius_i;
            while (x < radius_i) : (x += 1) {
                self.grid.items[self.gridIndex(x, z)] = self.gridFilled(x + center_x, z + center_z);
            }
        }

        const world_center_x = @as(f32, @floatFromInt(center_x)) * CLOUD_SIZE + self.mesh_origin_x;
        const world_center_z = @as(f32, @floatFromInt(center_z)) * CLOUD_SIZE + self.mesh_origin_z;

        const Cell = struct {
            x: i32,
            z: i32,
            cx: f32,
            cz: f32,

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                const ad = a.cx * a.cx + a.cz * a.cz;
                const bd = b.cx * b.cx + b.cz * b.cz;
                if (ad != bd) return ad < bd;
                return a.z < b.z or (a.z == b.z and a.x < b.x);
            }
        };
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        defer cells.deinit(self.allocator);
        try cells.ensureTotalCapacity(self.allocator, side * side);
        z = -radius_i;
        while (z < radius_i) : (z += 1) {
            var x: i32 = -radius_i;
            while (x < radius_i) : (x += 1) {
                if (!self.grid.items[self.gridIndex(x, z)]) continue;
                cells.appendAssumeCapacity(.{
                    .x = x,
                    .z = z,
                    .cx = world_center_x + @as(f32, @floatFromInt(x)) * CLOUD_SIZE - camera_pos.x,
                    .cz = world_center_z + @as(f32, @floatFromInt(z)) * CLOUD_SIZE - camera_pos.z,
                });
            }
        }
        // Clouds use the opaque, depth-writing terrain pipeline, not blending.
        std.mem.sort(Cell, cells.items, {}, Cell.lessThan);
        for (cells.items) |cell| {
            try self.emitCell(&next_vertices, cell.cx, -camera_pos.y, cell.cz, cell.x, cell.z);
        }

        self.vertices.deinit(self.allocator);
        self.vertices = next_vertices;
        self.mesh_origin_x = self.origin_x;
        self.mesh_origin_z = self.origin_z;
        self.mesh_camera_pos = camera_pos;
        self.last_noise_center_x = center_x;
        self.last_noise_center_z = center_z;
        self.mesh_valid = true;
        self.gpu_valid = false;
        self.vertex_count = @intCast(self.vertices.items.len);
    }

    fn emitCell(self: *CloudSystem, vertices: *std.ArrayListUnmanaged(rhi.Vertex), cx: f32, cy: f32, cz: f32, grid_x: i32, grid_z: i32) !void {
        const r = CLOUD_SIZE * 0.5;
        const y0 = self.config.height + cy;
        const y1 = self.config.height + cy + if (self.is3D()) self.config.thickness else 0.0;
        try self.emitQuad(vertices, .{ cx - r, y1, cz - r }, .{ cx - r, y1, cz + r }, .{ cx + r, y1, cz + r }, .{ cx + r, y1, cz - r }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 });
        if (!self.is3D()) return;
        const side1 = [_]f32{ 0.82, 0.82, 0.82 };
        const side2 = [_]f32{ 0.72, 0.72, 0.72 };
        const bottom = [_]f32{ 0.55, 0.55, 0.55 };
        if (!self.neighborFilled(grid_x, grid_z - 1)) try self.emitQuad(vertices, .{ cx - r, y1, cz - r }, .{ cx + r, y1, cz - r }, .{ cx + r, y0, cz - r }, .{ cx - r, y0, cz - r }, side1, .{ 0.0, 0.0, -1.0 });
        if (!self.neighborFilled(grid_x + 1, grid_z)) try self.emitQuad(vertices, .{ cx + r, y1, cz - r }, .{ cx + r, y1, cz + r }, .{ cx + r, y0, cz + r }, .{ cx + r, y0, cz - r }, side2, .{ 1.0, 0.0, 0.0 });
        if (!self.neighborFilled(grid_x, grid_z + 1)) try self.emitQuad(vertices, .{ cx + r, y1, cz + r }, .{ cx - r, y1, cz + r }, .{ cx - r, y0, cz + r }, .{ cx + r, y0, cz + r }, side1, .{ 0.0, 0.0, 1.0 });
        if (!self.neighborFilled(grid_x - 1, grid_z)) try self.emitQuad(vertices, .{ cx - r, y1, cz + r }, .{ cx - r, y1, cz - r }, .{ cx - r, y0, cz - r }, .{ cx - r, y0, cz + r }, side2, .{ -1.0, 0.0, 0.0 });
        try self.emitQuad(vertices, .{ cx + r, y0, cz + r }, .{ cx - r, y0, cz + r }, .{ cx - r, y0, cz - r }, .{ cx + r, y0, cz - r }, bottom, .{ 0.0, -1.0, 0.0 });
    }

    fn emitQuad(self: *CloudSystem, vertices: *std.ArrayListUnmanaged(rhi.Vertex), a: [3]f32, b: [3]f32, c: [3]f32, d: [3]f32, color: [3]f32, normal: [3]f32) !void {
        try vertices.append(self.allocator, rhi.Vertex.initCloud(a, color, normal, .{ 0.0, 1.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
        try vertices.append(self.allocator, rhi.Vertex.initCloud(b, color, normal, .{ 1.0, 1.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
        try vertices.append(self.allocator, rhi.Vertex.initCloud(c, color, normal, .{ 1.0, 0.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
        try vertices.append(self.allocator, rhi.Vertex.initCloud(c, color, normal, .{ 1.0, 0.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
        try vertices.append(self.allocator, rhi.Vertex.initCloud(d, color, normal, .{ 0.0, 0.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
        try vertices.append(self.allocator, rhi.Vertex.initCloud(a, color, normal, .{ 0.0, 1.0 }, rhi.Vertex.CLOUD_TILE_ID, 1.0, .{ 0.0, 0.0, 0.0 }, 1.0));
    }

    fn uploadMesh(self: *CloudSystem) !void {
        if (self.gpu_valid) return;
        if (self.vertices.items.len == 0) return;
        const vertex_bytes = std.mem.sliceAsBytes(self.vertices.items);

        if (vertex_bytes.len > self.vertex_buffer_capacity) return error.CloudVertexBufferTooSmall;
        try self.resources.updateBuffer(self.vertex_buffer, 0, vertex_bytes);
        self.gpu_valid = true;
    }

    fn gridFilled(self: *const CloudSystem, x: i32, z: i32) bool {
        const scale = CLOUD_SIZE / 100.0;
        const n = fbm(@as(f32, @floatFromInt(x)) * scale, @as(f32, @floatFromInt(z)) * scale, self.config.seed);
        const d = n / NOISE_BOUND * 0.5 + 0.5;
        return d < self.config.density;
    }

    fn is3D(self: *const CloudSystem) bool {
        return self.config.enable_3d and self.config.thickness >= 0.01;
    }

    fn gridIndex(self: *const CloudSystem, x: i32, z: i32) usize {
        const radius: i32 = self.config.radius;
        const side: usize = @as(usize, @intCast(radius)) * 2;
        return @as(usize, @intCast(z + radius)) * side + @as(usize, @intCast(x + radius));
    }

    fn neighborFilled(self: *const CloudSystem, x: i32, z: i32) bool {
        const radius: i32 = self.config.radius;
        if (x < -radius or x >= radius or z < -radius or z >= radius) return false;
        return self.grid.items[self.gridIndex(x, z)];
    }
};

const INTERFACE_VTABLE = ICloudSystem.VTable{
    .deinit = interfaceDeinit,
    .setConfig = interfaceSetConfig,
    .step = interfaceStep,
    .render = interfaceRender,
};

fn interfaceDeinit(ptr: *anyopaque) void {
    const self: *CloudSystem = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn interfaceSetConfig(ptr: *anyopaque, config: CloudConfig) void {
    const self: *CloudSystem = @ptrCast(@alignCast(ptr));
    self.setConfig(config);
}

fn interfaceStep(ptr: *anyopaque, dt: f32) void {
    const self: *CloudSystem = @ptrCast(@alignCast(ptr));
    self.step(dt);
}

fn interfaceRender(ptr: *anyopaque, ctx: rhi.RenderContext, camera_pos: Vec3) !void {
    const self: *CloudSystem = @ptrCast(@alignCast(ptr));
    try self.render(ctx, camera_pos);
}

fn normalizedConfig(config: CloudConfig) CloudConfig {
    var out = config;
    const max_radius: u16 = if (out.enable_3d) MAX_3D_RADIUS else MAX_FLAT_RADIUS;
    out.radius = @min(max_radius, @max(@as(u16, 8), out.radius));
    out.density = @max(0.0, @min(1.0, out.density));
    out.thickness = @max(0.0, out.thickness);
    return out;
}

fn maxCloudVertexBytes() usize {
    const flat_side = @as(usize, MAX_FLAT_RADIUS) * 2;
    const flat_vertices = flat_side * flat_side * 6;
    const cloud_3d_side = @as(usize, MAX_3D_RADIUS) * 2;
    const cloud_3d_vertices = cloud_3d_side * cloud_3d_side * 6 * 6;
    return @as(usize, @max(flat_vertices, cloud_3d_vertices)) * @sizeOf(rhi.Vertex);
}

fn fbm(x: f32, z: f32, seed: u32) f32 {
    return valueNoise(x, z, seed) + valueNoise(x * 2.0, z * 2.0, seed +% 1) * 0.5 + valueNoise(x * 4.0, z * 4.0, seed +% 2) * 0.25;
}

fn valueNoise(x: f32, z: f32, seed: u32) f32 {
    const x0: i32 = @intFromFloat(@floor(x));
    const z0: i32 = @intFromFloat(@floor(z));
    const tx = smooth(x - @floor(x));
    const tz = smooth(z - @floor(z));
    const a = hashNoise(x0, z0, seed);
    const b = hashNoise(x0 + 1, z0, seed);
    const c = hashNoise(x0, z0 + 1, seed);
    const d = hashNoise(x0 + 1, z0 + 1, seed);
    return std.math.lerp(std.math.lerp(a, b, tx), std.math.lerp(c, d, tx), tz);
}

fn smooth(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn hashNoise(x: i32, z: i32, seed: u32) f32 {
    var h: u32 = @bitCast(x);
    h *%= 0x8da6b343;
    h +%= @as(u32, @bitCast(z)) *% 0xd8163841;
    h +%= seed *% 0xcb1ab31f;
    h ^= h >> 13;
    h *%= 0x85ebca6b;
    h ^= h >> 16;
    return (@as(f32, @floatFromInt(h & 0xffff)) / 32767.5) - 1.0;
}

test "cloud config clamps radius" {
    const flat = normalizedConfig(.{ .enable_3d = false, .radius = 100 });
    try std.testing.expectEqual(@as(u16, 62), flat.radius);
    const cloud3d = normalizedConfig(.{ .enable_3d = true, .radius = 100 });
    try std.testing.expectEqual(@as(u16, 25), cloud3d.radius);
}

test "cloud noise is deterministic" {
    const allocator = std.testing.allocator;
    var system = CloudSystem{ .allocator = allocator, .resources = undefined, .config = normalizedConfig(.{ .seed = 99 }) };
    try std.testing.expectEqual(system.gridFilled(12, -4), system.gridFilled(12, -4));
}

test "cloud mesh orders filled cells nearest first without changing triangles" {
    const allocator = std.testing.allocator;
    const Triangle = [3]rhi.Vertex;
    const Order = struct {
        fn lessThan(_: void, a: Triangle, b: Triangle) bool {
            return std.mem.order(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)) == .lt;
        }
    };
    for ([_]bool{ false, true }) |enable_3d| {
        for ([_]Vec3{ Vec3.init(-49, 10, -81), Vec3.init(0, 180, 0), Vec3.init(47, 250, 95) }) |camera| {
            var system = CloudSystem{ .allocator = allocator, .resources = undefined, .config = normalizedConfig(.{ .radius = 8, .seed = 99, .density = 0.6, .enable_3d = enable_3d }) };
            defer system.vertices.deinit(allocator);
            defer system.grid.deinit(allocator);
            system.origin_x = 4;
            system.origin_z = -3;
            const old_origin_x = system.mesh_origin_x;
            const old_origin_z = system.mesh_origin_z;
            try system.updateMesh(camera);
            var reference: std.ArrayListUnmanaged(rhi.Vertex) = .empty;
            defer reference.deinit(allocator);
            const world_x = @as(f32, @floatFromInt(system.last_noise_center_x)) * CLOUD_SIZE + old_origin_x;
            const world_z = @as(f32, @floatFromInt(system.last_noise_center_z)) * CLOUD_SIZE + old_origin_z;
            var filled: usize = 0;
            var z: i32 = -8;
            while (z < 8) : (z += 1) {
                var x: i32 = -8;
                while (x < 8) : (x += 1) {
                    const dx = if (x >= 0) 7 - x else x;
                    const dz = if (z >= 0) 7 - z else z;
                    const expected_filled = system.gridFilled(dx + system.last_noise_center_x, dz + system.last_noise_center_z);
                    try std.testing.expectEqual(expected_filled, system.grid.items[system.gridIndex(dx, dz)]);
                    if (!expected_filled) continue;
                    filled += 1;
                    try system.emitCell(&reference, world_x + @as(f32, @floatFromInt(dx)) * CLOUD_SIZE - camera.x, -camera.y, world_z + @as(f32, @floatFromInt(dz)) * CLOUD_SIZE - camera.z, dx, dz);
                }
            }
            try std.testing.expect(filled > 1);
            var previous: f32 = -1;
            var tops: usize = 0;
            var i: usize = 0;
            while (i < system.vertices.items.len) : (i += 6) {
                const quad = system.vertices.items[i .. i + 6];
                if (quad[0].normal != reference.items[0].normal) continue;
                const cx = (quad[0].pos[0] + quad[2].pos[0]) * 0.5;
                const cz = (quad[0].pos[2] + quad[2].pos[2]) * 0.5;
                const distance = cx * cx + cz * cz;
                try std.testing.expect(distance >= previous);
                previous = distance;
                tops += 1;
            }
            try std.testing.expectEqual(filled, tops);
            try std.testing.expectEqual(reference.items.len, system.vertex_count);
            // Sort whole triangles, never their vertices: winding and all vertex
            // attributes must remain byte-identical, including duplicate triangles.
            const actual_triangles = std.mem.bytesAsSlice(Triangle, std.mem.sliceAsBytes(system.vertices.items));
            const expected_triangles = std.mem.bytesAsSlice(Triangle, std.mem.sliceAsBytes(reference.items));
            std.mem.sort(Triangle, actual_triangles, {}, Order.lessThan);
            std.mem.sort(Triangle, expected_triangles, {}, Order.lessThan);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(reference.items), std.mem.sliceAsBytes(system.vertices.items));
        }
    }
}
