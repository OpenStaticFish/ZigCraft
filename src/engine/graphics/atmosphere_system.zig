const std = @import("std");
const rhi = @import("rhi.zig");
const RHI = rhi.RHI;
const c = @import("../../c.zig").c;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;
const log = @import("../core/log.zig");

pub const AtmosphereSystem = struct {
    allocator: std.mem.Allocator,
    rhi: RHI,

    cloud_vbo: rhi.BufferHandle = 0,
    cloud_ebo: rhi.BufferHandle = 0,
    cloud_mesh_size: f32 = 2000.0,

    pub fn init(allocator: std.mem.Allocator, rhi_instance: RHI) !*AtmosphereSystem {
        const self = try allocator.create(AtmosphereSystem);
        self.* = .{
            .allocator = allocator,
            .rhi = rhi_instance,
        };

        // Create cloud mesh (large quad centered on camera)
        const cloud_vertices = [_]f32{
            -self.cloud_mesh_size, -self.cloud_mesh_size,
            self.cloud_mesh_size,  -self.cloud_mesh_size,
            self.cloud_mesh_size,  self.cloud_mesh_size,
            -self.cloud_mesh_size, self.cloud_mesh_size,
        };
        const cloud_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

        self.cloud_vbo = try rhi_instance.createBuffer(@sizeOf(@TypeOf(cloud_vertices)), .vertex);
        self.cloud_ebo = try rhi_instance.createBuffer(@sizeOf(@TypeOf(cloud_indices)), .index);

        try rhi_instance.uploadBuffer(self.cloud_vbo, std.mem.asBytes(&cloud_vertices));
        try rhi_instance.uploadBuffer(self.cloud_ebo, std.mem.asBytes(&cloud_indices));

        return self;
    }

    pub fn deinit(self: *AtmosphereSystem) void {
        if (self.cloud_vbo != 0) self.rhi.destroyBuffer(self.cloud_vbo);
        if (self.cloud_ebo != 0) self.rhi.destroyBuffer(self.cloud_ebo);
        self.allocator.destroy(self);
    }

    pub fn renderSky(self: *AtmosphereSystem, params: rhi.SkyParams) rhi.RhiError!void {
        const context = self.rhi.context();

        const pipeline_u64 = context.vtable.getNativeSkyPipeline(context.ptr);
        const layout_u64 = context.vtable.getNativeSkyPipelineLayout(context.ptr);
        const descriptor_set_u64 = context.vtable.getNativeMainDescriptorSet(context.ptr);
        const cmd_u64 = context.vtable.getNativeCommandBuffer(context.ptr);

        if (pipeline_u64 == 0 or layout_u64 == 0 or cmd_u64 == 0) {
            // Note: This may happen during early initialization before the main renderer has completed setup.
            log.log.warn("AtmosphereSystem: Sky rendering skipped, native handles missing (pipeline={}, layout={}, cmd={})", .{ pipeline_u64 != 0, layout_u64 != 0, cmd_u64 != 0 });
            if (pipeline_u64 == 0) return error.SkyPipelineNotReady;
            if (layout_u64 == 0) return error.SkyPipelineLayoutNotReady;
            if (cmd_u64 == 0) return error.CommandBufferNotReady;
            return error.ResourceNotReady;
        }

        const pipeline = @as(c.VkPipeline, @ptrFromInt(pipeline_u64));
        const layout = @as(c.VkPipelineLayout, @ptrFromInt(layout_u64));
        const descriptor_set = @as(c.VkDescriptorSet, @ptrFromInt(descriptor_set_u64));
        const cmd = @as(c.VkCommandBuffer, @ptrFromInt(cmd_u64));

        const pc = rhi.SkyPushConstants{
            .cam_forward = .{ params.cam_forward.x, params.cam_forward.y, params.cam_forward.z, 0.0 },
            .cam_right = .{ params.cam_right.x, params.cam_right.y, params.cam_right.z, 0.0 },
            .cam_up = .{ params.cam_up.x, params.cam_up.y, params.cam_up.z, 0.0 },
            .sun_dir = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, 0.0 },
            .sky_color = .{ params.sky_color.x, params.sky_color.y, params.sky_color.z, 1.0 },
            .horizon_color = .{ params.horizon_color.x, params.horizon_color.y, params.horizon_color.z, 1.0 },
            .params = .{ params.aspect, params.tan_half_fov, params.sun_intensity, params.moon_intensity },
            .time = .{ params.time, params.cam_pos.x, params.cam_pos.y, params.cam_pos.z },
        };

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        // Main descriptor set is optional for sky rendering if it only uses push constants.
        // It may be 0 if the render pass is starting but descriptors have not yet been updated for the current frame.
        if (descriptor_set_u64 != 0) {
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
        }
        c.vkCmdPushConstants(cmd, layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(rhi.SkyPushConstants), &pc);
        c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    pub fn renderClouds(self: *AtmosphereSystem, params: rhi.CloudParams, view_proj: Mat4) rhi.RhiError!void {
        const context = self.rhi.context();
        const pipeline_u64 = context.vtable.getNativeCloudPipeline(context.ptr);
        const layout_u64 = context.vtable.getNativeCloudPipelineLayout(context.ptr);
        const cmd_u64 = context.vtable.getNativeCommandBuffer(context.ptr);

        if (pipeline_u64 == 0 or layout_u64 == 0 or cmd_u64 == 0) {
            // Note: This may happen during early initialization before the main renderer has completed setup.
            log.log.warn("AtmosphereSystem: Cloud rendering skipped, native handles missing (pipeline={}, layout={}, cmd={})", .{ pipeline_u64 != 0, layout_u64 != 0, cmd_u64 != 0 });
            if (pipeline_u64 == 0) return error.CloudPipelineNotReady;
            if (layout_u64 == 0) return error.CloudPipelineLayoutNotReady;
            if (cmd_u64 == 0) return error.CommandBufferNotReady;
            return error.ResourceNotReady;
        }

        const pipeline = @as(c.VkPipeline, @ptrFromInt(pipeline_u64));
        const layout = @as(c.VkPipelineLayout, @ptrFromInt(layout_u64));
        const cmd = @as(c.VkCommandBuffer, @ptrFromInt(cmd_u64));

        const pc = rhi.CloudPushConstants{
            .view_proj = view_proj.data,
            .camera_pos = .{ params.cam_pos.x, params.cam_pos.y, params.cam_pos.z, params.cloud_height },
            .cloud_params = .{ params.cloud_coverage, params.cloud_scale, params.wind_offset_x, params.wind_offset_z },
            .sun_params = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, params.sun_intensity },
            .fog_params = .{ params.fog_color.x, params.fog_color.y, params.fog_color.z, params.fog_density },
        };

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        c.vkCmdPushConstants(cmd, layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(rhi.CloudPushConstants), &pc);

        context.bindBuffer(self.cloud_vbo, .vertex);
        context.bindBuffer(self.cloud_ebo, .index);
        context.drawIndexed(self.cloud_vbo, self.cloud_ebo, 6);
    }
};
