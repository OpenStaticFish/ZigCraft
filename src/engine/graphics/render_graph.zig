const std = @import("std");
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const RHI = @import("rhi.zig").RHI;
const rhi_pkg = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const CSM = @import("csm.zig");

pub const RenderPass = enum {
    shadow_cascade_0,
    shadow_cascade_1,
    shadow_cascade_2,
    main_opaque,
    main_transparent,
    sky,
    clouds,
    ui,
    post_process,
};

pub const RenderGraph = struct {
    passes: []const RenderPass,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        _ = allocator;
        const default_passes = &[_]RenderPass{
            .shadow_cascade_0,
            .shadow_cascade_1,
            .shadow_cascade_2,
            .sky,
            .main_opaque,
            .clouds,
        };
        return .{
            .passes = default_passes,
        };
    }

    pub fn execute(
        self: *const RenderGraph,
        rhi: RHI,
        world: *World,
        camera: *Camera,
        aspect: f32,
        sky_params: rhi_pkg.SkyParams,
        cloud_params: rhi_pkg.CloudParams,
        main_shader: rhi_pkg.ShaderHandle,
        atlas_handle: rhi_pkg.TextureHandle,
        shadow_distance: f32,
        shadow_resolution: u32,
    ) void {
        var main_pass_started = false;
        for (self.passes) |pass| {
            // Start main render pass (clears buffer) only once before the first non-shadow pass
            switch (pass) {
                .shadow_cascade_0, .shadow_cascade_1, .shadow_cascade_2 => {},
                else => {
                    if (!main_pass_started) {
                        rhi.beginMainPass();
                        main_pass_started = true;
                    }
                },
            }
            self.executePass(pass, rhi, world, camera, aspect, sky_params, cloud_params, main_shader, atlas_handle, shadow_distance, shadow_resolution);
        }
    }

    fn executePass(
        self: *const RenderGraph,
        pass: RenderPass,
        rhi: RHI,
        world: *World,
        camera: *Camera,
        aspect: f32,
        sky_params: rhi_pkg.SkyParams,
        cloud_params: rhi_pkg.CloudParams,
        main_shader: rhi_pkg.ShaderHandle,
        atlas_handle: rhi_pkg.TextureHandle,
        shadow_distance: f32,
        shadow_resolution: u32,
    ) void {
        _ = self;
        switch (pass) {
            .shadow_cascade_0 => RenderGraph.executeShadowPass(0, rhi, world, camera, aspect, sky_params.sun_dir, shadow_distance, shadow_resolution),
            .shadow_cascade_1 => RenderGraph.executeShadowPass(1, rhi, world, camera, aspect, sky_params.sun_dir, shadow_distance, shadow_resolution),
            .shadow_cascade_2 => RenderGraph.executeShadowPass(2, rhi, world, camera, aspect, sky_params.sun_dir, shadow_distance, shadow_resolution),
            .main_opaque => RenderGraph.executeMainPass(rhi, world, camera, aspect, main_shader, atlas_handle),
            .main_transparent => {},
            .sky => RenderGraph.executeSkyPass(rhi, camera, aspect, sky_params),
            .clouds => RenderGraph.executeCloudsPass(rhi, camera, aspect, cloud_params),
            .ui => {},
            .post_process => {},
        }
    }

    fn executeShadowPass(cascade_idx: usize, rhi: RHI, world: *World, camera: *Camera, aspect: f32, light_dir: Vec3, shadow_distance: f32, shadow_resolution: u32) void {
        var light_space_matrix = Mat4.identity;

        const cascades = CSM.computeCascades(
            shadow_resolution,
            camera.fov,
            aspect,
            0.1,
            shadow_distance,
            light_dir,
            camera.getViewMatrixOriginCentered(),
            true,
        );
        light_space_matrix = cascades.light_space_matrices[cascade_idx];

        // Update shadow uniforms UBO (binding 2)
        rhi.updateShadowUniforms(.{
            .light_space_matrices = cascades.light_space_matrices,
            .cascade_splits = cascades.cascade_splits,
            .shadow_texel_sizes = cascades.texel_sizes,
        });

        // Start the shadow pass BEFORE updating global uniforms for the shadow pass matrix.
        // This ensures updateGlobalUniforms detects shadow_pass_active=true and sets the matrix
        // without overwriting the global UBO (which holds the main camera view_proj).
        rhi.beginShadowPass(@intCast(cascade_idx));

        rhi.updateGlobalUniforms(light_space_matrix, camera.position, Vec3.zero, 0, Vec3.zero, 0, false, 0, 0, false, .{});

        // renderShadowPass uses the bound pipeline/shader with the matrix we just set
        world.renderShadowPass(light_space_matrix, camera.position);
        rhi.endShadowPass();
    }

    fn executeMainPass(rhi: RHI, world: *World, camera: *Camera, aspect: f32, shader: rhi_pkg.ShaderHandle, atlas_handle: rhi_pkg.TextureHandle) void {
        rhi.bindShader(shader);
        rhi.bindTexture(atlas_handle, 1);
        // rhi.beginMainPass() is now called in execute() to prevent clearing sky
        const view_proj = Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered());
        world.render(view_proj, camera.position);
    }

    fn executeSkyPass(rhi: RHI, camera: *Camera, aspect: f32, params: rhi_pkg.SkyParams) void {
        _ = aspect;
        _ = camera;
        rhi.drawSky(params);
    }

    fn executeCloudsPass(rhi: RHI, camera: *Camera, aspect: f32, params: rhi_pkg.CloudParams) void {
        // Use reverse-Z projection for Vulkan to match the depth buffer setup
        const view_proj = Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered());

        var final_params = params;
        final_params.view_proj = view_proj;
        final_params.cam_pos = camera.position;

        rhi.drawClouds(final_params);
    }
};
