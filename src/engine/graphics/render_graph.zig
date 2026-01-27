const std = @import("std");
const c = @import("../../c.zig").c;
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const shadow_scene = @import("shadow_scene.zig");
const RHI = @import("rhi.zig").RHI;
const rhi_pkg = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const log = @import("../core/log.zig");
const CSM = @import("csm.zig");
const AtmosphereSystem = @import("atmosphere_system.zig").AtmosphereSystem;
const MaterialSystem = @import("material_system.zig").MaterialSystem;

pub const SceneContext = struct {
    rhi: RHI,
    world: *World,
    shadow_scene: shadow_scene.IShadowScene,
    camera: *Camera,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    aspect: f32,
    sky_params: rhi_pkg.SkyParams,
    cloud_params: rhi_pkg.CloudParams,
    main_shader: rhi_pkg.ShaderHandle,
    env_map_handle: rhi_pkg.TextureHandle,
    shadow: rhi_pkg.ShadowConfig,
    ssao_enabled: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,
    // Phase 3: FXAA and Bloom flags
    fxaa_enabled: bool = true,
    bloom_enabled: bool = true,
    taa_enabled: bool = true,
    overlay_renderer: ?*const fn (ctx: SceneContext) void = null,
    overlay_ctx: ?*anyopaque = null,
};

pub const IRenderPass = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: []const u8,
        /// Returns true if this pass requires the main render pass (swapchain output) to be active.
        needs_main_pass: bool = false,
        execute: *const fn (ptr: *anyopaque, ctx: SceneContext) void,
    };

    pub fn execute(self: IRenderPass, ctx: SceneContext) void {
        self.vtable.execute(self.ptr, ctx);
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        self.passes.deinit(self.allocator);
    }

    pub fn addPass(self: *RenderGraph, pass: IRenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn execute(self: *const RenderGraph, ctx: SceneContext) void {
        const timing = ctx.rhi.timing();
        var main_pass_started = false;
        for (self.passes.items) |pass| {
            updateMainPassState(ctx, pass, &main_pass_started);

            const pass_name = pass.name();
            timing.beginPassTiming(pass_name);
            pass.execute(ctx);
            timing.endPassTiming(pass_name);
        }

        if (main_pass_started) {
            ctx.rhi.endMainPass();
        }
    }

    fn updateMainPassState(ctx: SceneContext, pass: IRenderPass, main_pass_started: *bool) void {
        if (pass.needsMainPass()) {
            if (!main_pass_started.*) {
                ctx.rhi.beginMainPass();
                main_pass_started.* = true;
            }
        } else {
            if (main_pass_started.*) {
                ctx.rhi.endMainPass();
                main_pass_started.* = false;
            }
        }
    }
};

// --- Standard Pass Implementations ---

const SHADOW_PASS_NAMES = [_][]const u8{ "ShadowPass0", "ShadowPass1", "ShadowPass2" };

pub const ShadowPass = struct {
    cascade_index: u32,

    pub fn init(cascade_index: u32) ShadowPass {
        return .{ .cascade_index = cascade_index };
    }

    const VTABLES = [_]IRenderPass.VTable{
        .{ .name = "ShadowPass0", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass1", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass2", .needs_main_pass = false, .execute = execute },
    };

    pub fn pass(self: *ShadowPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLES[self.cascade_index],
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        const self: *ShadowPass = @ptrCast(@alignCast(ptr));
        // Runtime verification to ensuring pointer safety in debug mode
        std.debug.assert(self.cascade_index < rhi_pkg.SHADOW_CASCADE_COUNT);

        const cascade_idx = self.cascade_index;
        const rhi = ctx.rhi;

        const cascades = CSM.computeCascades(
            ctx.shadow.resolution,
            ctx.camera.fov,
            ctx.aspect,
            0.1,
            ctx.shadow.distance,
            ctx.sky_params.sun_dir,
            ctx.camera.getViewMatrixOriginCentered(),
            true,
        );
        const light_space_matrix = cascades.light_space_matrices[cascade_idx];

        rhi.updateShadowUniforms(.{
            .light_space_matrices = cascades.light_space_matrices,
            .cascade_splits = cascades.cascade_splits,
            .shadow_texel_sizes = cascades.texel_sizes,
        });

        if (ctx.disable_shadow_draw) return;

        rhi.beginShadowPass(cascade_idx, light_space_matrix);
        ctx.shadow_scene.renderShadowPass(light_space_matrix, ctx.camera.position);
        rhi.endShadowPass();
    }
};

pub const GPass = struct {
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        if (!ctx.ssao_enabled or ctx.disable_gpass_draw) return;

        ctx.rhi.beginGPass();
        const atlas = ctx.material_system.getAtlasHandles(ctx.env_map_handle);
        ctx.rhi.bindTexture(atlas.diffuse, 1);
        const view_proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.render(view_proj, ctx.camera.position);
        ctx.rhi.endGPass();
    }
};

pub const SSAOPass = struct {
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        if (!ctx.ssao_enabled or ctx.disable_ssao) return;
        const proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far);
        const inv_proj = proj.inverse();
        ctx.rhi.ssao().compute(proj, inv_proj);
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        ctx.atmosphere_system.renderSky(ctx.sky_params) catch |err| {
            if (err != error.ResourceNotReady and
                err != error.SkyPipelineNotReady and
                err != error.SkyPipelineLayoutNotReady and
                err != error.CommandBufferNotReady)
            {
                log.log.err("SkyPass: rendering failed: {}", .{err});
            }
        };
    }
};

pub const OpaquePass = struct {
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        const rhi = ctx.rhi;
        rhi.bindShader(ctx.main_shader);
        ctx.material_system.bindTerrainMaterial(ctx.env_map_handle);
        const view_proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.render(view_proj, ctx.camera.position);
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        if (ctx.disable_clouds) return;
        const view_proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.atmosphere_system.renderClouds(ctx.cloud_params, view_proj) catch |err| {
            if (err != error.ResourceNotReady and
                err != error.CloudPipelineNotReady and
                err != error.CloudPipelineLayoutNotReady and
                err != error.CommandBufferNotReady)
            {
                log.log.err("CloudPass: rendering failed: {}", .{err});
            }
        };
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        ctx.rhi.beginPostProcessPass();
        ctx.rhi.draw(rhi_pkg.InvalidBufferHandle, 3, .triangles);
        ctx.rhi.endPostProcessPass();
    }
};

// Phase 3: Bloom Pass - Computes bloom mip chain from HDR buffer
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        const self: *BloomPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.bloom_enabled) return;
        ctx.rhi.computeBloom();
    }
};

// TAA Pass - Temporal Anti-Aliasing
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        const self: *TAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.taa_enabled) return;
        ctx.rhi.computeTAA();
    }
};

// Phase 3: FXAA Pass - Applies FXAA to LDR output
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

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        const self: *FXAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.fxaa_enabled) return;
        ctx.rhi.beginFXAAPass();
        ctx.rhi.endFXAAPass();
    }
};
