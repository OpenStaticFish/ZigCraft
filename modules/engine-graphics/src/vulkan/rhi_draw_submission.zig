const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const rhi_types = @import("engine-rhi").rhi_types;
const log = @import("engine-core").log;
const Mat4 = @import("engine-math").Mat4;
const pass_orchestration = @import("rhi_pass_orchestration.zig");

fn lodDescriptorSet(ctx: anytype) c.VkDescriptorSet {
    const frame = ctx.frames.current_frame;
    return ctx.descriptors.lodDescriptorSet(frame, ctx.draw.lod_descriptor_stream);
}

const ModelUniforms = extern struct {
    model: Mat4,
    color: [4]f32,
    mask_radius: f32,
};

/// Push constants for an indirect draw that must fetch instance data from the
/// bound instance buffer. Alpha is the shader's indirect sentinel so signed
/// LOD handoff masks remain valid direct-draw values.
pub fn indirectModelUniforms() ModelUniforms {
    return .{
        .model = Mat4.identity,
        .color = .{ 1.0, 1.0, 1.0, -1.0 },
        .mask_radius = 0.0,
    };
}

const ShadowModelUniforms = extern struct {
    mvp: Mat4,
    bias_params: [4]f32,
};

pub fn drawIndexed(ctx: anytype, vbo_handle: rhi.BufferHandle, ebo_handle: rhi.BufferHandle, count: u32) void {
    if (!ctx.frames.frame_in_progress) return;

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) {
        log.log.warn("drawIndexed: no active render pass after implicit main pass begin", .{});
        return;
    }

    const vbo_opt = ctx.resources.buffers.get(vbo_handle);
    const ebo_opt = ctx.resources.buffers.get(ebo_handle);

    if (vbo_opt) |vbo| {
        if (ebo_opt) |ebo| {
            ctx.runtime.draw_call_count += 1;
            const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

            if (!ctx.draw.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.water_system.pass_active)
                    if (ctx.options.wireframe_enabled and ctx.water_system.reflection_wireframe_pipeline != null)
                        ctx.water_system.reflection_wireframe_pipeline
                    else
                        ctx.water_system.reflection_terrain_pipeline
                else if (ctx.options.wireframe_enabled and ctx.pipeline_manager.wireframe_pipeline != null)
                    ctx.pipeline_manager.wireframe_pipeline
                else
                    ctx.pipeline_manager.terrain_pipeline;
                if (selected_pipeline == null) {
                    log.log.warn("drawIndexed: selected terrain pipeline is null", .{});
                    return;
                }
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.draw.terrain_pipeline_bound = !ctx.water_system.pass_active;
            }

            const descriptor_set = &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, descriptor_set, 0, null);

            const offset: c.VkDeviceSize = 0;
            c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset);
            c.vkCmdBindIndexBuffer(command_buffer, ebo.buffer, 0, c.VK_INDEX_TYPE_UINT16);
            c.vkCmdDrawIndexed(command_buffer, count, 1, 0, 0, 0);
        }
    }
}

/// Indexed, storage-buffer vertex pulling for compact far LOD tiles.  There is
/// deliberately no vertex buffer binding: the static index grid provides the
/// vertex id and binding 16 supplies the packed 16-byte samples.
pub fn drawCompactLOD(ctx: anytype, index_handle: rhi.BufferHandle, index_count: u32, params: rhi.CompactLODDraw) bool {
    if (!ctx.frames.frame_in_progress or index_count == 0 or params.width < 2 or params.layer > 1 or !ctx.draw.lod_descriptor_stream_valid) return false;
    if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
    if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) return false;
    const index = ctx.resources.buffers.get(index_handle) orelse return false;
    const index_bytes = std.math.mul(u64, @as(u64, index_count), @sizeOf(u32)) catch return false;
    if ((index.usage & c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT) == 0 or index.size < index_bytes) return false;
    const stream_index = @intFromEnum(ctx.draw.lod_descriptor_stream);
    const sample_handle = ctx.draw.lod_snapshot_bindings[ctx.frames.current_frame].compact_samples[stream_index];
    const samples = ctx.resources.buffers.get(sample_handle) orelse return false;
    if ((samples.usage & c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) == 0 or samples.size == 0 or samples.size % @sizeOf(rhi.CompactLODSampleWords) != 0) return false;

    // Every shader sample is a 16-byte uvec4. Validate the padded (one-sample
    // apron on each side) address range before recording the draw.
    const stride = std.math.add(u64, @as(u64, params.width), 2) catch return false;
    const sample_count = std.math.mul(u64, stride, stride) catch return false;
    const sample_end = std.math.add(u64, @as(u64, params.sample_offset), sample_count) catch return false;
    const sample_bytes = std.math.mul(u64, sample_end, @sizeOf(rhi.CompactLODSampleWords)) catch return false;
    if (sample_bytes > samples.size) return false;
    return recordCompactLOD(ctx, c, index.buffer, params, .{ .direct = index_count });
}

/// Compatibility-named fixed-capacity indexed submission for compact far LOD.
/// `count_handle` and `count_offset` are deliberately unused: RADV's indexed
/// indirect-count path corrupts this vertex-pulling stream, while the culler
/// guarantees every unused command is zero-filled. `max_draw_count` is the
/// submitted capacity, and zero-count entries are Vulkan no-ops.
pub fn drawCompactLODIndirectCount(ctx: anytype, index_handle: rhi.BufferHandle, command_handle: rhi.BufferHandle, offset: usize, _count_handle: rhi.BufferHandle, _count_offset: usize, max_draw_count: u32) bool {
    _ = _count_handle;
    _ = _count_offset;
    if (!ctx.frames.frame_in_progress or !ctx.vulkan_device.multi_draw_indirect or max_draw_count == 0 or !ctx.draw.lod_descriptor_stream_valid) return false;
    if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
    if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) return false;
    const index = ctx.resources.buffers.get(index_handle) orelse return false;
    const commands = ctx.resources.buffers.get(command_handle) orelse return false;
    const fi = ctx.frames.current_frame;
    const stream_index = @intFromEnum(ctx.draw.lod_descriptor_stream);
    const snapshots = ctx.draw.lod_snapshot_bindings[fi];
    const samples = ctx.resources.buffers.get(snapshots.compact_samples[stream_index]) orelse return false;
    const instances = ctx.resources.buffers.get(snapshots.compact_instances[stream_index]) orelse return false;
    if ((index.usage & c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT) == 0 or (commands.usage & c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT) == 0) return false;
    if ((samples.usage & c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) == 0 or (instances.usage & c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) == 0) return false;
    if (index.size == 0 or index.size % @sizeOf(u32) != 0) return false;
    const command_bytes = std.math.mul(usize, max_draw_count, @sizeOf(rhi_types.DrawIndexedIndirectCommand)) catch return false;
    const command_end = std.math.add(usize, offset, command_bytes) catch return false;
    if (command_end > commands.size) return false;
    const sentinel = rhi.CompactLODDraw{ .model = Mat4.identity, .mask_radius = 0, .lod_fade = 0, .sample_offset = 0, .width = 0, .cell_size = 0, .layer = 2, .skirt_depth = 0 };
    return recordCompactLOD(ctx, c, index.buffer, sentinel, .{ .indirect = .{
        .buffer = commands.buffer,
        .offset = @intCast(offset),
        .capacity = max_draw_count,
    } });
}

pub const CompactLODSubmission = union(enum) {
    direct: u32,
    indirect: struct { buffer: c.VkBuffer, offset: c.VkDeviceSize, capacity: u32 },
};

/// Shared recording policy after buffer validation. The Vulkan command sink is
/// injectable so pipeline ordering can be checked without a device.
pub fn recordCompactLOD(ctx: anytype, vk: anytype, index: c.VkBuffer, params: rhi.CompactLODDraw, submission: CompactLODSubmission) bool {
    if (!ctx.draw.lod_descriptor_stream_valid) return false;
    const layer: u32 = switch (submission) {
        .direct => params.layer,
        // pass_active denotes reflection rendering, not the main-pass water scope.
        .indirect => switch (ctx.draw.lod_descriptor_stream) {
            .terrain_compact_gpu => 0,
            .water_compact_gpu => 1,
            else => return false,
        },
    };
    if (layer > 1) return false;
    const pipeline = if (layer == 1) ctx.pipeline_manager.compact_lod_water_pipeline else ctx.pipeline_manager.compact_lod_terrain_pipeline;
    const restore_pipeline = if (layer == 1) ctx.water_system.water_pipeline else null;
    // Do not partially record water if expanded/full chunk water cannot resume.
    if (pipeline == null or (layer == 1 and restore_pipeline == null)) return false;

    const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
    vk.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    ctx.draw.terrain_pipeline_bound = false;
    const descriptor_set = lodDescriptorSet(ctx);
    vk.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);
    vk.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(rhi.CompactLODDraw), &params);
    vk.vkCmdBindIndexBuffer(cb, index, 0, c.VK_INDEX_TYPE_UINT32);
    switch (submission) {
        .direct => |count| vk.vkCmdDrawIndexed(cb, count, 1, 0, 0, 0),
        // Preserve the RADV workaround: the culler zero-fills unused commands,
        // so fixed-capacity indexed MDI needs neither indirect-count nor readback.
        .indirect => |commands| vk.vkCmdDrawIndexedIndirect(cb, commands.buffer, commands.offset, commands.capacity, @sizeOf(rhi_types.DrawIndexedIndirectCommand)),
    }
    ctx.runtime.draw_call_count += 1;
    if (restore_pipeline != null) {
        vk.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, restore_pipeline);
        // beginWaterDraw uses this flag to suppress ordinary terrain rebinding.
        ctx.draw.terrain_pipeline_bound = true;
    }
    return true;
}

pub fn drawIndirect(ctx: anytype, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.draw.lod_mode and !ctx.draw.lod_descriptor_stream_valid) return;

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) {
        log.log.warn("drawIndirect: no active render pass after implicit main pass begin", .{});
        return;
    }

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.runtime.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);
    const cmd_opt = ctx.resources.buffers.get(command_buffer);

    if (vbo_opt) |vbo| {
        if (cmd_opt) |cmd| {
            ctx.runtime.draw_call_count += 1;
            const cb = ctx.frames.command_buffers[ctx.frames.current_frame];

            if (use_shadow) {
                if (!ctx.shadow_system.pipeline_bound) {
                    if (ctx.shadow_system.shadow_pipeline == null) {
                        log.log.warn("drawIndirect: shadow pipeline is null", .{});
                        return;
                    }
                    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                    ctx.shadow_system.pipeline_bound = true;
                }
            } else if (use_g_pass) {
                if (ctx.pipeline_manager.g_pipeline == null) {
                    log.log.warn("drawIndirect: g-pass pipeline is null", .{});
                    return;
                }
                c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);
            } else {
                if (!ctx.draw.terrain_pipeline_bound) {
                    const selected_pipeline = if (ctx.water_system.pass_active)
                        if (ctx.options.wireframe_enabled and ctx.water_system.reflection_wireframe_pipeline != null)
                            ctx.water_system.reflection_wireframe_pipeline
                        else
                            ctx.water_system.reflection_terrain_pipeline
                    else if (ctx.options.wireframe_enabled and ctx.pipeline_manager.wireframe_pipeline != null)
                        ctx.pipeline_manager.wireframe_pipeline
                    else
                        ctx.pipeline_manager.terrain_pipeline;
                    if (selected_pipeline == null) {
                        log.log.warn("drawIndirect: main pipeline (selected_pipeline) is null - cannot draw terrain", .{});
                        return;
                    }
                    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                    ctx.draw.terrain_pipeline_bound = !ctx.water_system.pass_active and selected_pipeline == ctx.pipeline_manager.terrain_pipeline;
                }
            }

            const descriptor_set = if (ctx.draw.lod_mode)
                lodDescriptorSet(ctx)
            else
                ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);

            if (use_shadow) {
                const cascade_index = ctx.shadow_system.pass_index;
                const texel_size = ctx.shadow_runtime.shadow_texel_sizes[cascade_index];
                const shadow_uniforms = ShadowModelUniforms{
                    .mvp = ctx.shadow_system.pass_matrix,
                    .bias_params = .{ 0.0, -1.0, @floatFromInt(cascade_index), texel_size },
                };
                c.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
            } else {
                const uniforms = indirectModelUniforms();
                c.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
            }

            const offset_vals = [_]c.VkDeviceSize{0};
            c.vkCmdBindVertexBuffers(cb, 0, 1, &vbo.buffer, &offset_vals);

            if (cmd.is_host_visible and draw_count > 0 and stride > 0) {
                const stride_bytes: usize = @intCast(stride);
                const map_size: usize = @as(usize, @intCast(draw_count)) * stride_bytes;
                const cmd_size: usize = @intCast(cmd.size);
                if (offset <= cmd_size and map_size <= cmd_size - offset) {
                    if (cmd.mapped_ptr) |ptr| {
                        const base = @as([*]const u8, @ptrCast(ptr)) + offset;
                        var draw_index: u32 = 0;
                        while (draw_index < draw_count) : (draw_index += 1) {
                            const cmd_ptr = @as(*const rhi.DrawIndirectCommand, @ptrCast(@alignCast(base + @as(usize, draw_index) * stride_bytes)));
                            const draw_cmd = cmd_ptr.*;
                            if (draw_cmd.vertexCount == 0 or draw_cmd.instanceCount == 0) continue;
                            c.vkCmdDraw(cb, draw_cmd.vertexCount, draw_cmd.instanceCount, draw_cmd.firstVertex, draw_cmd.firstInstance);
                        }
                        return;
                    }
                } else {
                    log.log.warn("drawIndirect: command buffer range out of bounds (offset={}, size={}, buffer={})", .{ offset, map_size, cmd_size });
                }
            }

            if (ctx.vulkan_device.multi_draw_indirect) {
                c.vkCmdDrawIndirect(cb, cmd.buffer, @intCast(offset), draw_count, stride);
            } else {
                const stride_bytes: usize = @intCast(stride);
                var draw_index: u32 = 0;
                while (draw_index < draw_count) : (draw_index += 1) {
                    const draw_offset = offset + @as(usize, draw_index) * stride_bytes;
                    c.vkCmdDrawIndirect(cb, cmd.buffer, @intCast(draw_offset), 1, stride);
                }
                log.log.trace("drawIndirect: MDI unsupported - drew {} draws via single-draw fallback", .{draw_count});
            }
        }
    }
}

/// Compatibility-named fixed-capacity submission for compute-compacted
/// streams. `count_buffer` and `count_offset` are deliberately unused because
/// RADV's indirect-count path is avoided; the culler zero-fills unused commands.
pub fn drawIndirectCount(ctx: anytype, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, _count_buffer: rhi.BufferHandle, _count_offset: usize, max_draw_count: u32, stride: u32) bool {
    _ = _count_buffer;
    _ = _count_offset;
    if (!ctx.frames.frame_in_progress or !ctx.vulkan_device.multi_draw_indirect or max_draw_count == 0 or (ctx.draw.lod_mode and !ctx.draw.lod_descriptor_stream_valid)) return false;
    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) return false;
    const vbo = ctx.resources.buffers.get(handle) orelse return false;
    const commands = ctx.resources.buffers.get(command_buffer) orelse return false;
    const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.runtime.g_pass_active;
    if (use_shadow) {
        if (!ctx.shadow_system.pipeline_bound) {
            if (ctx.shadow_system.shadow_pipeline == null) return false;
            c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
            ctx.shadow_system.pipeline_bound = true;
        }
    } else if (use_g_pass) {
        if (ctx.pipeline_manager.g_pipeline == null) return false;
        c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);
    } else if (!ctx.draw.terrain_pipeline_bound) {
        const pipeline = if (ctx.water_system.pass_active)
            if (ctx.options.wireframe_enabled and ctx.water_system.reflection_wireframe_pipeline != null) ctx.water_system.reflection_wireframe_pipeline else ctx.water_system.reflection_terrain_pipeline
        else if (ctx.options.wireframe_enabled and ctx.pipeline_manager.wireframe_pipeline != null) ctx.pipeline_manager.wireframe_pipeline else ctx.pipeline_manager.terrain_pipeline;
        if (pipeline == null) return false;
        c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        ctx.draw.terrain_pipeline_bound = !ctx.water_system.pass_active and pipeline == ctx.pipeline_manager.terrain_pipeline;
    }
    const descriptor_set = if (ctx.draw.lod_mode) lodDescriptorSet(ctx) else ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    c.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);
    const uniforms = indirectModelUniforms();
    c.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
    const offsets = [_]c.VkDeviceSize{0};
    c.vkCmdBindVertexBuffers(cb, 0, 1, &vbo.buffer, &offsets);
    // See drawCompactLODIndirectCount. The compute pass zeroes the remainder
    // of each fixed-capacity stream, making this regular MDI submission exactly
    // match the compacted count without a CPU readback or a RADV count-path.
    c.vkCmdDrawIndirect(cb, commands.buffer, @intCast(offset), max_draw_count, stride);
    ctx.runtime.draw_call_count += 1;
    return true;
}

pub fn drawInstance(ctx: anytype, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.draw.lod_mode and !ctx.draw.lod_descriptor_stream_valid) return;

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.runtime.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);

    if (vbo_opt) |vbo| {
        ctx.runtime.draw_call_count += 1;
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        if (use_shadow) {
            if (!ctx.shadow_system.pipeline_bound) {
                if (ctx.shadow_system.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                ctx.shadow_system.pipeline_bound = true;
            }
        } else if (use_g_pass) {
            if (ctx.pipeline_manager.g_pipeline == null) return;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);
        } else {
            if (!ctx.draw.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.water_system.pass_active)
                    if (ctx.options.wireframe_enabled and ctx.water_system.reflection_wireframe_pipeline != null)
                        ctx.water_system.reflection_wireframe_pipeline
                    else
                        ctx.water_system.reflection_terrain_pipeline
                else if (ctx.options.wireframe_enabled and ctx.pipeline_manager.wireframe_pipeline != null)
                    ctx.pipeline_manager.wireframe_pipeline
                else
                    ctx.pipeline_manager.terrain_pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.draw.terrain_pipeline_bound = !ctx.water_system.pass_active and selected_pipeline == ctx.pipeline_manager.terrain_pipeline;
            }
        }

        const descriptor_set = if (ctx.draw.lod_mode)
            lodDescriptorSet(ctx)
        else
            ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);

        if (use_shadow) {
            const cascade_index = ctx.shadow_system.pass_index;
            const texel_size = ctx.shadow_runtime.shadow_texel_sizes[cascade_index];
            const shadow_uniforms = ShadowModelUniforms{
                .mvp = ctx.shadow_system.pass_matrix.multiply(ctx.draw.current_model),
                .bias_params = .{ 0.0, 1.0, @floatFromInt(cascade_index), texel_size },
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = Mat4.identity,
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
                .mask_radius = 0,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
        }

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, count, 1, 0, instance_index);
    }
}

pub fn drawOffset(ctx: anytype, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
    if (!ctx.frames.frame_in_progress) {
        log.log.warn("drawOffset: no frame in progress", .{});
        return;
    }
    if (ctx.draw.lod_mode and !ctx.draw.lod_descriptor_stream_valid) return;

    if (ctx.post_process.pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        c.vkCmdDraw(command_buffer, count, 1, 0, 0);
        ctx.runtime.draw_call_count += 1;
        return;
    }

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) {
        log.log.warn("drawOffset: beginning main pass internally", .{});
        pass_orchestration.beginMainPassInternal(ctx);
    }

    if (!ctx.runtime.main_pass_active and !ctx.shadow_system.pass_active and !ctx.runtime.g_pass_active and !ctx.water_system.pass_active) {
        log.log.warn("drawOffset: still no main pass after beginMainPassInternal", .{});
        return;
    }

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.runtime.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);

    if (vbo_opt) |vbo| {
        const vertex_stride: u64 = @sizeOf(rhi.Vertex);
        const required_bytes: u64 = @as(u64, offset) + @as(u64, count) * vertex_stride;
        if (required_bytes > vbo.size) {
            log.log.err("drawOffset: vertex buffer overrun (handle={}, offset={}, count={}, size={})", .{ handle, offset, count, vbo.size });
            return;
        }

        ctx.runtime.draw_call_count += 1;

        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        if (use_shadow) {
            if (!ctx.shadow_system.pipeline_bound) {
                if (ctx.shadow_system.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                ctx.shadow_system.pipeline_bound = true;
            }
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &ctx.descriptors.descriptor_sets[ctx.frames.current_frame], 0, null);
        } else if (use_g_pass) {
            if (ctx.pipeline_manager.g_pipeline == null) return;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);

            const descriptor_set = &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, descriptor_set, 0, null);
        } else {
            const needs_rebinding = !ctx.draw.terrain_pipeline_bound or ctx.ui.selection_mode or mode == .lines;
            if (needs_rebinding) {
                const selected_pipeline = if (ctx.water_system.pass_active)
                    if (ctx.ui.selection_mode and ctx.water_system.reflection_selection_pipeline != null)
                        ctx.water_system.reflection_selection_pipeline
                    else if (mode == .lines and ctx.water_system.reflection_line_pipeline != null)
                        ctx.water_system.reflection_line_pipeline
                    else if (ctx.options.wireframe_enabled and ctx.water_system.reflection_wireframe_pipeline != null)
                        ctx.water_system.reflection_wireframe_pipeline
                    else
                        ctx.water_system.reflection_terrain_pipeline
                else if (ctx.ui.selection_mode and ctx.pipeline_manager.selection_pipeline != null)
                    ctx.pipeline_manager.selection_pipeline
                else if (mode == .lines and ctx.pipeline_manager.line_pipeline != null)
                    ctx.pipeline_manager.line_pipeline
                else if (ctx.options.wireframe_enabled and ctx.pipeline_manager.wireframe_pipeline != null)
                    ctx.pipeline_manager.wireframe_pipeline
                else
                    ctx.pipeline_manager.terrain_pipeline;
                if (selected_pipeline == null) {
                    log.log.warn("drawOffset: selected_pipeline is null", .{});
                    return;
                }
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.draw.terrain_pipeline_bound = !ctx.water_system.pass_active and selected_pipeline == ctx.pipeline_manager.terrain_pipeline;
            }

            const descriptor_set = if (ctx.draw.lod_mode)
                lodDescriptorSet(ctx)
            else
                ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);
        }

        if (use_shadow) {
            const cascade_index = ctx.shadow_system.pass_index;
            const texel_size = ctx.shadow_runtime.shadow_texel_sizes[cascade_index];
            const shadow_uniforms = ShadowModelUniforms{
                .mvp = ctx.shadow_system.pass_matrix.multiply(ctx.draw.current_model),
                .bias_params = .{ 0.0, 1.0, @floatFromInt(cascade_index), texel_size },
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = ctx.draw.current_model,
                .color = ctx.draw.current_color,
                .mask_radius = ctx.draw.current_mask_radius,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
        }

        const offset_vbo: c.VkDeviceSize = @intCast(offset);
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset_vbo);
        c.vkCmdDraw(command_buffer, count, 1, 0, 0);
    } else {
        log.log.warn("drawOffset: vertex buffer not found (handle={})", .{handle});
    }
}

pub fn bindBuffer(ctx: anytype, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
    if (!ctx.frames.frame_in_progress) return;

    const buf_opt = ctx.resources.buffers.get(handle);

    if (buf_opt) |buf| {
        const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
        const offset: c.VkDeviceSize = 0;
        switch (usage) {
            .vertex => c.vkCmdBindVertexBuffers(cb, 0, 1, &buf.buffer, &offset),
            .index => c.vkCmdBindIndexBuffer(cb, buf.buffer, 0, c.VK_INDEX_TYPE_UINT16),
            else => {},
        }
    }
}

pub fn pushConstants(ctx: anytype, stages: rhi.ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
    if (!ctx.frames.frame_in_progress) return;

    var vk_stages: c.VkShaderStageFlags = 0;
    if (stages.vertex) vk_stages |= c.VK_SHADER_STAGE_VERTEX_BIT;
    if (stages.fragment) vk_stages |= c.VK_SHADER_STAGE_FRAGMENT_BIT;
    if (stages.compute) vk_stages |= c.VK_SHADER_STAGE_COMPUTE_BIT;

    const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, vk_stages, offset, size, data);
}
