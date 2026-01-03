const std = @import("std");
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const RHI = @import("rhi.zig").RHI;
const rhi_pkg = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const ShadowMap = @import("shadows.zig").ShadowMap;

pub const RenderPass = enum {
    shadow_cascade_0,
    shadow_cascade_1,
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
        shadow_map: ?ShadowMap,
        is_vulkan: bool,
        aspect: f32,
        sky_params: rhi_pkg.SkyParams,
        cloud_params: rhi_pkg.CloudParams,
        main_shader: rhi_pkg.ShaderHandle,
        atlas_handle: rhi_pkg.TextureHandle,
    ) void {
        var main_pass_started = false;
        for (self.passes) |pass| {
            // Start main render pass (clears buffer) only once before the first non-shadow pass
            switch (pass) {
                .shadow_cascade_0, .shadow_cascade_1 => {},
                else => {
                    if (!main_pass_started) {
                        rhi.beginMainPass();
                        main_pass_started = true;
                    }
                },
            }
            self.executePass(pass, rhi, world, camera, shadow_map, is_vulkan, aspect, sky_params, cloud_params, main_shader, atlas_handle);
        }
    }

    fn executePass(
        self: *const RenderGraph,
        pass: RenderPass,
        rhi: RHI,
        world: *World,
        camera: *Camera,
        shadow_map: ?ShadowMap,
        is_vulkan: bool,
        aspect: f32,
        sky_params: rhi_pkg.SkyParams,
        cloud_params: rhi_pkg.CloudParams,
        main_shader: rhi_pkg.ShaderHandle,
        atlas_handle: rhi_pkg.TextureHandle,
    ) void {
        _ = self;
        switch (pass) {
            .shadow_cascade_0 => if (is_vulkan) RenderGraph.executeShadowPass(0, rhi, world, camera, shadow_map, is_vulkan, aspect, sky_params.sun_dir),
            .shadow_cascade_1 => if (is_vulkan) RenderGraph.executeShadowPass(1, rhi, world, camera, shadow_map, is_vulkan, aspect, sky_params.sun_dir),
            .main_opaque => RenderGraph.executeMainPass(rhi, world, camera, is_vulkan, aspect, main_shader, atlas_handle),
            .main_transparent => {},
            .sky => RenderGraph.executeSkyPass(rhi, camera, is_vulkan, aspect, sky_params),
            .clouds => RenderGraph.executeCloudsPass(rhi, camera, is_vulkan, aspect, cloud_params),
            .ui => {},
            .post_process => {},
        }
    }

    fn executeShadowPass(cascade_idx: usize, rhi: RHI, world: *World, camera: *Camera, shadow_map: ?ShadowMap, is_vulkan: bool, aspect: f32, light_dir: Vec3) void {
        var light_space_matrix = Mat4.identity;

        if (is_vulkan) {
            const cascades = ShadowMap.computeCascades(
                2048,
                camera.fov,
                aspect,
                0.1,
                200.0,
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
        } else if (shadow_map) |sm| {
            light_space_matrix = sm.light_space_matrices[cascade_idx];
            // OpenGL shadow pass is handled in app.zig or via ShadowMap struct,
            // but if we are here, we might want to do something?
            // Currently beginShadowPass is a no-op for OpenGL RHI.
            rhi.beginShadowPass(@intCast(cascade_idx));
        } else {
            return;
        }

        // renderShadowPass uses the bound pipeline/shader with the matrix we just set
        world.renderShadowPass(light_space_matrix, camera.position);
        rhi.endShadowPass();
    }

    fn executeMainPass(rhi: RHI, world: *World, camera: *Camera, is_vulkan: bool, aspect: f32, shader: rhi_pkg.ShaderHandle, atlas_handle: rhi_pkg.TextureHandle) void {
        // rhi.beginMainPass() is now called in execute() to prevent clearing sky
        if (!is_vulkan and shader != 0) {
            rhi.bindShader(shader);
            // Force update texture uniforms for OpenGL to ensure uUseTexture is set on the active shader
            rhi.setTextureUniforms(true, .{ 0, 0, 0 });
            // Re-bind atlas for OpenGL to ensure it's on unit 0
            if (atlas_handle != 0) rhi.bindTexture(atlas_handle, 0);
        }

        const view_proj = if (is_vulkan)
            Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered())
        else
            camera.getViewProjectionMatrixOriginCentered(aspect);
        world.render(view_proj, camera.position);
    }

    fn executeSkyPass(rhi: RHI, camera: *Camera, is_vulkan: bool, aspect: f32, params: rhi_pkg.SkyParams) void {
        _ = is_vulkan;
        _ = aspect;
        _ = camera;
        rhi.drawSky(params);
    }

    fn executeCloudsPass(rhi: RHI, camera: *Camera, is_vulkan: bool, aspect: f32, params: rhi_pkg.CloudParams) void {
        // Use reverse-Z projection for Vulkan to match the depth buffer setup
        const view_proj = if (is_vulkan)
            Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered())
        else
            camera.getViewProjectionMatrixOriginCentered(aspect);

        var final_params = params;
        final_params.view_proj = view_proj;
        final_params.cam_pos = camera.position;

        rhi.drawClouds(final_params);
    }
};
