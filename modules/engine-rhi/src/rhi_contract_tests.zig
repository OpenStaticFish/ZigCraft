const std = @import("std");
const rhi = @import("rhi.zig");
const types = @import("rhi_types.zig");
const Vec3 = @import("engine-math").Vec3;

const Mock = struct {
    created_size: usize = 0,
    uploaded_handle: types.BufferHandle = 0,
    destroyed_handle: types.BufferHandle = 0,
    begin_count: u32 = 0,
    clear_color: Vec3 = Vec3.zero,
    command_buffer: u64 = 0x1234,

    fn createBuffer(ptr: *anyopaque, size: usize, usage: types.BufferUsage) types.RhiError!types.BufferHandle {
        _ = usage;
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.created_size = size;
        return 7;
    }
    fn uploadBuffer(ptr: *anyopaque, handle: types.BufferHandle, data: []const u8) types.RhiError!void {
        _ = data;
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.uploaded_handle = handle;
    }
    fn updateBuffer(_: *anyopaque, _: types.BufferHandle, _: usize, _: []const u8) types.RhiError!void {}
    fn destroyBuffer(ptr: *anyopaque, handle: types.BufferHandle) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.destroyed_handle = handle;
    }
    fn createTexture(_: *anyopaque, _: u32, _: u32, _: types.TextureFormat, _: types.TextureConfig, _: ?[]const u8) types.RhiError!types.TextureHandle {
        return 11;
    }
    fn createTexture3D(_: *anyopaque, _: u32, _: u32, _: u32, _: types.TextureFormat, _: types.TextureConfig, _: ?[]const u8) types.RhiError!types.TextureHandle {
        return 12;
    }
    fn destroyTexture(_: *anyopaque, _: types.TextureHandle) void {}
    fn updateTexture(_: *anyopaque, _: types.TextureHandle, _: []const u8) types.RhiError!void {}
    fn createShader(_: *anyopaque, _: [*c]const u8, _: [*c]const u8) types.RhiError!types.ShaderHandle {
        return 13;
    }
    fn destroyShader(_: *anyopaque, _: types.ShaderHandle) void {}
    fn mapBuffer(_: *anyopaque, _: types.BufferHandle) types.RhiError!?*anyopaque {
        return null;
    }
    fn unmapBuffer(_: *anyopaque, _: types.BufferHandle) void {}

    fn beginFrame(ptr: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.begin_count += 1;
    }
    fn endFrame(_: *anyopaque) void {}
    fn abortFrame(_: *anyopaque) void {}
    fn requestSwapchainRecreate(_: *anyopaque) void {}
    fn getEncoder(_: *anyopaque) rhi.IGraphicsCommandEncoder {
        return undefined;
    }
    fn getStateContext(_: *anyopaque) rhi.IRenderStateContext {
        return undefined;
    }
    fn setClearColor(ptr: *anyopaque, color: Vec3) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.clear_color = color;
    }

    fn getCommandBuffer(ptr: *anyopaque) u64 {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        return self.command_buffer;
    }
    fn getSwapchainExtent(_: *anyopaque) [2]u32 {
        return .{ 1920, 1080 };
    }
    fn getDevice(_: *anyopaque) u64 {
        return 1;
    }
    fn getInstance(_: *anyopaque) u64 {
        return 2;
    }
    fn getPhysicalDevice(_: *anyopaque) u64 {
        return 3;
    }
    fn getQueue(_: *anyopaque) u64 {
        return 4;
    }
    fn getQueueFamily(_: *anyopaque) u32 {
        return 5;
    }
    fn getDescriptorPool(_: *anyopaque) u64 {
        return 6;
    }
    fn getUiRenderPass(_: *anyopaque) u64 {
        return 8;
    }
    fn getSwapchainImageCount(_: *anyopaque) u32 {
        return 3;
    }
};

const resource_vtable = rhi.IResourceFactory.VTable{
    .createBuffer = Mock.createBuffer,
    .uploadBuffer = Mock.uploadBuffer,
    .updateBuffer = Mock.updateBuffer,
    .destroyBuffer = Mock.destroyBuffer,
    .createTexture = Mock.createTexture,
    .createTexture3D = Mock.createTexture3D,
    .destroyTexture = Mock.destroyTexture,
    .updateTexture = Mock.updateTexture,
    .createShader = Mock.createShader,
    .destroyShader = Mock.destroyShader,
    .mapBuffer = Mock.mapBuffer,
    .unmapBuffer = Mock.unmapBuffer,
};

const render_vtable = rhi.IRenderContext.VTable{
    .beginFrame = Mock.beginFrame,
    .endFrame = Mock.endFrame,
    .abortFrame = Mock.abortFrame,
    .requestSwapchainRecreate = Mock.requestSwapchainRecreate,
    .getEncoder = Mock.getEncoder,
    .getStateContext = Mock.getStateContext,
    .setClearColor = Mock.setClearColor,
};

const native_vtable = rhi.VulkanNativeHandles.VTable{
    .getCommandBuffer = Mock.getCommandBuffer,
    .getSwapchainExtent = Mock.getSwapchainExtent,
    .getDevice = Mock.getDevice,
    .getInstance = Mock.getInstance,
    .getPhysicalDevice = Mock.getPhysicalDevice,
    .getQueue = Mock.getQueue,
    .getQueueFamily = Mock.getQueueFamily,
    .getDescriptorPool = Mock.getDescriptorPool,
    .getUiRenderPass = Mock.getUiRenderPass,
    .getSwapchainImageCount = Mock.getSwapchainImageCount,
};

test "ResourceManager forwards resource factory calls" {
    var mock = Mock{};
    const manager = rhi.ResourceManager{ .factory = .{ .ptr = &mock, .vtable = &resource_vtable } };

    const handle = try manager.createBuffer(256, .vertex);
    try std.testing.expectEqual(@as(types.BufferHandle, 7), handle);
    try std.testing.expectEqual(@as(usize, 256), mock.created_size);

    try manager.uploadBuffer(handle, &.{ 1, 2, 3 });
    try std.testing.expectEqual(handle, mock.uploaded_handle);

    manager.destroyBuffer(handle);
    try std.testing.expectEqual(handle, mock.destroyed_handle);
}

test "IRenderContext forwards lifecycle and state calls" {
    var mock = Mock{};
    const ctx = rhi.IRenderContext{ .ptr = &mock, .vtable = &render_vtable };

    ctx.beginFrame();
    ctx.setClearColor(.{ .x = 0.25, .y = 0.5, .z = 0.75 });

    try std.testing.expectEqual(@as(u32, 1), mock.begin_count);
    try std.testing.expectEqual(@as(f32, 0.25), mock.clear_color.x);
}

test "native handles expose explicit handles only" {
    var mock = Mock{};
    const native = rhi.VulkanNativeHandles{ .ptr = &mock, .vtable = &native_vtable };

    try std.testing.expectEqual(@as(u64, 0x1234), native.getCommandBuffer());
    try std.testing.expectEqual([2]u32{ 1920, 1080 }, native.getSwapchainExtent());
    try std.testing.expect(!@hasDecl(rhi.VulkanNativeHandles, "getBackendContext"));
}

// Broad documentation-as-contract coverage for public RHI methods.
// These tests intentionally stay GPU-free: they lock interface names in place so
// vtable/wrapper drift is caught in engine-rhi instead of Vulkan integration.
test "RHI contract declares IResourceFactory.createBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "createBuffer"));
}
test "RHI contract declares IResourceFactory.uploadBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "uploadBuffer"));
}
test "RHI contract declares IResourceFactory.updateBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "updateBuffer"));
}
test "RHI contract declares IResourceFactory.destroyBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "destroyBuffer"));
}
test "RHI contract declares IResourceFactory.createTexture" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "createTexture"));
}
test "RHI contract declares IResourceFactory.createTexture3D" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "createTexture3D"));
}
test "RHI contract declares IResourceFactory.destroyTexture" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "destroyTexture"));
}
test "RHI contract declares IResourceFactory.updateTexture" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "updateTexture"));
}
test "RHI contract declares IResourceFactory.createShader" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "createShader"));
}
test "RHI contract declares IResourceFactory.destroyShader" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "destroyShader"));
}
test "RHI contract declares IResourceFactory.mapBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "mapBuffer"));
}
test "RHI contract declares IResourceFactory.unmapBuffer" {
    try std.testing.expect(@hasDecl(rhi.IResourceFactory, "unmapBuffer"));
}
test "RHI contract declares ResourceManager.createBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "createBuffer"));
}
test "RHI contract declares ResourceManager.uploadBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "uploadBuffer"));
}
test "RHI contract declares ResourceManager.updateBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "updateBuffer"));
}
test "RHI contract declares ResourceManager.destroyBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "destroyBuffer"));
}
test "RHI contract declares ResourceManager.createTexture" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "createTexture"));
}
test "RHI contract declares ResourceManager.createTexture3D" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "createTexture3D"));
}
test "RHI contract declares ResourceManager.destroyTexture" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "destroyTexture"));
}
test "RHI contract declares ResourceManager.updateTexture" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "updateTexture"));
}
test "RHI contract declares ResourceManager.createShader" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "createShader"));
}
test "RHI contract declares ResourceManager.destroyShader" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "destroyShader"));
}
test "RHI contract declares ResourceManager.mapBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "mapBuffer"));
}
test "RHI contract declares ResourceManager.unmapBuffer" {
    try std.testing.expect(@hasDecl(rhi.ResourceManager, "unmapBuffer"));
}
test "RHI contract declares RenderContext.beginFrame" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginFrame"));
}
test "RHI contract declares RenderContext.endFrame" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endFrame"));
}
test "RHI contract declares RenderContext.abortFrame" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "abortFrame"));
}
test "RHI contract declares RenderContext.beginMainPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginMainPass"));
}
test "RHI contract declares RenderContext.endMainPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endMainPass"));
}
test "RHI contract declares RenderContext.beginPostProcessPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginPostProcessPass"));
}
test "RHI contract declares RenderContext.endPostProcessPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endPostProcessPass"));
}
test "RHI contract declares RenderContext.beginGPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginGPass"));
}
test "RHI contract declares RenderContext.endGPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endGPass"));
}
test "RHI contract declares RenderContext.beginFXAAPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginFXAAPass"));
}
test "RHI contract declares RenderContext.endFXAAPass" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endFXAAPass"));
}
test "RHI contract declares RenderContext.computeBloom" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "computeBloom"));
}
test "RHI contract declares RenderContext.computeTAA" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "computeTAA"));
}
test "RHI contract declares RenderContext.computeDepthPyramid" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "computeDepthPyramid"));
}
test "RHI contract declares RenderContext.drawSky" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "drawSky"));
}
test "RHI contract declares RenderContext.beginWaterDraw" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "beginWaterDraw"));
}
test "RHI contract declares RenderContext.endWaterDraw" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "endWaterDraw"));
}
test "RHI contract declares RenderContext.requestSwapchainRecreate" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "requestSwapchainRecreate"));
}
test "RHI contract declares RenderContext.setClearColor" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setClearColor"));
}
test "RHI contract declares RenderContext.getNativeSwapchainExtent" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "getNativeSwapchainExtent"));
}
test "RHI contract declares RenderContext.getNativeDevice" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "getNativeDevice"));
}
test "RHI contract declares RenderContext.bindTexture" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "bindTexture"));
}
test "RHI contract declares RenderContext.bindBuffer" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "bindBuffer"));
}
test "RHI contract declares RenderContext.pushConstants" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "pushConstants"));
}
test "RHI contract declares RenderContext.draw" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "draw"));
}
test "RHI contract declares RenderContext.drawOffset" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "drawOffset"));
}
test "RHI contract declares RenderContext.drawIndexed" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "drawIndexed"));
}
test "RHI contract declares RenderContext.drawIndirect" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "drawIndirect"));
}
test "RHI contract declares RenderContext.drawInstance" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "drawInstance"));
}
test "RHI contract declares RenderContext.setViewport" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setViewport"));
}
test "RHI contract declares RenderContext.setModelMatrix" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setModelMatrix"));
}
test "RHI contract declares RenderContext.setInstanceBuffer" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setInstanceBuffer"));
}
test "RHI contract declares RenderContext.setTerrainPipelineBound" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setTerrainPipelineBound"));
}
test "RHI contract declares RenderContext.setSelectionMode" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setSelectionMode"));
}
test "RHI contract declares RenderContext.updateGlobalUniforms" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "updateGlobalUniforms"));
}
test "RHI contract declares RenderContext.setTextureUniforms" {
    try std.testing.expect(@hasDecl(rhi.RenderContext, "setTextureUniforms"));
}
test "RHI contract declares IShadowContext.beginPass" {
    try std.testing.expect(@hasDecl(rhi.IShadowContext, "beginPass"));
}
test "RHI contract declares IShadowContext.endPass" {
    try std.testing.expect(@hasDecl(rhi.IShadowContext, "endPass"));
}
test "RHI contract declares IShadowContext.updateUniforms" {
    try std.testing.expect(@hasDecl(rhi.IShadowContext, "updateUniforms"));
}
test "RHI contract declares IShadowContext.getShadowMapHandle" {
    try std.testing.expect(@hasDecl(rhi.IShadowContext, "getShadowMapHandle"));
}
test "RHI contract declares ShadowSystemWrapper.beginPass" {
    try std.testing.expect(@hasDecl(rhi.ShadowSystemWrapper, "beginPass"));
}
test "RHI contract declares ShadowSystemWrapper.endPass" {
    try std.testing.expect(@hasDecl(rhi.ShadowSystemWrapper, "endPass"));
}
test "RHI contract declares ShadowSystemWrapper.updateUniforms" {
    try std.testing.expect(@hasDecl(rhi.ShadowSystemWrapper, "updateUniforms"));
}
test "RHI contract declares ShadowSystemWrapper.getShadowMapHandle" {
    try std.testing.expect(@hasDecl(rhi.ShadowSystemWrapper, "getShadowMapHandle"));
}
test "RHI contract declares IWaterContext.beginReflectionPass" {
    try std.testing.expect(@hasDecl(rhi.IWaterContext, "beginReflectionPass"));
}
test "RHI contract declares IWaterContext.endReflectionPass" {
    try std.testing.expect(@hasDecl(rhi.IWaterContext, "endReflectionPass"));
}
test "RHI contract declares IWaterContext.getReflectionTextureHandle" {
    try std.testing.expect(@hasDecl(rhi.IWaterContext, "getReflectionTextureHandle"));
}
test "RHI contract declares IWaterContext.getSceneDepthTextureHandle" {
    try std.testing.expect(@hasDecl(rhi.IWaterContext, "getSceneDepthTextureHandle"));
}
test "RHI contract declares IWaterContext.computeReflectedViewProj" {
    try std.testing.expect(@hasDecl(rhi.IWaterContext, "computeReflectedViewProj"));
}
test "RHI contract declares WaterSystemWrapper.beginReflectionPass" {
    try std.testing.expect(@hasDecl(rhi.WaterSystemWrapper, "beginReflectionPass"));
}
test "RHI contract declares WaterSystemWrapper.endReflectionPass" {
    try std.testing.expect(@hasDecl(rhi.WaterSystemWrapper, "endReflectionPass"));
}
test "RHI contract declares WaterSystemWrapper.getReflectionTextureHandle" {
    try std.testing.expect(@hasDecl(rhi.WaterSystemWrapper, "getReflectionTextureHandle"));
}
test "RHI contract declares WaterSystemWrapper.getSceneDepthTextureHandle" {
    try std.testing.expect(@hasDecl(rhi.WaterSystemWrapper, "getSceneDepthTextureHandle"));
}
test "RHI contract declares WaterSystemWrapper.computeReflectedViewProj" {
    try std.testing.expect(@hasDecl(rhi.WaterSystemWrapper, "computeReflectedViewProj"));
}
test "RHI contract declares IUIContext.beginPass" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "beginPass"));
}
test "RHI contract declares IUIContext.endPass" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "endPass"));
}
test "RHI contract declares IUIContext.drawRect" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "drawRect"));
}
test "RHI contract declares IUIContext.drawTexture" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "drawTexture"));
}
test "RHI contract declares IUIContext.drawTextureRegion" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "drawTextureRegion"));
}
test "RHI contract declares IUIContext.drawDepthTexture" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "drawDepthTexture"));
}
test "RHI contract declares IUIContext.bindPipeline" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "bindPipeline"));
}
test "RHI contract declares IUIContext retained geometry operations" {
    try std.testing.expect(@hasDecl(rhi.IUIContext, "drawIndexedGeometry"));
    try std.testing.expect(@hasDecl(rhi.IUIContext, "setScissorRegion"));
}
test "RHI contract declares UIRenderer.beginPass" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "beginPass"));
}
test "RHI contract declares UIRenderer.endPass" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "endPass"));
}
test "RHI contract declares UIRenderer.drawRect" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "drawRect"));
}
test "RHI contract declares UIRenderer.drawTexture" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "drawTexture"));
}
test "RHI contract declares UIRenderer.drawTextureRegion" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "drawTextureRegion"));
}
test "RHI contract declares UIRenderer.drawDepthTexture" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "drawDepthTexture"));
}
test "RHI contract declares UIRenderer.bindPipeline" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "bindPipeline"));
}
test "RHI contract declares UIRenderer retained geometry operations" {
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "drawIndexedGeometry"));
    try std.testing.expect(@hasDecl(rhi.UIRenderer, "setScissorRegion"));
}
test "RHI UI geometry types retain the RmlUi-compatible memory layout" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(rhi.UiVertex));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(rhi.UiVertex, "position"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(rhi.UiVertex, "color"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(rhi.UiVertex, "uv"));
}
test "RHI contract declares IGraphicsCommandEncoder.bindTexture" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "bindTexture"));
}
test "RHI contract declares IGraphicsCommandEncoder.bindBuffer" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "bindBuffer"));
}
test "RHI contract declares IGraphicsCommandEncoder.pushConstants" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "pushConstants"));
}
test "RHI contract declares IGraphicsCommandEncoder.draw" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "draw"));
}
test "RHI contract declares IGraphicsCommandEncoder.drawOffset" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "drawOffset"));
}
test "RHI contract declares IGraphicsCommandEncoder.drawIndexed" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "drawIndexed"));
}
test "RHI contract declares IGraphicsCommandEncoder.drawIndirect" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "drawIndirect"));
}
test "RHI contract declares IGraphicsCommandEncoder.drawInstance" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "drawInstance"));
}
test "RHI contract declares IGraphicsCommandEncoder.setViewport" {
    try std.testing.expect(@hasDecl(rhi.IGraphicsCommandEncoder, "setViewport"));
}
test "RHI contract declares IRenderStateContext.setModelMatrix" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "setModelMatrix"));
}
test "RHI contract declares IRenderStateContext.setInstanceBuffer" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "setInstanceBuffer"));
}
test "RHI contract declares IRenderStateContext.setTerrainPipelineBound" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "setTerrainPipelineBound"));
}
test "RHI contract declares IRenderStateContext.setSelectionMode" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "setSelectionMode"));
}
test "RHI contract declares IRenderStateContext.updateGlobalUniforms" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "updateGlobalUniforms"));
}
test "RHI contract declares IRenderStateContext.setTextureUniforms" {
    try std.testing.expect(@hasDecl(rhi.IRenderStateContext, "setTextureUniforms"));
}
test "RHI contract declares ISSAOContext.compute" {
    try std.testing.expect(@hasDecl(rhi.ISSAOContext, "compute"));
}
test "RHI contract declares IDebugOverlayContext.drawDebugShadowMap" {
    try std.testing.expect(@hasDecl(rhi.IDebugOverlayContext, "drawDebugShadowMap"));
}
test "RHI contract declares IComputeContext.bindComputePipeline" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "bindComputePipeline"));
}
test "RHI contract declares IComputeContext.bindDescriptorSet" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "bindDescriptorSet"));
}
test "RHI contract declares IComputeContext.createComputeBuffer" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "createComputeBuffer"));
}
test "RHI contract declares IComputeContext.destroyComputeBuffer" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "destroyComputeBuffer"));
}
test "RHI contract declares IComputeContext.createComputePipeline" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "createComputePipeline"));
}
test "RHI contract declares IComputeContext.updateComputeDescriptors" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "updateComputeDescriptors"));
}
test "RHI contract declares IComputeContext.destroyComputePipeline" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "destroyComputePipeline"));
}
test "RHI contract declares IComputeContext.dispatch" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "dispatch"));
}
test "RHI contract declares IComputeContext.pushConstants" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "pushConstants"));
}
test "RHI contract declares IComputeContext.fillBuffer" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "fillBuffer"));
}
test "RHI contract declares IComputeContext.copyBuffer" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "copyBuffer"));
}
test "RHI contract declares IComputeContext.pipelineBarrier" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "pipelineBarrier"));
}
test "RHI contract declares IComputeContext.bufferBarrier" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "bufferBarrier"));
}
test "RHI contract declares IComputeContext.waitForFrameFence" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "waitForFrameFence"));
}
test "RHI contract declares IComputeContext.hasCommandBuffer" {
    try std.testing.expect(@hasDecl(rhi.IComputeContext, "hasCommandBuffer"));
}
test "RHI contract declares IRenderContext.beginFrame" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "beginFrame"));
}
test "RHI contract declares IRenderContext.endFrame" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "endFrame"));
}
test "RHI contract declares IRenderContext.abortFrame" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "abortFrame"));
}
test "RHI contract declares IRenderContext.requestSwapchainRecreate" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "requestSwapchainRecreate"));
}
test "RHI contract declares IRenderContext.getEncoder" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "getEncoder"));
}
test "RHI contract declares IRenderContext.getState" {
    try std.testing.expect(@hasDecl(rhi.IRenderContext, "getState"));
}
test "RHI contract declares IPassOrchestrationContext.beginMainPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "beginMainPass"));
}
test "RHI contract declares IPassOrchestrationContext.endMainPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "endMainPass"));
}
test "RHI contract declares IPassOrchestrationContext.beginPostProcessPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "beginPostProcessPass"));
}
test "RHI contract declares IPassOrchestrationContext.endPostProcessPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "endPostProcessPass"));
}
test "RHI contract declares IPassOrchestrationContext.beginGPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "beginGPass"));
}
test "RHI contract declares IPassOrchestrationContext.endGPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "endGPass"));
}
test "RHI contract declares IPassOrchestrationContext.beginFXAAPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "beginFXAAPass"));
}
test "RHI contract declares IPassOrchestrationContext.endFXAAPass" {
    try std.testing.expect(@hasDecl(rhi.IPassOrchestrationContext, "endFXAAPass"));
}
test "RHI contract declares IPostProcessContext.computeBloom" {
    try std.testing.expect(@hasDecl(rhi.IPostProcessContext, "computeBloom"));
}
test "RHI contract declares IPostProcessContext.computeTAA" {
    try std.testing.expect(@hasDecl(rhi.IPostProcessContext, "computeTAA"));
}
test "RHI contract declares IPostProcessContext.computeDepthPyramid" {
    try std.testing.expect(@hasDecl(rhi.IPostProcessContext, "computeDepthPyramid"));
}
test "RHI contract declares IRenderEffectsContext.drawSky" {
    try std.testing.expect(@hasDecl(rhi.IRenderEffectsContext, "drawSky"));
}
test "RHI contract declares IRenderEffectsContext.beginWaterDraw" {
    try std.testing.expect(@hasDecl(rhi.IRenderEffectsContext, "beginWaterDraw"));
}
test "RHI contract declares IRenderEffectsContext.endWaterDraw" {
    try std.testing.expect(@hasDecl(rhi.IRenderEffectsContext, "endWaterDraw"));
}
test "RHI contract declares VulkanNativeHandles.getCommandBuffer" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getCommandBuffer"));
}
test "RHI contract declares VulkanNativeHandles.getSwapchainExtent" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getSwapchainExtent"));
}
test "RHI contract declares VulkanNativeHandles.getDevice" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getDevice"));
}
test "RHI contract declares VulkanNativeHandles.getInstance" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getInstance"));
}
test "RHI contract declares VulkanNativeHandles.getPhysicalDevice" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getPhysicalDevice"));
}
test "RHI contract declares VulkanNativeHandles.getQueue" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getQueue"));
}
test "RHI contract declares VulkanNativeHandles.getQueueFamily" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getQueueFamily"));
}
test "RHI contract declares VulkanNativeHandles.getDescriptorPool" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getDescriptorPool"));
}
test "RHI contract declares VulkanNativeHandles.getUiRenderPass" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getUiRenderPass"));
}
test "RHI contract declares VulkanNativeHandles.getSwapchainImageCount" {
    try std.testing.expect(@hasDecl(rhi.VulkanNativeHandles, "getSwapchainImageCount"));
}
test "RHI contract declares IDeviceQuery.getFrameIndex" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getFrameIndex"));
}
test "RHI contract declares IDeviceQuery.supportsIndirectFirstInstance" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "supportsIndirectFirstInstance"));
}

test "RHI contract declares IDeviceQuery.getFaultCount" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getFaultCount"));
}
test "RHI contract declares IDeviceQuery.getValidationErrorCount" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getValidationErrorCount"));
}
test "RHI contract declares IDeviceQuery.getDrawCallCount" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getDrawCallCount"));
}
test "RHI contract declares IDeviceQuery.getDeviceLocalVramBytes" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getDeviceLocalVramBytes"));
}
test "RHI contract declares IDeviceQuery.getRenderResolution" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "getRenderResolution"));
}
test "RHI contract declares IDeviceQuery.waitIdle" {
    try std.testing.expect(@hasDecl(rhi.IDeviceQuery, "waitIdle"));
}
test "RHI contract declares IDeviceTiming.beginPassTiming" {
    try std.testing.expect(@hasDecl(rhi.IDeviceTiming, "beginPassTiming"));
}
test "RHI contract declares IDeviceTiming.endPassTiming" {
    try std.testing.expect(@hasDecl(rhi.IDeviceTiming, "endPassTiming"));
}
test "RHI contract declares IDeviceTiming.getTimingResults" {
    try std.testing.expect(@hasDecl(rhi.IDeviceTiming, "getTimingResults"));
}
test "RHI contract declares IDeviceTiming.isTimingEnabled" {
    try std.testing.expect(@hasDecl(rhi.IDeviceTiming, "isTimingEnabled"));
}
test "RHI contract declares IDeviceTiming.setTimingEnabled" {
    try std.testing.expect(@hasDecl(rhi.IDeviceTiming, "setTimingEnabled"));
}
test "RHI contract declares IRenderQualityOptions.setWireframe" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setWireframe"));
}
test "RHI contract declares IRenderQualityOptions.setTexturesEnabled" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setTexturesEnabled"));
}
test "RHI contract declares IRenderQualityOptions.setDebugShadowView" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setDebugShadowView"));
}
test "RHI contract declares IRenderQualityOptions.setShadowDebugChannel" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setShadowDebugChannel"));
}
test "RHI contract declares IRenderQualityOptions.setVSync" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setVSync"));
}
test "RHI contract declares IRenderQualityOptions.setAnisotropicFiltering" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setAnisotropicFiltering"));
}
test "RHI contract declares IRenderQualityOptions.setVolumetricDensity" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setVolumetricDensity"));
}
test "RHI contract declares IRenderQualityOptions.setMSAA" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setMSAA"));
}
test "RHI contract declares IRenderQualityOptions.setFXAA" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setFXAA"));
}
test "RHI contract declares IRenderQualityOptions.setBloom" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setBloom"));
}
test "RHI contract declares IRenderQualityOptions.setBloomIntensity" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setBloomIntensity"));
}
test "RHI contract declares IRenderQualityOptions.setVignetteEnabled" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setVignetteEnabled"));
}
test "RHI contract declares IRenderQualityOptions.setVignetteIntensity" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setVignetteIntensity"));
}
test "RHI contract declares IRenderQualityOptions.setFilmGrainEnabled" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setFilmGrainEnabled"));
}
test "RHI contract declares IRenderQualityOptions.setFilmGrainIntensity" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setFilmGrainIntensity"));
}
test "RHI contract declares IRenderQualityOptions.setColorGradingEnabled" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setColorGradingEnabled"));
}
test "RHI contract declares IRenderQualityOptions.setColorGradingIntensity" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setColorGradingIntensity"));
}
test "RHI contract declares IRenderQualityOptions.setTAABlendFactor" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setTAABlendFactor"));
}
test "RHI contract declares IRenderQualityOptions.setTAAVelocityRejection" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setTAAVelocityRejection"));
}
test "RHI contract declares IRenderQualityOptions.setDynamicResolution" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "setDynamicResolution"));
}
test "RHI contract declares IRenderQualityOptions.getResolutionScale" {
    try std.testing.expect(@hasDecl(rhi.IRenderQualityOptions, "getResolutionScale"));
}
test "RHI contract declares IDeviceRecovery.recover" {
    try std.testing.expect(@hasDecl(rhi.IDeviceRecovery, "recover"));
}
test "RHI contract declares ICullingSystemFactory.createCullingSystem" {
    try std.testing.expect(@hasDecl(rhi.ICullingSystemFactory, "createCullingSystem"));
}
test "RHI contract declares IScreenshotContext.captureFrame" {
    try std.testing.expect(@hasDecl(rhi.IScreenshotContext, "captureFrame"));
}
test "RHI contract declares RHI.composeVTable" {
    try std.testing.expect(@hasDecl(rhi.RHI, "composeVTable"));
}
test "RHI contract declares RHI.factory" {
    try std.testing.expect(@hasDecl(rhi.RHI, "factory"));
}
test "RHI contract declares RHI.resourceManager" {
    try std.testing.expect(@hasDecl(rhi.RHI, "resourceManager"));
}
test "RHI contract declares RHI.context" {
    try std.testing.expect(@hasDecl(rhi.RHI, "context"));
}
test "RHI contract declares RHI.renderContext" {
    try std.testing.expect(@hasDecl(rhi.RHI, "renderContext"));
}
test "RHI contract declares RHI.passOrchestration" {
    try std.testing.expect(@hasDecl(rhi.RHI, "passOrchestration"));
}
test "RHI contract declares RHI.postProcess" {
    try std.testing.expect(@hasDecl(rhi.RHI, "postProcess"));
}
test "RHI contract declares RHI.renderEffects" {
    try std.testing.expect(@hasDecl(rhi.RHI, "renderEffects"));
}
test "RHI contract declares RHI.vulkanHandles" {
    try std.testing.expect(@hasDecl(rhi.RHI, "vulkanHandles"));
}
test "RHI contract declares RHI.encoder" {
    try std.testing.expect(@hasDecl(rhi.RHI, "encoder"));
}
test "RHI contract declares RHI.state" {
    try std.testing.expect(@hasDecl(rhi.RHI, "state"));
}
test "RHI contract declares RHI.ssao" {
    try std.testing.expect(@hasDecl(rhi.RHI, "ssao"));
}
test "RHI contract declares RHI.debugOverlay" {
    try std.testing.expect(@hasDecl(rhi.RHI, "debugOverlay"));
}
test "RHI contract declares RHI.shadow" {
    try std.testing.expect(@hasDecl(rhi.RHI, "shadow"));
}
test "RHI contract declares RHI.shadowSystem" {
    try std.testing.expect(@hasDecl(rhi.RHI, "shadowSystem"));
}
test "RHI contract declares RHI.waterSystem" {
    try std.testing.expect(@hasDecl(rhi.RHI, "waterSystem"));
}
test "RHI contract declares RHI.water" {
    try std.testing.expect(@hasDecl(rhi.RHI, "water"));
}
test "RHI contract declares RHI.compute" {
    try std.testing.expect(@hasDecl(rhi.RHI, "compute"));
}
test "RHI contract declares RHI.ui" {
    try std.testing.expect(@hasDecl(rhi.RHI, "ui"));
}
test "RHI contract declares RHI.uiRenderer" {
    try std.testing.expect(@hasDecl(rhi.RHI, "uiRenderer"));
}
test "RHI contract declares RHI.query" {
    try std.testing.expect(@hasDecl(rhi.RHI, "query"));
}
test "RHI contract declares RHI.timing" {
    try std.testing.expect(@hasDecl(rhi.RHI, "timing"));
}
test "RHI contract declares RHI.options" {
    try std.testing.expect(@hasDecl(rhi.RHI, "options"));
}
test "RHI contract declares RHI.renderQualityOptions" {
    try std.testing.expect(@hasDecl(rhi.RHI, "renderQualityOptions"));
}
test "RHI contract declares RHI.recovery" {
    try std.testing.expect(@hasDecl(rhi.RHI, "recovery"));
}
test "RHI contract declares RHI.cullingFactory" {
    try std.testing.expect(@hasDecl(rhi.RHI, "cullingFactory"));
}
test "RHI contract declares RHI.screenshot" {
    try std.testing.expect(@hasDecl(rhi.RHI, "screenshot"));
}
test "RHI contract declares RHI.createCullingSystem" {
    try std.testing.expect(@hasDecl(rhi.RHI, "createCullingSystem"));
}
test "RHI contract declares RHI.init" {
    try std.testing.expect(@hasDecl(rhi.RHI, "init"));
}
test "RHI contract declares RHI.deinit" {
    try std.testing.expect(@hasDecl(rhi.RHI, "deinit"));
}
test "RHI contract declares RHI.waitIdle" {
    try std.testing.expect(@hasDecl(rhi.RHI, "waitIdle"));
}
