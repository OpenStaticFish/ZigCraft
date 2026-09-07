//! Render Hardware Interface (RHI) - Abstract rendering layer for GPU operations.
//!
//! This module provides a hardware abstraction layer that decouples the engine's
//! rendering code from the underlying graphics API (currently Vulkan). The RHI
//! exposes a set of segregated interfaces, each handling a specific aspect of
//! rendering, allowing for clean separation of concerns.
//!
//! ## Architecture Overview
//!
//! The RHI is composed of several segregated interfaces (vtable-based polymorphism):
//!
//! - **IResourceFactory**: Creates and manages GPU resources (buffers, textures, shaders)
//! - **IRenderContext**: Frame lifecycle management (begin/end frame, render passes)
//! - **IGraphicsCommandEncoder**: Drawing commands (bind, draw, push constants)
//! - **IRenderStateContext**: Render state configuration (model matrices, uniforms)
//! - **IShadowContext**: Shadow map rendering passes
//! - **IUIContext**: Immediate-mode UI rendering
//! - **ISSAOContext**: Screen-space ambient occlusion computation
//!
//! ## Resource Handle Model
//!
//! GPU resources are referenced through opaque `u32` handles:
//! - `BufferHandle`: Vertex, index, uniform, and storage buffers
//! - `TextureHandle`: 2D/3D textures, depth attachments, shadow maps
//! - `ShaderHandle`: Compiled shader pipelines
//!
//! Invalid handles are represented by 0 (InvalidBufferHandle, etc.). The RHI
//! internally maps these handles to backend-specific resources.
//!
//! ## Frame Synchronization
//!
//! The engine uses double-buffering (MAX_FRAMES_IN_FLIGHT = 2) to prevent GPU/CPU
//! synchronization issues. Each frame, resources are cycled via `getFrameIndex()`.
//!
//! ## Usage
//!
//! **DEPRECATED**: Use focused wrappers instead:
//! - `ResourceManager` for resource lifecycle (`createBuffer`, `createTexture`, etc.)
//! - `RenderContext` for frame rendering (`beginFrame`, `draw`, `bindTexture`, etc.)
//! - `UIRenderer` for UI rendering (`beginPass`, `drawRect`, `drawTexture`, etc.)
//! - `ShadowSystemWrapper` for shadow mapping
//!
//! ```zig
//! const resources = rhi.resourceManager();
//! const ctx = rhi.renderContext();
//! const ui = rhi.uiRenderer();
//! ```
//!
//! ## Backend Implementation
//!
//! The Vulkan backend (`rhi_vulkan.zig`) is the only supported backend. Vulkan
//! native handles and compute objects are intentionally exposed where engine
//! subsystems integrate directly with Vulkan-shaped APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const RenderDevice = @import("render_device.zig").RenderDevice;
const culling = @import("culling.zig");

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
pub const MAX_SWAPCHAIN_IMAGES = rhi_types.MAX_SWAPCHAIN_IMAGES;
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
pub const CompactLODDraw = rhi_types.CompactLODDraw;
pub const LODDescriptorStream = rhi_types.LODDescriptorStream;
pub const CompactLODSampleWords = rhi_types.CompactLODSampleWords;
pub const SkyParams = rhi_types.SkyParams;
pub const SkyPushConstants = rhi_types.SkyPushConstants;
pub const FrameRenderParams = rhi_types.FrameRenderParams;
pub const GlobalUniforms = rhi_types.GlobalUniforms;
pub const ShadowConfig = rhi_types.ShadowConfig;
pub const ShadowParams = rhi_types.ShadowParams;
pub const Color = rhi_types.Color;
pub const Rect = rhi_types.Rect;
pub const UVRect = rhi_types.UVRect;
pub const UiVertex = rhi_types.UiVertex;
pub const UiScissor = rhi_types.UiScissor;
pub const GpuTimingResults = rhi_types.GpuTimingResults;
pub const ICullingSystem = culling.ICullingSystem;
pub const ILODCullingSystem = culling.ILODCullingSystem;

pub const RenderResolution = struct {
    width: u32,
    height: u32,
};

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
        createTexture3D: *const fn (ptr: *anyopaque, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle,
        destroyTexture: *const fn (ptr: *anyopaque, handle: TextureHandle) void,
        updateTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, data: []const u8) RhiError!void,
        createShader: *const fn (ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle,
        destroyShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        mapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) RhiError!?*anyopaque,
        unmapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
    };

    /// Allocates a backend buffer with the requested byte size and usage flags.
    /// The returned handle is owned by the caller and must later be passed to `destroyBuffer`. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createBuffer(self: IResourceFactory, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }
    /// Uploads a complete byte slice into an existing buffer handle.
    /// The handle must be live and large enough for `data`; ownership of `data` remains with the caller. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn uploadBuffer(self: IResourceFactory, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.uploadBuffer(self.ptr, handle, data);
    }
    /// Writes `data` into an existing buffer starting at `offset` bytes.
    /// `offset + data.len` must fit the allocation; the backend defines when the write becomes visible to GPU work. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn updateBuffer(self: IResourceFactory, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }
    /// Releases a buffer handle previously returned by `createBuffer`.
    /// Callers must not use the handle again after destruction; invalid or already-destroyed handles are backend errors. Must be called from the render thread that owns the backend context.
    pub fn destroyBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }
    /// Creates a 2D texture resource and optionally initializes it from CPU pixels.
    /// `data`, when provided, must match the texture dimensions, format, and configuration expected by the backend. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createTexture(self: IResourceFactory, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.createTexture(self.ptr, width, height, format, config, data);
    }
    /// Creates a 3D texture resource and optionally initializes it from CPU voxel data.
    /// `data`, when provided, must match width, height, depth, and format layout. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createTexture3D(self: IResourceFactory, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.createTexture3D(self.ptr, width, height, depth, format, config, data);
    }
    /// Releases a texture handle previously returned by a texture creation call.
    /// The texture must no longer be referenced by queued draw or compute work. Must be called from the render thread that owns the backend context.
    pub fn destroyTexture(self: IResourceFactory, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ptr, handle);
    }
    /// Replaces texture contents from a CPU byte slice.
    /// The texture handle must be live and the byte layout must match the texture format. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn updateTexture(self: IResourceFactory, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.vtable.updateTexture(self.ptr, handle, data);
    }
    /// Builds a shader program from null-terminated vertex and fragment sources.
    /// Returned shader handles are backend-owned objects and must be destroyed explicitly. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createShader(self: IResourceFactory, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.vtable.createShader(self.ptr, vertex_src, fragment_src);
    }
    /// Destroys a shader program handle.
    /// The shader must not be bound by subsequent draw calls after this returns. Must be called from the render thread that owns the backend context.
    pub fn destroyShader(self: IResourceFactory, handle: ShaderHandle) void {
        self.vtable.destroyShader(self.ptr, handle);
    }
    /// Maps a buffer for CPU access when the backend supports host-visible memory for it.
    /// Returns `null` for buffers that cannot be mapped; non-null pointers are valid until `unmapBuffer`. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn mapBuffer(self: IResourceFactory, handle: BufferHandle) RhiError!?*anyopaque {
        return self.vtable.mapBuffer(self.ptr, handle);
    }
    /// Ends CPU access to a mapped buffer.
    /// The handle must refer to a buffer previously mapped through this interface. Must be called from the render thread that owns the backend context.
    pub fn unmapBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.unmapBuffer(self.ptr, handle);
    }
};

/// Concrete wrapper around `IResourceFactory` for GPU resource lifecycle operations.
///
/// Use this when a subsystem only needs buffer/texture/shader creation and
/// destruction, without accessing the full `RHI` composite. Obtain via
/// `rhi.resourceManager()`. Reduces coupling and clarifies intent.
///
/// ```zig
/// const rm = rhi.resourceManager();
/// const buffer = try rm.createBuffer(size, .vertex);
/// defer rm.destroyBuffer(buffer);
/// ```
pub const ResourceManager = struct {
    factory: IResourceFactory,

    /// Allocates a backend buffer with the requested byte size and usage flags.
    /// The returned handle is owned by the caller and must later be passed to `destroyBuffer`. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createBuffer(self: ResourceManager, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.factory.createBuffer(size, usage);
    }
    /// Uploads a complete byte slice into an existing buffer handle.
    /// The handle must be live and large enough for `data`; ownership of `data` remains with the caller. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn uploadBuffer(self: ResourceManager, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.factory.uploadBuffer(handle, data);
    }
    /// Writes `data` into an existing buffer starting at `offset` bytes.
    /// `offset + data.len` must fit the allocation; the backend defines when the write becomes visible to GPU work. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn updateBuffer(self: ResourceManager, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.factory.updateBuffer(handle, offset, data);
    }
    /// Releases a buffer handle previously returned by `createBuffer`.
    /// Callers must not use the handle again after destruction; invalid or already-destroyed handles are backend errors. Must be called from the render thread that owns the backend context.
    pub fn destroyBuffer(self: ResourceManager, handle: BufferHandle) void {
        self.factory.destroyBuffer(handle);
    }
    /// Creates a 2D texture resource and optionally initializes it from CPU pixels.
    /// `data`, when provided, must match the texture dimensions, format, and configuration expected by the backend. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createTexture(self: ResourceManager, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.factory.createTexture(width, height, format, config, data);
    }
    /// Creates a 3D texture resource and optionally initializes it from CPU voxel data.
    /// `data`, when provided, must match width, height, depth, and format layout. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createTexture3D(self: ResourceManager, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.factory.createTexture3D(width, height, depth, format, config, data);
    }
    /// Releases a texture handle previously returned by a texture creation call.
    /// The texture must no longer be referenced by queued draw or compute work. Must be called from the render thread that owns the backend context.
    pub fn destroyTexture(self: ResourceManager, handle: TextureHandle) void {
        self.factory.destroyTexture(handle);
    }
    /// Replaces texture contents from a CPU byte slice.
    /// The texture handle must be live and the byte layout must match the texture format. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn updateTexture(self: ResourceManager, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.factory.updateTexture(handle, data);
    }
    /// Builds a shader program from null-terminated vertex and fragment sources.
    /// Returned shader handles are backend-owned objects and must be destroyed explicitly. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createShader(self: ResourceManager, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.factory.createShader(vertex_src, fragment_src);
    }
    /// Destroys a shader program handle.
    /// The shader must not be bound by subsequent draw calls after this returns. Must be called from the render thread that owns the backend context.
    pub fn destroyShader(self: ResourceManager, handle: ShaderHandle) void {
        self.factory.destroyShader(handle);
    }
    /// Maps a buffer for CPU access when the backend supports host-visible memory for it.
    /// Returns `null` for buffers that cannot be mapped; non-null pointers are valid until `unmapBuffer`. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn mapBuffer(self: ResourceManager, handle: BufferHandle) RhiError!?*anyopaque {
        return self.factory.mapBuffer(handle);
    }
    /// Ends CPU access to a mapped buffer.
    /// The handle must refer to a buffer previously mapped through this interface. Must be called from the render thread that owns the backend context.
    pub fn unmapBuffer(self: ResourceManager, handle: BufferHandle) void {
        self.factory.unmapBuffer(handle);
    }
};

/// Concrete wrapper combining `IRenderContext`, `IGraphicsCommandEncoder`, and
/// `IRenderStateContext` for frame lifecycle, draw commands, and render state.
///
/// Use this when a subsystem needs to manage render passes and issue draw calls
/// without accessing the full `RHI` composite. Obtain via `rhi.renderContext()`.
/// Reduces coupling and clarifies intent.
///
/// **Note:** The encoder is resolved at construction time via `getEncoder()`, so
/// this must be constructed per-frame (not cached across frame boundaries).
///
/// ```zig
/// const rc = rhi.renderContext();
/// rc.beginMainPass();
/// rc.draw(buffer, count, .triangles);
/// rc.endMainPass();
/// ```
pub const RenderContext = struct {
    render: IRenderContext,
    passes: IPassOrchestrationContext,
    post_process: IPostProcessContext,
    effects: IRenderEffectsContext,
    vulkan: VulkanNativeHandles,
    encoder: IGraphicsCommandEncoder,
    state: IRenderStateContext,

    // --- IRenderContext delegates ---

    /// Begins the per-frame command recording scope.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginFrame(self: RenderContext) void {
        self.render.beginFrame();
    }
    /// Ends the per-frame command recording scope and submits queued frame work.
    /// All commands for that scope must be recorded before this call.
    pub fn endFrame(self: RenderContext) void {
        self.render.endFrame();
    }
    /// Cancels the current frame after a recoverable startup or rendering failure.
    /// Use only before `endFrame`; the backend may discard recorded commands for the active frame. Must be called from the render thread that owns the backend context.
    pub fn abortFrame(self: RenderContext) void {
        self.render.abortFrame();
    }
    /// Begins the main scene render pass for opaque and sky/world drawing.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginMainPass(self: RenderContext) void {
        self.passes.beginMainPass();
    }
    /// Ends the main scene render pass and finalizes its attachments for later passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endMainPass(self: RenderContext) void {
        self.passes.endMainPass();
    }
    /// Begins the post-process pass that consumes scene color/depth outputs.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginPostProcessPass(self: RenderContext) void {
        self.passes.beginPostProcessPass();
    }
    /// Ends the post-process pass and makes its output available for presentation or later passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endPostProcessPass(self: RenderContext) void {
        self.passes.endPostProcessPass();
    }
    /// Begins the G-pass that writes geometry buffers for screen-space effects.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginGPass(self: RenderContext) void {
        self.passes.beginGPass();
    }
    /// Ends the G-pass and makes geometry buffers available to SSAO or lighting passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endGPass(self: RenderContext) void {
        self.passes.endGPass();
    }
    /// Begins the FXAA post-process pass for the current frame.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginFXAAPass(self: RenderContext) void {
        self.passes.beginFXAAPass();
    }
    /// Ends the FXAA post-process pass for the current frame.
    /// All commands for that scope must be recorded before this call.
    pub fn endFXAAPass(self: RenderContext) void {
        self.passes.endFXAAPass();
    }
    /// Runs the bloom extraction and blur compute passes for the current frame.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeBloom(self: RenderContext) void {
        self.post_process.computeBloom();
    }
    /// Runs the TAA resolve pass using the current color, history, and velocity inputs.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeTAA(self: RenderContext) void {
        self.post_process.computeTAA();
    }
    /// Builds the hierarchical depth pyramid used by culling and screen-space effects.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeDepthPyramid(self: RenderContext) void {
        self.post_process.computeDepthPyramid();
    }
    /// Draws the sky and atmosphere contribution for the current camera parameters.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation.
    pub fn drawSky(self: RenderContext, params: SkyParams) RhiError!void {
        return self.effects.drawSky(params);
    }
    /// Begins water rendering using reflection and scene-depth textures as inputs.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginWaterDraw(self: RenderContext, reflection: TextureHandle, scene_depth: TextureHandle) bool {
        return self.effects.beginWaterDraw(reflection, scene_depth);
    }
    /// Ends water rendering and restores normal scene rendering state.
    /// All commands for that scope must be recorded before this call.
    pub fn endWaterDraw(self: RenderContext) void {
        self.effects.endWaterDraw();
    }
    /// Marks the swapchain-dependent render targets for recreation.
    /// Use after window resize or presentation errors; actual recreation is backend-controlled. Must be called from the render thread that owns the backend context.
    pub fn requestSwapchainRecreate(self: RenderContext) void {
        self.render.requestSwapchainRecreate();
    }
    /// Sets clear color on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setClearColor(self: RenderContext, color: Vec3) void {
        self.render.vtable.setClearColor(self.render.ptr, color);
    }
    /// Returns native swapchain extent from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getNativeSwapchainExtent(self: RenderContext) [2]u32 {
        return self.vulkan.getSwapchainExtent();
    }
    /// Returns native device from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getNativeDevice(self: RenderContext) u64 {
        return self.vulkan.getDevice();
    }

    // --- IGraphicsCommandEncoder delegates ---

    /// Binds a texture handle to the requested shader slot.
    /// The handle must be live and compatible with the active pipeline layout. Must be called from the render thread that owns the backend context.
    pub fn bindTexture(self: RenderContext, handle: TextureHandle, slot: u32) void {
        self.encoder.bindTexture(handle, slot);
    }
    /// Binds a buffer handle for subsequent draw or dispatch commands.
    /// The handle must be live and match the binding expected by the current pipeline. Must be called from the render thread that owns the backend context.
    pub fn bindBuffer(self: RenderContext, handle: BufferHandle, usage: BufferUsage) void {
        self.encoder.bindBuffer(handle, usage);
    }
    /// Uploads a small byte payload as push constants for the active pipeline.
    /// The payload size and layout must match the shader stage declaration. Must be called from the render thread that owns the backend context.
    pub fn pushConstants(self: RenderContext, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.encoder.pushConstants(stages, offset, size, data);
    }
    /// Issues a non-indexed draw using the currently bound graphics state.
    /// A compatible pipeline and vertex buffer must already be bound. Must be called from the render thread that owns the backend context.
    pub fn draw(self: RenderContext, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.encoder.draw(handle, count, mode);
    }
    /// Issues a non-indexed draw starting at a byte or vertex offset in the bound buffer.
    /// The offset and vertex count must stay within the bound buffer allocation. Must be called from the render thread that owns the backend context.
    pub fn drawOffset(self: RenderContext, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.encoder.drawOffset(handle, count, mode, offset);
    }
    /// Issues an indexed draw using currently bound vertex and index buffers.
    /// Index data and pipeline state must be valid for the requested primitive topology. Must be called from the render thread that owns the backend context.
    pub fn drawIndexed(self: RenderContext, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.encoder.drawIndexed(vbo, ebo, count);
    }
    /// Draws a compact far-LOD grid through a storage-buffer vertex-pulling
    /// pipeline.  The index buffer is reusable and no expanded Vertex array is
    /// required for the tile.
    pub fn drawCompactLOD(self: RenderContext, index_buffer: BufferHandle, index_count: u32, params: CompactLODDraw) bool {
        return self.encoder.drawCompactLOD(index_buffer, index_count, params);
    }
    /// Draws GPU-compacted indexed compact-LOD commands. Backends may consume
    /// `count_buffer`, or submit `max_draw_count` from a guaranteed zero-filled
    /// command stream when an indirect-count driver path is unsafe.
    pub fn drawCompactLODIndirectCount(self: RenderContext, index_buffer: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32) bool {
        // The Vulkan backend currently treats count_buffer/count_offset as
        // compatibility parameters and submits a zero-filled fixed capacity.
        return self.encoder.drawCompactLODIndirectCount(index_buffer, command_buffer, offset, count_buffer, count_offset, max_draw_count);
    }
    /// Issues indirect draw commands from a GPU buffer.
    /// The indirect buffer must contain backend-compatible command records and remain valid through submission. Must be called from the render thread that owns the backend context.
    pub fn drawIndirect(self: RenderContext, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        self.encoder.drawIndirect(handle, command_buffer, offset, draw_count, stride);
    }
    /// Issues GPU-generated indirect commands. Backends may consume
    /// `count_buffer`, or use a zero-filled fixed-capacity submission bounded by
    /// `max_draw_count`. Returns false when neither safe path is supported.
    pub fn drawIndirectCount(self: RenderContext, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32, stride: u32) bool {
        // See drawCompactLODIndirectCount: the backend may intentionally use
        // fixed-capacity MDI while preserving this cross-backend ABI.
        return self.encoder.drawIndirectCount(handle, command_buffer, offset, count_buffer, count_offset, max_draw_count, stride);
    }
    /// Issues an instanced draw using currently bound per-instance state.
    /// Instance buffers and model data must be populated for the active frame. Must be called from the render thread that owns the backend context.
    pub fn drawInstance(self: RenderContext, handle: BufferHandle, count: u32, instance_index: u32) void {
        self.encoder.drawInstance(handle, count, instance_index);
    }
    /// Sets viewport on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setViewport(self: RenderContext, width: u32, height: u32) void {
        self.encoder.setViewport(width, height);
    }

    // --- IRenderStateContext delegates ---

    /// Sets model matrix on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setModelMatrix(self: RenderContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.state.setModelMatrix(model, color, mask_radius);
    }

    pub fn setLODOwnershipBounds(self: RenderContext, bounds: [4]f32) void {
        self.state.vtable.setLODOwnershipBounds(self.state.ptr, bounds);
    }
    /// Sets instance buffer on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setInstanceBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setInstanceBuffer(handle);
    }
    /// Binds the LOD instance buffer used by distant-terrain draw calls.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setLODInstanceBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setLODInstanceBuffer(handle);
    }
    /// Selects the immutable LOD descriptor stream before binding its buffers.
    pub fn setLODDescriptorStream(self: RenderContext, stream: LODDescriptorStream) void {
        self.state.setLODDescriptorStream(stream);
    }
    /// Binds the shared compact LOD sample pool for subsequent vertex-pulling draws.
    pub fn setLODCompactSampleBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setLODCompactSampleBuffer(handle);
    }
    pub fn setLODCompactInstanceBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setLODCompactInstanceBuffer(handle);
    }
    /// Sets terrain pipeline bound on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTerrainPipelineBound(self: RenderContext, bound: bool) void {
        self.state.setTerrainPipelineBound(bound);
    }
    /// Sets selection mode on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setSelectionMode(self: RenderContext, enabled: bool) void {
        self.state.setSelectionMode(enabled);
    }
    /// Updates camera, lighting, and frame-global shader uniforms.
    /// Uniform payloads are copied into backend-managed per-frame storage. Must be called from the render thread that owns the backend context.
    pub fn updateGlobalUniforms(self: RenderContext, uniforms: GlobalUniforms, frame_params: FrameRenderParams) !void {
        try self.state.updateGlobalUniforms(uniforms, frame_params);
    }
    /// Sets texture uniforms on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTextureUniforms(self: RenderContext, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.state.setTextureUniforms(texture_enabled, shadow_map_handles);
    }
};

pub const IShadowContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPass: *const fn (ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void,
        endPass: *const fn (ptr: *anyopaque) void,
        updateUniforms: *const fn (ptr: *anyopaque, params: ShadowParams) anyerror!void,
        getShadowMapHandle: *const fn (ptr: *anyopaque, cascade_index: u32) TextureHandle,
        getResolution: *const fn (ptr: *anyopaque) u32 = defaultShadowResolution,
    };

    /// Begins rendering one shadow cascade using the supplied light-space transform.
    /// Must be paired with `endPass` after all shadow casters for the cascade are drawn.
    pub fn beginPass(self: IShadowContext, cascade_index: u32, light_space_matrix: Mat4) void {
        self.vtable.beginPass(self.ptr, cascade_index, light_space_matrix);
    }
    /// Ends this subsystem render pass and finalizes its pass-local state.
    /// All commands for that scope must be recorded before this call.
    pub fn endPass(self: IShadowContext) void {
        self.vtable.endPass(self.ptr);
    }
    /// Updates subsystem uniform data for later draws in the current frame.
    /// Inputs must remain valid for the duration of the call; backend storage owns any copied data. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation.
    pub fn updateUniforms(self: IShadowContext, params: ShadowParams) !void {
        try self.vtable.updateUniforms(self.ptr, params);
    }
    /// Returns shadow map handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getShadowMapHandle(self: IShadowContext, cascade_index: u32) TextureHandle {
        return self.vtable.getShadowMapHandle(self.ptr, cascade_index);
    }
    /// Returns the physical shadow-map width allocated by the backend.
    pub fn getResolution(self: IShadowContext) u32 {
        return self.vtable.getResolution(self.ptr);
    }
};

fn defaultShadowResolution(_: *anyopaque) u32 {
    return 4096;
}

/// Concrete wrapper around `IShadowContext` for shadow mapping operations.
///
/// Use this when a subsystem only needs shadow map rendering without accessing
/// the full `RHI` composite. Obtain via `rhi.shadowSystem()`. Reduces coupling
/// and clarifies intent.
///
/// ```zig
/// const ss = rhi.shadowSystem();
/// ss.beginPass(0, light_space_matrix);
/// // ... render shadow casters ...
/// ss.endPass();
/// const handle = ss.getShadowMapHandle(0);
/// ```
pub const ShadowSystemWrapper = struct {
    ctx: IShadowContext,

    /// Begins rendering one shadow cascade through the focused shadow-system wrapper.
    /// Must be paired with `endPass`; draw shadow casters between the two calls.
    pub fn beginPass(self: ShadowSystemWrapper, cascade_index: u32, light_space_matrix: Mat4) void {
        self.ctx.beginPass(cascade_index, light_space_matrix);
    }
    /// Ends this subsystem render pass and finalizes its pass-local state.
    /// All commands for that scope must be recorded before this call.
    pub fn endPass(self: ShadowSystemWrapper) void {
        self.ctx.endPass();
    }
    /// Updates subsystem uniform data for later draws in the current frame.
    /// Inputs must remain valid for the duration of the call; backend storage owns any copied data. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation.
    pub fn updateUniforms(self: ShadowSystemWrapper, params: ShadowParams) !void {
        try self.ctx.updateUniforms(params);
    }
    /// Returns shadow map handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getShadowMapHandle(self: ShadowSystemWrapper, cascade_index: u32) TextureHandle {
        return self.ctx.getShadowMapHandle(cascade_index);
    }
    /// Returns the physical shadow-map width allocated by the backend.
    pub fn getResolution(self: ShadowSystemWrapper) u32 {
        return self.ctx.getResolution();
    }
};

pub const IWaterContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginReflectionPass: *const fn (ptr: *anyopaque) void,
        endReflectionPass: *const fn (ptr: *anyopaque) void,
        getReflectionTextureHandle: *const fn (ptr: *anyopaque) TextureHandle,
        getSceneDepthTextureHandle: *const fn (ptr: *anyopaque) TextureHandle,
        computeReflectedViewProj: *const fn (ptr: *anyopaque, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4,
    };

    /// Begins rendering the reflected scene into the water reflection target.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginReflectionPass(self: IWaterContext) void {
        self.vtable.beginReflectionPass(self.ptr);
    }
    /// Ends reflection rendering and makes the reflection texture available to water shading.
    /// All commands for that scope must be recorded before this call.
    pub fn endReflectionPass(self: IWaterContext) void {
        self.vtable.endReflectionPass(self.ptr);
    }
    /// Returns reflection texture handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getReflectionTextureHandle(self: IWaterContext) TextureHandle {
        return self.vtable.getReflectionTextureHandle(self.ptr);
    }
    /// Returns scene depth texture handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getSceneDepthTextureHandle(self: IWaterContext) TextureHandle {
        return self.vtable.getSceneDepthTextureHandle(self.ptr);
    }
    /// Computes the reflected view-projection matrix used for water reflections.
    /// The input view-projection matrix is not modified.
    pub fn computeReflectedViewProj(self: IWaterContext, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        return self.vtable.computeReflectedViewProj(self.ptr, view, proj, camera_pos);
    }
};

pub const WaterSystemWrapper = struct {
    ctx: IWaterContext,

    /// Begins rendering the reflected scene into the water reflection target.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginReflectionPass(self: WaterSystemWrapper) void {
        self.ctx.beginReflectionPass();
    }
    /// Ends reflection rendering and makes the reflection texture available to water shading.
    /// All commands for that scope must be recorded before this call.
    pub fn endReflectionPass(self: WaterSystemWrapper) void {
        self.ctx.endReflectionPass();
    }
    /// Returns reflection texture handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getReflectionTextureHandle(self: WaterSystemWrapper) TextureHandle {
        return self.ctx.getReflectionTextureHandle();
    }
    /// Returns scene depth texture handle from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getSceneDepthTextureHandle(self: WaterSystemWrapper) TextureHandle {
        return self.ctx.getSceneDepthTextureHandle();
    }
    /// Computes the reflected view-projection matrix used for water reflections.
    /// The input view-projection matrix is not modified.
    pub fn computeReflectedViewProj(self: WaterSystemWrapper, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        return self.ctx.computeReflectedViewProj(view, proj, camera_pos);
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
        drawTextureRegion: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void,
        drawDepthTexture: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,
        bindPipeline: *const fn (ptr: *anyopaque, textured: bool) void,
        drawIndexedGeometry: *const fn (ptr: *anyopaque, vertices: []const UiVertex, indices: []const u32, texture: TextureHandle, translation: [2]f32) void = unsupportedDrawIndexedGeometry,
        setScissorRegion: *const fn (ptr: *anyopaque, region: UiScissor) void = unsupportedSetScissorRegion,
    };

    fn unsupportedDrawIndexedGeometry(_: *anyopaque, _: []const UiVertex, _: []const u32, _: TextureHandle, _: [2]f32) void {}
    fn unsupportedSetScissorRegion(_: *anyopaque, _: UiScissor) void {}

    /// Begins the immediate-mode UI pass for a framebuffer of `width` by `height` pixels.
    /// UI draw calls must be issued between this call and `endPass` on the render thread.
    pub fn beginPass(self: IUIContext, width: f32, height: f32) void {
        self.vtable.beginPass(self.ptr, width, height);
    }
    /// Ends this subsystem render pass and finalizes its pass-local state.
    /// All commands for that scope must be recorded before this call.
    pub fn endPass(self: IUIContext) void {
        self.vtable.endPass(self.ptr);
    }
    /// Queues an immediate-mode rectangle draw for the active UI pass.
    /// Coordinates and colors are interpreted by the UI backend for the current frame. Must be called from the render thread that owns the backend context.
    pub fn drawRect(self: IUIContext, rect: Rect, color: Color) void {
        self.vtable.drawRect(self.ptr, rect, color);
    }
    /// Queues an immediate-mode textured rectangle draw for the active UI pass.
    /// The texture handle must be valid and accessible to the UI pipeline. Must be called from the render thread that owns the backend context.
    pub fn drawTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawTexture(self.ptr, texture, rect);
    }
    /// Queues a textured UI rectangle using a subregion of the source texture.
    /// Source and destination rectangles are consumed immediately by the active UI pass. Must be called from the render thread that owns the backend context.
    pub fn drawTextureRegion(self: IUIContext, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void {
        self.vtable.drawTextureRegion(self.ptr, texture, rect, uv, color);
    }
    /// Queues a debug draw of a depth texture through the UI pipeline.
    /// The depth texture must remain valid for the current frame. Must be called from the render thread that owns the backend context.
    pub fn drawDepthTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawDepthTexture(self.ptr, texture, rect);
    }
    /// Binds the UI pipeline variant needed by subsequent UI draw commands.
    /// Call inside an active UI pass before issuing dependent draw calls. Must be called from the render thread that owns the backend context.
    pub fn bindPipeline(self: IUIContext, textured: bool) void {
        self.vtable.bindPipeline(self.ptr, textured);
    }
    /// Draws arbitrary indexed UI geometry. A zero texture handle selects the
    /// untextured pipeline; non-zero handles are sampled and modulated by the
    /// per-vertex RGBA color. `translation` is in UI pixels.
    pub fn drawIndexedGeometry(self: IUIContext, vertices: []const UiVertex, indices: []const u32, texture: TextureHandle, translation: [2]f32) void {
        self.vtable.drawIndexedGeometry(self.ptr, vertices, indices, texture, translation);
    }
    /// Sets the dynamic pixel scissor for subsequent indexed UI geometry.
    pub fn setScissorRegion(self: IUIContext, region: UiScissor) void {
        self.vtable.setScissorRegion(self.ptr, region);
    }
};

pub const IImGuiContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        initBackend: *const fn (ptr: *anyopaque, window: *anyopaque) bool,
        shutdownBackend: *const fn (ptr: *anyopaque) void,
        newFrame: *const fn (ptr: *anyopaque) void,
        renderDrawData: *const fn (ptr: *anyopaque, draw_data: *anyopaque) void,
    };

    /// Initializes the ImGui backend bridge against the active renderer.
    /// Must run after the graphics backend exists and before rendering ImGui draw data. Must be called from the render thread that owns the backend context.
    pub fn initBackend(self: IImGuiContext, window: *anyopaque) bool {
        return self.vtable.initBackend(self.ptr, window);
    }
    /// Shuts down ImGui backend resources.
    /// No further ImGui draw-data rendering is valid until `initBackend` succeeds again. Must be called from the render thread that owns the backend context.
    pub fn shutdownBackend(self: IImGuiContext) void {
        self.vtable.shutdownBackend(self.ptr);
    }
    /// Starts a new ImGui frame for the backend bridge.
    /// Call once per frame before building ImGui widgets. Must be called from the render thread that owns the backend context.
    pub fn newFrame(self: IImGuiContext) void {
        self.vtable.newFrame(self.ptr);
    }
    /// Submits ImGui draw data to the backend for the current frame.
    /// The draw data must be produced by the active ImGui frame and used on the render thread. Must be called from the render thread that owns the backend context.
    pub fn renderDrawData(self: IImGuiContext, draw_data: *anyopaque) void {
        self.vtable.renderDrawData(self.ptr, draw_data);
    }
};

/// Focused wrapper for immediate-mode UI rendering.
///
/// Provides a clean interface for 2D drawing operations (rectangles,
/// textures, depth textures) without exposing the full RHI composite.
///
/// ```zig
/// const ui = rhi.uiRenderer();
/// ui.beginPass(width, height);
/// ui.drawRect(rect, color);
/// ui.drawTexture(tex, rect);
/// ui.endPass();
/// ```
pub const UIRenderer = struct {
    ctx: IUIContext,

    /// Begins the immediate-mode UI pass through the focused UI renderer wrapper.
    /// UI rectangles and textures queued after this call target the supplied framebuffer size.
    pub fn beginPass(self: UIRenderer, width: f32, height: f32) void {
        self.ctx.beginPass(width, height);
    }
    /// Ends this subsystem render pass and finalizes its pass-local state.
    /// All commands for that scope must be recorded before this call.
    pub fn endPass(self: UIRenderer) void {
        self.ctx.endPass();
    }
    /// Queues an immediate-mode rectangle draw for the active UI pass.
    /// Coordinates and colors are interpreted by the UI backend for the current frame. Must be called from the render thread that owns the backend context.
    pub fn drawRect(self: UIRenderer, rect: Rect, color: Color) void {
        self.ctx.drawRect(rect, color);
    }
    /// Queues an immediate-mode textured rectangle draw for the active UI pass.
    /// The texture handle must be valid and accessible to the UI pipeline. Must be called from the render thread that owns the backend context.
    pub fn drawTexture(self: UIRenderer, texture: TextureHandle, rect: Rect) void {
        self.ctx.drawTexture(texture, rect);
    }
    /// Queues a textured UI rectangle using a subregion of the source texture.
    /// Source and destination rectangles are consumed immediately by the active UI pass. Must be called from the render thread that owns the backend context.
    pub fn drawTextureRegion(self: UIRenderer, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void {
        self.ctx.drawTextureRegion(texture, rect, uv, color);
    }
    /// Queues a debug draw of a depth texture through the UI pipeline.
    /// The depth texture must remain valid for the current frame. Must be called from the render thread that owns the backend context.
    pub fn drawDepthTexture(self: UIRenderer, texture: TextureHandle, rect: Rect) void {
        self.ctx.drawDepthTexture(texture, rect);
    }
    /// Binds the UI pipeline variant needed by subsequent UI draw commands.
    /// Call inside an active UI pass before issuing dependent draw calls. Must be called from the render thread that owns the backend context.
    pub fn bindPipeline(self: UIRenderer, textured: bool) void {
        self.ctx.bindPipeline(textured);
    }
    /// Draws retained indexed geometry, including RmlUi meshes, in the active
    /// UI pass. A zero texture handle selects the untextured pipeline.
    pub fn drawIndexedGeometry(self: UIRenderer, vertices: []const UiVertex, indices: []const u32, texture: TextureHandle, translation: [2]f32) void {
        self.ctx.drawIndexedGeometry(vertices, indices, texture, translation);
    }
    /// Sets the dynamic pixel scissor for following retained UI geometry.
    pub fn setScissorRegion(self: UIRenderer, region: UiScissor) void {
        self.ctx.setScissorRegion(region);
    }
};

pub const IGraphicsCommandEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bindTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, slot: u32) void,
        bindBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, usage: BufferUsage) void,
        pushConstants: *const fn (ptr: *anyopaque, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void,
        draw: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
        drawOffset: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void,
        drawIndexed: *const fn (ptr: *anyopaque, vbo: BufferHandle, ebo: BufferHandle, count: u32) void,
        drawCompactLOD: *const fn (ptr: *anyopaque, index_buffer: BufferHandle, index_count: u32, params: CompactLODDraw) bool,
        drawCompactLODIndirectCount: *const fn (ptr: *anyopaque, index_buffer: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32) bool,
        drawIndirect: *const fn (ptr: *anyopaque, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void,
        drawIndirectCount: *const fn (ptr: *anyopaque, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32, stride: u32) bool,
        drawInstance: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, instance_index: u32) void,
        setViewport: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
    };

    /// Binds a texture handle to the requested shader slot.
    /// The handle must be live and compatible with the active pipeline layout. Must be called from the render thread that owns the backend context.
    pub fn bindTexture(self: IGraphicsCommandEncoder, handle: TextureHandle, slot: u32) void {
        self.vtable.bindTexture(self.ptr, handle, slot);
    }
    /// Binds a buffer handle for subsequent draw or dispatch commands.
    /// The handle must be live and match the binding expected by the current pipeline. Must be called from the render thread that owns the backend context.
    pub fn bindBuffer(self: IGraphicsCommandEncoder, handle: BufferHandle, usage: BufferUsage) void {
        self.vtable.bindBuffer(self.ptr, handle, usage);
    }
    /// Uploads a small byte payload as push constants for the active pipeline.
    /// The payload size and layout must match the shader stage declaration. Must be called from the render thread that owns the backend context.
    pub fn pushConstants(self: IGraphicsCommandEncoder, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, stages, offset, size, data);
    }
    /// Issues a non-indexed draw using the currently bound graphics state.
    /// A compatible pipeline and vertex buffer must already be bound. Must be called from the render thread that owns the backend context.
    pub fn draw(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }
    /// Issues a non-indexed draw starting at a byte or vertex offset in the bound buffer.
    /// The offset and vertex count must stay within the bound buffer allocation. Must be called from the render thread that owns the backend context.
    pub fn drawOffset(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.vtable.drawOffset(self.ptr, handle, count, mode, offset);
    }
    /// Issues an indexed draw using currently bound vertex and index buffers.
    /// Index data and pipeline state must be valid for the requested primitive topology. Must be called from the render thread that owns the backend context.
    pub fn drawIndexed(self: IGraphicsCommandEncoder, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.vtable.drawIndexed(self.ptr, vbo, ebo, count);
    }
    pub fn drawCompactLOD(self: IGraphicsCommandEncoder, index_buffer: BufferHandle, index_count: u32, params: CompactLODDraw) bool {
        return self.vtable.drawCompactLOD(self.ptr, index_buffer, index_count, params);
    }
    pub fn drawCompactLODIndirectCount(self: IGraphicsCommandEncoder, index_buffer: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32) bool {
        return self.vtable.drawCompactLODIndirectCount(self.ptr, index_buffer, command_buffer, offset, count_buffer, count_offset, max_draw_count);
    }
    /// Issues indirect draw commands from a GPU buffer.
    /// The indirect buffer must contain backend-compatible command records and remain valid through submission. Must be called from the render thread that owns the backend context.
    pub fn drawIndirect(self: IGraphicsCommandEncoder, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        self.vtable.drawIndirect(self.ptr, handle, command_buffer, offset, draw_count, stride);
    }
    pub fn drawIndirectCount(self: IGraphicsCommandEncoder, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, count_buffer: BufferHandle, count_offset: usize, max_draw_count: u32, stride: u32) bool {
        return self.vtable.drawIndirectCount(self.ptr, handle, command_buffer, offset, count_buffer, count_offset, max_draw_count, stride);
    }
    /// Issues an instanced draw using currently bound per-instance state.
    /// Instance buffers and model data must be populated for the active frame. Must be called from the render thread that owns the backend context.
    pub fn drawInstance(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, instance_index: u32) void {
        self.vtable.drawInstance(self.ptr, handle, count, instance_index);
    }
    /// Sets viewport on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setViewport(self: IGraphicsCommandEncoder, width: u32, height: u32) void {
        self.vtable.setViewport(self.ptr, width, height);
    }
};

pub const IRenderStateContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setModelMatrix: *const fn (ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void,
        setLODOwnershipBounds: *const fn (ptr: *anyopaque, bounds: [4]f32) void,
        setInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODDescriptorStream: *const fn (ptr: *anyopaque, stream: LODDescriptorStream) void,
        setLODCompactSampleBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODCompactInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setTerrainPipelineBound: *const fn (ptr: *anyopaque, bound: bool) void,
        setSelectionMode: *const fn (ptr: *anyopaque, enabled: bool) void,
        updateGlobalUniforms: *const fn (ptr: *anyopaque, uniforms: GlobalUniforms, frame_params: FrameRenderParams) anyerror!void,
        setTextureUniforms: *const fn (ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void,
    };

    /// Sets model matrix on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setModelMatrix(self: IRenderStateContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.vtable.setModelMatrix(self.ptr, model, color, mask_radius);
    }
    /// Sets instance buffer on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setInstanceBuffer(self.ptr, handle);
    }
    /// Binds the LOD instance buffer used by distant-terrain draw calls.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setLODInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setLODInstanceBuffer(self.ptr, handle);
    }
    /// Selects the immutable descriptor set used by subsequent LOD bindings
    /// and draws. Must be called before the stream's buffers are set.
    pub fn setLODDescriptorStream(self: IRenderStateContext, stream: LODDescriptorStream) void {
        self.vtable.setLODDescriptorStream(self.ptr, stream);
    }
    /// Selects the immutable shared compact sample pool for LOD vertex pulling.
    pub fn setLODCompactSampleBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setLODCompactSampleBuffer(self.ptr, handle);
    }
    pub fn setLODCompactInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setLODCompactInstanceBuffer(self.ptr, handle);
    }
    /// Sets terrain pipeline bound on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTerrainPipelineBound(self: IRenderStateContext, bound: bool) void {
        self.vtable.setTerrainPipelineBound(self.ptr, bound);
    }
    /// Sets selection mode on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setSelectionMode(self: IRenderStateContext, enabled: bool) void {
        self.vtable.setSelectionMode(self.ptr, enabled);
    }
    /// Updates camera, lighting, and frame-global shader uniforms.
    /// Uniform payloads are copied into backend-managed per-frame storage. Must be called from the render thread that owns the backend context.
    pub fn updateGlobalUniforms(self: IRenderStateContext, uniforms: GlobalUniforms, frame_params: FrameRenderParams) !void {
        try self.vtable.updateGlobalUniforms(self.ptr, uniforms, frame_params);
    }
    /// Sets texture uniforms on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTextureUniforms(self: IRenderStateContext, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.vtable.setTextureUniforms(self.ptr, texture_enabled, shadow_map_handles);
    }
};

pub const ISSAOContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Computes SSAO.
        compute: *const fn (ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void,
    };

    /// Returns the compute command interface.
    /// Use for backend compute buffers, pipelines, dispatches, and barriers.
    pub fn compute(self: ISSAOContext, proj: Mat4, inv_proj: Mat4) void {
        self.vtable.compute(self.ptr, proj, inv_proj);
    }
};

pub const IDebugOverlayContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Draws debug shadow map overlay.
        drawDebugShadowMap: *const fn (ptr: *anyopaque, cascade_index: usize, depth_map_handle: TextureHandle) void,
    };

    /// Draws a debug visualization of the shadow map.
    /// Call from a debug overlay pass with a valid shadow-map target. Must be called from the render thread that owns the backend context.
    pub fn drawDebugShadowMap(self: IDebugOverlayContext, cascade_index: usize, depth_map_handle: TextureHandle) void {
        self.vtable.drawDebugShadowMap(self.ptr, cascade_index, depth_map_handle);
    }
};

pub const PipelineStageFlags = u32;
pub const AccessFlags = u32;

pub const PIPELINE_STAGE_HOST_BIT: PipelineStageFlags = 0x00004000;
pub const PIPELINE_STAGE_TRANSFER_BIT: PipelineStageFlags = 0x00001000;
pub const PIPELINE_STAGE_COMPUTE_SHADER_BIT: PipelineStageFlags = 0x00000800;
pub const PIPELINE_STAGE_VERTEX_INPUT_BIT: PipelineStageFlags = 0x00000004;

pub const ACCESS_HOST_READ_BIT: AccessFlags = 0x00002000;
pub const ACCESS_TRANSFER_READ_BIT: AccessFlags = 0x00000800;
pub const ACCESS_TRANSFER_WRITE_BIT: AccessFlags = 0x00001000;
pub const ACCESS_SHADER_READ_BIT: AccessFlags = 0x00000020;
pub const ACCESS_SHADER_WRITE_BIT: AccessFlags = 0x00000040;
pub const ACCESS_VERTEX_ATTRIBUTE_READ_BIT: AccessFlags = 0x00000004;

pub const ComputeBuffer = struct {
    handle: u32 = 0,
    mapped_ptr: ?*anyopaque = null,
};

pub const ComputePipeline = struct {
    handle: u32 = 0,
};

pub const IComputeContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bindComputePipeline: *const fn (ptr: *anyopaque, pipeline: ComputePipeline) void,
        bindDescriptorSet: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, frame_index: usize) void,
        createComputeBuffer: *const fn (ptr: *anyopaque, size: usize, host_visible: bool) RhiError!ComputeBuffer,
        destroyComputeBuffer: *const fn (ptr: *anyopaque, buffer: *ComputeBuffer) void,
        createComputePipeline: *const fn (ptr: *anyopaque, allocator: Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!ComputePipeline,
        updateComputeDescriptors: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, frame_index: usize, storage_buffers: []const ComputeBufferBinding) void,
        destroyComputePipeline: *const fn (ptr: *anyopaque, pipeline: *ComputePipeline) void,
        dispatch: *const fn (ptr: *anyopaque, group_count_x: u32, group_count_y: u32, group_count_z: u32) void,
        pushConstants: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void,
        fillBuffer: *const fn (ptr: *anyopaque, buffer: ComputeBuffer, offset: u64, size: u64, data: u32) void,
        copyBuffer: *const fn (ptr: *anyopaque, src_buffer: ComputeBufferBinding, dst_buffer: ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void,
        pipelineBarrier: *const fn (ptr: *anyopaque, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags) void,
        bufferBarrier: *const fn (ptr: *anyopaque, buffer: ComputeBufferBinding, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags, offset: u64, size: u64) void,
        waitForFrameFence: *const fn (ptr: *anyopaque, frame_index: usize) bool,
        hasCommandBuffer: *const fn (ptr: *anyopaque) bool,
    };

    /// Binds a compute pipeline for following compute commands.
    /// The pipeline handle must be live and compatible with later descriptor bindings. Must be called from the render thread that owns the backend context.
    pub fn bindComputePipeline(self: IComputeContext, pipeline: ComputePipeline) void {
        self.vtable.bindComputePipeline(self.ptr, pipeline);
    }
    /// Binds a descriptor set for the active compute pipeline.
    /// The set layout must match the currently bound pipeline. Must be called from the render thread that owns the backend context.
    pub fn bindDescriptorSet(self: IComputeContext, pipeline: ComputePipeline, frame_index: usize) void {
        self.vtable.bindDescriptorSet(self.ptr, pipeline, frame_index);
    }
    /// Allocates a buffer intended for compute workloads.
    /// Usage and size must match the dispatch path that will read or write the buffer. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createComputeBuffer(self: IComputeContext, size: usize, host_visible: bool) RhiError!ComputeBuffer {
        return self.vtable.createComputeBuffer(self.ptr, size, host_visible);
    }
    /// Destroys a compute buffer handle.
    /// No queued compute work may reference the buffer after destruction. Must be called from the render thread that owns the backend context.
    pub fn destroyComputeBuffer(self: IComputeContext, buffer: *ComputeBuffer) void {
        self.vtable.destroyComputeBuffer(self.ptr, buffer);
    }
    /// Creates a compute pipeline from shader bytecode or backend shader metadata.
    /// The returned handle is owned by the caller and must be destroyed explicitly. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createComputePipeline(self: IComputeContext, allocator: Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!ComputePipeline {
        return self.vtable.createComputePipeline(self.ptr, allocator, shader_path, storage_binding_count, push_constant_size);
    }
    /// Refreshes descriptor bindings for a compute pipeline.
    /// All referenced buffers and textures must be live and layout-compatible. Must be called from the render thread that owns the backend context.
    pub fn updateComputeDescriptors(self: IComputeContext, pipeline: ComputePipeline, frame_index: usize, storage_buffers: []const ComputeBufferBinding) void {
        self.vtable.updateComputeDescriptors(self.ptr, pipeline, frame_index, storage_buffers);
    }
    /// Destroys a compute pipeline handle.
    /// The pipeline must not be bound by any later dispatch. Must be called from the render thread that owns the backend context.
    pub fn destroyComputePipeline(self: IComputeContext, pipeline: *ComputePipeline) void {
        self.vtable.destroyComputePipeline(self.ptr, pipeline);
    }
    /// Dispatches compute workgroups for the active compute pipeline.
    /// Group counts must match shader expectations and bound resource sizes. Must be called from the render thread that owns the backend context.
    pub fn dispatch(self: IComputeContext, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        self.vtable.dispatch(self.ptr, group_count_x, group_count_y, group_count_z);
    }
    /// Uploads a small byte payload as push constants for the active pipeline.
    /// The payload size and layout must match the shader stage declaration. Must be called from the render thread that owns the backend context.
    pub fn pushConstants(self: IComputeContext, pipeline: ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, pipeline, offset, size, data);
    }
    /// Records a command to fill a buffer range with a repeated value.
    /// The target range must be valid for the buffer allocation. Must be called from the render thread that owns the backend context.
    pub fn fillBuffer(self: IComputeContext, buffer: ComputeBuffer, offset: u64, size: u64, data: u32) void {
        self.vtable.fillBuffer(self.ptr, buffer, offset, size, data);
    }
    /// Records a GPU buffer-to-buffer copy.
    /// Source and destination ranges must be valid and non-overlapping unless the backend documents otherwise. Must be called from the render thread that owns the backend context.
    pub fn copyBuffer(self: IComputeContext, src_buffer: ComputeBufferBinding, dst_buffer: ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void {
        self.vtable.copyBuffer(self.ptr, src_buffer, dst_buffer, src_offset, dst_offset, size);
    }
    /// Inserts a backend synchronization barrier between pipeline stages.
    /// Use to make prior writes visible to later reads or writes. Must be called from the render thread that owns the backend context.
    pub fn pipelineBarrier(self: IComputeContext, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags) void {
        self.vtable.pipelineBarrier(self.ptr, src_stage, dst_stage, src_access, dst_access);
    }
    /// Inserts synchronization for a specific buffer resource.
    /// The buffer handle must be live and the access masks must describe the surrounding commands. Must be called from the render thread that owns the backend context.
    pub fn bufferBarrier(self: IComputeContext, buffer: ComputeBufferBinding, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags, offset: u64, size: u64) void {
        self.vtable.bufferBarrier(self.ptr, buffer, src_stage, dst_stage, src_access, dst_access, offset, size);
    }
    /// Waits for the frame fence associated with a frame index.
    /// Use only for explicit synchronization points; waiting on the render thread may stall the frame.
    pub fn waitForFrameFence(self: IComputeContext, frame_index: usize) bool {
        return self.vtable.waitForFrameFence(self.ptr, frame_index);
    }
    /// Reports whether the backend has a command buffer for a frame index.
    /// Useful for optional compute paths that must skip frames without command recording.
    pub fn hasCommandBuffer(self: IComputeContext) bool {
        return self.vtable.hasCommandBuffer(self.ptr);
    }
};

pub const ComputeBufferBinding = union(enum) {
    compute: ComputeBuffer,
    buffer: BufferHandle,
};

pub const IRenderContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn (ptr: *anyopaque) void,
        endFrame: *const fn (ptr: *anyopaque) void,
        abortFrame: *const fn (ptr: *anyopaque) void,
        requestSwapchainRecreate: *const fn (ptr: *anyopaque) void,
        getEncoder: *const fn (ptr: *anyopaque) IGraphicsCommandEncoder,
        getStateContext: *const fn (ptr: *anyopaque) IRenderStateContext,
        setClearColor: *const fn (ptr: *anyopaque, color: Vec3) void,
    };

    /// Begins the per-frame command recording scope.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginFrame(self: IRenderContext) void {
        self.vtable.beginFrame(self.ptr);
    }
    /// Ends the per-frame command recording scope and submits queued frame work.
    /// All commands for that scope must be recorded before this call.
    pub fn endFrame(self: IRenderContext) void {
        self.vtable.endFrame(self.ptr);
    }
    /// Cancels the current frame after a recoverable startup or rendering failure.
    /// Use only before `endFrame`; the backend may discard recorded commands for the active frame. Must be called from the render thread that owns the backend context.
    pub fn abortFrame(self: IRenderContext) void {
        self.vtable.abortFrame(self.ptr);
    }
    /// Marks the swapchain-dependent render targets for recreation.
    /// Use after window resize or presentation errors; actual recreation is backend-controlled. Must be called from the render thread that owns the backend context.
    pub fn requestSwapchainRecreate(self: IRenderContext) void {
        self.vtable.requestSwapchainRecreate(self.ptr);
    }
    /// Returns encoder from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getEncoder(self: IRenderContext) IGraphicsCommandEncoder {
        return self.vtable.getEncoder(self.ptr);
    }
    /// Returns state from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getState(self: IRenderContext) IRenderStateContext {
        return self.vtable.getStateContext(self.ptr);
    }
};

pub const IPassOrchestrationContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginMainPass: *const fn (ptr: *anyopaque) void,
        endMainPass: *const fn (ptr: *anyopaque) void,
        beginPostProcessPass: *const fn (ptr: *anyopaque) void,
        endPostProcessPass: *const fn (ptr: *anyopaque) void,
        beginGPass: *const fn (ptr: *anyopaque) void,
        endGPass: *const fn (ptr: *anyopaque) void,
        beginFXAAPass: *const fn (ptr: *anyopaque) void,
        endFXAAPass: *const fn (ptr: *anyopaque) void,
    };

    /// Begins the main scene render pass for opaque and sky/world drawing.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginMainPass(self: IPassOrchestrationContext) void {
        self.vtable.beginMainPass(self.ptr);
    }
    /// Ends the main scene render pass and finalizes its attachments for later passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endMainPass(self: IPassOrchestrationContext) void {
        self.vtable.endMainPass(self.ptr);
    }
    /// Begins the post-process pass that consumes scene color/depth outputs.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginPostProcessPass(self: IPassOrchestrationContext) void {
        self.vtable.beginPostProcessPass(self.ptr);
    }
    /// Ends the post-process pass and makes its output available for presentation or later passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endPostProcessPass(self: IPassOrchestrationContext) void {
        self.vtable.endPostProcessPass(self.ptr);
    }
    /// Begins the G-pass that writes geometry buffers for screen-space effects.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginGPass(self: IPassOrchestrationContext) void {
        self.vtable.beginGPass(self.ptr);
    }
    /// Ends the G-pass and makes geometry buffers available to SSAO or lighting passes.
    /// All commands for that scope must be recorded before this call.
    pub fn endGPass(self: IPassOrchestrationContext) void {
        self.vtable.endGPass(self.ptr);
    }
    /// Begins the FXAA post-process pass for the current frame.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginFXAAPass(self: IPassOrchestrationContext) void {
        self.vtable.beginFXAAPass(self.ptr);
    }
    /// Ends the FXAA post-process pass for the current frame.
    /// All commands for that scope must be recorded before this call.
    pub fn endFXAAPass(self: IPassOrchestrationContext) void {
        self.vtable.endFXAAPass(self.ptr);
    }
};

pub const IPostProcessContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        computeBloom: *const fn (ptr: *anyopaque) void,
        computeTAA: *const fn (ptr: *anyopaque) void,
        computeDepthPyramid: *const fn (ptr: *anyopaque) void,
    };

    /// Runs the bloom extraction and blur compute passes for the current frame.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeBloom(self: IPostProcessContext) void {
        self.vtable.computeBloom(self.ptr);
    }
    /// Runs the TAA resolve pass using the current color, history, and velocity inputs.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeTAA(self: IPostProcessContext) void {
        self.vtable.computeTAA(self.ptr);
    }
    /// Builds the hierarchical depth pyramid used by culling and screen-space effects.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules.
    pub fn computeDepthPyramid(self: IPostProcessContext) void {
        self.vtable.computeDepthPyramid(self.ptr);
    }
};

pub const IRenderEffectsContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        drawSky: *const fn (ptr: *anyopaque, params: SkyParams) RhiError!void,
        beginWaterDraw: *const fn (ptr: *anyopaque, reflection: TextureHandle, scene_depth: TextureHandle) bool,
        endWaterDraw: *const fn (ptr: *anyopaque) void,
    };

    /// Draws the sky and atmosphere contribution for the current camera parameters.
    /// The call delegates to backend-owned state and must obey the active backend lifetime and render-thread rules. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation.
    pub fn drawSky(self: IRenderEffectsContext, params: SkyParams) RhiError!void {
        return self.vtable.drawSky(self.ptr, params);
    }
    /// Begins water rendering using reflection and scene-depth textures as inputs.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginWaterDraw(self: IRenderEffectsContext, reflection: TextureHandle, scene_depth: TextureHandle) bool {
        return self.vtable.beginWaterDraw(self.ptr, reflection, scene_depth);
    }
    /// Ends water rendering and restores normal scene rendering state.
    /// All commands for that scope must be recorded before this call.
    pub fn endWaterDraw(self: IRenderEffectsContext) void {
        self.vtable.endWaterDraw(self.ptr);
    }
};

/// Vulkan-only native handles used by ImGui, LPV, and other integrations that
/// need concrete Vulkan objects. This intentionally is not an abstract native
/// handle interface for portable render backends.
pub const VulkanNativeHandles = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getCommandBuffer: *const fn (ptr: *anyopaque) u64,
        getSwapchainExtent: *const fn (ptr: *anyopaque) [2]u32,
        getDevice: *const fn (ptr: *anyopaque) u64,
        getInstance: *const fn (ptr: *anyopaque) u64,
        getPhysicalDevice: *const fn (ptr: *anyopaque) u64,
        getQueue: *const fn (ptr: *anyopaque) u64,
        getQueueFamily: *const fn (ptr: *anyopaque) u32,
        getDescriptorPool: *const fn (ptr: *anyopaque) u64,
        getUiRenderPass: *const fn (ptr: *anyopaque) u64,
        getSwapchainImageCount: *const fn (ptr: *anyopaque) u32,
    };

    /// Returns command buffer from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getCommandBuffer(self: VulkanNativeHandles) u64 {
        return self.vtable.getCommandBuffer(self.ptr);
    }
    /// Returns swapchain extent from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getSwapchainExtent(self: VulkanNativeHandles) [2]u32 {
        return self.vtable.getSwapchainExtent(self.ptr);
    }
    /// Returns device from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getDevice(self: VulkanNativeHandles) u64 {
        return self.vtable.getDevice(self.ptr);
    }
    /// Returns instance from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getInstance(self: VulkanNativeHandles) u64 {
        return self.vtable.getInstance(self.ptr);
    }
    /// Returns physical device from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getPhysicalDevice(self: VulkanNativeHandles) u64 {
        return self.vtable.getPhysicalDevice(self.ptr);
    }
    /// Returns queue from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getQueue(self: VulkanNativeHandles) u64 {
        return self.vtable.getQueue(self.ptr);
    }
    /// Returns queue family from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getQueueFamily(self: VulkanNativeHandles) u32 {
        return self.vtable.getQueueFamily(self.ptr);
    }
    /// Returns descriptor pool from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getDescriptorPool(self: VulkanNativeHandles) u64 {
        return self.vtable.getDescriptorPool(self.ptr);
    }
    /// Returns ui render pass from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getUiRenderPass(self: VulkanNativeHandles) u64 {
        return self.vtable.getUiRenderPass(self.ptr);
    }
    /// Returns swapchain image count from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getSwapchainImageCount(self: VulkanNativeHandles) u32 {
        return self.vtable.getSwapchainImageCount(self.ptr);
    }
};

pub const IDeviceQuery = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getFrameIndex: *const fn (ptr: *anyopaque) usize,
        supportsIndirectFirstInstance: *const fn (ptr: *anyopaque) bool,
        supportsIndirectCount: *const fn (ptr: *anyopaque) bool,
        /// The backend provides immutable descriptor snapshots for compact
        /// terrain/water GPU-culling streams.
        supportsCompactLODGpuCulling: *const fn (ptr: *anyopaque) bool,
        getMaxAnisotropy: *const fn (ptr: *anyopaque) u8,
        getMaxMSAASamples: *const fn (ptr: *anyopaque) u8,
        getFaultCount: *const fn (ptr: *anyopaque) u32,
        getValidationErrorCount: *const fn (ptr: *anyopaque) u32,
        getDrawCallCount: *const fn (ptr: *anyopaque) u32,
        getDeviceLocalVramBytes: *const fn (ptr: *anyopaque) u64,
        getRenderResolution: *const fn (ptr: *anyopaque) RenderResolution,
        waitIdle: *const fn (ptr: *anyopaque) void,
    };

    /// Returns frame index from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getFrameIndex(self: IDeviceQuery) usize {
        return self.vtable.getFrameIndex(self.ptr);
    }
    /// Reports whether indirect draw commands may use non-zero `firstInstance`.
    /// Callers must fall back to direct or rebased draws when this returns false.
    pub fn supportsIndirectFirstInstance(self: IDeviceQuery) bool {
        return self.vtable.supportsIndirectFirstInstance(self.ptr);
    }
    /// Reports whether GPU-generated indirect command counts are supported.
    pub fn supportsIndirectCount(self: IDeviceQuery) bool {
        return self.vtable.supportsIndirectCount(self.ptr);
    }
    /// Reports whether compact terrain and water can share a frame without
    /// mutating descriptors referenced by already-recorded commands.
    pub fn supportsCompactLODGpuCulling(self: IDeviceQuery) bool {
        return self.vtable.supportsCompactLODGpuCulling(self.ptr);
    }
    /// Returns fault count from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getFaultCount(self: IDeviceQuery) u32 {
        return self.vtable.getFaultCount(self.ptr);
    }
    /// Returns validation error count from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getValidationErrorCount(self: IDeviceQuery) u32 {
        return self.vtable.getValidationErrorCount(self.ptr);
    }

    /// Returns draw call count from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getDrawCallCount(self: IDeviceQuery) u32 {
        return self.vtable.getDrawCallCount(self.ptr);
    }

    /// Returns device local vram bytes from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getDeviceLocalVramBytes(self: IDeviceQuery) u64 {
        return self.vtable.getDeviceLocalVramBytes(self.ptr);
    }

    /// Returns render resolution from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getRenderResolution(self: IDeviceQuery) RenderResolution {
        return self.vtable.getRenderResolution(self.ptr);
    }
    /// Blocks until the backend device has completed queued work.
    /// Use during shutdown, resource teardown, or tests; avoid in normal frame paths.
    pub fn waitIdle(self: IDeviceQuery) void {
        self.vtable.waitIdle(self.ptr);
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

    /// Starts GPU timestamp collection for a named render pass.
    /// Must be paired with the matching end call and used from the render thread.
    pub fn beginPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.beginPassTiming(self.ptr, pass_name);
    }
    /// Stops GPU timestamp collection for a named render pass.
    /// All commands for that scope must be recorded before this call.
    pub fn endPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.endPassTiming(self.ptr, pass_name);
    }
    /// Returns timing results from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getTimingResults(self: IDeviceTiming) GpuTimingResults {
        return self.vtable.getTimingResults(self.ptr);
    }
    /// Reports whether GPU timing capture is enabled.
    /// Callers can use this to avoid timing-only work when profiling is disabled.
    pub fn isTimingEnabled(self: IDeviceTiming) bool {
        return self.vtable.isTimingEnabled(self.ptr);
    }
    /// Sets timing enabled on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTimingEnabled(self: IDeviceTiming, enabled: bool) void {
        self.vtable.setTimingEnabled(self.ptr, enabled);
    }
};

pub const IRenderQualityOptions = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setWireframe: *const fn (ctx: *anyopaque, enabled: bool) void,
        setTexturesEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setDebugShadowView: *const fn (ctx: *anyopaque, enabled: bool) void,
        setShadowDebugChannel: *const fn (ctx: *anyopaque, channel: u32) void,
        setVSync: *const fn (ctx: *anyopaque, enabled: bool) void,
        setAnisotropicFiltering: *const fn (ctx: *anyopaque, level: u8) void,
        setVolumetricDensity: *const fn (ctx: *anyopaque, density: f32) void,
        setShadowResolution: *const fn (ctx: *anyopaque, resolution: u32) void,
        setMSAA: *const fn (ctx: *anyopaque, samples: u8) void,
        setFXAA: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloom: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloomIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setVignetteEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setVignetteIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setFilmGrainEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setFilmGrainIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setColorGradingEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setColorGradingIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setTAABlendFactor: *const fn (ctx: *anyopaque, value: f32) void,
        setTAAVelocityRejection: *const fn (ctx: *anyopaque, value: f32) void,
        setDynamicResolution: *const fn (ctx: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void,
        getResolutionScale: *const fn (ctx: *anyopaque) f32,
    };

    /// Sets wireframe on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setWireframe(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setWireframe(self.ptr, enabled);
    }
    /// Sets textures enabled on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTexturesEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setTexturesEnabled(self.ptr, enabled);
    }
    /// Sets debug shadow view on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setDebugShadowView(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setDebugShadowView(self.ptr, enabled);
    }
    /// Sets shadow debug channel on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setShadowDebugChannel(self: IRenderQualityOptions, channel: u32) void {
        self.vtable.setShadowDebugChannel(self.ptr, channel);
    }
    /// Sets v sync on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setVSync(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setVSync(self.ptr, enabled);
    }
    /// Sets anisotropic filtering on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setAnisotropicFiltering(self: IRenderQualityOptions, level: u8) void {
        self.vtable.setAnisotropicFiltering(self.ptr, level);
    }
    /// Sets volumetric density on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setVolumetricDensity(self: IRenderQualityOptions, density: f32) void {
        self.vtable.setVolumetricDensity(self.ptr, density);
    }
    /// Requests shadow-map recreation at the next frame boundary.
    pub fn setShadowResolution(self: IRenderQualityOptions, resolution: u32) void {
        self.vtable.setShadowResolution(self.ptr, resolution);
    }
    /// Sets the requested MSAA sample count on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setMSAA(self: IRenderQualityOptions, samples: u8) void {
        self.vtable.setMSAA(self.ptr, samples);
    }
    /// Enables or disables FXAA on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setFXAA(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setFXAA(self.ptr, enabled);
    }
    /// Sets bloom on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setBloom(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setBloom(self.ptr, enabled);
    }
    /// Sets bloom intensity on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setBloomIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setBloomIntensity(self.ptr, intensity);
    }
    /// Sets vignette enabled on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setVignetteEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setVignetteEnabled(self.ptr, enabled);
    }
    /// Sets vignette intensity on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setVignetteIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setVignetteIntensity(self.ptr, intensity);
    }
    /// Sets film grain enabled on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setFilmGrainEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setFilmGrainEnabled(self.ptr, enabled);
    }
    /// Sets film grain intensity on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setFilmGrainIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setFilmGrainIntensity(self.ptr, intensity);
    }
    /// Sets color grading enabled on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setColorGradingEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setColorGradingEnabled(self.ptr, enabled);
    }
    /// Sets color grading intensity on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setColorGradingIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setColorGradingIntensity(self.ptr, intensity);
    }
    /// Sets the TAA history blend factor on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTAABlendFactor(self: IRenderQualityOptions, value: f32) void {
        self.vtable.setTAABlendFactor(self.ptr, value);
    }
    /// Sets the TAA velocity rejection threshold on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setTAAVelocityRejection(self: IRenderQualityOptions, value: f32) void {
        self.vtable.setTAAVelocityRejection(self.ptr, value);
    }
    /// Sets dynamic resolution on the active graphics backend.
    /// The setting affects later frames or later commands according to backend state lifetime. Must be called from the render thread that owns the backend context.
    pub fn setDynamicResolution(self: IRenderQualityOptions, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        self.vtable.setDynamicResolution(self.ptr, enabled, min_scale, max_scale, target_fps);
    }
    /// Returns resolution scale from the active graphics backend.
    /// The returned value is backend-owned or diagnostic unless the specific type documents otherwise.
    pub fn getResolutionScale(self: IRenderQualityOptions) f32 {
        return self.vtable.getResolutionScale(self.ptr);
    }
};

pub const IDeviceRecovery = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recover: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Attempts to recover the graphics backend after a recoverable failure.
    /// Returns an error if backend resources cannot be recreated safely. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn recover(self: IDeviceRecovery) !void {
        return self.vtable.recover(self.ptr);
    }
};

pub const ICullingSystemFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createCullingSystem: *const fn (ctx: *anyopaque, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem,
        createLODCullingSystem: *const fn (ctx: *anyopaque, allocator: Allocator, max_regions: usize) anyerror!?ILODCullingSystem,
    };

    /// Creates a GPU culling system bound to the active backend resources.
    /// The caller owns the returned interface and must deinitialize it through its contract. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createCullingSystem(self: ICullingSystemFactory, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem {
        return self.vtable.createCullingSystem(self.ptr, allocator, max_chunks);
    }
    pub fn createLODCullingSystem(self: ICullingSystemFactory, allocator: Allocator, max_regions: usize) anyerror!?ILODCullingSystem {
        return self.vtable.createLODCullingSystem(self.ptr, allocator, max_regions);
    }
};

pub const IScreenshotContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        captureFrame: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    /// Requests a capture of the final composed framebuffer, including UI, to
    /// the requested path. Must be called after UI rendering and before
    /// `endFrame`; encoding completes as part of frame submission.
    pub fn captureFrame(self: IScreenshotContext, path: []const u8) bool {
        return self.vtable.captureFrame(self.ptr, path);
    }
};

/// DEPRECATED: This struct is retained as a composition root during the RHI
/// modularization refactoring (issue #291 / #272). New code should use focused
/// wrappers: `ResourceManager`, `RenderContext`, `UIRenderer`, `ShadowSystemWrapper`.
///
/// Migration guide:
/// - Resource operations -> `rhi.resourceManager()`
/// - Frame rendering -> `rhi.renderContext()`
/// - UI rendering -> `rhi.uiRenderer()`
/// - Shadow mapping -> `rhi.shadowSystem()`
/// - Device timing -> `rhi.timing()`
/// - Device query -> `rhi.query()`
pub const RHI = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    device: ?*RenderDevice,

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque, allocator: Allocator, device: ?*RenderDevice) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,

        resources: ?*const IResourceFactory.VTable = null,
        render: ?*const IRenderContext.VTable = null,
        passes: ?*const IPassOrchestrationContext.VTable = null,
        post_process: ?*const IPostProcessContext.VTable = null,
        effects: ?*const IRenderEffectsContext.VTable = null,
        vulkan: ?*const VulkanNativeHandles.VTable = null,
        ssao: ?*const ISSAOContext.VTable = null,
        debug_overlay: ?*const IDebugOverlayContext.VTable = null,
        shadow: ?*const IShadowContext.VTable = null,
        water: ?*const IWaterContext.VTable = null,
        compute: ?*const IComputeContext.VTable = null,
        ui: ?*const IUIContext.VTable = null,
        imgui: ?*const IImGuiContext.VTable = null,
        query: ?*const IDeviceQuery.VTable = null,
        timing: ?*const IDeviceTiming.VTable = null,
        quality: ?*const IRenderQualityOptions.VTable = null,
        recovery: ?*const IDeviceRecovery.VTable = null,
        culling_factory: ?*const ICullingSystemFactory.VTable = null,
        screenshot: ?*const IScreenshotContext.VTable = null,
    };

    pub const Lifecycle = struct {
        init: *const fn (ctx: *anyopaque, allocator: Allocator, device: ?*RenderDevice) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub const Interfaces = struct {
        resources: ?*const IResourceFactory.VTable = null,
        render: ?*const IRenderContext.VTable = null,
        passes: ?*const IPassOrchestrationContext.VTable = null,
        post_process: ?*const IPostProcessContext.VTable = null,
        effects: ?*const IRenderEffectsContext.VTable = null,
        vulkan: ?*const VulkanNativeHandles.VTable = null,
        ssao: ?*const ISSAOContext.VTable = null,
        debug_overlay: ?*const IDebugOverlayContext.VTable = null,
        shadow: ?*const IShadowContext.VTable = null,
        water: ?*const IWaterContext.VTable = null,
        compute: ?*const IComputeContext.VTable = null,
        ui: ?*const IUIContext.VTable = null,
        imgui: ?*const IImGuiContext.VTable = null,
        query: ?*const IDeviceQuery.VTable = null,
        timing: ?*const IDeviceTiming.VTable = null,
        quality: ?*const IRenderQualityOptions.VTable = null,
        recovery: ?*const IDeviceRecovery.VTable = null,
        culling_factory: ?*const ICullingSystemFactory.VTable = null,
        screenshot: ?*const IScreenshotContext.VTable = null,
    };

    /// Builds the composite RHI vtable from subsystem interfaces.
    /// Used during RHI construction; all subsystem pointers must outlive the composed `RHI`.
    pub fn composeVTable(lifecycle: Lifecycle, interfaces: Interfaces) VTable {
        return .{
            .init = lifecycle.init,
            .deinit = lifecycle.deinit,
            .resources = interfaces.resources,
            .render = interfaces.render,
            .passes = interfaces.passes,
            .post_process = interfaces.post_process,
            .effects = interfaces.effects,
            .vulkan = interfaces.vulkan,
            .ssao = interfaces.ssao,
            .debug_overlay = interfaces.debug_overlay,
            .shadow = interfaces.shadow,
            .water = interfaces.water,
            .compute = interfaces.compute,
            .ui = interfaces.ui,
            .imgui = interfaces.imgui,
            .query = interfaces.query,
            .timing = interfaces.timing,
            .quality = interfaces.quality,
            .recovery = interfaces.recovery,
            .culling_factory = interfaces.culling_factory,
            .screenshot = interfaces.screenshot,
        };
    }

    /// Returns the resource factory interface for direct buffer, texture, and shader lifecycle operations.
    /// The returned interface borrows the RHI backend and must not outlive it.
    pub fn factory(self: RHI) IResourceFactory {
        return .{ .ptr = self.ptr, .vtable = self.vtable.resources orelse unreachable };
    }
    /// Returns the convenience resource manager wrapper.
    /// Use when a subsystem needs resource lifecycle operations without the full RHI surface.
    pub fn resourceManager(self: RHI) ResourceManager {
        return .{ .factory = self.factory() };
    }
    /// Returns the legacy render-context wrapper for frame and draw operations.
    /// Prefer narrower interfaces for new subsystem code when possible.
    pub fn context(self: RHI) IRenderContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.render orelse unreachable };
    }
    /// Returns the frame-local render context wrapper.
    /// Construct per frame because encoder and pass state are tied to current backend state.
    pub fn renderContext(self: RHI) RenderContext {
        const rc = self.context();
        return .{
            .render = rc,
            .passes = self.passOrchestration(),
            .post_process = self.postProcess(),
            .effects = self.renderEffects(),
            .vulkan = self.vulkanHandles(),
            .encoder = rc.getEncoder(),
            .state = rc.getState(),
        };
    }
    /// Returns the pass orchestration interface.
    /// Use to begin and end high-level render passes in backend-defined order.
    pub fn passOrchestration(self: RHI) IPassOrchestrationContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.passes orelse unreachable };
    }
    /// Returns the post-processing interface.
    /// Use for bloom, TAA, and depth-pyramid compute passes.
    pub fn postProcess(self: RHI) IPostProcessContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.post_process orelse unreachable };
    }
    /// Returns the render-effects interface.
    /// Use for sky, water, and other effect-specific draw orchestration.
    pub fn renderEffects(self: RHI) IRenderEffectsContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.effects orelse unreachable };
    }
    /// Returns the Vulkan native-handle facet used by ImGui, LPV, and other
    /// Vulkan-shaped integrations. This is a documented backend seam, not a
    /// portability guarantee for non-Vulkan renderers.
    pub fn vulkanHandles(self: RHI) VulkanNativeHandles {
        return .{ .ptr = self.ptr, .vtable = self.vtable.vulkan orelse unreachable };
    }
    /// Returns the graphics command encoder interface.
    /// The encoder is frame-scoped and follows render-thread ownership.
    pub fn encoder(self: RHI) IGraphicsCommandEncoder {
        return self.context().getEncoder();
    }
    /// Returns the render state interface.
    /// Use to update uniforms, bind instance buffers, and configure draw state.
    pub fn state(self: RHI) IRenderStateContext {
        return self.context().getState();
    }
    /// Returns the SSAO subsystem interface.
    /// The subsystem remains owned by the RHI backend.
    pub fn ssao(self: RHI) ISSAOContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.ssao orelse unreachable };
    }
    /// Returns the debug-overlay rendering interface.
    /// Use only for diagnostic visualizations.
    pub fn debugOverlay(self: RHI) IDebugOverlayContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.debug_overlay orelse unreachable };
    }
    /// Returns the shadow-scene pass interface.
    /// Use for shadow-map pass control and uniforms.
    pub fn shadow(self: RHI) IShadowContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.shadow orelse unreachable };
    }
    /// Returns the shadow system interface.
    /// Use for shadow resources and debug inspection.
    pub fn shadowSystem(self: RHI) ShadowSystemWrapper {
        return .{ .ctx = self.shadow() };
    }
    /// Returns the water reflection system interface.
    /// Use for reflection pass control and water render targets.
    pub fn waterSystem(self: RHI) WaterSystemWrapper {
        return .{ .ctx = self.water() };
    }
    /// Returns the water convenience wrapper.
    /// This borrows the RHI backend and must not outlive it.
    pub fn water(self: RHI) IWaterContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.water orelse unreachable };
    }
    /// Returns the compute command interface.
    /// Use for backend compute buffers, pipelines, dispatches, and barriers.
    pub fn compute(self: RHI) IComputeContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.compute orelse unreachable };
    }
    /// Returns the immediate-mode UI rendering interface.
    /// Use inside UI pass setup for rectangles and textures.
    pub fn ui(self: RHI) IUIContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.ui orelse unreachable };
    }
    /// Returns the Dear ImGui backend interface.
    /// Use when the optional ImGui integration is enabled.
    pub fn imgui(self: RHI) IImGuiContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.imgui orelse unreachable };
    }
    /// Returns the convenience UI renderer wrapper.
    /// This narrows callers to UI drawing operations.
    pub fn uiRenderer(self: RHI) UIRenderer {
        return .{ .ctx = self.ui() };
    }
    /// Returns backend query and diagnostic counters.
    /// Use for frame index, indirect support, validation, and memory telemetry.
    pub fn query(self: RHI) IDeviceQuery {
        return .{ .ptr = self.ptr, .vtable = self.vtable.query orelse unreachable };
    }
    /// Returns the GPU timing interface.
    /// Use for optional pass timing capture and result retrieval.
    pub fn timing(self: RHI) IDeviceTiming {
        return .{ .ptr = self.ptr, .vtable = self.vtable.timing orelse unreachable };
    }
    /// Returns the render-quality option interface.
    /// Use to mutate graphics settings exposed by the backend.
    pub fn options(self: RHI) IRenderQualityOptions {
        return self.renderQualityOptions();
    }
    /// Returns the convenience render-quality wrapper.
    /// This narrows callers to quality option mutation and queries.
    pub fn renderQualityOptions(self: RHI) IRenderQualityOptions {
        return .{ .ptr = self.ptr, .vtable = self.vtable.quality orelse unreachable };
    }
    /// Returns the backend recovery interface.
    /// Use only around recoverable device or swapchain failures.
    pub fn recovery(self: RHI) IDeviceRecovery {
        return .{ .ptr = self.ptr, .vtable = self.vtable.recovery orelse unreachable };
    }
    /// Returns the GPU culling factory interface.
    /// Use to construct culling systems backed by the active RHI.
    pub fn cullingFactory(self: RHI) ICullingSystemFactory {
        return .{ .ptr = self.ptr, .vtable = self.vtable.culling_factory orelse unreachable };
    }
    /// Returns the screenshot capture interface.
    /// Use for test and diagnostic frame capture.
    pub fn screenshot(self: RHI) IScreenshotContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.screenshot orelse unreachable };
    }
    /// Creates a GPU culling system bound to the active backend resources.
    /// The caller owns the returned interface and must deinitialize it through its contract. Propagates `RhiError` when the backend cannot allocate, stage, or encode the requested operation. Must be called from the render thread that owns the backend context.
    pub fn createCullingSystem(self: RHI, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem {
        return self.cullingFactory().createCullingSystem(allocator, max_chunks);
    }
    /// Creates the dedicated LOD compute/MDI compaction system.
    pub fn createLODCullingSystem(self: RHI, allocator: Allocator, max_regions: usize) anyerror!?ILODCullingSystem {
        return self.cullingFactory().createLODCullingSystem(allocator, max_regions);
    }

    // Lifecycle
    /// Constructs an `RHI` composite from a backend pointer and vtable.
    /// The backend pointer and vtable must remain valid until `deinit`.
    pub fn init(self: RHI, allocator: Allocator, device: ?*RenderDevice) !void {
        return self.vtable.init(self.ptr, allocator, device);
    }
    /// Destroys the RHI backend and releases owned graphics resources.
    /// No borrowed subsystem interfaces may be used after this returns. Must be called from the render thread that owns the backend context.
    pub fn deinit(self: RHI) void {
        self.vtable.deinit(self.ptr);
    }
    /// Blocks until the backend device has completed queued work.
    /// Use during shutdown, resource teardown, or tests; avoid in normal frame paths.
    pub fn waitIdle(self: RHI) void {
        (self.vtable.query orelse unreachable).waitIdle(self.ptr);
    }
};
