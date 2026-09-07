//! Render Graph - Orchestrates frame rendering through sequential render passes.
//!
//! This module implements a simple render graph that executes a series of render
//! passes in order, managing the main pass lifecycle automatically based on each
//! pass's requirements.
//!
//! ## Pass Execution Model
//!
//! Passes are added via `addPass()` and executed sequentially in `execute()`:
//! ```
//! ShadowPass0 -> ShadowPass1 -> ShadowPass2 -> ShadowPass3 ->
//! GPass -> SSAOPass -> SkyPass -> OpaquePass -> UIPass
//! ```
//!
//! ## Main Pass Lifecycle
//!
//! The render graph automatically manages the main render pass state machine:
//! - Passes with `needs_main_pass = true` require an active main pass
//! - The graph calls `beginMainPass()` / `endMainPass()` as needed when
//!   transitioning between pass types
//! - This allows mixing pre-pass work (shadows, SSAO) with main pass rendering
//!
//! ## Standard Passes
//!
//! - **ShadowPass**: Renders shadow map cascades (0-3), outside main pass
//! - **GPass**: Geometry pass for SSAO, outputs normals/depth
//! - **SSAOPass**: Screen-space ambient occlusion computation
//! - **SkyPass**: Atmospheric sky rendering, inside main pass
//! - **OpaquePass**: Main world geometry rendering
//! - **UIPass**: Immediate-mode UI overlay
//!
//! ## Scene Context
//!
//! All passes receive a `SceneContext` struct containing references to:
//! RHI, World, Camera, shadow scene, atmosphere system, and various configuration
//! parameters. This provides passes with everything needed for rendering.

const std = @import("std");
const build_options = @import("engine_graphics_options");
const Camera = @import("engine-camera").Camera;
const IWorldRenderView = @import("engine-rhi").IWorldRenderView;
const IShadowScene = @import("engine-rhi").IShadowScene;
const rhi_pkg = @import("engine-rhi").rhi;
const RenderContext = rhi_pkg.RenderContext;
const ShadowSystemWrapper = rhi_pkg.ShadowSystemWrapper;
const WaterSystemWrapper = rhi_pkg.WaterSystemWrapper;
const ISSAOContext = rhi_pkg.ISSAOContext;
const IDeviceTiming = rhi_pkg.IDeviceTiming;
const Vec3 = @import("engine-math").Vec3;
const engine_core = @import("engine-core");
const log = @import("engine-core").log;
const CSM = @import("engine-shadows").csm;
pub const AtmosphereSystem = @import("engine-atmosphere").AtmosphereSystem;
const MaterialSystem = @import("engine-assets").MaterialSystem;
pub const LPVSystem = @import("vulkan/lpv_system.zig").LPVSystem;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const CloudSystem = @import("engine-clouds").CloudSystem;

pub const LPVConfig = struct {
    grid_size: u32,
    cell_size: f32,
    intensity: f32,
    propagation_iterations: u32,
    enabled: bool,
};

pub const LPVTextureHandles = struct {
    red: rhi_pkg.TextureHandle = 0,
    green: rhi_pkg.TextureHandle = 0,
    blue: rhi_pkg.TextureHandle = 0,

    pub fn fromSystem(lpv_system: *LPVSystem) LPVTextureHandles {
        return .{
            .red = lpv_system.getTextureHandle(),
            .green = lpv_system.getTextureHandleG(),
            .blue = lpv_system.getTextureHandleB(),
        };
    }
};

pub const SceneContext = struct {
    render_ctx: RenderContext,
    shadow_ctx: ShadowSystemWrapper,
    water_ctx: WaterSystemWrapper,
    ssao_ctx: ISSAOContext,
    timing: IDeviceTiming,
    world: IWorldRenderView,
    shadow_scene: IShadowScene,
    camera: *Camera,
    atmosphere_system: *AtmosphereSystem,
    aspect: f32,
    sky_params: rhi_pkg.SkyParams,
    shadow_sun_dir: Vec3,
    taa_enabled: bool,
    viewport_width: f32,
    viewport_height: f32,
    main_shader: rhi_pkg.ShaderHandle,
    env_map_handle: rhi_pkg.TextureHandle,
    shadow: rhi_pkg.ShadowConfig,
    ssao_enabled: bool,
    gpu_culling_enabled: bool = false,
    shadow_draw_enabled: bool,
    fxaa_enabled: bool = true,
    bloom_enabled: bool = true,
    resolution_scale: f32 = 1.0,
    overlay_renderer: ?*const fn (ctx: SceneContext) void = null,
    overlay_ctx: ?*anyopaque = null,
    shadow_caster_renderer: ?*const fn (ctx: *anyopaque, render_ctx: RenderContext, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void = null,
    shadow_caster_ctx: ?*anyopaque = null,
    lpv_textures: LPVTextureHandles = .{},
    cached_cascades: *?CSM.ShadowCascades,
    gpu_mesh_dispatch_fn: ?*const fn (*anyopaque) void = null,
    gpu_mesh_dispatch_ctx: ?*anyopaque = null,
    cloud_system: ?*CloudSystem = null,
};

pub const IRenderPass = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: []const u8,
        needs_main_pass: bool,
        execute: *const fn (ptr: *anyopaque, ctx: SceneContext) anyerror!void,
    };

    pub fn execute(self: IRenderPass, ctx: SceneContext) !void {
        try self.vtable.execute(self.ptr, ctx);
    }

    pub fn name(self: IRenderPass) []const u8 {
        return self.vtable.name;
    }

    pub fn needsMainPass(self: IRenderPass) bool {
        return self.vtable.needs_main_pass;
    }
};

pub const RenderGraph = struct {
    passes: std.ArrayListUnmanaged(IRenderPass),
    atmosphere_system: *AtmosphereSystem,
    allocator: std.mem.Allocator,
    lpv_system: *LPVSystem,
    material_system: ?*MaterialSystem,

    pub fn init(allocator: std.mem.Allocator, rhi: rhi_pkg.RHI, lpv_config: LPVConfig) !RenderGraph {
        const atmosphere_system = try AtmosphereSystem.init(allocator);
        errdefer atmosphere_system.deinit();

        const lpv_system = try LPVSystem.init(
            allocator,
            rhi,
            lpv_config.grid_size,
            lpv_config.cell_size,
            lpv_config.intensity,
            lpv_config.propagation_iterations,
            lpv_config.enabled,
        );
        errdefer lpv_system.deinit();

        return .{
            .passes = .empty,
            .atmosphere_system = atmosphere_system,
            .allocator = allocator,
            .lpv_system = lpv_system,
            .material_system = null,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        self.passes.deinit(self.allocator);
        self.atmosphere_system.deinit();
        self.lpv_system.deinit();
        if (self.material_system) |material_system| material_system.deinit();
    }

    pub fn getLPVSystem(self: *RenderGraph) *LPVSystem {
        return self.lpv_system;
    }

    pub fn initMaterials(self: *RenderGraph, atlas: *TextureAtlas) !void {
        self.material_system = try MaterialSystem.init(self.allocator, atlas);
    }

    pub fn materials(self: *RenderGraph) *MaterialSystem {
        return self.material_system.?;
    }

    pub fn getAtmosphereSystem(self: *RenderGraph) *AtmosphereSystem {
        return self.atmosphere_system;
    }

    pub fn addPass(self: *RenderGraph, pass: IRenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn execute(self: *const RenderGraph, ctx: SceneContext) !void {
        var main_pass_started = false;
        for (self.passes.items) |pass| {
            updateMainPassState(ctx, pass, &main_pass_started);

            const pass_name = pass.name();
            ctx.timing.beginPassTiming(pass_name);
            try pass.execute(ctx);
            ctx.timing.endPassTiming(pass_name);
        }

        if (main_pass_started) {
            ctx.render_ctx.endMainPass();
        }
    }

    fn updateMainPassState(ctx: SceneContext, pass: IRenderPass, main_pass_started: *bool) void {
        if (pass.needsMainPass()) {
            if (!main_pass_started.*) {
                ctx.render_ctx.beginMainPass();
                main_pass_started.* = true;
            }
        } else {
            if (main_pass_started.*) {
                ctx.render_ctx.endMainPass();
                main_pass_started.* = false;
            }
        }
    }
};

// --- Standard Pass Implementations ---

const SHADOW_PASS_NAMES = [_][]const u8{ "ShadowPass0", "ShadowPass1", "ShadowPass2", "ShadowPass3" };

pub const ShadowPass = struct {
    cascade_index: u32,
    material_system: *MaterialSystem,
    enabled: bool = true,

    pub fn init(cascade_index: u32, material_system: *MaterialSystem) ShadowPass {
        return .{ .cascade_index = cascade_index, .material_system = material_system };
    }

    const VTABLES = [_]IRenderPass.VTable{
        .{ .name = "ShadowPass0", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass1", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass2", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass3", .needs_main_pass = false, .execute = execute },
    };

    pub fn pass(self: *ShadowPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLES[self.cascade_index],
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *ShadowPass = @ptrCast(@alignCast(ptr));
        // Runtime verification to ensuring pointer safety in debug mode
        std.debug.assert(self.cascade_index < rhi_pkg.SHADOW_CASCADE_COUNT);
        if (!self.enabled or !ctx.shadow_draw_enabled) return;

        const cascade_idx = self.cascade_index;
        const shadow_resolution = ctx.shadow_ctx.getResolution();

        // Compute cascades once per frame and cache via shared pointer so all
        // cascade passes within the same frame use identical matrices.
        const cascades = if (ctx.cached_cascades.*) |cached| cached else blk: {
            const computed = CSM.computeCascadesWithCamera(
                shadow_resolution,
                ctx.camera.fov,
                ctx.aspect,
                0.1,
                ctx.shadow.distance,
                ctx.shadow_sun_dir,
                ctx.camera.getViewMatrixOriginCentered(),
                ctx.camera.position,
                true,
            );
            // Validate cascade data before using
            if (!CSM.validateCascades(computed, log.log)) {
                log.log.err("ShadowPass{}: Invalid cascade data, skipping shadow pass", .{cascade_idx});
                return error.InvalidShadowCascades;
            }
            ctx.cached_cascades.* = computed;
            break :blk computed;
        };

        const light_space_matrix = cascades.light_space_matrices[cascade_idx];

        // Only update uniforms on first cascade pass
        if (cascade_idx == 0) {
            try ctx.shadow_ctx.updateUniforms(.{
                .light_space_matrices = cascades.light_space_matrices,
                .cascade_splits = cascades.cascade_splits,
                .overlap_starts = cascades.overlap_starts,
                .shadow_texel_sizes = cascades.texel_sizes,
                .shadow_depth_spans = cascades.depth_spans,
                .resolution = shadow_resolution,
                .distance = ctx.shadow.distance,
            });
        }

        // Keep cutout casters sampling the terrain atlas during the shadow pass.
        // Without this, shadow.frag can alpha-clip against whatever texture was last bound.
        self.material_system.bindTerrainMaterial(ctx.render_ctx, ctx.env_map_handle);

        ctx.shadow_ctx.beginPass(cascade_idx, light_space_matrix);
        errdefer ctx.shadow_ctx.endPass();
        const caster_bounds = CSM.computeCasterBounds(cascades.receiver_corners[cascade_idx], ctx.shadow_sun_dir, ctx.shadow.caster_distance);
        ctx.shadow_scene.renderShadowPass(light_space_matrix, ctx.camera.position, caster_bounds.min, caster_bounds.max, ctx.shadow);
        if (ctx.shadow_caster_renderer) |render| {
            render(ctx.shadow_caster_ctx orelse return error.InvalidShadowCasterContext, ctx.render_ctx, ctx.camera.position, caster_bounds.min, caster_bounds.max);
        }
        if (ctx.cloud_system) |clouds| {
            try clouds.renderShadow(ctx.render_ctx, ctx.camera.position);
        }
        ctx.shadow_ctx.endPass();
    }
};

pub const GPass = struct {
    material_system: *MaterialSystem,
    enabled: bool = true,

    pub fn init(material_system: *MaterialSystem) GPass {
        return .{ .material_system = material_system };
    }

    const VTABLE = IRenderPass.VTable{
        .name = "GPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *GPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *GPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.ssao_enabled) return;

        ctx.render_ctx.beginGPass();
        const atlas = self.material_system.getAtlasHandles(ctx.env_map_handle);
        ctx.render_ctx.bindTexture(atlas.diffuse, 1);
        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.renderOpaque(view_proj, ctx.camera.position);
        ctx.render_ctx.endGPass();
    }
};

pub const SSAOPass = struct {
    enabled: bool = true,

    const VTABLE = IRenderPass.VTable{
        .name = "SSAOPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *SSAOPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *SSAOPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.ssao_enabled) return;
        const proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled);
        const inv_proj = proj.inverse();
        ctx.ssao_ctx.compute(proj, inv_proj);
    }
};

pub const DepthPyramidPass = struct {
    enabled: bool = true,

    const VTABLE = IRenderPass.VTable{
        .name = "DepthPyramidPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *DepthPyramidPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *DepthPyramidPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.gpu_culling_enabled) return;
        ctx.render_ctx.computeDepthPyramid();
    }
};

pub const SkyPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "SkyPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *SkyPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.atmosphere_system.renderSky(ctx.render_ctx, ctx.sky_params) catch |err| {
            if (err != error.ResourceNotReady and
                err != error.SkyPipelineNotReady and
                err != error.SkyPipelineLayoutNotReady and
                err != error.CommandBufferNotReady)
            {
                log.log.errWithTrace("SkyPass: rendering failed: {}", .{err});
            }
        };
    }
};

pub const CloudPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "CloudPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *CloudPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (ctx.cloud_system) |clouds| {
            clouds.render(ctx.render_ctx, ctx.camera.position) catch |err| {
                log.log.errWithTrace("CloudPass: rendering failed: {}", .{err});
            };
        }
    }
};

pub const OpaquePass = struct {
    material_system: *MaterialSystem,

    pub fn init(material_system: *MaterialSystem) OpaquePass {
        return .{ .material_system = material_system };
    }

    const VTABLE = IRenderPass.VTable{
        .name = "OpaquePass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *OpaquePass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *OpaquePass = @ptrCast(@alignCast(ptr));
        self.material_system.bindTerrainMaterial(ctx.render_ctx, ctx.env_map_handle);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.red, 11);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.green, 12);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.blue, 13);
        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.renderOpaque(view_proj, ctx.camera.position);
    }
};

pub const EntityPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "EntityPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *EntityPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (ctx.overlay_renderer) |render| {
            render(ctx);
        }
    }
};

pub const PostProcessPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "PostProcessPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *PostProcessPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.render_ctx.beginPostProcessPass();
        ctx.render_ctx.draw(rhi_pkg.InvalidBufferHandle, 3, .triangles);
        ctx.render_ctx.endPostProcessPass();
    }
};

// Bloom pass - computes bloom mip chain from HDR buffer
pub const BloomPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "BloomPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *BloomPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *BloomPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.bloom_enabled) return;
        ctx.render_ctx.computeBloom();
    }
};

// TAA pass - reserved temporal AA stage between scene rendering and bloom/post.
pub const TAAPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "TAAPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *TAAPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *TAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.taa_enabled) return;
        ctx.render_ctx.computeTAA();
    }
};

// FXAA pass - applies anti-aliasing to LDR output
pub const FXAAPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "FXAAPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *FXAAPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *FXAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.fxaa_enabled) return;
        ctx.render_ctx.beginFXAAPass();
        ctx.render_ctx.endFXAAPass();
    }
};

pub const WaterReflectionPass = struct {
    material_system: *MaterialSystem,
    enabled: bool = true,

    pub fn init(material_system: *MaterialSystem) WaterReflectionPass {
        return .{ .material_system = material_system };
    }

    const VTABLE = IRenderPass.VTable{
        .name = "WaterReflectionPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *WaterReflectionPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *WaterReflectionPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled) return;

        ctx.water_ctx.beginReflectionPass();
        defer ctx.water_ctx.endReflectionPass();

        const view = ctx.camera.getViewMatrixOriginCentered();
        const proj = ctx.camera.getProjectionMatrixReverseZ(ctx.aspect);
        const reflected_vp = ctx.water_ctx.computeReflectedViewProj(view, proj, ctx.camera.position);

        self.material_system.bindTerrainMaterial(ctx.render_ctx, ctx.env_map_handle);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.red, 11);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.green, 12);
        ctx.render_ctx.bindTexture(ctx.lpv_textures.blue, 13);

        ctx.world.renderOpaque(reflected_vp, ctx.camera.position);
    }
};

pub const WaterPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "WaterPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *WaterPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *WaterPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled) return;

        const reflection_handle = ctx.water_ctx.getReflectionTextureHandle();
        const scene_depth_handle = ctx.water_ctx.getSceneDepthTextureHandle();

        if (!ctx.render_ctx.beginWaterDraw(reflection_handle, scene_depth_handle)) return;
        defer ctx.render_ctx.endWaterDraw();

        ctx.render_ctx.bindTexture(reflection_handle, 14);
        ctx.render_ctx.bindTexture(scene_depth_handle, 15);

        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.renderFluid(view_proj, ctx.camera.position);
    }
};

pub const MeshBuildPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "MeshBuildPass",
        .needs_main_pass = false,
        .execute = execute,
    };

    pub fn pass(self: *MeshBuildPass) IRenderPass {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (ctx.gpu_mesh_dispatch_fn) |dispatch_fn| {
            if (ctx.gpu_mesh_dispatch_ctx) |dispatch_ctx| dispatch_fn(dispatch_ctx);
        }
    }
};
