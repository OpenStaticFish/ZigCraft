const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const bindings = @import("descriptor_bindings.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const GlobalUniforms = extern struct {
    view_proj: Mat4,
    view_proj_prev: Mat4,
    cam_pos: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    fog_color: [4]f32,
    reserved0: [4]f32,
    params: [4]f32,
    lighting: [4]f32,
    render_flags: [4]f32,
    shadow_params: [4]f32,
    pbr_params: [4]f32,
    volumetric_params: [4]f32,
    viewport_size: [4]f32,
    lpv_params: [4]f32,
    lpv_origin: [4]f32,
};

pub fn updateGlobalUniforms(ctx: anytype, uniforms: rhi.GlobalUniforms, frame_params: rhi.FrameRenderParams) !void {
    const global_uniforms = GlobalUniforms{
        .view_proj = uniforms.view_proj,
        .view_proj_prev = ctx.velocity.view_proj_prev,
        .cam_pos = .{ uniforms.cam_pos.x, uniforms.cam_pos.y, uniforms.cam_pos.z, 1.0 },
        .sun_dir = .{ uniforms.sun_dir.x, uniforms.sun_dir.y, uniforms.sun_dir.z, 0.0 },
        .sun_color = .{ uniforms.sun_color.x, uniforms.sun_color.y, uniforms.sun_color.z, 1.0 },
        .fog_color = .{ uniforms.fog_color.x, uniforms.fog_color.y, uniforms.fog_color.z, 1.0 },
        .reserved0 = .{ 0.0, 0.0, 0.0, 0.0 },
        .params = .{ uniforms.time, uniforms.fog_density, if (uniforms.fog_enabled) 1.0 else 0.0, uniforms.sun_intensity },
        .lighting = .{ uniforms.ambient, if (uniforms.use_texture) 1.0 else 0.0, if (frame_params.pbr_enabled) 1.0 else 0.0, 0.0 },
        .render_flags = .{ 0.0, 0.0, if (frame_params.pbr_enabled) 1.0 else 0.0, 0.0 },
        .shadow_params = .{ @floatFromInt(frame_params.shadow.pcf_samples), if (frame_params.shadow.cascade_blend) 1.0 else 0.0, frame_params.shadow.strength, if (frame_params.shadow_apply_to_beauty) 1.0 else 0.0 },
        .pbr_params = .{ @floatFromInt(frame_params.pbr_quality), frame_params.exposure, frame_params.saturation, if (frame_params.ssao_enabled) 1.0 else 0.0 },
        .volumetric_params = .{ if (frame_params.volumetric_enabled) 1.0 else 0.0, frame_params.volumetric_density, @floatFromInt(frame_params.volumetric_steps), frame_params.volumetric_scattering },
        .viewport_size = .{ @floatFromInt(ctx.swapchain.swapchain.extent.width), @floatFromInt(ctx.swapchain.swapchain.extent.height), if (ctx.options.debug_shadows_active) 1.0 else 0.0, @floatFromInt(ctx.options.shadow_debug_channel) },
        .lpv_params = .{ if (frame_params.lpv_enabled) 1.0 else 0.0, frame_params.lpv_intensity, frame_params.lpv_cell_size, @floatFromInt(frame_params.lpv_grid_size) },
        .lpv_origin = .{ frame_params.lpv_origin.x, frame_params.lpv_origin.y, frame_params.lpv_origin.z, 0.0 },
    };

    // Env var override for debug channel (ZIGCRAFT_DEBUG_SHADER=5 for tile_id, 6 for tex_color)
    if (getenv("ZIGCRAFT_DEBUG_SHADER")) |ds| {
        const ch: u32 = std.fmt.parseInt(u32, ds, 10) catch 0;
        if (ch > 0) {
            var gu = global_uniforms;
            gu.viewport_size[2] = 1.0;
            gu.viewport_size[3] = @floatFromInt(ch);
            try ctx.descriptors.updateGlobalUniforms(ctx.frames.current_frame, &gu);
            return;
        }
    }

    try ctx.descriptors.updateGlobalUniforms(ctx.frames.current_frame, &global_uniforms);
    ctx.velocity.view_proj_prev = uniforms.view_proj;
}

pub fn setModelMatrix(ctx: anytype, model: Mat4, color: Vec3) void {
    ctx.draw.current_model = model;
    ctx.draw.current_color = .{ color.x, color.y, color.z, 1.0 };
}

pub fn setInstanceBuffer(ctx: anytype, handle: rhi.BufferHandle) void {
    if (!ctx.frames.frame_in_progress) return;
    ctx.draw.pending_instance_buffer = handle;
    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
}

pub fn setTerrainPipelineBound(ctx: anytype, bound: bool) void {
    ctx.draw.terrain_pipeline_bound = bound;
}

pub fn setSelectionMode(ctx: anytype, enabled: bool) void {
    ctx.ui.selection_mode = enabled;
}

pub fn applyPendingDescriptorUpdates(ctx: anytype, frame_index: usize) void {
    if (ctx.draw.pending_instance_buffer != 0 and ctx.draw.bound_instance_buffer[frame_index] != ctx.draw.pending_instance_buffer) {
        const buf_opt = ctx.resources.buffers.get(ctx.draw.pending_instance_buffer);

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptors.descriptor_sets[frame_index];
            write.dstBinding = bindings.INSTANCE_SSBO;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.draw.bound_instance_buffer[frame_index] = ctx.draw.pending_instance_buffer;
        }
    }
}
