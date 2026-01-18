const std = @import("std");
const rhi = @import("rhi.zig");
const IGraphicsCommandEncoder = rhi.IGraphicsCommandEncoder;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;

pub const AtmosphereSystem = struct {
    allocator: std.mem.Allocator,
    rhi: rhi.RHI,

    cloud_vbo: rhi.BufferHandle = 0,
    cloud_ebo: rhi.BufferHandle = 0,
    cloud_mesh_size: f32 = 2000.0,

    pub fn init(allocator: std.mem.Allocator, rhi_instance: rhi.RHI) !*AtmosphereSystem {
        const self = try allocator.create(AtmosphereSystem);
        self.* = .{
            .allocator = allocator,
            .rhi = rhi_instance,
        };

        return self;
    }

    pub fn deinit(self: *AtmosphereSystem) void {
        if (self.cloud_vbo != 0) self.rhi.destroyBuffer(self.cloud_vbo);
        if (self.cloud_ebo != 0) self.rhi.destroyBuffer(self.cloud_ebo);
        self.allocator.destroy(self);
    }

    pub fn createCloudGeometry(self: *AtmosphereSystem) !void {
        const cloud_vertices = [_]f32{
            -self.cloud_mesh_size, -self.cloud_mesh_size,
            self.cloud_mesh_size,  -self.cloud_mesh_size,
            self.cloud_mesh_size,  self.cloud_mesh_size,
            -self.cloud_mesh_size, self.cloud_mesh_size,
        };
        const cloud_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

        self.cloud_vbo = self.rhi.createBuffer(@sizeOf(@TypeOf(cloud_vertices)), .vertex);
        self.cloud_ebo = self.rhi.createBuffer(@sizeOf(@TypeOf(cloud_indices)), .index);

        self.rhi.uploadBuffer(self.cloud_vbo, std.mem.asBytes(&cloud_vertices));
        self.rhi.uploadBuffer(self.cloud_ebo, std.mem.asBytes(&cloud_indices));
    }

    pub fn renderClouds(self: *AtmosphereSystem, encoder: IGraphicsCommandEncoder, params: rhi.CloudParams, view_proj: Mat4) void {
        _ = self;
        _ = encoder;
        _ = params;
        _ = view_proj;
    }

    pub fn renderSky(self: *AtmosphereSystem, encoder: IGraphicsCommandEncoder, params: rhi.SkyParams) void {
        _ = self;
        _ = encoder;
        _ = params;
    }
};
