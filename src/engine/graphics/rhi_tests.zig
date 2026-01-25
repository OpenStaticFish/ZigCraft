const std = @import("std");
const testing = std.testing;
const rhi = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

const MockContext = struct {
    bind_shader_called: bool = false,
    bind_texture_called: bool = false,
    draw_called: bool = false,
    sky_pipeline_requested: bool = false,
    cloud_pipeline_requested: bool = false,

    fn bindShader(ptr: *anyopaque, handle: rhi.ShaderHandle) void {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        _ = handle;
        self.bind_shader_called = true;
    }
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

    fn getNativeSkyPipeline(ptr: *anyopaque) u64 {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        self.sky_pipeline_requested = true;
        return 0;
    }
    fn getNativeSkyPipelineLayout(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeCloudPipeline(ptr: *anyopaque) u64 {
        const self: *MockContext = @ptrCast(@alignCast(ptr));
        self.cloud_pipeline_requested = true;
        return 0;
    }
    fn getNativeCloudPipelineLayout(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeMainDescriptorSet(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOPipeline(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOPipelineLayout(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOBlurPipeline(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOBlurPipelineLayout(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAODescriptorSet(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOBlurDescriptorSet(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeCommandBuffer(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSwapchainExtent(ptr: *anyopaque) [2]u32 {
        _ = ptr;
        return .{ 800, 600 };
    }
    fn getNativeSSAOFramebuffer(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOBlurFramebuffer(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAORenderPass(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOBlurRenderPass(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOParamsBuffer(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeSSAOParamsMemory(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
    }
    fn getNativeDevice(ptr: *anyopaque) u64 {
        _ = ptr;
        return 0;
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

    const MOCK_RENDER_VTABLE = rhi.IRenderContext.VTable{
        .beginFrame = undefined,
        .endFrame = undefined,
        .abortFrame = undefined,
        .beginMainPass = undefined,
        .endMainPass = undefined,
        .beginPostProcessPass = undefined,
        .endPostProcessPass = undefined,
        .beginGPass = undefined,
        .endGPass = undefined,
        .beginFXAAPass = undefined,
        .endFXAAPass = undefined,
        .computeBloom = undefined,
        .getEncoder = MockContext.getEncoder,
        .getStateContext = MockContext.getStateContext,
        .setClearColor = undefined,
        .getNativeSkyPipeline = getNativeSkyPipeline,
        .getNativeSkyPipelineLayout = getNativeSkyPipelineLayout,
        .getNativeCloudPipeline = getNativeCloudPipeline,
        .getNativeCloudPipelineLayout = getNativeCloudPipelineLayout,
        .getNativeMainDescriptorSet = getNativeMainDescriptorSet,
        .getNativeSSAOPipeline = getNativeSSAOPipeline,
        .getNativeSSAOPipelineLayout = getNativeSSAOPipelineLayout,
        .getNativeSSAOBlurPipeline = getNativeSSAOBlurPipeline,
        .getNativeSSAOBlurPipelineLayout = getNativeSSAOBlurPipelineLayout,
        .getNativeSSAODescriptorSet = getNativeSSAODescriptorSet,
        .getNativeSSAOBlurDescriptorSet = getNativeSSAOBlurDescriptorSet,
        .getNativeCommandBuffer = getNativeCommandBuffer,
        .getNativeSwapchainExtent = getNativeSwapchainExtent,
        .getNativeSSAOFramebuffer = getNativeSSAOFramebuffer,
        .getNativeSSAOBlurFramebuffer = getNativeSSAOBlurFramebuffer,
        .getNativeSSAORenderPass = getNativeSSAORenderPass,
        .getNativeSSAOBlurRenderPass = getNativeSSAOBlurRenderPass,
        .getNativeSSAOParamsBuffer = getNativeSSAOParamsBuffer,
        .getNativeSSAOParamsMemory = getNativeSSAOParamsMemory,
        .getNativeDevice = getNativeDevice,
        .computeSSAO = undefined,
        .drawDebugShadowMap = undefined,
    };

    const MOCK_RESOURCES_VTABLE = rhi.IResourceFactory.VTable{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .createTexture = createTexture,
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
        .getMaxAnisotropy = undefined,
        .getMaxMSAASamples = undefined,
        .getFaultCount = undefined,
        .getValidationErrorCount = undefined,
        .waitIdle = undefined,
    };

    const MOCK_VULKAN_RHI_VTABLE = rhi.RHI.VTable{
        .init = undefined,
        .deinit = undefined,
        .resources = MOCK_RESOURCES_VTABLE,
        .render = MOCK_RENDER_VTABLE,
        .shadow = undefined,
        .ui = undefined,
        .query = MOCK_QUERY_VTABLE,
        .timing = .{
            .beginPassTiming = beginPassTiming,
            .endPassTiming = endPassTiming,
            .getTimingResults = getTimingResults,
            .isTimingEnabled = isTimingEnabled,
            .setTimingEnabled = setTimingEnabled,
        },
        .setWireframe = undefined,
        .setTexturesEnabled = undefined,
        .setDebugShadowView = undefined,
        .setVSync = undefined,
        .setAnisotropicFiltering = undefined,
        .setVolumetricDensity = undefined,
        .setMSAA = undefined,
        .recover = undefined,
        .setFXAA = undefined,
        .setBloom = undefined,
        .setBloomIntensity = undefined,
    };

    const MOCK_ENCODER_VTABLE = rhi.IGraphicsCommandEncoder.VTable{
        .bindShader = bindShader,
        .bindTexture = bindTexture,
        .bindBuffer = bindBuffer,
        .pushConstants = pushConstants,
        .draw = draw,
        .drawOffset = drawOffset,
        .drawIndexed = drawIndexed,
        .drawIndirect = drawIndirect,
        .drawInstance = drawInstance,
        .setViewport = setViewport,
    };

    const MOCK_STATE_VTABLE = rhi.IRenderStateContext.VTable{
        .setModelMatrix = undefined,
        .setInstanceBuffer = undefined,
        .setLODInstanceBuffer = undefined,
        .setSelectionMode = undefined,
        .updateGlobalUniforms = undefined,
        .setTextureUniforms = undefined,
    };
};

test "IGraphicsCommandEncoder delegation" {
    var mock = MockContext{};
    const encoder = MockContext.getEncoder(&mock);

    encoder.bindShader(1);
    try testing.expect(mock.bind_shader_called);

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

test "AtmosphereSystem.renderSky with null handles" {
    var mock = MockContext{};
    const rhi_instance = rhi.RHI{ .ptr = &mock, .vtable = &MockContext.MOCK_VULKAN_RHI_VTABLE, .device = null };

    const AtmosphereSystem = @import("atmosphere_system.zig").AtmosphereSystem;
    var system = try AtmosphereSystem.init(testing.allocator, rhi_instance);
    defer system.deinit();

    // Should return error.SkyPipelineNotReady if handles are missing
    try testing.expectError(error.SkyPipelineNotReady, system.renderSky(.{
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

test "AtmosphereSystem.renderClouds with null handles" {
    var mock = MockContext{};
    const rhi_instance = rhi.RHI{ .ptr = &mock, .vtable = &MockContext.MOCK_VULKAN_RHI_VTABLE, .device = null };

    const AtmosphereSystem = @import("atmosphere_system.zig").AtmosphereSystem;
    var system = try AtmosphereSystem.init(testing.allocator, rhi_instance);
    defer system.deinit();

    try testing.expectError(error.CloudPipelineNotReady, system.renderClouds(.{
        .cam_pos = Vec3.zero,
        .sun_dir = Vec3.init(0, -1, 0),
        .sun_intensity = 1.0,
        .cloud_coverage = 0.5,
        .cloud_scale = 1.0,
        .cloud_height = 100.0,
        .wind_offset_x = 0.0,
        .wind_offset_z = 0.0,
        .fog_color = Vec3.init(0.8, 0.9, 1.0),
        .fog_density = 0.01,
        .view_proj = Mat4.identity,
    }, Mat4.identity));

    try testing.expect(mock.cloud_pipeline_requested);
}
