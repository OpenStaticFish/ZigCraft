const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Mat4 = @import("engine-math").Mat4;
const pass_orchestration = @import("rhi_pass_orchestration.zig");

const ModelUniforms = extern struct {
    model: Mat4,
    color: [4]f32,
};

/// Push constants for an indirect draw that fetches per-instance model data.
pub fn indirectModelUniforms() ModelUniforms {
    return .{
        .model = Mat4.identity,
        .color = .{ 1.0, 1.0, 1.0, -1.0 },
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

pub fn drawIndirect(ctx: anytype, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    if (!ctx.frames.frame_in_progress) return;

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

            const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
    if (!ctx.frames.frame_in_progress or !ctx.vulkan_device.multi_draw_indirect or max_draw_count == 0) return false;
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
    const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    c.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &descriptor_set, 0, null);
    const uniforms = indirectModelUniforms();
    c.vkCmdPushConstants(cb, ctx.pipeline_manager.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
    const offsets = [_]c.VkDeviceSize{0};
    c.vkCmdBindVertexBuffers(cb, 0, 1, &vbo.buffer, &offsets);
    c.vkCmdDrawIndirect(cb, commands.buffer, @intCast(offset), max_draw_count, stride);
    ctx.runtime.draw_call_count += 1;
    return true;
}

pub fn drawInstance(ctx: anytype, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
    if (!ctx.frames.frame_in_progress) return;

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

        const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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

            const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
