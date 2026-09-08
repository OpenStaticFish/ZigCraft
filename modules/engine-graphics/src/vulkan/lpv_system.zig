const std = @import("std");
const c = @import("c").c;
const rhi_pkg = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Vec3 = @import("engine-math").Vec3;
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
const Utils = @import("utils.zig");
const lpv_utils = @import("../lpv_utils.zig");
const lpv_types = @import("engine-lighting").lpv_types;

const MAX_LIGHTS_PER_UPDATE = lpv_types.MAX_LIGHTS_PER_UPDATE;
const DEFAULT_PROPAGATION_FACTOR = lpv_types.DEFAULT_PROPAGATION_FACTOR;
const DEFAULT_CENTER_RETENTION = lpv_types.DEFAULT_CENTER_RETENTION;
const INJECT_SHADER_PATH = lpv_types.INJECT_SHADER_PATH;
const PROPAGATE_SHADER_PATH = lpv_types.PROPAGATE_SHADER_PATH;
const GpuLight = lpv_types.GpuLight;
const InjectPush = lpv_types.InjectPush;
const PropagatePush = lpv_types.PropagatePush;
const GridResources = lpv_types.GridResources;

pub const ILPVWorld = @import("engine-rhi").ILPVWorld;

pub const LPVSystem = struct {
    pub const Stats = lpv_types.Stats;

    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    vk_ctx: *VulkanContext,

    // SH L1: 3 textures per grid (R, G, B channels), each storing 4 SH coefficients as rgba32f
    grid_textures_a: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    grid_textures_b: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    active_grid_textures: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    debug_overlay_texture: rhi_pkg.TextureHandle = 0,
    grid_size: u32,
    cell_size: f32,
    intensity: f32,
    propagation_iterations: u32,
    propagation_factor: f32,
    center_retention: f32,
    enabled: bool,
    resources_initialized: bool = false,
    abort_generation: u64 = 0,
    update_interval_frames: u32 = 6,

    origin: Vec3 = Vec3.zero,
    current_frame: u32 = 0,
    was_enabled_last_frame: bool = true,
    debug_overlay_was_enabled: bool = false,

    image_layout_a: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    image_layout_b: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,

    debug_overlay_pixels: []f32,
    stats: Stats,

    light_buffer: Utils.VulkanBuffer = .{},
    occlusion_buffer: Utils.VulkanBuffer = .{},
    occlusion_grid: []u32 = &.{},

    descriptor_pool: c.VkDescriptorPool = null,
    inject_set_layout: c.VkDescriptorSetLayout = null,
    propagate_set_layout: c.VkDescriptorSetLayout = null,
    inject_descriptor_set: c.VkDescriptorSet = null,
    propagate_ab_descriptor_set: c.VkDescriptorSet = null,
    propagate_ba_descriptor_set: c.VkDescriptorSet = null,
    inject_pipeline_layout: c.VkPipelineLayout = null,
    propagate_pipeline_layout: c.VkPipelineLayout = null,
    inject_pipeline: c.VkPipeline = null,
    propagate_pipeline: c.VkPipeline = null,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        grid_size: u32,
        cell_size: f32,
        intensity: f32,
        propagation_iterations: u32,
        enabled: bool,
    ) !*LPVSystem {
        const self = try allocator.create(LPVSystem);
        errdefer allocator.destroy(self);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));
        const clamped_grid = std.math.clamp(grid_size, 16, 64);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .vk_ctx = vk_ctx,
            .grid_size = clamped_grid,
            .cell_size = @max(cell_size, 0.5),
            .intensity = std.math.clamp(intensity, 0.0, 4.0),
            .propagation_iterations = std.math.clamp(propagation_iterations, 1, 8),
            .propagation_factor = DEFAULT_PROPAGATION_FACTOR,
            .center_retention = DEFAULT_CENTER_RETENTION,
            .enabled = enabled,
            .was_enabled_last_frame = enabled,
            .debug_overlay_pixels = &.{},
            .stats = .{
                .grid_size = clamped_grid,
                .propagation_iterations = std.math.clamp(propagation_iterations, 1, 8),
                .update_interval_frames = 6,
            },
        };

        if (enabled) try self.initResources();

        return self;
    }

    fn initResources(self: *LPVSystem) !void {
        std.debug.assert(!self.resources_initialized);

        try self.createGridTextures();
        errdefer self.destroyGridTextures();

        const light_buffer_size = MAX_LIGHTS_PER_UPDATE * @sizeOf(GpuLight);
        self.light_buffer = try Utils.createVulkanBuffer(
            &self.vk_ctx.vulkan_device,
            light_buffer_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyLightBuffer();
        if (self.light_buffer.mapped_ptr == null or self.light_buffer.size < light_buffer_size) return error.InvalidBuffer;

        // Occlusion grid buffer: one u32 per cell (1 = opaque, 0 = transparent)
        const cells = try occlusionCellCount(self.grid_size);
        const occlusion_buffer_size = cells * @sizeOf(u32);
        self.occlusion_buffer = try Utils.createVulkanBuffer(
            &self.vk_ctx.vulkan_device,
            occlusion_buffer_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyOcclusionBuffer();
        self.occlusion_grid = try self.allocator.alloc(u32, cells);
        try validateOcclusionCapacity(self.grid_size, self.occlusion_grid.len, self.occlusion_buffer);

        try lpv_utils.ensureShaderFileExists(INJECT_SHADER_PATH);
        try lpv_utils.ensureShaderFileExists(PROPAGATE_SHADER_PATH);

        errdefer self.deinitComputeResources();
        try self.initComputeResources();

        self.abort_generation = self.vk_ctx.runtime.lpv_abort_generation;
        self.resources_initialized = true;
    }

    fn deinitResources(self: *LPVSystem) void {
        if (!self.resources_initialized) return;

        self.deinitComputeResources();
        self.destroyOcclusionBuffer();
        self.destroyLightBuffer();
        self.destroyGridTextures();
        self.resources_initialized = false;
    }

    pub fn deinit(self: *LPVSystem) void {
        if (self.resources_initialized) self.waitForGpu() catch |err| {
            log.log.err("LPV teardown GPU wait failed: {}", .{err});
        };
        self.deinitResources();
        self.allocator.destroy(self);
    }

    pub fn setSettings(self: *LPVSystem, enabled: bool, intensity: f32, cell_size: f32, propagation_iterations: u32, grid_size: u32, update_interval_frames: u32) !void {
        const clamped_grid = std.math.clamp(grid_size, 16, 64);
        // An aborted dispatch advanced CPU layouts/output selection without
        // executing them. Rebuild rather than guessing the images' real layouts.
        const replacing = enabled and (!self.isEnabled() or clamped_grid != self.grid_size);
        if (self.resources_initialized and (replacing or !enabled)) {
            // Waiting cannot retire resources referenced by an unsubmitted command buffer.
            if (self.vk_ctx.frames.frame_in_progress and
                (self.vk_ctx.runtime.lpv_recorded_this_frame or self.vk_ctx.runtime.draw_call_count != 0)) return error.InvalidState;
            try self.waitForGpu();
        }

        if (replacing) {
            // Build a complete generation, including mapped SSBOs and immutable compute sets.
            // No live state changes until every allocation and descriptor write succeeds.
            const replacement = try LPVSystem.init(self.allocator, self.rhi, clamped_grid, cell_size, intensity, propagation_iterations, true);
            replacement.propagation_factor = self.propagation_factor;
            replacement.center_retention = self.center_retention;
            replacement.current_frame = self.current_frame;
            replacement.was_enabled_last_frame = false;
            std.mem.swap(LPVSystem, self, replacement);
            replacement.deinitResources();
            self.allocator.destroy(replacement);
        }

        self.intensity = std.math.clamp(intensity, 0.0, 4.0);
        self.cell_size = @max(cell_size, 0.5);
        self.propagation_iterations = std.math.clamp(propagation_iterations, 1, 8);
        self.update_interval_frames = std.math.clamp(update_interval_frames, 1, 16);
        self.stats.propagation_iterations = self.propagation_iterations;
        self.stats.update_interval_frames = self.update_interval_frames;

        self.enabled = enabled;
        if (!enabled) {
            self.deinitResources();
            self.grid_size = clamped_grid;
            self.stats.grid_size = clamped_grid;
            self.stats.light_count = 0;
            self.stats.cpu_update_ms = 0.0;
        }
    }

    fn waitForGpu(self: *LPVSystem) !void {
        self.vk_ctx.vulkan_device.mutex.lock();
        defer self.vk_ctx.vulkan_device.mutex.unlock();
        try Utils.checkVk(c.vkDeviceWaitIdle(self.vk_ctx.vulkan_device.vk_device));
    }

    pub fn getTextureHandle(self: *const LPVSystem) rhi_pkg.TextureHandle {
        if (!self.isEnabled()) return 0;
        return self.active_grid_textures[0]; // R channel (binding 11)
    }

    pub fn getTextureHandleG(self: *const LPVSystem) rhi_pkg.TextureHandle {
        if (!self.isEnabled()) return 0;
        return self.active_grid_textures[1]; // G channel (binding 12)
    }

    pub fn getTextureHandleB(self: *const LPVSystem) rhi_pkg.TextureHandle {
        if (!self.isEnabled()) return 0;
        return self.active_grid_textures[2]; // B channel (binding 13)
    }

    pub fn getDebugOverlayTextureHandle(self: *const LPVSystem) rhi_pkg.TextureHandle {
        if (!self.isEnabled()) return 0;
        return self.debug_overlay_texture;
    }

    pub fn getStats(self: *const LPVSystem) Stats {
        var stats = self.stats;
        if (!self.isEnabled()) {
            stats.updated_this_frame = false;
            stats.light_count = 0;
            stats.cpu_update_ms = 0;
        }
        return stats;
    }

    pub fn getOrigin(self: *const LPVSystem) Vec3 {
        return self.origin;
    }

    pub fn getGridSize(self: *const LPVSystem) u32 {
        return self.grid_size;
    }

    pub fn getCellSize(self: *const LPVSystem) f32 {
        return self.cell_size;
    }

    pub fn isEnabled(self: *const LPVSystem) bool {
        return self.enabled and self.resources_initialized and self.abort_generation == self.vk_ctx.runtime.lpv_abort_generation;
    }

    pub fn update(self: *LPVSystem, world: ILPVWorld, camera_pos: Vec3, debug_overlay_enabled: bool) !void {
        if (self.enabled and !self.isEnabled()) {
            try self.setSettings(true, self.intensity, self.cell_size, self.propagation_iterations, self.grid_size, self.update_interval_frames);
        }
        self.current_frame +%= 1;
        const timer_start = std.Io.Clock.awake.now(std.Options.debug_io);
        self.stats.updated_this_frame = false;
        self.stats.grid_size = self.grid_size;
        self.stats.propagation_iterations = self.propagation_iterations;
        self.stats.update_interval_frames = self.update_interval_frames;

        if (!self.isEnabled()) {
            self.was_enabled_last_frame = false;
            self.debug_overlay_was_enabled = debug_overlay_enabled;
            self.stats.light_count = 0;
            self.stats.cpu_update_ms = 0.0;
            return;
        }

        const half_extent = (@as(f32, @floatFromInt(self.grid_size)) * self.cell_size) * 0.5;
        const next_origin = Vec3.init(
            lpv_utils.quantizeToCell(camera_pos.x - half_extent, self.cell_size),
            lpv_utils.quantizeToCell(camera_pos.y - half_extent, self.cell_size),
            lpv_utils.quantizeToCell(camera_pos.z - half_extent, self.cell_size),
        );

        const moved = @abs(next_origin.x - self.origin.x) >= self.cell_size or
            @abs(next_origin.y - self.origin.y) >= self.cell_size or
            @abs(next_origin.z - self.origin.z) >= self.cell_size;

        const tick_update = (self.current_frame % self.update_interval_frames) == 0;
        const debug_toggle_on = debug_overlay_enabled and !self.debug_overlay_was_enabled;
        self.debug_overlay_was_enabled = debug_overlay_enabled;

        if (!moved and !tick_update and !debug_toggle_on and self.was_enabled_last_frame) {
            self.stats.cpu_update_ms = 0.0;
            return;
        }

        // These mapped inputs are shared across frames, not frame-buffered.
        if (self.vk_ctx.runtime.lpv_recorded_this_frame and self.vk_ctx.frames.frame_in_progress) return error.InvalidState;
        try self.waitForGpu();
        self.origin = next_origin;
        self.was_enabled_last_frame = true;

        var lights: [MAX_LIGHTS_PER_UPDATE]GpuLight = undefined;
        const light_count = self.collectLights(world, lights[0..]);
        if (light_count > lights.len) return error.InvalidLightCount;
        if (self.light_buffer.mapped_ptr) |ptr| {
            const bytes = std.mem.sliceAsBytes(lights[0..light_count]);
            if (bytes.len > self.light_buffer.size) return error.InvalidBufferSize;
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
        } else {
            return error.InvalidBuffer;
        }

        // Build occlusion grid for opaque block awareness during propagation
        if (!self.buildOcclusionGrid(world)) {
            const elapsed_ns = timer_start.durationTo(std.Io.Clock.awake.now(std.Options.debug_io)).toNanoseconds();
            const delta_ms: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms));
            self.stats.light_count = @intCast(light_count);
            self.stats.cpu_update_ms = delta_ms;
            return;
        }

        if (debug_overlay_enabled) {
            // Keep debug overlay generation only when overlay is active.
            self.buildDebugOverlay(lights[0..], light_count);
            try self.uploadDebugOverlay();
        }

        try self.dispatchCompute(light_count);

        const elapsed_ns = timer_start.durationTo(std.Io.Clock.awake.now(std.Options.debug_io)).toNanoseconds();
        const delta_ms: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms));
        self.stats.updated_this_frame = true;
        self.stats.light_count = @intCast(light_count);
        self.stats.cpu_update_ms = delta_ms;
    }

    fn collectLights(self: *LPVSystem, world: ILPVWorld, out: []GpuLight) usize {
        return world.collectLights(self.origin, self.grid_size, self.cell_size, out);
    }

    /// Build a per-cell occlusion grid (1 = opaque, 0 = transparent) for the current LPV volume.
    /// Stored as packed u32 array where each u32 holds the opacity for one cell.
    fn buildOcclusionGrid(self: *LPVSystem, world: ILPVWorld) bool {
        validateOcclusionCapacity(self.grid_size, self.occlusion_grid.len, self.occlusion_buffer) catch |err| {
            log.log.err("LPV occlusion upload rejected: {}", .{err});
            return false;
        };

        @memset(self.occlusion_grid, 0);
        world.buildOcclusionGrid(self.origin, self.grid_size, self.cell_size, self.occlusion_grid);

        // Upload to GPU
        if (self.occlusion_buffer.mapped_ptr) |ptr| {
            const bytes = std.mem.sliceAsBytes(self.occlusion_grid);
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
            return true;
        }

        log.log.err("LPV occlusion upload skipped: buffer is not mapped", .{});
        return false;
    }

    fn createGridResources(self: *LPVSystem, grid_size: u32) !GridResources {
        var resources = GridResources{};
        errdefer self.destroyGridResources(&resources);

        const empty = try self.allocator.alloc(f32, (try occlusionCellCount(grid_size)) * 4);
        defer self.allocator.free(empty);
        @memset(empty, 0.0);
        const bytes = std.mem.sliceAsBytes(empty);

        const tex_config = rhi_pkg.TextureConfig{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = false,
            .is_render_target = false,
        };

        for (0..3) |ch| {
            resources.grid_textures_a[ch] = try self.rhi.factory().createTexture3D(
                grid_size,
                grid_size,
                grid_size,
                .rgba32f,
                tex_config,
                bytes,
            );

            resources.grid_textures_b[ch] = try self.rhi.factory().createTexture3D(
                grid_size,
                grid_size,
                grid_size,
                .rgba32f,
                tex_config,
                bytes,
            );
        }

        const debug_size = @as(usize, grid_size) * @as(usize, grid_size) * 4;
        resources.debug_overlay_pixels = try self.allocator.alloc(f32, debug_size);
        @memset(resources.debug_overlay_pixels, 0.0);

        resources.debug_overlay_texture = try self.rhi.resourceManager().createTexture(
            grid_size,
            grid_size,
            .rgba32f,
            .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .wrap_s = .clamp_to_edge,
                .wrap_t = .clamp_to_edge,
                .generate_mipmaps = false,
                .is_render_target = false,
            },
            std.mem.sliceAsBytes(resources.debug_overlay_pixels),
        );

        resources.active_grid_textures = resources.grid_textures_a;
        resources.image_layout_a = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        resources.image_layout_b = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        return resources;
    }

    fn applyGridResources(self: *LPVSystem, resources: GridResources) void {
        self.grid_textures_a = resources.grid_textures_a;
        self.grid_textures_b = resources.grid_textures_b;
        self.active_grid_textures = resources.active_grid_textures;
        self.debug_overlay_texture = resources.debug_overlay_texture;
        self.debug_overlay_pixels = resources.debug_overlay_pixels;
        self.image_layout_a = resources.image_layout_a;
        self.image_layout_b = resources.image_layout_b;
    }

    fn destroyGridResources(self: *LPVSystem, resources: *GridResources) void {
        for (0..3) |ch| {
            if (resources.grid_textures_a[ch] != 0) {
                self.rhi.resourceManager().destroyTexture(resources.grid_textures_a[ch]);
                resources.grid_textures_a[ch] = 0;
            }
            if (resources.grid_textures_b[ch] != 0) {
                self.rhi.resourceManager().destroyTexture(resources.grid_textures_b[ch]);
                resources.grid_textures_b[ch] = 0;
            }
        }

        if (resources.debug_overlay_texture != 0) {
            self.rhi.resourceManager().destroyTexture(resources.debug_overlay_texture);
            resources.debug_overlay_texture = 0;
        }
        if (resources.debug_overlay_pixels.len > 0) {
            self.allocator.free(resources.debug_overlay_pixels);
            resources.debug_overlay_pixels = &.{};
        }

        resources.active_grid_textures = .{ 0, 0, 0 };
    }

    fn dispatchCompute(self: *LPVSystem, light_count: usize) !void {
        const cmd = self.vk_ctx.frames.command_buffers[self.vk_ctx.frames.current_frame];
        if (cmd == null or !self.vk_ctx.frames.frame_in_progress) return error.InvalidState;
        self.vk_ctx.runtime.lpv_recorded_this_frame = true;

        // Transition all 6 SH channel textures (3 per grid) to GENERAL for compute access
        for (0..3) |ch| {
            const tex_a = self.vk_ctx.resources.textures.get(self.grid_textures_a[ch]) orelse return;
            const tex_b = self.vk_ctx.resources.textures.get(self.grid_textures_b[ch]) orelse return;
            try self.transitionImage(cmd, tex_a.image.?, self.image_layout_a, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_READ_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT);
            try self.transitionImage(cmd, tex_b.image.?, self.image_layout_b, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_READ_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT);
        }
        self.image_layout_a = c.VK_IMAGE_LAYOUT_GENERAL;
        self.image_layout_b = c.VK_IMAGE_LAYOUT_GENERAL;

        // Ensure host writes to light buffer and occlusion grid are visible to compute shaders.
        // Both buffers use HOST_COHERENT, but we still need an execution dependency to guarantee
        // the memcpy completes before the GPU reads the SSBOs.
        var host_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        host_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        host_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        host_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &host_barrier, 0, null, 0, null);

        const groups = lpv_utils.divCeil(self.grid_size, 4);

        const inject_push = InjectPush{
            .grid_origin = .{ self.origin.x, self.origin.y, self.origin.z, self.cell_size },
            .grid_params = .{ @floatFromInt(self.grid_size), 0.0, 0.0, 0.0 },
            .light_count = @intCast(light_count),
            ._pad0 = .{ 0, 0, 0 },
        };

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.inject_pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.inject_pipeline_layout, 0, 1, &self.inject_descriptor_set, 0, null);
        c.vkCmdPushConstants(cmd, self.inject_pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(InjectPush), &inject_push);
        c.vkCmdDispatch(cmd, groups, groups, groups);

        var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        mem_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        mem_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, null, 0, null);

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.propagate_pipeline);
        const prop_push = PropagatePush{
            .grid_size = self.grid_size,
            ._pad0 = .{ 0, 0, 0 },
            .propagation = .{ self.propagation_factor, self.center_retention, 0, 0 },
        };

        var use_ab = true;
        var i: u32 = 0;
        while (i < self.propagation_iterations) : (i += 1) {
            const descriptor_set = if (use_ab) self.propagate_ab_descriptor_set else self.propagate_ba_descriptor_set;
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.propagate_pipeline_layout, 0, 1, &descriptor_set, 0, null);
            c.vkCmdPushConstants(cmd, self.propagate_pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PropagatePush), &prop_push);
            c.vkCmdDispatch(cmd, groups, groups, groups);

            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, null, 0, null);
            use_ab = !use_ab;
        }

        // Transition final textures to SHADER_READ_ONLY for fragment shader sampling
        const final_is_a = (self.propagation_iterations % 2) == 0;
        const final_textures = if (final_is_a) &self.grid_textures_a else &self.grid_textures_b;

        for (0..3) |ch| {
            const final_tex = self.vk_ctx.resources.textures.get(final_textures[ch]) orelse return;
            try self.transitionImage(cmd, final_tex.image.?, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
        }

        if (final_is_a) {
            self.image_layout_a = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            self.active_grid_textures = self.grid_textures_a;
        } else {
            self.image_layout_b = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            self.active_grid_textures = self.grid_textures_b;
        }
    }

    fn transitionImage(
        self: *LPVSystem,
        cmd: c.VkCommandBuffer,
        image: c.VkImage,
        old_layout: c.VkImageLayout,
        new_layout: c.VkImageLayout,
        src_stage: c.VkPipelineStageFlags,
        dst_stage: c.VkPipelineStageFlags,
        src_access: c.VkAccessFlags,
        dst_access: c.VkAccessFlags,
    ) !void {
        _ = self;
        if (old_layout == new_layout) return;
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = old_layout;
        barrier.newLayout = new_layout;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = src_access;
        barrier.dstAccessMask = dst_access;

        c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    }

    fn createGridTextures(self: *LPVSystem) !void {
        const resources = try self.createGridResources(self.grid_size);
        self.applyGridResources(resources);
        errdefer self.destroyGridTextures();

        self.buildDebugOverlay(&.{}, 0);
        try self.uploadDebugOverlay();
    }

    fn destroyGridTextures(self: *LPVSystem) void {
        for (0..3) |ch| {
            if (self.grid_textures_a[ch] != 0) {
                self.rhi.resourceManager().destroyTexture(self.grid_textures_a[ch]);
                self.grid_textures_a[ch] = 0;
            }
            if (self.grid_textures_b[ch] != 0) {
                self.rhi.resourceManager().destroyTexture(self.grid_textures_b[ch]);
                self.grid_textures_b[ch] = 0;
            }
        }
        if (self.debug_overlay_texture != 0) {
            self.rhi.resourceManager().destroyTexture(self.debug_overlay_texture);
            self.debug_overlay_texture = 0;
        }
        if (self.debug_overlay_pixels.len > 0) {
            self.allocator.free(self.debug_overlay_pixels);
            self.debug_overlay_pixels = &.{};
        }
        self.active_grid_textures = .{ 0, 0, 0 };
    }

    fn buildDebugOverlay(self: *LPVSystem, lights: []const GpuLight, light_count: usize) void {
        const gs = @as(usize, self.grid_size);
        var y: usize = 0;
        while (y < gs) : (y += 1) {
            var x: usize = 0;
            while (x < gs) : (x += 1) {
                const idx = (y * gs + x) * 4;
                const checker: f32 = if (((x / 4) + (y / 4)) % 2 == 0) @as(f32, 1.5) else @as(f32, 2.0);
                self.debug_overlay_pixels[idx + 0] = checker;
                self.debug_overlay_pixels[idx + 1] = checker;
                self.debug_overlay_pixels[idx + 2] = checker;
                self.debug_overlay_pixels[idx + 3] = 1.0;

                if (x == 0 or y == 0 or x + 1 == gs or y + 1 == gs) {
                    self.debug_overlay_pixels[idx + 0] = 4.0;
                    self.debug_overlay_pixels[idx + 1] = 4.0;
                    self.debug_overlay_pixels[idx + 2] = 4.0;
                }
            }
        }

        for (lights[0..light_count]) |light| {
            const cx: f32 = ((light.pos_radius[0] - self.origin.x) / self.cell_size);
            const cz: f32 = ((light.pos_radius[2] - self.origin.z) / self.cell_size);
            const radius = @max(light.pos_radius[3], 0.5);

            var ty: usize = 0;
            while (ty < gs) : (ty += 1) {
                var tx: usize = 0;
                while (tx < gs) : (tx += 1) {
                    const dx = @as(f32, @floatFromInt(tx)) - cx;
                    const dz = @as(f32, @floatFromInt(ty)) - cz;
                    const dist = @sqrt(dx * dx + dz * dz);
                    if (dist > radius) continue;

                    const falloff = std.math.pow(f32, 1.0 - (dist / radius), 2.0);
                    const idx = (ty * gs + tx) * 4;
                    self.debug_overlay_pixels[idx + 0] += light.color[0] * falloff * 6.0;
                    self.debug_overlay_pixels[idx + 1] += light.color[1] * falloff * 6.0;
                    self.debug_overlay_pixels[idx + 2] += light.color[2] * falloff * 6.0;
                }
            }
        }

        for (0..gs * gs) |i| {
            const idx = i * 4;
            self.debug_overlay_pixels[idx + 0] = lpv_utils.toneMap(self.debug_overlay_pixels[idx + 0]);
            self.debug_overlay_pixels[idx + 1] = lpv_utils.toneMap(self.debug_overlay_pixels[idx + 1]);
            self.debug_overlay_pixels[idx + 2] = lpv_utils.toneMap(self.debug_overlay_pixels[idx + 2]);
        }
    }

    fn uploadDebugOverlay(self: *LPVSystem) !void {
        if (self.debug_overlay_texture == 0 or self.debug_overlay_pixels.len == 0) return;
        try self.rhi.resourceManager().updateTexture(self.debug_overlay_texture, std.mem.sliceAsBytes(self.debug_overlay_pixels));
    }

    fn destroyLightBuffer(self: *LPVSystem) void {
        if (self.light_buffer.buffer != null) {
            if (self.light_buffer.memory == null) {
                log.log.warn("LPV light buffer has VkBuffer but null VkDeviceMemory during teardown", .{});
            }
            if (self.light_buffer.mapped_ptr != null) {
                c.vkUnmapMemory(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.memory);
                self.light_buffer.mapped_ptr = null;
            }
            c.vkDestroyBuffer(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.buffer, null);
            c.vkFreeMemory(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.memory, null);
            self.light_buffer = .{};
        }
    }

    fn destroyOcclusionBuffer(self: *LPVSystem) void {
        if (self.occlusion_buffer.buffer != null) {
            if (self.occlusion_buffer.mapped_ptr != null) {
                c.vkUnmapMemory(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.memory);
                self.occlusion_buffer.mapped_ptr = null;
            }
            c.vkDestroyBuffer(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.buffer, null);
            if (self.occlusion_buffer.memory != null) {
                c.vkFreeMemory(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.memory, null);
            }
            self.occlusion_buffer = .{};
        }
        if (self.occlusion_grid.len > 0) {
            self.allocator.free(self.occlusion_grid);
            self.occlusion_grid = &.{};
        }
    }

    fn initComputeResources(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        // SH L1: inject needs 3 output images + 1 SSBO = 4 bindings
        // propagate needs 3 src + 3 dst images + 1 occlusion SSBO = 7 bindings
        // Total images: inject(3) + prop_ab(6) + prop_ba(6) = 15
        // Total buffers: inject(1) + prop_ab(1) + prop_ba(1) = 3
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 16 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 4;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        // Inject: binding 0,1,2 = output images (R,G,B SH channels), binding 3 = light buffer
        const inject_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        var inject_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        inject_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        inject_layout_info.bindingCount = inject_bindings.len;
        inject_layout_info.pBindings = &inject_bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &inject_layout_info, null, &self.inject_set_layout));

        // Propagate: binding 0-2 = src (R,G,B), binding 3-5 = dst (R,G,B), binding 6 = occlusion
        const prop_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        var prop_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        prop_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        prop_layout_info.bindingCount = prop_bindings.len;
        prop_layout_info.pBindings = &prop_bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &prop_layout_info, null, &self.propagate_set_layout));

        try self.allocateDescriptorSets();
        try self.updateDescriptorSets();

        try self.createComputePipelines();
    }

    fn allocateDescriptorSets(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var inject_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        inject_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        inject_alloc.descriptorPool = self.descriptor_pool;
        inject_alloc.descriptorSetCount = 1;
        inject_alloc.pSetLayouts = &self.inject_set_layout;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &inject_alloc, &self.inject_descriptor_set));

        const layouts = [_]c.VkDescriptorSetLayout{ self.propagate_set_layout, self.propagate_set_layout };
        var prop_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        prop_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        prop_alloc.descriptorPool = self.descriptor_pool;
        prop_alloc.descriptorSetCount = 2;
        prop_alloc.pSetLayouts = &layouts;
        var prop_sets: [2]c.VkDescriptorSet = .{ null, null };
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &prop_alloc, &prop_sets));
        self.propagate_ab_descriptor_set = prop_sets[0];
        self.propagate_ba_descriptor_set = prop_sets[1];
    }

    fn updateDescriptorSets(self: *LPVSystem) !void {
        try validateOcclusionCapacity(self.grid_size, self.occlusion_grid.len, self.occlusion_buffer);
        // Resolve all 6 texture resources (3 channels x 2 grids)
        var imgs_a: [3]c.VkDescriptorImageInfo = undefined;
        var imgs_b: [3]c.VkDescriptorImageInfo = undefined;
        for (0..3) |ch| {
            const tex_a = self.vk_ctx.resources.textures.get(self.grid_textures_a[ch]) orelse return error.ResourceNotFound;
            const tex_b = self.vk_ctx.resources.textures.get(self.grid_textures_b[ch]) orelse return error.ResourceNotFound;
            imgs_a[ch] = c.VkDescriptorImageInfo{ .sampler = null, .imageView = tex_a.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
            imgs_b[ch] = c.VkDescriptorImageInfo{ .sampler = null, .imageView = tex_b.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
        }
        var light_info = c.VkDescriptorBufferInfo{ .buffer = self.light_buffer.buffer, .offset = 0, .range = @sizeOf(GpuLight) * MAX_LIGHTS_PER_UPDATE };
        const occlusion_size = (try occlusionCellCount(self.grid_size)) * @sizeOf(u32);
        var occlusion_info = c.VkDescriptorBufferInfo{ .buffer = self.occlusion_buffer.buffer, .offset = 0, .range = @intCast(occlusion_size) };

        // Inject: bindings 0,1,2 = output R,G,B images (grid A), binding 3 = light buffer
        // Propagate A->B: bindings 0-2 = src (A), bindings 3-5 = dst (B), binding 6 = occlusion
        // Propagate B->A: bindings 0-2 = src (B), bindings 3-5 = dst (A), binding 6 = occlusion
        // Total writes: 4 (inject) + 7 (prop_ab) + 7 (prop_ba) = 18
        var writes: [18]c.VkWriteDescriptorSet = undefined;
        var n: usize = 0;

        // --- Inject set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.inject_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.inject_descriptor_set;
        writes[n].dstBinding = 3;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &light_info;
        n += 1;

        // --- Propagate A->B set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ab_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ab_descriptor_set;
            writes[n].dstBinding = @intCast(ch + 3);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_b[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.propagate_ab_descriptor_set;
        writes[n].dstBinding = 6;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &occlusion_info;
        n += 1;

        // --- Propagate B->A set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ba_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_b[ch];
            n += 1;
        }
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ba_descriptor_set;
            writes[n].dstBinding = @intCast(ch + 3);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.propagate_ba_descriptor_set;
        writes[n].dstBinding = 6;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &occlusion_info;
        n += 1;

        c.vkUpdateDescriptorSets(self.vk_ctx.vulkan_device.vk_device, @intCast(n), &writes[0], 0, null);
    }

    fn createComputePipelines(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        const inject_module = try lpv_utils.createShaderModule(vk, INJECT_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, inject_module, null);
        const propagate_module = try lpv_utils.createShaderModule(vk, PROPAGATE_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, propagate_module, null);

        var inject_pc = std.mem.zeroes(c.VkPushConstantRange);
        inject_pc.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        inject_pc.offset = 0;
        inject_pc.size = @sizeOf(InjectPush);

        var inject_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        inject_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        inject_layout_info.setLayoutCount = 1;
        inject_layout_info.pSetLayouts = &self.inject_set_layout;
        inject_layout_info.pushConstantRangeCount = 1;
        inject_layout_info.pPushConstantRanges = &inject_pc;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &inject_layout_info, null, &self.inject_pipeline_layout));

        var prop_pc = std.mem.zeroes(c.VkPushConstantRange);
        prop_pc.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        prop_pc.offset = 0;
        prop_pc.size = @sizeOf(PropagatePush);

        var prop_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        prop_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        prop_layout_info.setLayoutCount = 1;
        prop_layout_info.pSetLayouts = &self.propagate_set_layout;
        prop_layout_info.pushConstantRangeCount = 1;
        prop_layout_info.pPushConstantRanges = &prop_pc;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &prop_layout_info, null, &self.propagate_pipeline_layout));

        var inject_stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        inject_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        inject_stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        inject_stage.module = inject_module;
        inject_stage.pName = "main";

        var inject_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        inject_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        inject_info.stage = inject_stage;
        inject_info.layout = self.inject_pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &inject_info, null, &self.inject_pipeline));

        var prop_stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        prop_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        prop_stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        prop_stage.module = propagate_module;
        prop_stage.pName = "main";

        var prop_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        prop_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        prop_info.stage = prop_stage;
        prop_info.layout = self.propagate_pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &prop_info, null, &self.propagate_pipeline));
    }

    fn deinitComputeResources(self: *LPVSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.inject_pipeline != null) c.vkDestroyPipeline(vk, self.inject_pipeline, null);
        if (self.propagate_pipeline != null) c.vkDestroyPipeline(vk, self.propagate_pipeline, null);
        if (self.inject_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.inject_pipeline_layout, null);
        if (self.propagate_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.propagate_pipeline_layout, null);
        if (self.inject_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.inject_set_layout, null);
        if (self.propagate_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.propagate_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.inject_pipeline = null;
        self.propagate_pipeline = null;
        self.inject_pipeline_layout = null;
        self.propagate_pipeline_layout = null;
        self.inject_set_layout = null;
        self.propagate_set_layout = null;
        self.descriptor_pool = null;
        self.inject_descriptor_set = null;
        self.propagate_ab_descriptor_set = null;
        self.propagate_ba_descriptor_set = null;
    }
};

pub fn occlusionCellCount(grid_size: u32) !usize {
    if (grid_size < 16 or grid_size > 64) return error.InvalidGridSize;
    const size: usize = grid_size;
    return size * size * size;
}

pub fn validateOcclusionCapacity(grid_size: u32, cpu_cells: usize, buffer: Utils.VulkanBuffer) !void {
    const cells = try occlusionCellCount(grid_size);
    if (cpu_cells != cells or buffer.size < cells * @sizeOf(u32)) return error.InvalidBufferSize;
    if (buffer.mapped_ptr == null) return error.InvalidBuffer;
}
