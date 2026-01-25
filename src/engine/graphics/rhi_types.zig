const std = @import("std");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

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
    InvalidImageView,
    FragmentedPool,
    NoMatchingMemoryType,
    ResourceNotReady,
    SkyPipelineNotReady,
    SkyPipelineLayoutNotReady,
    CloudPipelineNotReady,
    CloudPipelineLayoutNotReady,
    CommandBufferNotReady,
    Unknown,
};

pub const BufferHandle = u32;
pub const InvalidBufferHandle: BufferHandle = 0;
pub const ShaderHandle = u32;
pub const InvalidShaderHandle: ShaderHandle = 0;
pub const TextureHandle = u32;
pub const InvalidTextureHandle: TextureHandle = 0;

pub const MAX_FRAMES_IN_FLIGHT = 2;
/// Number of cascaded shadow map splits.
/// 3 cascades provide a good balance between quality (near detail) and performance (draw calls).
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

pub const ShadowConfig = struct {
    distance: f32 = 250.0,
    resolution: u32 = 4096,
    pcf_samples: u8 = 12,
    cascade_blend: bool = true,
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
    shadow: ShadowConfig = .{},
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

pub const GpuTimingResults = struct {
    shadow_pass_ms: [SHADOW_CASCADE_COUNT]f32,
    g_pass_ms: f32,
    ssao_pass_ms: f32,
    sky_pass_ms: f32,
    opaque_pass_ms: f32,
    cloud_pass_ms: f32,
    main_pass_ms: f32, // Overall main pass time (sum of sky, opaque, clouds)
    bloom_pass_ms: f32,
    fxaa_pass_ms: f32,
    post_process_pass_ms: f32,
    total_gpu_ms: f32,

    pub fn validate(self: GpuTimingResults) void {
        const expected_main = self.sky_pass_ms + self.opaque_pass_ms + self.cloud_pass_ms;
        const epsilon = 0.01;
        if (@abs(self.main_pass_ms - expected_main) > epsilon) {
            std.debug.print("Timing Drift Warning: Main Pass {d:.3}ms != Sum {d:.3}ms (Sky {d:.3} + Opaque {d:.3} + Cloud {d:.3})\n", .{
                self.main_pass_ms,
                expected_main,
                self.sky_pass_ms,
                self.opaque_pass_ms,
                self.cloud_pass_ms,
            });
        }
    }
};
