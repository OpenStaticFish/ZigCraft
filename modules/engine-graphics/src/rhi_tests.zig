const std = @import("std");
const testing = std.testing;
const rhi = @import("engine-rhi").rhi;
const c = @import("c").c;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;

const MockContext = struct {
    bind_texture_called: bool = false,
    draw_called: bool = false,
    draw_depth_texture_called: bool = false,
    sky_pipeline_requested: bool = false,
    sky_pipeline_ready: bool = false,
    dynamic_resolution_called: bool = false,
    dynamic_resolution_enabled: bool = false,
    dynamic_resolution_min_scale: f32 = 0.0,
    dynamic_resolution_max_scale: f32 = 0.0,
    dynamic_resolution_target_fps: u32 = 0,
    resolution_scale: f32 = 1.0,

    fn bindTexture(ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        _ = handle;
        _ = slot;
        self.bind_texture_called = true;
    }
    fn bindBuffer(ptr: *anyopaque, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
        _ = ptr;
        _ = handle;
        _ = usage;
    }
    fn pushConstants(ptr: *anyopaque, stages: rhi.ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        _ = ptr;
        _ = stages;
        _ = offset;
        _ = size;
        _ = data;
    }
    fn draw(ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        _ = handle;
        _ = count;
        _ = mode;
        self.draw_called = true;
    }
    fn drawOffset(ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
        _ = ptr;
        _ = handle;
        _ = count;
        _ = mode;
        _ = offset;
    }
    fn drawIndexed(ptr: *anyopaque, vbo: rhi.BufferHandle, ebo: rhi.BufferHandle, count: u32) void {
        _ = ptr;
        _ = vbo;
        _ = ebo;
        _ = count;
    }
    fn drawIndirect(ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        _ = ptr;
        _ = handle;
        _ = command_buffer;
        _ = offset;
        _ = draw_count;
        _ = stride;
    }
    fn drawIndirectCount(_: *anyopaque, _: rhi.BufferHandle, _: rhi.BufferHandle, _: usize, _: rhi.BufferHandle, _: usize, _: u32, _: u32) bool {
        return false;
    }
    fn drawInstance(ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
        _ = ptr;
        _ = handle;
        _ = count;
        _ = instance_index;
    }
    fn setViewport(ptr: *anyopaque, width: u32, height: u32) void {
        _ = ptr;
        _ = width;
        _ = height;
    }

    fn getNativeCommandBuffer(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSwapchainExtent(ptr: *anyopaque) [2]u32 {
        _ = ptr;
        return .{ 800, 600 };
    }
    fn getNativeDevice(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeInstance(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativePhysicalDevice(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeQueue(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeQueueFamily(ptr: *anyopaque) u32 {
        _ = ptr;
        return 0;
    }
    fn getNativeDescriptorPool(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeUiRenderPass(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSwapchainImageCount(ptr: *anyopaque) u32 {
        _ = ptr;
        return 2;
    }
    fn computeSsao(ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void {
        _ = ptr;
        _ = proj;
        _ = inv_proj;
    }

    fn drawDebugShadowMap(ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
        _ = ptr;
        _ = cascade_index;
        _ = depth_map_handle;
    }

    fn drawSky(ptr: *anyopaque, params: rhi.SkyParams) rhi.RhiError!void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        _ = params;
        self.sky_pipeline_requested = true;
        if (!self.sky_pipeline_ready) return error.SkyPipelineNotReady;
    }

    fn beginWaterDraw(ptr: *anyopaque, reflection: rhi.TextureHandle, scene_depth: rhi.TextureHandle) bool {
        _ = ptr;
        return reflection != 0 and scene_depth != 0;
    }

    fn endWaterDraw(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn getEncoder(ptr: *anyopaque) rhi.IGraphicsCommandEncoder {
        return .{ .ptr = ptr, .vtable = &MOCK_ENCODER_VTABLE };
    }

    fn getStateContext(ptr: *anyopaque) rhi.IRenderStateContext {
        return .{ .ptr = ptr, .vtable = &MOCK_STATE_VTABLE };
    }

    fn isTimingEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }
    fn setTimingEnabled(ptr: *anyopaque, enabled: bool) void {
        _ = ptr;
        _ = enabled;
    }
    fn beginPassTiming(ptr: *anyopaque, name: []const u8) void {
        _ = ptr;
        _ = name;
    }
    fn endPassTiming(ptr: *anyopaque, name: []const u8) void {
        _ = ptr;
        _ = name;
    }
    fn getTimingResults(ptr: *anyopaque) rhi.GpuTimingResults {
        _ = ptr;
        return std.mem.zeroes(rhi.GpuTimingResults);
    }

    fn setDynamicResolution(ptr: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        self.dynamic_resolution_called = true;
        self.dynamic_resolution_enabled = enabled;
        self.dynamic_resolution_min_scale = min_scale;
        self.dynamic_resolution_max_scale = max_scale;
        self.dynamic_resolution_target_fps = target_fps;
    }

    fn getResolutionScale(ptr: *anyopaque) f32 {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        return self.resolution_scale;
    }

    fn createCullingSystem(ptr: *anyopaque, allocator: std.mem.Allocator, max_chunks: usize) anyerror!?rhi.ICullingSystem {
        _ = ptr;
        _ = allocator;
        _ = max_chunks;
        return null;
    }
    fn createLODCullingSystem(_: *anyopaque, _: std.mem.Allocator, _: usize) anyerror!?rhi.ILODCullingSystem {
        return null;
    }

    fn getRenderResolution(ptr: *anyopaque) rhi.RenderResolution {
        _ = ptr;
        return .{ .width = 1920, .height = 1080 };
    }

    fn getShadowMapHandle(ptr: *anyopaque, cascade_index: u32) rhi.TextureHandle {
        _ = ptr;
        _ = cascade_index;
        return 0;
    }

    fn getWaterReflectionHandle(ptr: *anyopaque) rhi.TextureHandle {
        _ = ptr;
        return 0;
    }

    fn getWaterSceneDepthHandle(ptr: *anyopaque) rhi.TextureHandle {
        _ = ptr;
        return 0;
    }

    fn computeWaterReflectedViewProj(ptr: *anyopaque, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        _ = ptr;
        _ = view;
        _ = proj;
        _ = camera_pos;
        return Mat4.identity;
    }

    fn drawDepthTexture(ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        _ = texture;
        _ = rect;
        self.draw_depth_texture_called = true;
    }

    fn bindComputePipeline(ptr: *anyopaque, pipeline: rhi.ComputePipeline) void {
        _ = ptr;
        _ = pipeline;
    }
    fn bindDescriptorSet(ptr: *anyopaque, pipeline: rhi.ComputePipeline, frame_index: usize) void {
        _ = ptr;
        _ = pipeline;
        _ = frame_index;
    }
    fn createComputeBuffer(ptr: *anyopaque, size: usize, host_visible: bool) rhi.RhiError!rhi.ComputeBuffer {
        _ = ptr;
        _ = size;
        _ = host_visible;
        return .{};
    }
    fn destroyComputeBuffer(ptr: *anyopaque, buffer: *rhi.ComputeBuffer) void {
        _ = ptr;
        buffer.* = .{};
    }
    fn createComputePipeline(ptr: *anyopaque, allocator: std.mem.Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!rhi.ComputePipeline {
        _ = ptr;
        _ = allocator;
        _ = shader_path;
        _ = storage_binding_count;
        _ = push_constant_size;
        return .{};
    }
    fn updateComputeDescriptors(ptr: *anyopaque, pipeline: rhi.ComputePipeline, frame_index: usize, buffers: []const rhi.ComputeBufferBinding) void {
        _ = ptr;
        _ = pipeline;
        _ = frame_index;
        _ = buffers;
    }
    fn destroyComputePipeline(ptr: *anyopaque, pipeline: *rhi.ComputePipeline) void {
        _ = ptr;
        pipeline.* = .{};
    }
    fn dispatchCompute(ptr: *anyopaque, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        _ = ptr;
        _ = group_count_x;
        _ = group_count_y;
        _ = group_count_z;
    }
    fn pushComputeConstants(ptr: *anyopaque, pipeline: rhi.ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void {
        _ = ptr;
        _ = pipeline;
        _ = offset;
        _ = size;
        _ = data;
    }
    fn fillComputeBuffer(ptr: *anyopaque, buffer: rhi.ComputeBuffer, offset: u64, size: u64, data: u32) void {
        _ = ptr;
        _ = buffer;
        _ = offset;
        _ = size;
        _ = data;
    }
    fn copyComputeBuffer(ptr: *anyopaque, src_buffer: rhi.ComputeBufferBinding, dst_buffer: rhi.ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void {
        _ = ptr;
        _ = src_buffer;
        _ = dst_buffer;
        _ = src_offset;
        _ = dst_offset;
        _ = size;
    }
    fn computePipelineBarrier(ptr: *anyopaque, src_stage: rhi.PipelineStageFlags, dst_stage: rhi.PipelineStageFlags, src_access: rhi.AccessFlags, dst_access: rhi.AccessFlags) void {
        _ = ptr;
        _ = src_stage;
        _ = dst_stage;
        _ = src_access;
        _ = dst_access;
    }
    fn computeBufferBarrier(ptr: *anyopaque, buffer: rhi.ComputeBufferBinding, src_stage: rhi.PipelineStageFlags, dst_stage: rhi.PipelineStageFlags, src_access: rhi.AccessFlags, dst_access: rhi.AccessFlags, offset: u64, size: u64) void {
        _ = ptr;
        _ = buffer;
        _ = src_stage;
        _ = dst_stage;
        _ = src_access;
        _ = dst_access;
        _ = offset;
        _ = size;
    }
    fn waitForFrameFence(ptr: *anyopaque, frame_index: usize) bool {
        _ = ptr;
        _ = frame_index;
        return true;
    }
    fn hasCommandBuffer(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    const MOCK_RENDER_VTABLE = rhi.IRenderContext.VTable{
        .beginFrame = undefined,
        .endFrame = undefined,
        .abortFrame = undefined,
        .requestSwapchainRecreate = undefined,
        .getEncoder = MockContext.getEncoder,
        .getStateContext = MockContext.getStateContext,
        .setClearColor = undefined,
    };

    const MOCK_PASSES_VTABLE = rhi.IPassOrchestrationContext.VTable{
        .beginMainPass = undefined,
        .endMainPass = undefined,
        .beginPostProcessPass = undefined,
        .endPostProcessPass = undefined,
        .beginGPass = undefined,
        .endGPass = undefined,
        .beginFXAAPass = undefined,
        .endFXAAPass = undefined,
    };

    const MOCK_POST_PROCESS_VTABLE = rhi.IPostProcessContext.VTable{
        .computeBloom = undefined,
        .computeTAA = undefined,
        .computeDepthPyramid = undefined,
    };

    const MOCK_EFFECTS_VTABLE = rhi.IRenderEffectsContext.VTable{
        .drawSky = drawSky,
        .beginWaterDraw = beginWaterDraw,
        .endWaterDraw = endWaterDraw,
    };

    const MOCK_NATIVE_VTABLE = rhi.VulkanNativeHandles.VTable{
        .getCommandBuffer = getNativeCommandBuffer,
        .getSwapchainExtent = getNativeSwapchainExtent,
        .getDevice = getNativeDevice,
        .getInstance = getNativeInstance,
        .getPhysicalDevice = getNativePhysicalDevice,
        .getQueue = getNativeQueue,
        .getQueueFamily = getNativeQueueFamily,
        .getDescriptorPool = getNativeDescriptorPool,
        .getUiRenderPass = getNativeUiRenderPass,
        .getSwapchainImageCount = getNativeSwapchainImageCount,
    };

    const MOCK_SSAO_VTABLE = rhi.ISSAOContext.VTable{
        .compute = computeSsao,
    };

    const MOCK_DEBUG_OVERLAY_VTABLE = rhi.IDebugOverlayContext.VTable{
        .drawDebugShadowMap = drawDebugShadowMap,
    };

    const MOCK_WATER_VTABLE = rhi.IWaterContext.VTable{
        .beginReflectionPass = undefined,
        .endReflectionPass = undefined,
        .getReflectionTextureHandle = getWaterReflectionHandle,
        .getSceneDepthTextureHandle = getWaterSceneDepthHandle,
        .computeReflectedViewProj = computeWaterReflectedViewProj,
    };

    const MOCK_RESOURCES_VTABLE = rhi.IResourceFactory.VTable{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .createTexture = createTexture,
        .createTexture3D = createTexture3D,
        .destroyTexture = destroyTexture,
        .updateTexture = updateTexture,
        .createShader = createShader,
        .destroyShader = destroyShader,
        .mapBuffer = mapBuffer,
        .unmapBuffer = unmapBuffer,
    };

    fn createBuffer(ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
        _ = ptr;
        _ = size;
        _ = usage;
        return 1;
    }
    fn uploadBuffer(ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
        _ = ptr;
        _ = handle;
        _ = data;
    }
    fn updateBuffer(ptr: *anyopaque, handle: rhi.BufferHandle, offset: usize, data: []const u8) rhi.RhiError!void {
        _ = ptr;
        _ = handle;
        _ = offset;
        _ = data;
    }
    fn destroyBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) void {
        _ = ptr;
        _ = handle;
    }
    fn createTexture(ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        _ = ptr;
        _ = width;
        _ = height;
        _ = format;
        _ = config;
        _ = data;
        return 1;
    }
    fn createTexture3D(ptr: *anyopaque, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        _ = ptr;
        _ = width;
        _ = height;
        _ = depth;
        _ = format;
        _ = config;
        _ = data;
        return 1;
    }
    fn destroyTexture(ptr: *anyopaque, handle: rhi.TextureHandle) void {
        _ = ptr;
        _ = handle;
    }
    fn updateTexture(ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
        _ = ptr;
        _ = handle;
        _ = data;
    }
    fn createShader(ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
        _ = ptr;
        _ = vertex_src;
        _ = fragment_src;
        return 1;
    }
    fn destroyShader(ptr: *anyopaque, handle: rhi.ShaderHandle) void {
        _ = ptr;
        _ = handle;
    }
    fn mapBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
        _ = ptr;
        _ = handle;
        return null;
    }
    fn unmapBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) void {
        _ = ptr;
        _ = handle;
    }

    const MOCK_QUERY_VTABLE = rhi.IDeviceQuery.VTable{
        .getFrameIndex = undefined,
        .supportsIndirectFirstInstance = undefined,
        .supportsIndirectCount = undefined,
        .supportsCompactLODGpuCulling = undefined,
        .getMaxAnisotropy = undefined,
        .getMaxMSAASamples = undefined,
        .getFaultCount = undefined,
        .getValidationErrorCount = undefined,
        .getDrawCallCount = undefined,
        .getDeviceLocalVramBytes = undefined,
        .getRenderResolution = getRenderResolution,
        .waitIdle = undefined,
    };

    const MOCK_SHADOW_VTABLE = rhi.IShadowContext.VTable{
        .beginPass = undefined,
        .endPass = undefined,
        .updateUniforms = undefined,
        .getShadowMapHandle = getShadowMapHandle,
    };

    const MOCK_UI_VTABLE = rhi.IUIContext.VTable{
        .beginPass = undefined,
        .endPass = undefined,
        .drawRect = undefined,
        .drawTexture = undefined,
        .drawTextureRegion = undefined,
        .drawDepthTexture = drawDepthTexture,
        .bindPipeline = undefined,
        .drawIndexedGeometry = undefined,
        .setScissorRegion = undefined,
    };

    const MOCK_VULKAN_RHI_VTABLE = rhi.RHI.VTable{
        .init = undefined,
        .deinit = undefined,
        .resources = &MOCK_RESOURCES_VTABLE,
        .render = &MOCK_RENDER_VTABLE,
        .passes = &MOCK_PASSES_VTABLE,
        .post_process = &MOCK_POST_PROCESS_VTABLE,
        .effects = &MOCK_EFFECTS_VTABLE,
        .vulkan = &MOCK_NATIVE_VTABLE,
        .ssao = &MOCK_SSAO_VTABLE,
        .debug_overlay = &MOCK_DEBUG_OVERLAY_VTABLE,
        .shadow = &MOCK_SHADOW_VTABLE,
        .water = &MOCK_WATER_VTABLE,
        .compute = &.{
            .bindComputePipeline = bindComputePipeline,
            .bindDescriptorSet = bindDescriptorSet,
            .createComputeBuffer = createComputeBuffer,
            .destroyComputeBuffer = destroyComputeBuffer,
            .createComputePipeline = createComputePipeline,
            .updateComputeDescriptors = updateComputeDescriptors,
            .destroyComputePipeline = destroyComputePipeline,
            .dispatch = dispatchCompute,
            .pushConstants = pushComputeConstants,
            .fillBuffer = fillComputeBuffer,
            .copyBuffer = copyComputeBuffer,
            .pipelineBarrier = computePipelineBarrier,
            .bufferBarrier = computeBufferBarrier,
            .waitForFrameFence = waitForFrameFence,
            .hasCommandBuffer = hasCommandBuffer,
        },
        .ui = &MOCK_UI_VTABLE,
        .query = &MOCK_QUERY_VTABLE,
        .timing = &.{
            .beginPassTiming = beginPassTiming,
            .endPassTiming = endPassTiming,
            .getTimingResults = getTimingResults,
            .isTimingEnabled = isTimingEnabled,
            .setTimingEnabled = setTimingEnabled,
        },
        .quality = &.{
            .setWireframe = undefined,
            .setTexturesEnabled = undefined,
            .setDebugShadowView = undefined,
            .setShadowDebugChannel = undefined,
            .setVSync = undefined,
            .setAnisotropicFiltering = undefined,
            .setVolumetricDensity = undefined,
            .setShadowResolution = undefined,
            .setMSAA = undefined,
            .setFXAA = undefined,
            .setBloom = undefined,
            .setBloomIntensity = undefined,
            .setVignetteEnabled = undefined,
            .setVignetteIntensity = undefined,
            .setFilmGrainEnabled = undefined,
            .setFilmGrainIntensity = undefined,
            .setColorGradingEnabled = undefined,
            .setColorGradingIntensity = undefined,
            .setTAABlendFactor = undefined,
            .setTAAVelocityRejection = undefined,
            .setDynamicResolution = MockContext.setDynamicResolution,
            .getResolutionScale = MockContext.getResolutionScale,
        },
        .recovery = &.{
            .recover = undefined,
        },
        .culling_factory = &.{
            .createCullingSystem = MockContext.createCullingSystem,
            .createLODCullingSystem = MockContext.createLODCullingSystem,
        },
        .screenshot = &.{
            .captureFrame = undefined,
        },
    };

    const MOCK_ENCODER_VTABLE = rhi.IGraphicsCommandEncoder.VTable{
        .bindTexture = bindTexture,
        .bindBuffer = bindBuffer,
        .pushConstants = pushConstants,
        .draw = draw,
        .drawOffset = drawOffset,
        .drawIndexed = drawIndexed,
        .drawCompactLOD = undefined,
        .drawCompactLODIndirectCount = undefined,
        .drawIndirect = drawIndirect,
        .drawIndirectCount = drawIndirectCount,
        .drawInstance = drawInstance,
        .setViewport = setViewport,
    };

    const MOCK_STATE_VTABLE = rhi.IRenderStateContext.VTable{
        .setModelMatrix = undefined,
        .setLODOwnershipBounds = undefined,
        .setInstanceBuffer = undefined,
        .setLODInstanceBuffer = undefined,
        .setLODDescriptorStream = undefined,
        .setLODCompactSampleBuffer = undefined,
        .setLODCompactInstanceBuffer = undefined,
        .setTerrainPipelineBound = undefined,
        .setSelectionMode = undefined,
        .updateGlobalUniforms = undefined,
        .setTextureUniforms = undefined,
    };
};

test "IGraphicsCommandEncoder delegation" {
    var mock = MockContext{};
    const encoder = MockContext.getEncoder(&mock);

    encoder.bindTexture(2, 0);
    try testing.expect(mock.bind_texture_called);

    encoder.draw(3, 3, .triangles);
    try testing.expect(mock.draw_called);
}

test "IRenderContext getEncoder" {
    var mock = MockContext{};
    const ctx = rhi.IRenderContext{ .ptr = &mock, .vtable = &MockContext.MOCK_RENDER_VTABLE };
    const encoder = ctx.getEncoder();

    try testing.expectEqual(@as(?*anyopaque, &mock), encoder.ptr);
    try testing.expectEqual(&MockContext.MOCK_ENCODER_VTABLE, encoder.vtable);

    const state = ctx.getState();
    try testing.expectEqual(@as(?*anyopaque, &mock), state.ptr);
    try testing.expectEqual(&MockContext.MOCK_STATE_VTABLE, state.vtable);
}

test "indirect model uniforms use alpha sentinel without consuming mask sign" {
    const uniforms = @import("vulkan/rhi_draw_submission.zig").indirectModelUniforms();

    try testing.expect(uniforms.color[3] < 0.0);
    try testing.expectEqual(@as(f32, 0.0), uniforms.mask_radius);
}

const compact_submission = @import("vulkan/rhi_draw_submission.zig");

const CompactSubmissionContext = struct {
    frames: struct {
        current_frame: usize = 0,
        command_buffers: [1]c.VkCommandBuffer = .{null},
    } = .{},
    draw: struct {
        lod_descriptor_stream: rhi.LODDescriptorStream = .water_compact_gpu,
        lod_descriptor_stream_valid: bool = true,
        terrain_pipeline_bound: bool = true,
    } = .{},
    runtime: struct { draw_call_count: u32 = 0 } = .{},
    water_system: struct {
        pass_active: bool = false,
        water_pipeline: c.VkPipeline = @ptrFromInt(0x3000),
    } = .{},
    pipeline_manager: struct {
        compact_lod_terrain_pipeline: c.VkPipeline = @ptrFromInt(0x1000),
        compact_lod_water_pipeline: c.VkPipeline = @ptrFromInt(0x2000),
        pipeline_layout: c.VkPipelineLayout = null,
    } = .{},
    descriptors: struct {
        pub fn lodDescriptorSet(_: @This(), _: usize, stream: rhi.LODDescriptorStream) c.VkDescriptorSet {
            return @ptrFromInt(0x4000 + @as(usize, @intFromEnum(stream)) * 0x100);
        }
    } = .{},
};

// Only the command sink is mocked; selection, preflight, recording order, and
// cached pipeline state all run through the helper used by both backend draws.
const CompactCommandRecorder = struct {
    const Event = enum { pipeline, descriptors, constants, index, direct, indirect };
    ctx: *CompactSubmissionContext,
    events: [8]Event = undefined,
    event_count: usize = 0,
    pipelines: [2]c.VkPipeline = undefined,
    bound_at_bind: [2]bool = undefined,
    pipeline_count: usize = 0,
    descriptor: c.VkDescriptorSet = null,
    params: rhi.CompactLODDraw = undefined,
    index_type: c.VkIndexType = undefined,
    draw_count: u32 = 0,
    command_buffer: c.VkBuffer = null,
    command_offset: c.VkDeviceSize = 0,
    command_stride: u32 = 0,

    fn append(self: *@This(), event: Event) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    pub fn vkCmdBindPipeline(self: *@This(), _: c.VkCommandBuffer, _: c.VkPipelineBindPoint, pipeline: c.VkPipeline) void {
        self.append(.pipeline);
        self.pipelines[self.pipeline_count] = pipeline;
        self.bound_at_bind[self.pipeline_count] = self.ctx.draw.terrain_pipeline_bound;
        self.pipeline_count += 1;
    }

    pub fn vkCmdBindDescriptorSets(self: *@This(), _: c.VkCommandBuffer, _: c.VkPipelineBindPoint, _: c.VkPipelineLayout, _: u32, _: u32, sets: [*c]const c.VkDescriptorSet, _: u32, _: ?*const u32) void {
        self.append(.descriptors);
        self.descriptor = sets[0];
    }

    pub fn vkCmdPushConstants(self: *@This(), _: c.VkCommandBuffer, _: c.VkPipelineLayout, _: c.VkShaderStageFlags, _: u32, _: u32, params: *const rhi.CompactLODDraw) void {
        self.append(.constants);
        self.params = params.*;
    }

    pub fn vkCmdBindIndexBuffer(self: *@This(), _: c.VkCommandBuffer, _: c.VkBuffer, _: c.VkDeviceSize, index_type: c.VkIndexType) void {
        self.append(.index);
        self.index_type = index_type;
    }

    pub fn vkCmdDrawIndexed(self: *@This(), _: c.VkCommandBuffer, count: u32, _: u32, _: u32, _: i32, _: u32) void {
        self.append(.direct);
        self.draw_count = count;
    }

    pub fn vkCmdDrawIndexedIndirect(self: *@This(), _: c.VkCommandBuffer, buffer: c.VkBuffer, offset: c.VkDeviceSize, count: u32, stride: u32) void {
        self.append(.indirect);
        self.command_buffer = buffer;
        self.command_offset = offset;
        self.draw_count = count;
        self.command_stride = stride;
    }
};

const compact_water_params = rhi.CompactLODDraw{
    .model = Mat4.identity,
    .mask_radius = -32,
    .lod_fade = 0.5,
    .sample_offset = 16,
    .width = 4,
    .cell_size = 8,
    .layer = 1,
    .skirt_depth = 4,
};
const compact_indirect_submission = compact_submission.CompactLODSubmission{ .indirect = .{
    .buffer = @ptrFromInt(0x5000),
    .offset = 40,
    .capacity = 128,
} };

test "compact main-pass water indirect selects stream and restores water after fixed-capacity draw" {
    var ctx = CompactSubmissionContext{};
    var recorder = CompactCommandRecorder{ .ctx = &ctx };
    var sentinel = compact_water_params;
    sentinel.layer = 2;
    sentinel.width = 0;

    try testing.expect(compact_submission.recordCompactLOD(&ctx, &recorder, null, sentinel, compact_indirect_submission));
    try testing.expectEqualSlices(CompactCommandRecorder.Event, &.{ .pipeline, .descriptors, .constants, .index, .indirect, .pipeline }, recorder.events[0..recorder.event_count]);
    try testing.expectEqual(ctx.pipeline_manager.compact_lod_water_pipeline, recorder.pipelines[0]);
    try testing.expectEqual(ctx.water_system.water_pipeline, recorder.pipelines[1]);
    try testing.expect(!recorder.bound_at_bind[1]);
    try testing.expect(ctx.draw.terrain_pipeline_bound);
    try testing.expectEqual(@as(u32, 1), ctx.runtime.draw_call_count);
    try testing.expectEqual(ctx.descriptors.lodDescriptorSet(0, .water_compact_gpu), recorder.descriptor);
    try testing.expectEqualDeep(sentinel, recorder.params);
    try testing.expectEqual(@as(c.VkIndexType, c.VK_INDEX_TYPE_UINT32), recorder.index_type);
    try testing.expectEqual(compact_indirect_submission.indirect.buffer, recorder.command_buffer);
    try testing.expectEqual(@as(c.VkDeviceSize, 40), recorder.command_offset);
    try testing.expectEqual(@as(u32, 128), recorder.draw_count);
    try testing.expectEqual(@as(u32, @sizeOf(@import("engine-rhi").rhi_types.DrawIndexedIndirectCommand)), recorder.command_stride);
}

test "compact direct water restores expanded water pipeline and preserves direct parameters" {
    var ctx = CompactSubmissionContext{};
    ctx.draw.lod_descriptor_stream = .water_compact_direct;
    var recorder = CompactCommandRecorder{ .ctx = &ctx };

    try testing.expect(compact_submission.recordCompactLOD(&ctx, &recorder, null, compact_water_params, .{ .direct = 96 }));
    try testing.expectEqualSlices(CompactCommandRecorder.Event, &.{ .pipeline, .descriptors, .constants, .index, .direct, .pipeline }, recorder.events[0..recorder.event_count]);
    try testing.expectEqual(ctx.pipeline_manager.compact_lod_water_pipeline, recorder.pipelines[0]);
    try testing.expectEqual(ctx.water_system.water_pipeline, recorder.pipelines[1]);
    try testing.expect(!recorder.bound_at_bind[1]);
    try testing.expect(ctx.draw.terrain_pipeline_bound);
    try testing.expectEqual(@as(u32, 1), ctx.runtime.draw_call_count);
    try testing.expectEqual(ctx.descriptors.lodDescriptorSet(0, .water_compact_direct), recorder.descriptor);
    try testing.expectEqualDeep(compact_water_params, recorder.params);
    try testing.expectEqual(@as(u32, 96), recorder.draw_count);
}

test "compact terrain leaves ordinary pipeline invalidated regardless of reflection flag" {
    for ([_]bool{ false, true }) |reflection| {
        for ([_]bool{ false, true }) |indirect| {
            var ctx = CompactSubmissionContext{};
            ctx.water_system.pass_active = reflection;
            ctx.water_system.water_pipeline = null;
            ctx.draw.lod_descriptor_stream = if (indirect) .terrain_compact_gpu else .terrain_compact_direct;
            var recorder = CompactCommandRecorder{ .ctx = &ctx };
            var params = compact_water_params;
            params.layer = if (indirect) 2 else 0;

            try testing.expect(compact_submission.recordCompactLOD(&ctx, &recorder, null, params, if (indirect) compact_indirect_submission else .{ .direct = 96 }));
            try testing.expectEqual(@as(usize, 1), recorder.pipeline_count);
            try testing.expectEqual(ctx.pipeline_manager.compact_lod_terrain_pipeline, recorder.pipelines[0]);
            try testing.expectEqual(@as(usize, 5), recorder.event_count);
            try testing.expectEqual(if (indirect) CompactCommandRecorder.Event.indirect else .direct, recorder.events[4]);
            try testing.expect(!ctx.draw.terrain_pipeline_bound);
            try testing.expectEqual(@as(u32, 1), ctx.runtime.draw_call_count);
        }
    }
}

test "compact indirect rejects non-GPU-compact descriptor streams without recording" {
    for ([_]rhi.LODDescriptorStream{
        .terrain_standard_direct,
        .water_standard_direct,
        .terrain_standard_gpu,
        .water_standard_gpu,
        .terrain_compact_direct,
        .water_compact_direct,
    }) |stream| {
        var ctx = CompactSubmissionContext{};
        ctx.draw.lod_descriptor_stream = stream;
        var recorder = CompactCommandRecorder{ .ctx = &ctx };

        try testing.expect(!compact_submission.recordCompactLOD(&ctx, &recorder, null, compact_water_params, compact_indirect_submission));
        try testing.expectEqual(@as(usize, 0), recorder.event_count);
        try testing.expectEqual(@as(u32, 0), ctx.runtime.draw_call_count);
        try testing.expect(ctx.draw.terrain_pipeline_bound);
    }
}

test "compact water preflight failures preserve bindings and draw count" {
    for ([_]bool{ false, true }) |indirect| {
        for (0..3) |failure| {
            for ([_]bool{ false, true }) |bound| {
                var ctx = CompactSubmissionContext{};
                ctx.draw.lod_descriptor_stream = if (indirect) .water_compact_gpu else .water_compact_direct;
                ctx.draw.terrain_pipeline_bound = bound;
                switch (failure) {
                    0 => ctx.water_system.water_pipeline = null,
                    1 => ctx.pipeline_manager.compact_lod_water_pipeline = null,
                    2 => ctx.draw.lod_descriptor_stream_valid = false,
                    else => unreachable,
                }
                var recorder = CompactCommandRecorder{ .ctx = &ctx };

                try testing.expect(!compact_submission.recordCompactLOD(&ctx, &recorder, null, compact_water_params, if (indirect) compact_indirect_submission else .{ .direct = 96 }));
                try testing.expectEqual(@as(usize, 0), recorder.event_count);
                try testing.expectEqual(@as(u32, 0), ctx.runtime.draw_call_count);
                try testing.expectEqual(bound, ctx.draw.terrain_pipeline_bound);
            }
        }
    }
}

test "AtmosphereSystem.renderSky with null handles" {
    var mock = MockContext{};
    const rhi_instance = rhi.RHI{ .ptr = &mock, .vtable = &MockContext.MOCK_VULKAN_RHI_VTABLE, .device = null };

    const AtmosphereSystem = @import("engine-atmosphere").AtmosphereSystem;
    var system = try AtmosphereSystem.init(testing.allocator);
    defer system.deinit();

    try testing.expectError(error.SkyPipelineNotReady, system.renderSky(rhi_instance.renderContext(), .{
        .cam_pos = Vec3.zero,
        .cam_forward = Vec3.init(0, 0, 1),
        .cam_right = Vec3.init(1, 0, 0),
        .cam_up = Vec3.init(0, 1, 0),
        .sun_dir = Vec3.init(0, -1, 0),
        .sky_color = Vec3.init(0.5, 0.7, 1.0),
        .horizon_color = Vec3.init(0.8, 0.9, 1.0),
        .aspect = 1.77,
        .tan_half_fov = 1.0,
        .sun_intensity = 1.0,
        .moon_intensity = 0.1,
        .time = 0.0,
    }));

    try testing.expect(mock.sky_pipeline_requested);
}

test "SSAOSystem params defaults" {
    const SSAOParams = @import("vulkan/ssao_system.zig").SSAOParams;
    const KERNEL_SIZE = @import("vulkan/ssao_system.zig").KERNEL_SIZE;
    const DEFAULT_RADIUS = @import("vulkan/ssao_system.zig").DEFAULT_RADIUS;
    const DEFAULT_BIAS = @import("vulkan/ssao_system.zig").DEFAULT_BIAS;

    const params = std.mem.zeroes(SSAOParams);
    _ = params;
    // Note: std.mem.zeroes might not use struct defaults if defined with = DEFAULT_RADIUS
    // but in SSAOSystem.init we manually set them.
    // Let's test that the struct layout and constants are accessible.
    try testing.expectEqual(@as(usize, 64), KERNEL_SIZE);
    try testing.expectEqual(@as(f32, 0.5), DEFAULT_RADIUS);
    try testing.expectEqual(@as(f32, 0.025), DEFAULT_BIAS);
}

test "ResourceManager.registerExternalTexture validation" {
    const ResourceManager = @import("vulkan/resource_manager.zig").ResourceManager;
    const VulkanDevice = @import("vulkan_device.zig").VulkanDevice;

    // We don't need a real Vulkan device for this specific test as it only tests map insertion and validation logic
    var dummy_device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    var manager = ResourceManager{
        .allocator = testing.allocator,
        .vulkan_device = &dummy_device,
        .buffers = std.AutoHashMap(rhi.BufferHandle, @import("vulkan/resource_manager.zig").VulkanBuffer).init(testing.allocator),
        .next_buffer_handle = 1,
        .textures = std.AutoHashMap(rhi.TextureHandle, @import("vulkan/resource_manager.zig").TextureResource).init(testing.allocator),
        .next_texture_handle = 1,
        .buffer_deletion_queue = undefined,
        .image_deletion_queue = undefined,
        .staging_ring = undefined,
        .transfer = undefined,
    };
    defer manager.textures.deinit();
    defer manager.buffers.deinit();

    const dummy_view: c.VkImageView = @ptrFromInt(0x1234);
    const dummy_sampler: c.VkSampler = @ptrFromInt(0x5678);

    // Test successful registration
    const handle = try manager.registerExternalTexture(128, 128, .rgba, dummy_view, dummy_sampler);
    try testing.expect(handle != 0);
    try testing.expectEqual(@as(usize, 1), manager.textures.count());

    // Test null view validation
    try testing.expectError(error.InvalidImageView, manager.registerExternalTexture(128, 128, .rgba, null, dummy_sampler));

    // Test null sampler validation
    try testing.expectError(error.InvalidImageView, manager.registerExternalTexture(128, 128, .rgba, dummy_view, null));
}

test "RHI render options dynamic resolution" {
    var mock = MockContext{};
    mock.resolution_scale = 0.75;
    const rhi_instance = rhi.RHI{ .ptr = &mock, .vtable = &MockContext.MOCK_VULKAN_RHI_VTABLE, .device = null };

    rhi_instance.options().setDynamicResolution(true, 0.5, 0.9, 120);
    try testing.expect(mock.dynamic_resolution_called);
    try testing.expect(mock.dynamic_resolution_enabled);
    try testing.expectEqual(@as(f32, 0.5), mock.dynamic_resolution_min_scale);
    try testing.expectEqual(@as(f32, 0.9), mock.dynamic_resolution_max_scale);
    try testing.expectEqual(@as(u32, 120), mock.dynamic_resolution_target_fps);
    try testing.expectEqual(@as(f32, 0.75), rhi_instance.options().getResolutionScale());
}
