const std = @import("std");
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const shadow_scene = @import("shadow_scene.zig");
const RHI = @import("rhi.zig").RHI;
const rhi_pkg = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
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
        var main_pass_started = false;
        for (self.passes.items) |pass| {
            // Handle main pass transition
            if (pass.needsMainPass() and !main_pass_started) {
                ctx.rhi.beginMainPass();
                main_pass_started = true;
            }

            pass.execute(ctx);
        }
    }
};

// --- Standard Pass Implementations ---

pub const ShadowPass = struct {
    cascade_index: u32,

    pub fn init(cascade_index: u32) ShadowPass {
        return .{ .cascade_index = cascade_index };
    }

    pub fn pass(self: *ShadowPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "ShadowPass",
                .needs_main_pass = false,
                .execute = execute,
            },
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
    pub fn pass(self: *GPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "GPass",
                .needs_main_pass = false,
                .execute = execute,
            },
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
    pub fn pass(self: *SSAOPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "SSAOPass",
                .needs_main_pass = false,
                .execute = execute,
            },
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        if (!ctx.ssao_enabled or ctx.disable_ssao) return;
        ctx.rhi.computeSSAO();
    }
};

pub const SkyPass = struct {
    pub fn pass(self: *SkyPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "SkyPass",
                .needs_main_pass = true,
                .execute = execute,
            },
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        ctx.rhi.drawSky(ctx.sky_params);
    }
};

pub const OpaquePass = struct {
    pub fn pass(self: *OpaquePass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "OpaquePass",
                .needs_main_pass = true,
                .execute = execute,
            },
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
    pub fn pass(self: *CloudPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = "CloudPass",
                .needs_main_pass = true,
                .execute = execute,
            },
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) void {
        _ = ptr;
        if (ctx.disable_clouds) return;
        const view_proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.atmosphere_system.renderClouds(ctx.cloud_params, view_proj);
    }
};
