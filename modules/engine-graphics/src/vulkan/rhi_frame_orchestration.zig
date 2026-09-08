const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const build_options = @import("engine_graphics_options");
const bindings = @import("descriptor_bindings.zig");
const lifecycle = @import("rhi_resource_lifecycle.zig");
const final_composition = @import("final_composition.zig");
const setup = @import("rhi_resource_setup.zig");

pub fn recreatePendingShadowResources(ctx: anytype) void {
    const requested = ctx.shadow_runtime.pending_shadow_resolution orelse return;
    ctx.shadow_runtime.pending_shadow_resolution = null;
    if (requested == ctx.shadow_runtime.shadow_resolution) return;

    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    const previous = ctx.shadow_runtime.shadow_resolution;
    var previous_system = ctx.shadow_system;
    const previous_handles = ctx.shadow_runtime.shadow_map_handles;

    ctx.shadow_system = @TypeOf(ctx.shadow_system).init(ctx.allocator, requested) catch return;
    ctx.shadow_runtime.shadow_resolution = requested;
    ctx.shadow_runtime.shadow_map_handles = .{0} ** rhi.SHADOW_CASCADE_COUNT;
    setup.createShadowResources(ctx) catch |err| {
        log.log.err("Failed to create {}px shadow resources: {}; retaining {}px resources", .{ requested, err, previous });
        for (ctx.shadow_runtime.shadow_map_handles) |handle| if (handle != 0) ctx.resources.destroyTexture(handle);
        ctx.shadow_system.deinit(ctx.vulkan_device.vk_device);
        ctx.shadow_system = previous_system;
        ctx.shadow_runtime.shadow_resolution = previous;
        ctx.shadow_runtime.shadow_map_handles = previous_handles;
        return;
    };

    if (ctx.shadow_system.shadow_image != null) {
        lifecycle.transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true, rhi.SHADOW_CASCADE_COUNT) catch |err| {
            log.log.err("Failed to transition recreated shadow array: {}", .{err});
            for (ctx.shadow_runtime.shadow_map_handles) |handle| if (handle != 0) ctx.resources.destroyTexture(handle);
            ctx.shadow_system.deinit(ctx.vulkan_device.vk_device);
            ctx.shadow_system = previous_system;
            ctx.shadow_runtime.shadow_resolution = previous;
            ctx.shadow_runtime.shadow_map_handles = previous_handles;
            return;
        };
        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
            ctx.draw.bound_shadow_views[i] = null;
        }
    }

    for (previous_handles) |handle| if (handle != 0) ctx.resources.destroyTexture(handle);
    previous_system.deinit(ctx.vulkan_device.vk_device);
    log.log.info("Shadow resources recreated at {}x{}", .{ ctx.shadow_runtime.shadow_resolution, ctx.shadow_runtime.shadow_resolution });
}

pub fn recreateSwapchainInternal(ctx: anytype) void {
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) return;

    setup.destroyMainRenderPassAndPipelines(ctx);
    lifecycle.destroyHDRResources(ctx);
    lifecycle.destroyFXAAResources(ctx);
    lifecycle.destroyTAAResources(ctx);
    lifecycle.destroyBloomResources(ctx);
    lifecycle.destroyPostProcessResources(ctx);
    lifecycle.destroyGPassResources(ctx);
    lifecycle.destroyUpscaleResources(ctx);

    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.g_pass_active = false;
    ctx.runtime.ssao_pass_active = false;

    ctx.swapchain.recreate() catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "swapchain", err);
        return;
    };

    if (!ctx.swapchain.skip_present) {
        lifecycle.transitionImagesToPresent(ctx, ctx.swapchain.swapchain.images.items) catch |err| {
            log.log.warn("Failed to transition swapchain images to PRESENT: {}", .{err});
        };
    } else {
        lifecycle.transitionImagesToColorAttachment(ctx, ctx.swapchain.swapchain.images.items) catch |err| {
            log.log.warn("Failed to transition headless image to COLOR_ATTACHMENT: {}", .{err});
        };
    }

    lifecycle.createHDRResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "HDR resources", err);
        return;
    };
    setup.createGPassResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "G-Pass resources", err);
        return;
    };
    setup.createSSAOResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "SSAO resources", err);
        return;
    };
    setup.createTAAResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "TAA resources", err);
        return;
    };
    if (ctx.water_system.reflection_texture_handle != 0) {
        ctx.resources.destroyTexture(ctx.water_system.reflection_texture_handle);
        ctx.water_system.reflection_texture_handle = 0;
    }
    ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), ctx.options.msaa_samples) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "render pass", err);
        return;
    };
    ctx.pipeline_manager.createMainPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, ctx.render_pass_manager.g_render_pass, ctx.options.msaa_samples) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "pipelines", err);
        return;
    };
    setup.createWaterResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "water resources", err);
        return;
    };

    ctx.draw.current_water_reflection_texture = if (ctx.water_system.reflection_texture_handle != 0)
        ctx.water_system.reflection_texture_handle
    else
        ctx.draw.dummy_texture;
    ctx.draw.current_scene_depth_texture = if (ctx.gpass.g_depth_handle != 0)
        ctx.gpass.g_depth_handle
    else
        ctx.draw.dummy_texture;

    ctx.water_system.createWaterPipeline(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, ctx.options.msaa_samples) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "water pipeline", err);
        return;
    };
    ctx.water_system.createReflectionTerrainPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.pipeline_manager.pipeline_layout) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "reflection terrain pipelines", err);
        return;
    };
    setup.createPostProcessResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "post-process resources", err);
        return;
    };
    setup.createSwapchainUIResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "swapchain UI resources", err);
        return;
    };
    ctx.fxaa.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.swapchain.getExtent(), ctx.swapchain.getImageFormat(), ctx.post_process.sampler, ctx.swapchain.getImageViews(), final_composition.displayLayout(ctx.swapchain.skip_present)) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "FXAA resources", err);
        return;
    };
    ctx.pipeline_manager.createSwapchainUIPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.ui_swapchain_render_pass) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "swapchain UI pipelines", err);
        return;
    };
    ctx.bloom.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.hdr.hdr_view, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, c.VK_FORMAT_R16G16B16A16_SFLOAT) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "Bloom resources", err);
        return;
    };
    setup.updatePostProcessDescriptorsWithBloom(ctx);
    lifecycle.initializePostProcessInputs(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "post-process inputs", err);
        return;
    };

    setup.createUpscaleResources(ctx) catch |err| {
        _ = markSwapchainRecreateFailed(ctx, "upscale resources", err);
        return;
    };

    ctx.dynamic_resolution.setSwapchainExtent(ctx.swapchain.getExtent());

    if (!ctx.options.safe_mode) {
        var list: [32]c.VkImage = undefined;
        var count: usize = 0;
        const candidates = [_]c.VkImage{ ctx.gpass.g_normal_image, ctx.ssao_system.image, ctx.ssao_system.blur_image, ctx.ssao_system.noise_image, ctx.velocity.velocity_image };
        for (candidates) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }

        if (count > 0) {
            lifecycle.transitionImagesToShaderRead(ctx, list[0..count], false, 1) catch |err| log.log.warn("Failed to transition images: {}", .{err});
        }

        if (ctx.shadow_system.shadow_image != null) {
            lifecycle.transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true, rhi.SHADOW_CASCADE_COUNT) catch |err| log.log.warn("Failed to transition Shadow image: {}", .{err});
            for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
                ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
            }
        }
    }

    markSwapchainRecreateSucceeded(ctx);
}

pub fn markSwapchainRecreateFailed(ctx: anytype, stage: []const u8, err: anyerror) bool {
    const already_failed = ctx.runtime.swapchain_recreate_failed;
    ctx.runtime.swapchain_recreate_failed = true;
    // Consume the resize request instead of re-arming it. Re-arming here would
    // cause beginFrame to retry the recreation every frame; if the failure is
    // persistent (e.g. SSAO allocation under memory pressure) this loops
    // forever. The swapchain_recreate_failed flag above gates retries until a
    // fresh request (resize / vsync / msaa change) clears it.
    ctx.runtime.framebuffer_resized = false;
    ctx.runtime.pipeline_rebuild_needed = true;
    if (!already_failed) {
        log.log.errWithTrace("Failed to recreate swapchain at {s}: {}", .{ stage, err });
        return true;
    }
    return false;
}

pub fn markSwapchainRecreateSucceeded(ctx: anytype) void {
    ctx.runtime.framebuffer_resized = false;
    ctx.runtime.pipeline_rebuild_needed = false;
    ctx.runtime.swapchain_recreate_failed = false;
}

pub fn startFrame(ctx: anytype) !bool {
    if (ctx.frames.terminal_failure) return error.GpuLost;
    const faults_before = ctx.vulkan_device.fault_count;
    const started = ctx.frames.beginFrame(&ctx.swapchain) catch |err| {
        if (ctx.frames.terminal_failure) {
            ctx.runtime.gpu_fault_detected = true;
            if (ctx.vulkan_device.fault_count == faults_before) ctx.vulkan_device.fault_count +|= 1;
        }
        return err;
    };
    // Both success and OutOfDate have retired this slot's graphics fence.
    // Updates/uploads still run after a benign skip, so they must not keep
    // recording into the previous slot's potentially pending transfer buffer.
    ctx.resources.setCurrentFrame(ctx.frames.current_frame);
    return started;
}

pub fn prepareFrameState(ctx: anytype) void {
    if (ctx.frames.terminal_failure or !ctx.frames.frame_in_progress) return;
    ctx.descriptors.beginFrame(ctx.frames.current_frame);
    ctx.draw.pending_instance_buffer = 0;
    ctx.runtime.draw_call_count = 0;
    ctx.runtime.lpv_recorded_this_frame = false;
    ctx.runtime.first_main_pass_draw_logged = false;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.post_process_ran_this_frame = false;
    ctx.runtime.fxaa_ran_this_frame = false;
    ctx.runtime.direct_ui_composed_this_frame = false;
    ctx.runtime.final_composed.clear();
    ctx.taa.beginFrame();
    ctx.ui.ui_using_swapchain = false;
    ctx.ui.ui_swapchain_pass_active = false;
    ctx.ui.ui_swapchain_clears_output = false;

    ctx.draw.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;

    const command_buffer = ctx.frames.getCurrentCommandBuffer();

    if (ctx.runtime.transfer_barrier_needed) {
        var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        mem_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT;
        mem_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
        c.vkCmdPipelineBarrier(
            command_buffer,
            c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            0,
            1,
            &mem_barrier,
            0,
            null,
            0,
            null,
        );
        ctx.runtime.transfer_barrier_needed = false;
    }

    ctx.ui.ui_vertex_offset = 0;
    ctx.ui.ui_flushed_vertex_count = 0;
    ctx.ui.ui_active_textured = false;
    ctx.ui.ui_active_texture = 0;
    ctx.ui.ui_active_tint = .{ 0.0, 0.0, 0.0, 0.0 };
    ctx.ui.rml_vertex_offset = 0;
    ctx.ui.rml_index_offset = 0;
    ctx.ui.legacy_pipeline_bound = false;
    ctx.ui.ui_tex_descriptor_next[ctx.frames.current_frame] = 0;
    if (comptime build_options.debug_shadows) {
        ctx.debug_shadow.descriptor_next[ctx.frames.current_frame] = 0;
    }

    refreshTextureDescriptors(ctx);
}

/// Invalidates CPU publication only. The caller must either discard recording
/// commands or quarantine their slot; this never releases or resets GPU state.
pub fn invalidateAbortedTemporalState(ctx: anytype) void {
    if (ctx.runtime.lpv_recorded_this_frame) {
        ctx.runtime.lpv_abort_generation +%= 1;
        ctx.draw.current_lpv_texture = ctx.draw.dummy_texture_3d;
        ctx.draw.current_lpv_texture_g = ctx.draw.dummy_texture_3d;
        ctx.draw.current_lpv_texture_b = ctx.draw.dummy_texture_3d;
    }
    ctx.runtime.lpv_recorded_this_frame = false;
    ctx.taa.history_valid = false;
    ctx.taa.ran_this_frame = false;
    ctx.taa.pass_active = false;
    ctx.taa.output_texture = 0;
}

pub fn refreshTextureDescriptors(ctx: anytype) void {
    if (ctx.frames.terminal_failure or !ctx.frames.frame_in_progress) return;
    if (ctx.descriptors.snapshot_failed[ctx.frames.current_frame]) return;
    const cur_tex = ctx.draw.current_texture;
    const cur_nor = ctx.draw.current_normal_texture;
    const cur_rou = ctx.draw.current_roughness_texture;
    const cur_dis = ctx.draw.current_displacement_texture;
    const cur_env = ctx.draw.current_env_texture;
    const cur_water_reflection = ctx.draw.current_water_reflection_texture;
    const cur_scene_depth = ctx.draw.current_scene_depth_texture;
    const cur_lpv = ctx.draw.current_lpv_texture;
    const cur_lpv_g = ctx.draw.current_lpv_texture_g;
    const cur_lpv_b = ctx.draw.current_lpv_texture_b;

    var needs_update = false;
    if (ctx.draw.bound_texture != cur_tex) needs_update = true;
    if (ctx.draw.bound_normal_texture != cur_nor) needs_update = true;
    if (ctx.draw.bound_roughness_texture != cur_rou) needs_update = true;
    if (ctx.draw.bound_displacement_texture != cur_dis) needs_update = true;
    if (ctx.draw.bound_env_texture != cur_env) needs_update = true;
    if (ctx.draw.bound_water_reflection_texture != cur_water_reflection) needs_update = true;
    if (ctx.draw.bound_scene_depth_texture != cur_scene_depth) needs_update = true;
    if (ctx.draw.bound_lpv_texture != cur_lpv) needs_update = true;
    if (ctx.draw.bound_lpv_texture_g != cur_lpv_g) needs_update = true;
    if (ctx.draw.bound_lpv_texture_b != cur_lpv_b) needs_update = true;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (ctx.draw.bound_shadow_views[si] != ctx.shadow_system.shadow_image_views[si]) needs_update = true;
    }

    if (needs_update) {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| ctx.draw.descriptors_dirty[i] = true;
        ctx.draw.bound_texture = cur_tex;
        ctx.draw.bound_normal_texture = cur_nor;
        ctx.draw.bound_roughness_texture = cur_rou;
        ctx.draw.bound_displacement_texture = cur_dis;
        ctx.draw.bound_env_texture = cur_env;
        ctx.draw.bound_water_reflection_texture = cur_water_reflection;
        ctx.draw.bound_scene_depth_texture = cur_scene_depth;
        ctx.draw.bound_lpv_texture = cur_lpv;
        ctx.draw.bound_lpv_texture_g = cur_lpv_g;
        ctx.draw.bound_lpv_texture_b = cur_lpv_b;
        for (0..rhi.SHADOW_CASCADE_COUNT) |si| ctx.draw.bound_shadow_views[si] = ctx.shadow_system.shadow_image_views[si];
        ctx.draw.texture_state_revision +%= 1;
    }

    if (ctx.draw.descriptors_dirty[ctx.frames.current_frame]) {
        if (ctx.descriptors.descriptor_sets[ctx.frames.current_frame] == null) {
            log.log.err("CRITICAL: Descriptor set for frame {} is NULL!", .{ctx.frames.current_frame});
            return;
        }
        if (!ctx.descriptors.ensureWritable(ctx.frames.current_frame)) return;

        var writes: [16]c.VkWriteDescriptorSet = undefined;
        var write_count: u32 = 0;
        var image_infos: [16]c.VkDescriptorImageInfo = undefined;
        var info_count: u32 = 0;

        const dummy_tex_entry = ctx.resources.textures.get(ctx.draw.dummy_texture);
        const dummy_tex_3d_entry = ctx.resources.textures.get(ctx.draw.dummy_texture_3d);

        const atlas_slots = [_]struct { handle: rhi.TextureHandle, binding: u32, is_3d: bool }{
            .{ .handle = cur_tex, .binding = bindings.ALBEDO_TEXTURE, .is_3d = false },
            .{ .handle = cur_nor, .binding = bindings.NORMAL_TEXTURE, .is_3d = false },
            .{ .handle = cur_rou, .binding = bindings.ROUGHNESS_TEXTURE, .is_3d = false },
            .{ .handle = cur_dis, .binding = bindings.DISPLACEMENT_TEXTURE, .is_3d = false },
            .{ .handle = cur_env, .binding = bindings.ENV_TEXTURE, .is_3d = false },
            .{ .handle = cur_water_reflection, .binding = bindings.WATER_REFLECTION_TEXTURE, .is_3d = false },
            .{ .handle = cur_scene_depth, .binding = bindings.SCENE_DEPTH_TEXTURE, .is_3d = false },
            .{ .handle = cur_lpv, .binding = bindings.LPV_TEXTURE, .is_3d = true },
            .{ .handle = cur_lpv_g, .binding = bindings.LPV_TEXTURE_G, .is_3d = true },
            .{ .handle = cur_lpv_b, .binding = bindings.LPV_TEXTURE_B, .is_3d = true },
        };

        for (atlas_slots) |slot| {
            const fallback = if (slot.is_3d) dummy_tex_3d_entry else dummy_tex_entry;
            const entry = if (ctx.resources.textures.get(slot.handle)) |tex|
                if (tex.format == .depth) fallback else tex
            else
                fallback;
            if (entry) |tex| {
                image_infos[info_count] = .{
                    .sampler = tex.sampler,
                    .imageView = tex.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
                writes[write_count].dstBinding = slot.binding;
                writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes[write_count].descriptorCount = 1;
                writes[write_count].pImageInfo = &image_infos[info_count];
                write_count += 1;
                info_count += 1;
            }
        }

        if (ctx.shadow_system.shadow_image_view != null and ctx.shadow_system.shadow_sampler != null) {
            image_infos[info_count] = .{
                .sampler = ctx.shadow_system.shadow_sampler,
                .imageView = ctx.shadow_system.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            };
            writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            writes[write_count].dstBinding = bindings.SHADOW_COMPARE_TEXTURE;
            writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[write_count].descriptorCount = 1;
            writes[write_count].pImageInfo = &image_infos[info_count];
            write_count += 1;
            info_count += 1;

            const regular_shadow_sampler = ctx.shadow_system.shadow_sampler_regular orelse ctx.shadow_system.shadow_sampler;
            if (regular_shadow_sampler != null) {
                image_infos[info_count] = .{
                    .sampler = regular_shadow_sampler,
                    .imageView = ctx.shadow_system.shadow_image_view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
                };
                writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
                writes[write_count].dstBinding = bindings.SHADOW_REGULAR_TEXTURE;
                writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes[write_count].descriptorCount = 1;
                writes[write_count].pImageInfo = &image_infos[info_count];
                write_count += 1;
                info_count += 1;
            }
        }

        if (write_count > 0) {
            ctx.descriptors.writeDescriptors(writes[0..write_count]);
        }

        ctx.draw.descriptors_dirty[ctx.frames.current_frame] = false;
    }

    ctx.draw.descriptors_updated = true;
}
