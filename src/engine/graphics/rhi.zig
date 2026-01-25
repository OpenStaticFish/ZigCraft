const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const RenderDevice = @import("render_device.zig").RenderDevice;

const rhi_types = @import("rhi_types.zig");

// Re-exports
pub const RhiError = rhi_types.RhiError;
pub const BufferHandle = rhi_types.BufferHandle;
pub const InvalidBufferHandle = rhi_types.InvalidBufferHandle;
pub const ShaderHandle = rhi_types.ShaderHandle;
pub const InvalidShaderHandle = rhi_types.InvalidShaderHandle;
pub const TextureHandle = rhi_types.TextureHandle;
pub const InvalidTextureHandle = rhi_types.InvalidTextureHandle;

pub const MAX_FRAMES_IN_FLIGHT = rhi_types.MAX_FRAMES_IN_FLIGHT;
pub const SHADOW_CASCADE_COUNT = rhi_types.SHADOW_CASCADE_COUNT;
pub const BLOOM_MIP_COUNT = 5;

pub const BufferUsage = rhi_types.BufferUsage;
pub const TextureFormat = rhi_types.TextureFormat;
pub const FilterMode = rhi_types.FilterMode;
pub const WrapMode = rhi_types.WrapMode;
pub const TextureConfig = rhi_types.TextureConfig;
pub const TextureAtlasHandles = rhi_types.TextureAtlasHandles;
pub const Vertex = rhi_types.Vertex;
pub const DrawMode = rhi_types.DrawMode;
pub const ShaderStageFlags = rhi_types.ShaderStageFlags;
pub const DrawIndirectCommand = rhi_types.DrawIndirectCommand;
pub const InstanceData = rhi_types.InstanceData;
pub const SkyParams = rhi_types.SkyParams;
pub const SkyPushConstants = rhi_types.SkyPushConstants;
pub const CloudPushConstants = rhi_types.CloudPushConstants;
pub const CloudParams = rhi_types.CloudParams;
pub const ShadowConfig = rhi_types.ShadowConfig;
pub const ShadowParams = rhi_types.ShadowParams;
pub const Color = rhi_types.Color;
pub const Rect = rhi_types.Rect;
pub const GpuTimingResults = rhi_types.GpuTimingResults;

// --- Segregated Interfaces ---

pub const IResourceFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle,
        uploadBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void,
        updateBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void,
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle,
        destroyTexture: *const fn (ptr: *anyopaque, handle: TextureHandle) void,
        updateTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, data: []const u8) RhiError!void,
        createShader: *const fn (ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle,
        destroyShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        mapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) RhiError!?*anyopaque,
        unmapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
    };

    pub fn createBuffer(self: IResourceFactory, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }
    pub fn uploadBuffer(self: IResourceFactory, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.uploadBuffer(self.ptr, handle, data);
    }
    pub fn updateBuffer(self: IResourceFactory, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }
    pub fn destroyBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }
    pub fn createTexture(self: IResourceFactory, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.createTexture(self.ptr, width, height, format, config, data);
    }
    pub fn destroyTexture(self: IResourceFactory, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ptr, handle);
    }
    pub fn updateTexture(self: IResourceFactory, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.vtable.updateTexture(self.ptr, handle, data);
    }
    pub fn createShader(self: IResourceFactory, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.vtable.createShader(self.ptr, vertex_src, fragment_src);
    }
    pub fn destroyShader(self: IResourceFactory, handle: ShaderHandle) void {
        self.vtable.destroyShader(self.ptr, handle);
    }
    pub fn mapBuffer(self: IResourceFactory, handle: BufferHandle) RhiError!?*anyopaque {
        return self.vtable.mapBuffer(self.ptr, handle);
    }
    pub fn unmapBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.unmapBuffer(self.ptr, handle);
    }
};

pub const IShadowContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPass: *const fn (ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void,
        endPass: *const fn (ptr: *anyopaque) void,
        updateUniforms: *const fn (ptr: *anyopaque, params: ShadowParams) void,
        getShadowMapHandle: *const fn (ptr: *anyopaque, cascade_index: u32) TextureHandle,
    };

    pub fn beginPass(self: IShadowContext, cascade_index: u32, light_space_matrix: Mat4) void {
        self.vtable.beginPass(self.ptr, cascade_index, light_space_matrix);
    }
    pub fn endPass(self: IShadowContext) void {
        self.vtable.endPass(self.ptr);
    }
    pub fn updateUniforms(self: IShadowContext, params: ShadowParams) void {
        self.vtable.updateUniforms(self.ptr, params);
    }
    pub fn getShadowMapHandle(self: IShadowContext, cascade_index: u32) TextureHandle {
        return self.vtable.getShadowMapHandle(self.ptr, cascade_index);
    }
};

pub const IUIContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPass: *const fn (ptr: *anyopaque, width: f32, height: f32) void,
        endPass: *const fn (ptr: *anyopaque) void,
        drawRect: *const fn (ptr: *anyopaque, rect: Rect, color: Color) void,
        drawTexture: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,
        drawDepthTexture: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,
        bindPipeline: *const fn (ptr: *anyopaque, textured: bool) void,
    };

    pub fn beginPass(self: IUIContext, width: f32, height: f32) void {
        self.vtable.beginPass(self.ptr, width, height);
    }
    pub fn endPass(self: IUIContext) void {
        self.vtable.endPass(self.ptr);
    }
    pub fn drawRect(self: IUIContext, rect: Rect, color: Color) void {
        self.vtable.drawRect(self.ptr, rect, color);
    }
    pub fn drawTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawTexture(self.ptr, texture, rect);
    }
    pub fn drawDepthTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawDepthTexture(self.ptr, texture, rect);
    }
    pub fn bindPipeline(self: IUIContext, textured: bool) void {
        self.vtable.bindPipeline(self.ptr, textured);
    }
};

pub const IGraphicsCommandEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bindShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        bindTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, slot: u32) void,
        bindBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, usage: BufferUsage) void,
        pushConstants: *const fn (ptr: *anyopaque, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void,
        draw: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
        drawOffset: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void,
        drawIndexed: *const fn (ptr: *anyopaque, vbo: BufferHandle, ebo: BufferHandle, count: u32) void,
        drawIndirect: *const fn (ptr: *anyopaque, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void,
        drawInstance: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, instance_index: u32) void,
        setViewport: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
    };

    pub fn bindShader(self: IGraphicsCommandEncoder, handle: ShaderHandle) void {
        self.vtable.bindShader(self.ptr, handle);
    }
    pub fn bindTexture(self: IGraphicsCommandEncoder, handle: TextureHandle, slot: u32) void {
        self.vtable.bindTexture(self.ptr, handle, slot);
    }
    pub fn bindBuffer(self: IGraphicsCommandEncoder, handle: BufferHandle, usage: BufferUsage) void {
        self.vtable.bindBuffer(self.ptr, handle, usage);
    }
    pub fn pushConstants(self: IGraphicsCommandEncoder, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, stages, offset, size, data);
    }
    pub fn draw(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }
    pub fn drawOffset(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.vtable.drawOffset(self.ptr, handle, count, mode, offset);
    }
    pub fn drawIndexed(self: IGraphicsCommandEncoder, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.vtable.drawIndexed(self.ptr, vbo, ebo, count);
    }
    pub fn drawIndirect(self: IGraphicsCommandEncoder, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        self.vtable.drawIndirect(self.ptr, handle, command_buffer, offset, draw_count, stride);
    }
    pub fn drawInstance(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, instance_index: u32) void {
        self.vtable.drawInstance(self.ptr, handle, count, instance_index);
    }
    pub fn setViewport(self: IGraphicsCommandEncoder, width: u32, height: u32) void {
        self.vtable.setViewport(self.ptr, width, height);
    }
};

pub const IRenderStateContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setModelMatrix: *const fn (ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void,
        setInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setSelectionMode: *const fn (ptr: *anyopaque, enabled: bool) void,
        updateGlobalUniforms: *const fn (ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: CloudParams) void,
        setTextureUniforms: *const fn (ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void,
    };

    pub fn setModelMatrix(self: IRenderStateContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.vtable.setModelMatrix(self.ptr, model, color, mask_radius);
    }
    pub fn setInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setInstanceBuffer(self.ptr, handle);
    }
    pub fn setLODInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setLODInstanceBuffer(self.ptr, handle);
    }
    pub fn setSelectionMode(self: IRenderStateContext, enabled: bool) void {
        self.vtable.setSelectionMode(self.ptr, enabled);
    }
    pub fn updateGlobalUniforms(self: IRenderStateContext, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: CloudParams) void {
        self.vtable.updateGlobalUniforms(self.ptr, view_proj, cam_pos, sun_dir, sun_color, time, fog_color, fog_density, fog_enabled, sun_intensity, ambient, use_texture, cloud_params);
    }
    pub fn setTextureUniforms(self: IRenderStateContext, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.vtable.setTextureUniforms(self.ptr, texture_enabled, shadow_map_handles);
    }
};

pub const IRenderContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn (ptr: *anyopaque) void,
        endFrame: *const fn (ptr: *anyopaque) void,
        abortFrame: *const fn (ptr: *anyopaque) void,
        beginMainPass: *const fn (ptr: *anyopaque) void,
        endMainPass: *const fn (ptr: *anyopaque) void,
        beginPostProcessPass: *const fn (ptr: *anyopaque) void,
        endPostProcessPass: *const fn (ptr: *anyopaque) void,
        beginGPass: *const fn (ptr: *anyopaque) void,
        endGPass: *const fn (ptr: *anyopaque) void,
        // FXAA Pass (Phase 3)
        beginFXAAPass: *const fn (ptr: *anyopaque) void,
        endFXAAPass: *const fn (ptr: *anyopaque) void,
        // Bloom Pass (Phase 3)
        computeBloom: *const fn (ptr: *anyopaque) void,
        getEncoder: *const fn (ptr: *anyopaque) IGraphicsCommandEncoder,
        getStateContext: *const fn (ptr: *anyopaque) IRenderStateContext,

        // High-level context state
        setClearColor: *const fn (ptr: *anyopaque, color: Vec3) void,

        // Resource Accessors for Systems
        // Note: All accessors return backend-specific handles (e.g., Vulkan handles as u64).
        // If a resource is not initialized or unavailable, the accessor returns 0.

        /// Returns the native sky pipeline handle (VkPipeline).
        getNativeSkyPipeline: *const fn (ptr: *anyopaque) u64,
        /// Returns the native sky pipeline layout handle (VkPipelineLayout).
        getNativeSkyPipelineLayout: *const fn (ptr: *anyopaque) u64,
        /// Returns the native cloud pipeline handle (VkPipeline).
        getNativeCloudPipeline: *const fn (ptr: *anyopaque) u64,
        /// Returns the native cloud pipeline layout handle (VkPipelineLayout).
        getNativeCloudPipelineLayout: *const fn (ptr: *anyopaque) u64,
        /// Returns the main native descriptor set handle (VkDescriptorSet).
        getNativeMainDescriptorSet: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO pipeline handle (VkPipeline).
        getNativeSSAOPipeline: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO pipeline layout handle (VkPipelineLayout).
        getNativeSSAOPipelineLayout: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO blur pipeline handle (VkPipeline).
        getNativeSSAOBlurPipeline: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO blur pipeline layout handle (VkPipelineLayout).
        getNativeSSAOBlurPipelineLayout: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO descriptor set handle (VkDescriptorSet).
        getNativeSSAODescriptorSet: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO blur descriptor set handle (VkDescriptorSet).
        getNativeSSAOBlurDescriptorSet: *const fn (ptr: *anyopaque) u64,
        /// Returns the native command buffer handle for the current frame (VkCommandBuffer).
        getNativeCommandBuffer: *const fn (ptr: *anyopaque) u64,
        /// Returns the current swapchain extent [width, height].
        getNativeSwapchainExtent: *const fn (ptr: *anyopaque) [2]u32,
        /// Returns the native SSAO framebuffer handle (VkFramebuffer).
        getNativeSSAOFramebuffer: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO blur framebuffer handle (VkFramebuffer).
        getNativeSSAOBlurFramebuffer: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO render pass handle (VkRenderPass).
        getNativeSSAORenderPass: *const fn (ptr: *anyopaque) u64,
        /// Returns the native SSAO blur render pass handle (VkRenderPass).
        getNativeSSAOBlurRenderPass: *const fn (ptr: *anyopaque) u64,
        /// Returns the native buffer handle for SSAO parameters (VkBuffer).
        getNativeSSAOParamsBuffer: *const fn (ptr: *anyopaque) u64,
        /// Returns the native memory handle for SSAO parameters (VkDeviceMemory).
        getNativeSSAOParamsMemory: *const fn (ptr: *anyopaque) u64,
        /// Returns the native device handle (VkDevice).
        getNativeDevice: *const fn (ptr: *anyopaque) u64,

        // Specific rendering passes/techniques
        // TODO (#189): Relocate computeSSAO to a dedicated SSAOSystem and remove from RHI.
        computeSSAO: *const fn (ptr: *anyopaque) void,
    };

    pub fn beginFrame(self: IRenderContext) void {
        self.vtable.beginFrame(self.ptr);
    }
    pub fn endFrame(self: IRenderContext) void {
        self.vtable.endFrame(self.ptr);
    }
    pub fn beginMainPass(self: IRenderContext) void {
        self.vtable.beginMainPass(self.ptr);
    }
    pub fn endMainPass(self: IRenderContext) void {
        self.vtable.endMainPass(self.ptr);
    }
    pub fn beginPostProcessPass(self: IRenderContext) void {
        self.vtable.beginPostProcessPass(self.ptr);
    }
    pub fn endPostProcessPass(self: IRenderContext) void {
        self.vtable.endPostProcessPass(self.ptr);
    }
    pub fn beginFXAAPass(self: IRenderContext) void {
        self.vtable.beginFXAAPass(self.ptr);
    }
    pub fn endFXAAPass(self: IRenderContext) void {
        self.vtable.endFXAAPass(self.ptr);
    }
    pub fn computeBloom(self: IRenderContext) void {
        self.vtable.computeBloom(self.ptr);
    }
    pub fn getEncoder(self: IRenderContext) IGraphicsCommandEncoder {
        return self.vtable.getEncoder(self.ptr);
    }
    pub fn getState(self: IRenderContext) IRenderStateContext {
        return self.vtable.getStateContext(self.ptr);
    }

    pub fn getNativeSwapchainExtent(self: IRenderContext) [2]u32 {
        return self.vtable.getNativeSwapchainExtent(self.ptr);
    }

    // Pass-throughs to encoder (convenience)
    pub fn bindShader(self: IRenderContext, handle: ShaderHandle) void {
        self.getEncoder().bindShader(handle);
    }
    pub fn bindTexture(self: IRenderContext, handle: TextureHandle, slot: u32) void {
        self.getEncoder().bindTexture(handle, slot);
    }
    pub fn draw(self: IRenderContext, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.getEncoder().draw(handle, count, mode);
    }
    pub fn drawOffset(self: IRenderContext, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.getEncoder().drawOffset(handle, count, mode, offset);
    }
    pub fn drawIndexed(self: IRenderContext, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.getEncoder().drawIndexed(vbo, ebo, count);
    }
    pub fn bindBuffer(self: IRenderContext, handle: BufferHandle, usage: BufferUsage) void {
        self.getEncoder().bindBuffer(handle, usage);
    }
    pub fn pushConstants(self: IRenderContext, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.getEncoder().pushConstants(stages, offset, size, data);
    }

    // Pass-throughs to state (convenience)
    pub fn setModelMatrix(self: IRenderContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.getState().setModelMatrix(model, color, mask_radius);
    }

    // Legacy/Techniques (to be removed once systems are updated)
    pub fn computeSSAO(self: IRenderContext) void {
        self.vtable.computeSSAO(self.ptr);
    }
};

pub const IDeviceQuery = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getFrameIndex: *const fn (ptr: *anyopaque) usize,
        supportsIndirectFirstInstance: *const fn (ptr: *anyopaque) bool,
        getMaxAnisotropy: *const fn (ptr: *anyopaque) u8,
        getMaxMSAASamples: *const fn (ptr: *anyopaque) u8,
        getFaultCount: *const fn (ptr: *anyopaque) u32,
        getValidationErrorCount: *const fn (ptr: *anyopaque) u32,
        waitIdle: *const fn (ptr: *anyopaque) void,
    };

    pub fn getFrameIndex(self: IDeviceQuery) usize {
        return self.vtable.getFrameIndex(self.ptr);
    }
    pub fn supportsIndirectFirstInstance(self: IDeviceQuery) bool {
        return self.vtable.supportsIndirectFirstInstance(self.ptr);
    }
    pub fn getFaultCount(self: IDeviceQuery) u32 {
        return self.vtable.getFaultCount(self.ptr);
    }
    pub fn getValidationErrorCount(self: IDeviceQuery) u32 {
        return self.vtable.getValidationErrorCount(self.ptr);
    }
};

pub const IDeviceTiming = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPassTiming: *const fn (ptr: *anyopaque, pass_name: []const u8) void,
        endPassTiming: *const fn (ptr: *anyopaque, pass_name: []const u8) void,
        getTimingResults: *const fn (ptr: *anyopaque) GpuTimingResults,
        isTimingEnabled: *const fn (ptr: *anyopaque) bool,
        setTimingEnabled: *const fn (ptr: *anyopaque, enabled: bool) void,
    };

    pub fn beginPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.beginPassTiming(self.ptr, pass_name);
    }
    pub fn endPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.endPassTiming(self.ptr, pass_name);
    }
    pub fn getTimingResults(self: IDeviceTiming) GpuTimingResults {
        return self.vtable.getTimingResults(self.ptr);
    }
    pub fn isTimingEnabled(self: IDeviceTiming) bool {
        return self.vtable.isTimingEnabled(self.ptr);
    }
    pub fn setTimingEnabled(self: IDeviceTiming, enabled: bool) void {
        self.vtable.setTimingEnabled(self.ptr, enabled);
    }
};

/// Composite RHI structure for backward compatibility during refactoring
pub const RHI = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    device: ?*RenderDevice,

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque, allocator: Allocator, device: ?*RenderDevice) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,

        // Composition of all vtables (temp)
        resources: IResourceFactory.VTable,
        render: IRenderContext.VTable,
        shadow: IShadowContext.VTable,
        ui: IUIContext.VTable,
        query: IDeviceQuery.VTable,
        timing: IDeviceTiming.VTable,

        // Options
        setWireframe: *const fn (ctx: *anyopaque, enabled: bool) void,
        setTexturesEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setDebugShadowView: *const fn (ctx: *anyopaque, enabled: bool) void,
        setVSync: *const fn (ctx: *anyopaque, enabled: bool) void,
        setAnisotropicFiltering: *const fn (ctx: *anyopaque, level: u8) void,
        setVolumetricDensity: *const fn (ctx: *anyopaque, density: f32) void,
        setMSAA: *const fn (ctx: *anyopaque, samples: u8) void,
        recover: *const fn (ctx: *anyopaque) anyerror!void,
        // Phase 3: FXAA and Bloom options
        setFXAA: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloom: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloomIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
    };

    pub fn factory(self: RHI) IResourceFactory {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.resources };
    }
    pub fn context(self: RHI) IRenderContext {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.render };
    }
    pub fn encoder(self: RHI) IGraphicsCommandEncoder {
        return self.context().getEncoder();
    }
    pub fn state(self: RHI) IRenderStateContext {
        return self.context().getState();
    }
    pub fn shadow(self: RHI) IShadowContext {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.shadow };
    }
    pub fn ui(self: RHI) IUIContext {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.ui };
    }
    pub fn query(self: RHI) IDeviceQuery {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.query };
    }
    pub fn timing(self: RHI) IDeviceTiming {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.timing };
    }

    // Legacy wrappers (redirecting to sub-interfaces)
    pub fn createBuffer(self: RHI, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.resources.createBuffer(self.ptr, size, usage);
    }
    pub fn updateBuffer(self: RHI, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.resources.updateBuffer(self.ptr, handle, offset, data);
    }
    pub fn destroyBuffer(self: RHI, handle: BufferHandle) void {
        self.vtable.resources.destroyBuffer(self.ptr, handle);
    }

    pub fn createTexture(self: RHI, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.resources.createTexture(self.ptr, width, height, format, config, data);
    }
    pub fn destroyTexture(self: RHI, handle: TextureHandle) void {
        self.vtable.resources.destroyTexture(self.ptr, handle);
    }
    pub fn uploadBuffer(self: RHI, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.resources.uploadBuffer(self.ptr, handle, data);
    }

    pub fn updateTexture(self: RHI, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.vtable.resources.updateTexture(self.ptr, handle, data);
    }

    pub fn createShader(self: RHI, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.vtable.resources.createShader(self.ptr, vertex_src, fragment_src);
    }
    pub fn destroyShader(self: RHI, handle: ShaderHandle) void {
        self.vtable.resources.destroyShader(self.ptr, handle);
    }

    pub fn beginFrame(self: RHI) void {
        self.vtable.render.beginFrame(self.ptr);
    }
    pub fn endFrame(self: RHI) void {
        self.vtable.render.endFrame(self.ptr);
    }
    pub fn setClearColor(self: RHI, color: Vec3) void {
        self.vtable.render.setClearColor(self.ptr, color);
    }
    pub fn beginMainPass(self: RHI) void {
        self.vtable.render.beginMainPass(self.ptr);
    }
    pub fn endMainPass(self: RHI) void {
        self.vtable.render.endMainPass(self.ptr);
    }
    pub fn beginPostProcessPass(self: RHI) void {
        self.vtable.render.beginPostProcessPass(self.ptr);
    }
    pub fn endPostProcessPass(self: RHI) void {
        self.vtable.render.endPostProcessPass(self.ptr);
    }
    pub fn draw(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.encoder().draw(handle, count, mode);
    }
    pub fn drawOffset(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.encoder().drawOffset(handle, count, mode, offset);
    }
    pub fn drawIndexed(self: RHI, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.encoder().drawIndexed(vbo, ebo, count);
    }
    pub fn bindTexture(self: RHI, handle: TextureHandle, slot: u32) void {
        self.encoder().bindTexture(handle, slot);
    }
    pub fn bindShader(self: RHI, handle: ShaderHandle) void {
        self.encoder().bindShader(handle);
    }
    pub fn setModelMatrix(self: RHI, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.state().setModelMatrix(model, color, mask_radius);
    }
    pub fn setInstanceBuffer(self: RHI, handle: BufferHandle) void {
        self.state().setInstanceBuffer(handle);
    }
    pub fn setLODInstanceBuffer(self: RHI, handle: BufferHandle) void {
        self.state().setLODInstanceBuffer(handle);
    }
    pub fn setSelectionMode(self: RHI, enabled: bool) void {
        self.state().setSelectionMode(enabled);
    }
    pub fn pushConstants(self: RHI, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.encoder().pushConstants(stages, offset, size, data);
    }
    pub fn updateGlobalUniforms(self: RHI, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: CloudParams) void {
        self.state().updateGlobalUniforms(view_proj, cam_pos, sun_dir, sun_color, time, fog_color, fog_density, fog_enabled, sun_intensity, ambient, use_texture, cloud_params);
    }

    pub fn bindBuffer(self: RHI, handle: BufferHandle, usage: BufferUsage) void {
        self.encoder().bindBuffer(handle, usage);
    }

    pub fn getFrameIndex(self: RHI) usize {
        return self.vtable.query.getFrameIndex(self.ptr);
    }
    pub fn supportsIndirectFirstInstance(self: RHI) bool {
        return self.vtable.query.supportsIndirectFirstInstance(self.ptr);
    }
    pub fn getFaultCount(self: RHI) u32 {
        return self.vtable.query.getFaultCount(self.ptr);
    }
    pub fn getValidationErrorCount(self: RHI) u32 {
        return self.vtable.query.getValidationErrorCount(self.ptr);
    }

    pub fn getShadowMapHandle(self: RHI, cascade: u32) TextureHandle {
        return self.vtable.shadow.getShadowMapHandle(self.ptr, cascade);
    }
    pub fn drawDepthTexture2D(self: RHI, handle: TextureHandle, rect: Rect) void {
        self.vtable.ui.drawDepthTexture(self.ptr, handle, rect);
    }

    // Lifecycle
    pub fn init(self: RHI, allocator: Allocator, device: ?*RenderDevice) !void {
        return self.vtable.init(self.ptr, allocator, device);
    }
    pub fn deinit(self: RHI) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn waitIdle(self: RHI) void {
        self.vtable.query.waitIdle(self.ptr);
    }

    // Pass-throughs
    pub fn begin2DPass(self: RHI, width: f32, height: f32) void {
        self.vtable.ui.beginPass(self.ptr, width, height);
    }
    pub fn end2DPass(self: RHI) void {
        self.vtable.ui.endPass(self.ptr);
    }
    pub fn drawRect2D(self: RHI, rect: Rect, color: Color) void {
        self.vtable.ui.drawRect(self.ptr, rect, color);
    }
    pub fn drawTexture2D(self: RHI, handle: TextureHandle, rect: Rect) void {
        self.vtable.ui.drawTexture(self.ptr, handle, rect);
    }
    pub fn beginShadowPass(self: RHI, cascade: u32, matrix: Mat4) void {
        self.vtable.shadow.beginPass(self.ptr, cascade, matrix);
    }
    pub fn endShadowPass(self: RHI) void {
        self.vtable.shadow.endPass(self.ptr);
    }
    pub fn beginGPass(self: RHI) void {
        self.vtable.render.beginGPass(self.ptr);
    }
    pub fn endGPass(self: RHI) void {
        self.vtable.render.endGPass(self.ptr);
    }
    pub fn computeSSAO(self: RHI) void {
        self.vtable.render.computeSSAO(self.ptr);
    }
    pub fn beginFXAAPass(self: RHI) void {
        self.vtable.render.beginFXAAPass(self.ptr);
    }
    pub fn endFXAAPass(self: RHI) void {
        self.vtable.render.endFXAAPass(self.ptr);
    }
    pub fn computeBloom(self: RHI) void {
        self.vtable.render.computeBloom(self.ptr);
    }
    pub fn updateShadowUniforms(self: RHI, params: ShadowParams) void {
        self.vtable.shadow.updateUniforms(self.ptr, params);
    }
    pub fn setTextureUniforms(self: RHI, enabled: bool, handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.vtable.render.setTextureUniforms(self.ptr, enabled, handles);
    }
    pub fn setViewport(self: RHI, width: u32, height: u32) void {
        self.encoder().setViewport(width, height);
    }

    pub fn setWireframe(self: RHI, enabled: bool) void {
        self.vtable.setWireframe(self.ptr, enabled);
    }
    pub fn setTexturesEnabled(self: RHI, enabled: bool) void {
        self.vtable.setTexturesEnabled(self.ptr, enabled);
    }
    pub fn setDebugShadowView(self: RHI, enabled: bool) void {
        self.vtable.setDebugShadowView(self.ptr, enabled);
    }
    pub fn setVSync(self: RHI, enabled: bool) void {
        self.vtable.setVSync(self.ptr, enabled);
    }
    pub fn setAnisotropicFiltering(self: RHI, level: u8) void {
        self.vtable.setAnisotropicFiltering(self.ptr, level);
    }
    pub fn setVolumetricDensity(self: RHI, density: f32) void {
        self.vtable.setVolumetricDensity(self.ptr, density);
    }
    pub fn setMSAA(self: RHI, samples: u8) void {
        self.vtable.setMSAA(self.ptr, samples);
    }
    pub fn recover(self: RHI) !void {
        return self.vtable.recover(self.ptr);
    }
    pub fn bindUIPipeline(self: RHI, textured: bool) void {
        self.vtable.ui.bindPipeline(self.ptr, textured);
    }
    // Phase 3: FXAA and Bloom controls
    pub fn setFXAA(self: RHI, enabled: bool) void {
        self.vtable.setFXAA(self.ptr, enabled);
    }
    pub fn setBloom(self: RHI, enabled: bool) void {
        self.vtable.setBloom(self.ptr, enabled);
    }
    pub fn setBloomIntensity(self: RHI, intensity: f32) void {
        self.vtable.setBloomIntensity(self.ptr, intensity);
    }
};
