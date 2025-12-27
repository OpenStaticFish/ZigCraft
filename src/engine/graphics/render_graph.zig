const std = @import("std");
const Camera = @import("camera.zig").Camera;
const World = @import("../../world/world.zig").World;
const RHI = @import("rhi.zig").RHI;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const ShadowMap = @import("shadows.zig").ShadowMap;

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
            .main_opaque,
            .sky,
            .clouds,
            .ui,
        };
        return .{
            .passes = default_passes,
        };
    }

    pub fn execute(self: *const RenderGraph, rhi: RHI, world: *World, camera: *Camera, shadow_map: ?ShadowMap, is_vulkan: bool, aspect: f32) void {
        for (self.passes) |pass| {
            self.executePass(pass, rhi, world, camera, shadow_map, is_vulkan, aspect);
        }
    }

    fn executePass(self: *const RenderGraph, pass: RenderPass, rhi: RHI, world: *World, camera: *Camera, shadow_map: ?ShadowMap, is_vulkan: bool, aspect: f32) void {
        _ = self;
        switch (pass) {
            .shadow_cascade_0 => RenderGraph.executeShadowPass(0, rhi, world, camera, shadow_map, is_vulkan, aspect),
            .shadow_cascade_1 => RenderGraph.executeShadowPass(1, rhi, world, camera, shadow_map, is_vulkan, aspect),
            .shadow_cascade_2 => RenderGraph.executeShadowPass(2, rhi, world, camera, shadow_map, is_vulkan, aspect),
            .main_opaque => RenderGraph.executeMainPass(rhi, world, camera, aspect),
            .main_transparent => {},
            .sky => RenderGraph.executeSkyPass(rhi, camera, aspect),
            .clouds => RenderGraph.executeCloudsPass(rhi, camera, is_vulkan, aspect),
            .ui => {},
            .post_process => {},
        }
    }

    fn executeShadowPass(cascade_idx: usize, rhi: RHI, world: *World, camera: *Camera, shadow_map: ?ShadowMap, is_vulkan: bool, aspect: f32) void {
        var light_space_matrix = Mat4.identity;
        const light_dir = Vec3.init(0, 1, 0);

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
            rhi.updateShadowUniforms(.{
                .light_space_matrices = cascades.light_space_matrices,
                .cascade_splits = cascades.cascade_splits,
                .shadow_texel_sizes = cascades.texel_sizes,
            });
        } else if (shadow_map) |sm| {
            light_space_matrix = sm.light_space_matrices[cascade_idx];
        } else {
            return;
        }

        rhi.beginShadowPass(@intCast(cascade_idx));
        world.renderShadowPass(light_space_matrix, camera.position);
        rhi.endShadowPass();
    }

    fn executeMainPass(rhi: RHI, world: *World, camera: *Camera, aspect: f32) void {
        rhi.beginMainPass();
        defer rhi.endMainPass();
        const view_proj = camera.getViewProjectionMatrixOriginCentered(aspect);
        world.render(view_proj, camera.position);
    }

    fn executeSkyPass(rhi: RHI, camera: *Camera, aspect: f32) void {
        rhi.drawSky(.{
            .cam_pos = camera.position,
            .cam_forward = camera.forward,
            .cam_right = camera.right,
            .cam_up = camera.up,
            .aspect = aspect,
            .tan_half_fov = @tan(camera.fov / 2.0),
            .sun_dir = Vec3.init(0, 1, 0),
            .sky_color = Vec3.init(0.4, 0.65, 1.0),
            .horizon_color = Vec3.init(0.7, 0.8, 0.95),
            .sun_intensity = 1.0,
            .moon_intensity = 0.0,
            .time = 0.25,
        });
    }

    fn executeCloudsPass(rhi: RHI, camera: *Camera, is_vulkan: bool, aspect: f32) void {
        // Use reverse-Z projection for Vulkan to match the depth buffer setup
        const view_proj = if (is_vulkan)
            Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered())
        else
            camera.getViewProjectionMatrixOriginCentered(aspect);
        rhi.drawClouds(.{
            .cam_pos = camera.position,
            .view_proj = view_proj,
            .sun_dir = Vec3.init(0, 1, 0),
            .sun_intensity = 1.0,
            .fog_color = Vec3.init(0.6, 0.75, 0.95),
            .fog_density = 0.0015,
            .wind_offset_x = 0.0,
            .wind_offset_z = 0.0,
            .cloud_scale = 1.0 / 64.0,
            .cloud_coverage = 0.5,
            .cloud_height = 160.0,
            .base_color = Vec3.init(1.0, 1.0, 1.0),
        });
    }
};
