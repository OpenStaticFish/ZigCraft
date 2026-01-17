const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const RenderDevice = @import("render_device.zig").RenderDevice;

/// Common RHI errors that backends may return.
pub const RhiError = error{
    VulkanError,
    OutOfMemory,
    ResourceNotFound,
    InvalidState,
    GpuLost,
    SurfaceLost,
    InitializationFailed,
    ExtensionNotPresent,
    FeatureNotPresent,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    Unknown,
};

pub const BufferHandle = u32;
pub const InvalidBufferHandle: BufferHandle = 0;
pub const ShaderHandle = u32;
pub const InvalidShaderHandle: ShaderHandle = 0;
pub const TextureHandle = u32;
pub const InvalidTextureHandle: TextureHandle = 0;

pub const MAX_FRAMES_IN_FLIGHT = 2;
pub const SHADOW_CASCADE_COUNT = 3;

pub const BufferUsage = enum {
    vertex,
    index,
    uniform,
    indirect,
    storage,
};

pub const TextureFormat = enum {
    rgb,
    rgba,
    rgba_srgb,
    red,
    depth,
    rgba32f,
};

pub const FilterMode = enum {
    nearest,
    linear,
    nearest_mipmap_nearest,
    linear_mipmap_nearest,
    nearest_mipmap_linear,
    linear_mipmap_linear,
};

pub const WrapMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
    clamp_to_border,
};

pub const TextureConfig = struct {
    min_filter: FilterMode = .linear_mipmap_linear,
    mag_filter: FilterMode = .linear,
    wrap_s: WrapMode = .repeat,
    wrap_t: WrapMode = .repeat,
    generate_mipmaps: bool = true,
    is_render_target: bool = false,
};

pub const TextureAtlasHandles = struct {
    diffuse: TextureHandle,
    normal: TextureHandle,
    roughness: TextureHandle,
    displacement: TextureHandle,
    env: TextureHandle,
};

pub const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
    tile_id: f32,
    skylight: f32,
    blocklight: [3]f32,
    ao: f32,
};

pub const DrawMode = enum {
    triangles,
    lines,
    points,
};

pub const ShaderStageFlags = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _pad: u29 = 0,
};

pub const DrawIndirectCommand = extern struct {
    vertexCount: u32,
    instanceCount: u32,
    firstVertex: u32,
    firstInstance: u32,
};

pub const InstanceData = extern struct {
    view_proj: Mat4,
    model: Mat4,
    mask_radius: f32,
    padding: [3]f32,
};

pub const SkyParams = struct {
    cam_pos: Vec3,
    cam_forward: Vec3,
    cam_right: Vec3,
    cam_up: Vec3,
    aspect: f32,
    tan_half_fov: f32,
    sun_dir: Vec3,
    sky_color: Vec3,
    horizon_color: Vec3,
    sun_intensity: f32,
    moon_intensity: f32,
    time: f32,
};

pub const SkyPushConstants = extern struct {
    cam_forward: [4]f32,
    cam_right: [4]f32,
    cam_up: [4]f32,
    sun_dir: [4]f32,
    sky_color: [4]f32,
    horizon_color: [4]f32,
    params: [4]f32, // x=aspect, y=tan_half_fov, z=sun_intensity, w=moon_intensity
    time: [4]f32, // x=time, y=cam_pos.x, z=cam_pos.y, w=cam_pos.z
};

pub const CloudPushConstants = extern struct {
    view_proj: [4][4]f32,
    camera_pos: [4]f32, // xyz = camera position, w = cloud_height
    cloud_params: [4]f32, // x = coverage, y = scale, z = wind_offset_x, w = wind_offset_z
    sun_params: [4]f32, // xyz = sun_dir, w = sun_intensity
    fog_params: [4]f32, // xyz = fog_color, w = fog_density
};

pub const ShadowParams = struct {
    light_space_matrices: [SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [SHADOW_CASCADE_COUNT]f32,
    shadow_texel_sizes: [SHADOW_CASCADE_COUNT]f32,
};

pub const CloudParams = struct {
    cam_pos: Vec3 = Vec3.init(0, 0, 0),
    view_proj: Mat4 = Mat4.identity,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    sun_intensity: f32 = 1.0,
    fog_color: Vec3 = Vec3.init(0.7, 0.8, 0.9),
    fog_density: f32 = 0.0,
    cloud_height: f32 = 160.0,
    cloud_coverage: f32 = 0.5,
    cloud_scale: f32 = 1.0 / 64.0,
    wind_offset_x: f32 = 0.0,
    wind_offset_z: f32 = 0.0,
    base_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),
    pbr_enabled: bool = true,
    shadow_samples: u8 = 12,
    shadow_blend: bool = true,
    cloud_shadows: bool = true,
    pbr_quality: u8 = 2,
    volumetric_enabled: bool = true,
    volumetric_density: f32 = 0.05,
    volumetric_steps: u32 = 16,
    volumetric_scattering: f32 = 0.8,
    exposure: f32 = 0.9,
    saturation: f32 = 1.3,
    ssao_enabled: bool = true,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,
    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    pub const dark_gray = Color{ .r = 0.2, .g = 0.2, .b = 0.2 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

// --- Segregated Interfaces ---

pub const IResourceFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: BufferUsage) BufferHandle,
        uploadBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, data: []const u8) void,
        updateBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) void,
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) TextureHandle,
        destroyTexture: *const fn (ptr: *anyopaque, handle: TextureHandle) void,
        updateTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, data: []const u8) void,
        createShader: *const fn (ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle,
        destroyShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        mapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) ?*anyopaque,
        unmapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
    };

    pub fn createBuffer(self: IResourceFactory, size: usize, usage: BufferUsage) BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }
    pub fn uploadBuffer(self: IResourceFactory, handle: BufferHandle, data: []const u8) void {
        self.vtable.uploadBuffer(self.ptr, handle, data);
    }
    pub fn updateBuffer(self: IResourceFactory, handle: BufferHandle, offset: usize, data: []const u8) void {
        self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }
    pub fn destroyBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }
    pub fn createTexture(self: IResourceFactory, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) TextureHandle {
        return self.vtable.createTexture(self.ptr, width, height, format, config, data);
    }
    pub fn destroyTexture(self: IResourceFactory, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ptr, handle);
    }
    pub fn updateTexture(self: IResourceFactory, handle: TextureHandle, data: []const u8) void {
        self.vtable.updateTexture(self.ptr, handle, data);
    }
    pub fn createShader(self: IResourceFactory, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.vtable.createShader(self.ptr, vertex_src, fragment_src);
    }
    pub fn destroyShader(self: IResourceFactory, handle: ShaderHandle) void {
        self.vtable.destroyShader(self.ptr, handle);
    }
    pub fn mapBuffer(self: IResourceFactory, handle: BufferHandle) ?*anyopaque {
        return self.vtable.mapBuffer(self.ptr, handle);
    }
    pub fn unmapBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.unmapBuffer(self.ptr, handle);
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
        beginShadowPass: *const fn (ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void,
        endShadowPass: *const fn (ptr: *anyopaque) void,
        beginGPass: *const fn (ptr: *anyopaque) void,
        endGPass: *const fn (ptr: *anyopaque) void,
        computeSSAO: *const fn (ptr: *anyopaque) void,
        bindShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        bindTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, slot: u32) void,
        setModelMatrix: *const fn (ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void,
        setInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        updateGlobalUniforms: *const fn (ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: CloudParams) void,
        updateShadowUniforms: *const fn (ptr: *anyopaque, params: ShadowParams) void,
        setTextureUniforms: *const fn (ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void,
        draw: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
        drawOffset: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void,
        drawIndexed: *const fn (ptr: *anyopaque, vbo: BufferHandle, ebo: BufferHandle, count: u32) void,
        drawIndirect: *const fn (ptr: *anyopaque, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void,
        drawInstance: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, instance_index: u32) void,
        setViewport: *const fn (ptr: *anyopaque, width: u32, height: u32) void,

        // Low-level primitives for Systems
        bindBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, usage: BufferUsage) void,
        pushConstants: *const fn (ptr: *anyopaque, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void,

        setClearColor: *const fn (ptr: *anyopaque, color: Vec3) void,

        // 2D / UI primitives
        begin2DPass: *const fn (ptr: *anyopaque, screen_width: f32, screen_height: f32) void,
        end2DPass: *const fn (ptr: *anyopaque) void,
        drawRect2D: *const fn (ptr: *anyopaque, rect: Rect, color: Color) void,
        drawTexture2D: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,

        drawSky: *const fn (ptr: *anyopaque, params: SkyParams) void,
        beginCloudPass: *const fn (ptr: *anyopaque, params: CloudParams) void,
        drawDebugShadowMap: *const fn (ptr: *anyopaque, cascade_index: usize, depth_map_handle: TextureHandle) void,

        // Bind UI Pipeline (replaces beginUI/drawUIQuad internal logic)
        bindUIPipeline: *const fn (ptr: *anyopaque, textured: bool) void,
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
    pub fn bindShader(self: IRenderContext, handle: ShaderHandle) void {
        self.vtable.bindShader(self.ptr, handle);
    }
    pub fn bindTexture(self: IRenderContext, handle: TextureHandle, slot: u32) void {
        self.vtable.bindTexture(self.ptr, handle, slot);
    }
    pub fn draw(self: IRenderContext, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }
    pub fn drawOffset(self: IRenderContext, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.vtable.drawOffset(self.ptr, handle, count, mode, offset);
    }
    pub fn drawIndexed(self: IRenderContext, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.vtable.drawIndexed(self.ptr, vbo, ebo, count);
    }
    pub fn pushConstants(self: IRenderContext, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, stages, offset, size, data);
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
        query: IDeviceQuery.VTable,

        // Options
        setWireframe: *const fn (ctx: *anyopaque, enabled: bool) void,
        setTexturesEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setVSync: *const fn (ctx: *anyopaque, enabled: bool) void,
        setAnisotropicFiltering: *const fn (ctx: *anyopaque, level: u8) void,
        setVolumetricDensity: *const fn (ctx: *anyopaque, density: f32) void,
        setMSAA: *const fn (ctx: *anyopaque, samples: u8) void,
        recover: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn factory(self: RHI) IResourceFactory {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.resources };
    }
    pub fn context(self: RHI) IRenderContext {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.render };
    }
    pub fn query(self: RHI) IDeviceQuery {
        return .{ .ptr = self.ptr, .vtable = &self.vtable.query };
    }

    // Legacy wrappers (redirecting to sub-interfaces)
    pub fn createBuffer(self: RHI, size: usize, usage: BufferUsage) BufferHandle {
        return self.vtable.resources.createBuffer(self.ptr, size, usage);
    }
    pub fn updateBuffer(self: RHI, handle: BufferHandle, offset: usize, data: []const u8) void {
        self.vtable.resources.updateBuffer(self.ptr, handle, offset, data);
    }
    pub fn destroyBuffer(self: RHI, handle: BufferHandle) void {
        self.vtable.resources.destroyBuffer(self.ptr, handle);
    }

    pub fn createTexture(self: RHI, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) TextureHandle {
        return self.vtable.resources.createTexture(self.ptr, width, height, format, config, data);
    }
    pub fn destroyTexture(self: RHI, handle: TextureHandle) void {
        self.vtable.resources.destroyTexture(self.ptr, handle);
    }
    pub fn uploadBuffer(self: RHI, handle: BufferHandle, data: []const u8) void {
        self.vtable.resources.uploadBuffer(self.ptr, handle, data);
    }

    pub fn updateTexture(self: RHI, handle: TextureHandle, data: []const u8) void {
        self.vtable.resources.updateTexture(self.ptr, handle, data);
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
    pub fn draw(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.render.draw(self.ptr, handle, count, mode);
    }
    pub fn drawOffset(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.vtable.render.drawOffset(self.ptr, handle, count, mode, offset);
    }
    pub fn drawIndexed(self: RHI, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.vtable.render.drawIndexed(self.ptr, vbo, ebo, count);
    }
    pub fn bindTexture(self: RHI, handle: TextureHandle, slot: u32) void {
        self.vtable.render.bindTexture(self.ptr, handle, slot);
    }
    pub fn bindShader(self: RHI, handle: ShaderHandle) void {
        self.vtable.render.bindShader(self.ptr, handle);
    }
    pub fn setModelMatrix(self: RHI, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.vtable.render.setModelMatrix(self.ptr, model, color, mask_radius);
    }
    pub fn pushConstants(self: RHI, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.render.pushConstants(self.ptr, stages, offset, size, data);
    }
    pub fn updateGlobalUniforms(self: RHI, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: CloudParams) void {
        self.vtable.render.updateGlobalUniforms(self.ptr, view_proj, cam_pos, sun_dir, sun_color, time, fog_color, fog_density, fog_enabled, sun_intensity, ambient, use_texture, cloud_params);
    }

    pub fn bindBuffer(self: RHI, handle: BufferHandle, usage: BufferUsage) void {
        self.vtable.render.bindBuffer(self.ptr, handle, usage);
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
        self.vtable.render.begin2DPass(self.ptr, width, height);
    }
    pub fn end2DPass(self: RHI) void {
        self.vtable.render.end2DPass(self.ptr);
    }
    pub fn drawRect2D(self: RHI, rect: Rect, color: Color) void {
        self.vtable.render.drawRect2D(self.ptr, rect, color);
    }
    pub fn drawTexture2D(self: RHI, handle: TextureHandle, rect: Rect) void {
        self.vtable.render.drawTexture2D(self.ptr, handle, rect);
    }
    pub fn drawSky(self: RHI, params: SkyParams) void {
        self.vtable.render.drawSky(self.ptr, params);
    }
    pub fn beginCloudPass(self: RHI, params: CloudParams) void {
        self.vtable.render.beginCloudPass(self.ptr, params);
    }
    pub fn beginShadowPass(self: RHI, cascade: u32, matrix: Mat4) void {
        self.vtable.render.beginShadowPass(self.ptr, cascade, matrix);
    }
    pub fn endShadowPass(self: RHI) void {
        self.vtable.render.endShadowPass(self.ptr);
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
    pub fn updateShadowUniforms(self: RHI, params: ShadowParams) void {
        self.vtable.render.updateShadowUniforms(self.ptr, params);
    }
    pub fn setTextureUniforms(self: RHI, enabled: bool, handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.vtable.render.setTextureUniforms(self.ptr, enabled, handles);
    }
    pub fn setViewport(self: RHI, width: u32, height: u32) void {
        self.vtable.render.setViewport(self.ptr, width, height);
    }

    pub fn setWireframe(self: RHI, enabled: bool) void {
        self.vtable.setWireframe(self.ptr, enabled);
    }
    pub fn setTexturesEnabled(self: RHI, enabled: bool) void {
        self.vtable.setTexturesEnabled(self.ptr, enabled);
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
        self.vtable.render.bindUIPipeline(self.ptr, textured);
    }
};
