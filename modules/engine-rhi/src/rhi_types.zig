const std = @import("std");
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;

/// Common RHI errors that backends may return.
pub const RhiError = error{
    BackendError,
    OutOfMemory,
    ResourceNotFound,
    InvalidState,
    GpuLost,
    SurfaceLost,
    InitializationFailed,
    ExtensionNotPresent,
    FeatureNotPresent,
    ShaderCreationNotSupported,
    TooManyObjects,
    FormatNotSupported,
    InvalidImageView,
    FragmentedPool,
    NoMatchingMemoryType,
    ResourceNotReady,
    SkyPipelineNotReady,
    SkyPipelineLayoutNotReady,
    CommandBufferNotReady,
    PendingCopyOverflow,
    Unknown,
};

pub const BufferHandle = u32;
pub const InvalidBufferHandle: BufferHandle = 0;
pub const ShaderHandle = u32;
pub const InvalidShaderHandle: ShaderHandle = 0;
pub const TextureHandle = u32;
pub const InvalidTextureHandle: TextureHandle = 0;

pub const MAX_FRAMES_IN_FLIGHT = 2;
pub const MAX_SWAPCHAIN_IMAGES = 8;
/// Number of cascaded shadow map splits.
/// 4 cascades provide smoother transitions for large shadow distances (1000+) while maintaining quality.
pub const SHADOW_CASCADE_COUNT = 4;

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

/// Vertex format used by retained UI geometry such as RmlUi meshes.
///
/// `color` is stored in RGBA byte order so it maps directly to an
/// `R8G8B8A8_UNORM` vertex attribute on graphics backends.
pub const UiVertex = extern struct {
    position: [2]f32,
    color: [4]u8,
    uv: [2]f32,
};

/// Pixel-aligned clipping rectangle for retained UI geometry.
pub const UiScissor = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Vertex = extern struct {
    pos: [3]f32,
    color: u32,
    normal: u32,
    uv: [2]f16,
    packed_meta: u32,
    blocklight: u32,

    pub const LOD_TILE_ID: u16 = 0xFFFF;

    pub fn init(
        pos: [3]f32,
        color: [3]f32,
        normal: [3]f32,
        uv: [2]f32,
        tile_id: u16,
        skylight: f32,
        blocklight: [3]f32,
        ao: f32,
    ) Vertex {
        return .{
            .pos = pos,
            .color = encodeColor(color),
            .normal = encodeNormal(normal),
            .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
            .packed_meta = encodeMeta(tile_id, skylight, ao),
            .blocklight = encodeBlocklight(blocklight, false),
        };
    }

    pub fn initCloud(
        pos: [3]f32,
        color: [3]f32,
        normal: [3]f32,
        uv: [2]f32,
        tile_id: u16,
        skylight: f32,
        blocklight: [3]f32,
        ao: f32,
    ) Vertex {
        return .{
            .pos = pos,
            .color = encodeColor(color),
            .normal = encodeNormal(normal),
            .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
            .packed_meta = encodeMeta(tile_id, skylight, ao),
            .blocklight = encodeBlocklight(blocklight, true),
        };
    }

    pub fn initLOD(
        pos: [3]f32,
        color: [3]f32,
        normal: [3]f32,
        uv: [2]f32,
    ) Vertex {
        return .{
            .pos = pos,
            .color = encodeColor(color),
            .normal = encodeNormal(normal),
            .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
            .packed_meta = encodeMeta(LOD_TILE_ID, 1.0, 1.0),
            .blocklight = encodeBlocklight(.{ 0.0, 0.0, 0.0 }, false),
        };
    }
};

/// Encode RGB float color to RGBA8. Alpha is always 255.
/// Precision: 1/255 per channel (~0.4% steps). Banding may be visible on smooth gradients.
pub fn encodeColor(c: [3]f32) u32 {
    const r: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, c[0])) * 255.0));
    const g: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, c[1])) * 255.0));
    const b: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, c[2])) * 255.0));
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, @as(u8, 255)) << 24);
}

/// Encode a unit normal via octahedral mapping to 2×i16 packed in a u32.
/// Precision: ~0.1° angular error for axis-aligned normals, up to ~0.3° for diagonals.
/// Zero-length normals encode as 0 (decode as up).
pub fn encodeNormal(n: [3]f32) u32 {
    const l1 = @abs(n[0]) + @abs(n[1]) + @abs(n[2]);
    if (l1 < 0.0001) return 0;

    var px = n[0] / l1;
    var py = n[1] / l1;

    if (n[2] < 0.0) {
        const orig_px = px;
        const sign_x: f32 = if (px >= 0.0) 1.0 else -1.0;
        const sign_y: f32 = if (py >= 0.0) 1.0 else -1.0;
        px = (1.0 - @abs(py)) * sign_x;
        py = (1.0 - @abs(orig_px)) * sign_y;
    }

    const sx: i16 = @intFromFloat(@round(@max(-1.0, @min(1.0, px)) * 32767.0));
    const sy: i16 = @intFromFloat(@round(@max(-1.0, @min(1.0, py)) * 32767.0));
    const ux: u16 = @bitCast(sx);
    const uy: u16 = @bitCast(sy);
    return @as(u32, ux) | (@as(u32, uy) << 16);
}

/// Pack tile_id (u16), skylight (u8), and AO (u8) into a single u32.
/// Skylight and AO precision: 1/255 (~0.4% steps). Tile IDs 0-65534 valid; 0xFFFF is LOD sentinel.
pub fn encodeMeta(tile_id: u16, skylight: f32, ao: f32) u32 {
    const sl: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, skylight)) * 255.0));
    const ao_u8: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, ao)) * 255.0));
    return @as(u32, tile_id) | (@as(u32, sl) << 16) | (@as(u32, ao_u8) << 24);
}

/// Encode RGB blocklight with a cloud marker in alpha.
/// Precision: 1/255 per channel. Sufficient for per-vertex lighting where values blend smoothly.
pub fn encodeBlocklight(bl: [3]f32, is_cloud: bool) u32 {
    const r: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, bl[0])) * 255.0));
    const g: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, bl[1])) * 255.0));
    const b: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, bl[2])) * 255.0));
    const a: u8 = if (is_cloud) 255 else 0;
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

test "terrain vertex ABI remains tightly packed" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Vertex, "pos"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Vertex, "color"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Vertex, "normal"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Vertex, "uv"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Vertex, "packed_meta"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Vertex, "blocklight"));
}

pub const DrawMode = enum {
    triangles,
    lines,
    points,
};

/// Parameters for the far-LOD vertex-pulling path.  Samples live in a storage
/// buffer; the reusable index grid supplies `gl_VertexIndex`.
pub const CompactLODDraw = extern struct {
    model: Mat4,
    mask_radius: f32,
    lod_fade: f32,
    sample_offset: u32,
    width: u32,
    cell_size: f32,
    layer: u32,
    skirt_depth: f32,
    /// Bits 0..3: authoritative same-level compact aprons (N/E/S/W). The
    /// shader emits a skirt for every complementary edge.
    edge_masks: u32 = 0,
    /// Local min X/Z, max X/Z ownership rectangle; zero disables clipping.
    ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Selects one immutable descriptor snapshot before any LOD stream bindings
/// are updated or draw commands are recorded.  Direct and GPU-indirect streams
/// are intentionally distinct even when they currently share a buffer type.
pub const LODDescriptorStream = enum(u3) {
    terrain_standard_direct,
    water_standard_direct,
    terrain_standard_gpu,
    water_standard_gpu,
    terrain_compact_direct,
    water_compact_direct,
    terrain_compact_gpu,
    water_compact_gpu,
};

/// Per-draw compact-tile data consumed from a std430 SSBO by the indirect
/// vertex-pulling path. `gl_InstanceIndex` includes `firstInstance`, so the
/// compute pass can compact this record and use its output slot directly.
pub const CompactLODInstance = extern struct {
    model: Mat4,
    /// mask radius, LOD fade, cell size, skirt depth
    params: [4]f32,
    /// sample offset, tile width, layer, authoritative-apron mask
    words: [4]u32,
    ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const DrawIndexedIndirectCommand = extern struct {
    indexCount: u32,
    instanceCount: u32,
    firstIndex: u32,
    vertexOffset: i32,
    firstInstance: u32,
};

comptime {
    // extern alignment rounds the scalar payload fields to a 16-byte
    // push-constant block, matching Vulkan's GLSL layout size.
    std.debug.assert(@sizeOf(CompactLODDraw) == 112);
    std.debug.assert(@offsetOf(CompactLODDraw, "ownership_bounds") == 96);
    std.debug.assert(@offsetOf(CompactLODDraw, "mask_radius") == 64);
    std.debug.assert(@offsetOf(CompactLODDraw, "lod_fade") == 68);
    std.debug.assert(@offsetOf(CompactLODDraw, "sample_offset") == 72);
    std.debug.assert(@offsetOf(CompactLODDraw, "width") == 76);
    std.debug.assert(@offsetOf(CompactLODDraw, "cell_size") == 80);
    std.debug.assert(@offsetOf(CompactLODDraw, "layer") == 84);
    std.debug.assert(@offsetOf(CompactLODDraw, "skirt_depth") == 88);
    std.debug.assert(@offsetOf(CompactLODDraw, "edge_masks") == 92);
}

test "compact LOD push constants match GLSL scalar offsets" {
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(CompactLODDraw));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(CompactLODDraw, "ownership_bounds"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CompactLODDraw, "model"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(CompactLODDraw, "mask_radius"));
    try std.testing.expectEqual(@as(usize, 68), @offsetOf(CompactLODDraw, "lod_fade"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(CompactLODDraw, "sample_offset"));
    try std.testing.expectEqual(@as(usize, 76), @offsetOf(CompactLODDraw, "width"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(CompactLODDraw, "cell_size"));
    try std.testing.expectEqual(@as(usize, 84), @offsetOf(CompactLODDraw, "layer"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(CompactLODDraw, "skirt_depth"));
    try std.testing.expectEqual(@as(usize, 92), @offsetOf(CompactLODDraw, "edge_masks"));
}

test "compact LOD indirect instance and indexed command ABI" {
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(CompactLODInstance));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(CompactLODInstance, "ownership_bounds"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(CompactLODInstance, "params"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(CompactLODInstance, "words"));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(DrawIndexedIndirectCommand));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DrawIndexedIndirectCommand, "firstInstance"));
}

/// Little-endian 128-bit compact LOD sample, represented as Vulkan SSBO words.
/// The field locations are shared by the world upload format and the compact
/// vertex shaders. This is deliberately a word view: Vulkan storage buffers
/// expose the 16-byte sample as `uvec4`.
pub const CompactLODSampleWords = extern struct {
    words: [4]u32,

    pub const Decoded = struct {
        terrain_height: i16,
        water_height: i16,
        water_depth: u8,
        water_coverage: u8,
        surface_material: u7,
        subsurface_material: u7,
        foundation_material: u7,
        color: u32,
        sky_light: u4,
        block_light: u4,
        ambient_occlusion: u6,
    };

    pub fn decode(self: CompactLODSampleWords) Decoded {
        return .{
            .terrain_height = signed16(self.words[0], 0),
            .water_height = signed16(self.words[0], 16),
            .water_depth = @truncate(self.words[1]),
            .water_coverage = @truncate(self.words[1] >> 8),
            .surface_material = @truncate(self.words[1] >> 16),
            .subsurface_material = @truncate(self.words[1] >> 23),
            .foundation_material = @truncate((self.words[1] >> 30) | (self.words[2] << 2)),
            .color = (self.words[2] >> 5) & 0x00ff_ffff,
            .sky_light = @truncate((self.words[2] >> 29) | (self.words[3] << 3)),
            .block_light = @truncate(self.words[3] >> 1),
            .ambient_occlusion = @truncate(self.words[3] >> 5),
        };
    }

    fn signed16(word: u32, shift: u5) i16 {
        const raw: u16 = @truncate(word >> shift);
        return @bitCast(raw);
    }
};

comptime {
    std.debug.assert(@sizeOf(CompactLODSampleWords) == 16);
    std.debug.assert(@alignOf(CompactLODSampleWords) == @alignOf(u32));
    std.debug.assert(@offsetOf(CompactLODSampleWords, "words") == 0);
}

test "compact LOD 128-bit sample golden vector decodes across word boundaries" {
    var bits: u128 = 0;
    bits |= @as(u128, @as(u16, @bitCast(@as(i16, -100))));
    bits |= @as(u128, @as(u16, @bitCast(@as(i16, 58)))) << 16;
    bits |= @as(u128, 9) << 32;
    bits |= @as(u128, 255) << 40;
    bits |= @as(u128, 0x15) << 48;
    bits |= @as(u128, 0x2a) << 55;
    bits |= @as(u128, 0x45) << 62;
    bits |= @as(u128, 0x00ab_cdef) << 69;
    bits |= @as(u128, 15) << 93;
    bits |= @as(u128, 11) << 97;
    bits |= @as(u128, 42) << 101;

    const sample = CompactLODSampleWords{ .words = .{
        @truncate(bits),
        @truncate(bits >> 32),
        @truncate(bits >> 64),
        @truncate(bits >> 96),
    } };
    const decoded = sample.decode();
    try std.testing.expectEqual(@as(i16, -100), decoded.terrain_height);
    try std.testing.expectEqual(@as(i16, 58), decoded.water_height);
    try std.testing.expectEqual(@as(u8, 9), decoded.water_depth);
    try std.testing.expectEqual(@as(u8, 255), decoded.water_coverage);
    try std.testing.expectEqual(@as(u7, 0x15), decoded.surface_material);
    try std.testing.expectEqual(@as(u7, 0x2a), decoded.subsurface_material);
    try std.testing.expectEqual(@as(u7, 0x45), decoded.foundation_material);
    try std.testing.expectEqual(@as(u32, 0x00ab_cdef), decoded.color);
    try std.testing.expectEqual(@as(u4, 15), decoded.sky_light);
    try std.testing.expectEqual(@as(u4, 11), decoded.block_light);
    try std.testing.expectEqual(@as(u6, 42), decoded.ambient_occlusion);
}

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
    model: Mat4,
    mask_radius: f32,
    lod_fade: f32,
    padding: [2]f32,
    /// Local min X/Z, max X/Z. Zero disables clipping for full chunks.
    ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(InstanceData) == 96);
    std.debug.assert(@offsetOf(InstanceData, "ownership_bounds") == 80);
}

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

pub const ShadowConfig = struct {
    distance: f32 = 250.0,
    resolution: u32 = 4096,
    pcf_samples: u8 = 9,
    cascade_blend: bool = true,
    strength: f32 = 0.35,
    caster_distance: f32 = 250.0,
};

pub const ShadowParams = struct {
    light_space_matrices: [SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [SHADOW_CASCADE_COUNT]f32,
    overlap_starts: [SHADOW_CASCADE_COUNT]f32 = .{0.0} ** SHADOW_CASCADE_COUNT,
    shadow_texel_sizes: [SHADOW_CASCADE_COUNT]f32,
    shadow_depth_spans: [SHADOW_CASCADE_COUNT]f32 = .{1.0} ** SHADOW_CASCADE_COUNT,
    resolution: u32 = 4096,
    distance: f32 = 250.0,
};

pub const FrameRenderParams = struct {
    cam_pos: Vec3 = Vec3.init(0, 0, 0),
    view_proj: Mat4 = Mat4.identity,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    sun_intensity: f32 = 1.0,
    fog_color: Vec3 = Vec3.init(0.7, 0.8, 0.9),
    fog_density: f32 = 0.0,
    pbr_enabled: bool = false,
    shadow_apply_to_beauty: bool = false,
    shadow: ShadowConfig = .{},
    pbr_quality: u8 = 0,
    volumetric_enabled: bool = false,
    volumetric_density: f32 = 0.05,
    volumetric_steps: u32 = 16,
    volumetric_scattering: f32 = 0.8,
    exposure: f32 = 1.0,
    saturation: f32 = 1.0,
    ssao_enabled: bool = false,
    lpv_enabled: bool = false,
    lpv_intensity: f32 = 0.5,
    lpv_cell_size: f32 = 2.0,
    lpv_grid_size: u32 = 32,
    lpv_origin: Vec3 = Vec3.init(0.0, 0.0, 0.0),
};

pub const GlobalUniforms = struct {
    view_proj: Mat4,
    cam_pos: Vec3,
    sun_dir: Vec3,
    sun_color: Vec3,
    time: f32,
    fog_color: Vec3,
    fog_density: f32,
    fog_enabled: bool,
    sun_intensity: f32,
    ambient: f32,
    use_texture: bool,
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

pub const UVRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const GpuTimingResults = struct {
    shadow_pass_ms: [SHADOW_CASCADE_COUNT]f32,
    g_pass_ms: f32,
    ssao_pass_ms: f32,
    lpv_pass_ms: f32,
    sky_pass_ms: f32,
    opaque_pass_ms: f32,
    /// GPU time spent drawing distant-terrain LOD geometry. This is a subset
    /// of the containing scene pass and is therefore excluded from total_gpu_ms.
    lod_terrain_pass_ms: f32,
    /// GPU time spent drawing distant-water LOD geometry. This is a subset
    /// of the containing scene pass and is therefore excluded from total_gpu_ms.
    lod_water_pass_ms: f32,
    /// Compact LOD terrain draw scope; retained separately from aggregate LOD terrain.
    lod_compact_terrain_pass_ms: f32,
    /// Compact LOD water draw scope; retained separately from aggregate LOD water.
    lod_compact_water_pass_ms: f32,
    /// GPU time spent culling LOD candidates, compacting indirect commands,
    /// and executing the compute-to-indirect barrier.
    lod_culling_compute_ms: f32,
    main_pass_ms: f32, // Overall main pass time (sum of sky and opaque)
    bloom_pass_ms: f32,
    fxaa_pass_ms: f32,
    post_process_pass_ms: f32,
    total_gpu_ms: f32,

    pub fn validate(self: GpuTimingResults) void {
        const expected_main = self.sky_pass_ms + self.opaque_pass_ms;
        const epsilon = 0.01;
        if (@abs(self.main_pass_ms - expected_main) > epsilon) {
            std.debug.print("Timing Drift Warning: Main Pass {d:.3}ms != Sum {d:.3}ms (Sky {d:.3} + Opaque {d:.3})\n", .{
                self.main_pass_ms,
                expected_main,
                self.sky_pass_ms,
                self.opaque_pass_ms,
            });
        }
    }
};
