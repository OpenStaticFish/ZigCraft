const std = @import("std");
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const RHI = @import("rhi.zig").RHI;
const rhi_pkg = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const CSM = @import("csm.zig");

pub const SceneContext = struct {
    rhi: RHI,
    world: *World,
    camera: *Camera,
    aspect: f32,
    sky_params: rhi_pkg.SkyParams,
    cloud_params: rhi_pkg.CloudParams,
    main_shader: rhi_pkg.ShaderHandle,
    atlas: rhi_pkg.TextureAtlasHandles,
    shadow_distance: f32,
    shadow_resolution: u32,
    ssao_enabled: bool,
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
        const cascade_idx = self.cascade_index;
        const rhi = ctx.rhi;

        const cascades = CSM.computeCascades(
            ctx.shadow_resolution,
            ctx.camera.fov,
            ctx.aspect,
            0.1,
            ctx.shadow_distance,
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

        rhi.beginShadowPass(cascade_idx);
        rhi.updateGlobalUniforms(light_space_matrix, ctx.camera.position, Vec3.zero, Vec3.zero, 0, Vec3.zero, 0, false, 0, 0, false, .{});
        ctx.world.renderShadowPass(light_space_matrix, ctx.camera.position);
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
        if (!ctx.ssao_enabled) return;

        ctx.rhi.beginGPass();
        ctx.rhi.bindTexture(ctx.atlas.diffuse, 1);
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
        if (!ctx.ssao_enabled) return;
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
        rhi.bindTexture(ctx.atlas.diffuse, 1);
        rhi.bindTexture(ctx.atlas.normal, 6);
        rhi.bindTexture(ctx.atlas.roughness, 7);
        rhi.bindTexture(ctx.atlas.displacement, 8);
        rhi.bindTexture(ctx.atlas.env, 9);
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
        const view_proj = Mat4.perspectiveReverseZ(ctx.camera.fov, ctx.aspect, ctx.camera.near, ctx.camera.far).multiply(ctx.camera.getViewMatrixOriginCentered());
        var params = ctx.cloud_params;
        params.view_proj = view_proj;
        params.cam_pos = ctx.camera.position;
        ctx.rhi.drawClouds(params);
    }
};
