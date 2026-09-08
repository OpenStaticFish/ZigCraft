const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const ShadowSystem = @import("shadow_system.zig").ShadowSystem;
const ShadowSystemWrapper = rhi.ShadowSystemWrapper;
const ShadowConfig = rhi.ShadowConfig;
const ShadowParams = rhi.ShadowParams;
const computeCascades = @import("csm.zig").computeCascades;
const ShadowCascades = @import("csm.zig").ShadowCascades;
const CASCADE_COUNT = @import("csm.zig").CASCADE_COUNT;
const IShadowContext = rhi.IShadowContext;

test "ShadowSystem beginPass rejects null render pass" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    try testing.expectEqual(@as(bool, false), sys.pass_active);
    sys.beginPass(null, 0, Mat4.identity);
    try testing.expectEqual(@as(bool, false), sys.pass_active);
}

test "ShadowSystem beginPass rejects out-of-bounds cascade index" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    try testing.expectEqual(@as(bool, false), sys.pass_active);
    sys.beginPass(null, rhi.SHADOW_CASCADE_COUNT, Mat4.identity);
    try testing.expectEqual(@as(bool, false), sys.pass_active);
}

test "ShadowSystem beginPass rejects null framebuffer" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = null;
    try testing.expectEqual(@as(bool, false), sys.pass_active);
    sys.beginPass(null, 0, Mat4.identity);
    try testing.expectEqual(@as(bool, false), sys.pass_active);
}

test "ShadowSystem beginPass rejects null command buffer before setting pass state" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = @ptrFromInt(1);
    sys.shadow_framebuffers[1] = @ptrFromInt(2);
    sys.shadow_framebuffers[2] = @ptrFromInt(3);
    sys.shadow_framebuffers[3] = @ptrFromInt(4);

    var light_matrix = Mat4.identity;
    light_matrix.data[0][0] = 5.0;

    sys.beginPass(null, 2, light_matrix);

    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);
    try testing.expectEqual(@as(f32, 1.0), sys.pass_matrix.data[0][0]);
    try testing.expect(!sys.pipeline_bound);
}

test "ShadowSystem beginPass leaves image layout unchanged for null command buffer" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = @ptrFromInt(1);
    sys.shadow_framebuffers[1] = @ptrFromInt(2);
    sys.shadow_framebuffers[2] = @ptrFromInt(3);
    sys.shadow_framebuffers[3] = @ptrFromInt(4);

    try testing.expectEqual(@as(u32, c.VK_IMAGE_LAYOUT_UNDEFINED), sys.shadow_image_layouts[0]);

    sys.beginPass(null, 1, Mat4.identity);

    try testing.expectEqual(@as(u32, c.VK_IMAGE_LAYOUT_UNDEFINED), sys.shadow_image_layouts[1]);
}

test "ShadowConfig default field values" {
    const cfg = ShadowConfig{};

    try testing.expectEqual(@as(f32, 250.0), cfg.distance);
    try testing.expectEqual(@as(u32, 4096), cfg.resolution);
    // The cascaded-shadow rewrite uses the supported nine-tap default.
    try testing.expectEqual(@as(u8, 9), cfg.pcf_samples);
    try testing.expect(cfg.cascade_blend);
    try testing.expectEqual(@as(f32, 0.35), cfg.strength);
    try testing.expectEqual(@as(f32, 250.0), cfg.caster_distance);
}

test "ShadowConfig custom field values" {
    const cfg = ShadowConfig{
        .distance = 500.0,
        .resolution = 8192,
        .pcf_samples = 16,
        .cascade_blend = false,
        .strength = 0.5,
        .caster_distance = 400.0,
    };

    try testing.expectEqual(@as(f32, 500.0), cfg.distance);
    try testing.expectEqual(@as(u32, 8192), cfg.resolution);
    try testing.expectEqual(@as(u8, 16), cfg.pcf_samples);
    try testing.expect(!cfg.cascade_blend);
    try testing.expectEqual(@as(f32, 0.5), cfg.strength);
    try testing.expectEqual(@as(f32, 400.0), cfg.caster_distance);
}

test "ShadowParams all cascade splits set correctly" {
    const params = ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
        .cascade_splits = .{ 25.0, 100.0, 300.0, 750.0 },
        .shadow_texel_sizes = .{ 0.25, 0.5, 1.0, 2.0 },
    };

    try testing.expectEqual(@as(f32, 25.0), params.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 100.0), params.cascade_splits[1]);
    try testing.expectEqual(@as(f32, 300.0), params.cascade_splits[2]);
    try testing.expectEqual(@as(f32, 750.0), params.cascade_splits[3]);
}

test "IShadowContext wrapper delegates beginPass" {
    const MockShadow = struct {
        call_count: *u32,
        last_cascade: *u32,
        last_matrix: *Mat4,

        fn beginPass(ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count.* += 1;
            self.last_cascade.* = cascade_index;
            self.last_matrix.* = light_space_matrix;
        }
        fn endPass(_: *anyopaque) void {}
        fn updateUniforms(_: *anyopaque, _: ShadowParams) anyerror!void {}
        fn getShadowMapHandle(_: *anyopaque, _: u32) rhi.TextureHandle {
            return 0;
        }
    };

    var call_count: u32 = 0;
    var last_cascade: u32 = 99;
    var last_matrix = Mat4.identity;

    var mock = MockShadow{
        .call_count = &call_count,
        .last_cascade = &last_cascade,
        .last_matrix = &last_matrix,
    };

    const vtable = IShadowContext.VTable{
        .beginPass = MockShadow.beginPass,
        .endPass = MockShadow.endPass,
        .updateUniforms = MockShadow.updateUniforms,
        .getShadowMapHandle = MockShadow.getShadowMapHandle,
    };

    const shadow_ctx = IShadowContext{ .ptr = &mock, .vtable = &vtable };

    var m = Mat4.identity;
    m.data[1][1] = 7.0;
    shadow_ctx.beginPass(3, m);

    try testing.expectEqual(@as(u32, 1), call_count);
    try testing.expectEqual(@as(u32, 3), last_cascade);
    try testing.expectEqual(@as(f32, 7.0), last_matrix.data[1][1]);
}

test "IShadowContext wrapper delegates endPass" {
    const MockShadow = struct {
        call_count: *u32,

        fn beginPass(_: *anyopaque, _: u32, _: Mat4) void {}
        fn endPass(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count.* += 1;
        }
        fn updateUniforms(_: *anyopaque, _: ShadowParams) anyerror!void {}
        fn getShadowMapHandle(_: *anyopaque, _: u32) rhi.TextureHandle {
            return 0;
        }
    };

    var call_count: u32 = 0;

    var mock = MockShadow{ .call_count = &call_count };

    const vtable = IShadowContext.VTable{
        .beginPass = MockShadow.beginPass,
        .endPass = MockShadow.endPass,
        .updateUniforms = MockShadow.updateUniforms,
        .getShadowMapHandle = MockShadow.getShadowMapHandle,
    };

    const shadow_ctx = IShadowContext{ .ptr = &mock, .vtable = &vtable };

    shadow_ctx.endPass();

    try testing.expectEqual(@as(u32, 1), call_count);
}

test "IShadowContext wrapper delegates updateUniforms" {
    const MockShadow = struct {
        call_count: *u32,
        received_params: *?ShadowParams,

        fn beginPass(_: *anyopaque, _: u32, _: Mat4) void {}
        fn endPass(_: *anyopaque) void {}
        fn updateUniforms(ptr: *anyopaque, params: ShadowParams) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.call_count.* += 1;
            self.received_params.* = params;
        }
        fn getShadowMapHandle(_: *anyopaque, _: u32) rhi.TextureHandle {
            return 0;
        }
    };

    var call_count: u32 = 0;
    var received_params: ?ShadowParams = null;

    var mock = MockShadow{
        .call_count = &call_count,
        .received_params = &received_params,
    };

    const vtable = IShadowContext.VTable{
        .beginPass = MockShadow.beginPass,
        .endPass = MockShadow.endPass,
        .updateUniforms = MockShadow.updateUniforms,
        .getShadowMapHandle = MockShadow.getShadowMapHandle,
    };

    const shadow_ctx = IShadowContext{ .ptr = &mock, .vtable = &vtable };

    const params = ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
        .cascade_splits = .{ 20.0, 80.0, 250.0, 600.0 },
        .shadow_texel_sizes = .{ 0.1, 0.2, 0.4, 0.8 },
    };

    try shadow_ctx.updateUniforms(params);

    try testing.expectEqual(@as(u32, 1), call_count);
    try testing.expect(received_params != null);
}

test "ShadowSystemWrapper forwards all operations" {
    const MockShadow = struct {
        begin_calls: *u32,
        end_calls: *u32,
        update_calls: *u32,
        last_cascade: *u32,

        fn beginPass(ptr: *anyopaque, cascade_index: u32, _: Mat4) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.begin_calls.* += 1;
            self.last_cascade.* = cascade_index;
        }
        fn endPass(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.end_calls.* += 1;
        }
        fn updateUniforms(ptr: *anyopaque, _: ShadowParams) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.update_calls.* += 1;
        }
        fn getShadowMapHandle(_: *anyopaque, cascade_index: u32) rhi.TextureHandle {
            return cascade_index + 100;
        }
    };

    var begin_calls: u32 = 0;
    var end_calls: u32 = 0;
    var update_calls: u32 = 0;
    var last_cascade: u32 = 99;

    var mock = MockShadow{
        .begin_calls = &begin_calls,
        .end_calls = &end_calls,
        .update_calls = &update_calls,
        .last_cascade = &last_cascade,
    };

    const vtable = IShadowContext.VTable{
        .beginPass = MockShadow.beginPass,
        .endPass = MockShadow.endPass,
        .updateUniforms = MockShadow.updateUniforms,
        .getShadowMapHandle = MockShadow.getShadowMapHandle,
    };

    const shadow_ctx = IShadowContext{ .ptr = &mock, .vtable = &vtable };
    const wrapper = ShadowSystemWrapper{ .ctx = shadow_ctx };

    wrapper.beginPass(2, Mat4.identity);
    try testing.expectEqual(@as(u32, 1), begin_calls);
    try testing.expectEqual(@as(u32, 2), last_cascade);

    wrapper.endPass();
    try testing.expectEqual(@as(u32, 1), end_calls);

    const params = ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
        .cascade_splits = .{ 5.0, 25.0, 100.0, 300.0 },
        .shadow_texel_sizes = .{ 0.3, 0.6, 1.2, 2.4 },
    };
    try wrapper.updateUniforms(params);
    try testing.expectEqual(@as(u32, 1), update_calls);

    const handle = wrapper.getShadowMapHandle(1);
    try testing.expectEqual(@as(rhi.TextureHandle, 101), handle);
}

test "ShadowSystem deinit resets all shadow image views to null" {
    var sys = try ShadowSystem.init(testing.allocator, 2048);
    defer sys.deinit(null);

    sys.shadow_image_views[0] = @ptrFromInt(1);
    sys.shadow_image_views[1] = @ptrFromInt(2);
    sys.shadow_image_views[2] = @ptrFromInt(3);
    sys.shadow_image_views[3] = @ptrFromInt(4);
    sys.shadow_framebuffers[0] = @ptrFromInt(10);
    sys.shadow_framebuffers[1] = @ptrFromInt(20);
    sys.shadow_framebuffers[2] = @ptrFromInt(30);
    sys.shadow_framebuffers[3] = @ptrFromInt(40);
    sys.shadow_sampler = @ptrFromInt(100);
    sys.shadow_sampler_regular = @ptrFromInt(200);

    sys.deinit(null);

    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_image_views[0]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_image_views[1]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_image_views[2]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_image_views[3]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_framebuffers[0]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_framebuffers[1]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_framebuffers[2]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_framebuffers[3]));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_sampler));
    try testing.expectEqual(@as(u32, 0), @intFromPtr(sys.shadow_sampler_regular));
}

test "ShadowSystem endPass resets pass_active to false" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = @ptrFromInt(1);
    sys.shadow_framebuffers[1] = @ptrFromInt(2);
    sys.shadow_framebuffers[2] = @ptrFromInt(3);
    sys.shadow_framebuffers[3] = @ptrFromInt(4);

    sys.pass_active = true;
    sys.pass_index = 1;
    try testing.expect(sys.pass_active);

    sys.endPass(null);
    try testing.expect(!sys.pass_active);
}

test "ShadowSystem endPass does not modify pass_index" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = @ptrFromInt(1);
    sys.shadow_framebuffers[1] = @ptrFromInt(2);
    sys.shadow_framebuffers[2] = @ptrFromInt(3);
    sys.shadow_framebuffers[3] = @ptrFromInt(4);

    sys.pass_active = true;
    sys.pass_index = 2;
    try testing.expectEqual(@as(u32, 2), sys.pass_index);

    sys.endPass(null);
    try testing.expectEqual(@as(u32, 2), sys.pass_index);
}

test "ShadowSystem endPass updates image layout to depth stencil read only optimal" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    sys.shadow_render_pass = @ptrFromInt(1);
    sys.shadow_framebuffers[0] = @ptrFromInt(1);
    sys.shadow_framebuffers[1] = @ptrFromInt(2);
    sys.shadow_framebuffers[2] = @ptrFromInt(3);
    sys.shadow_framebuffers[3] = @ptrFromInt(4);

    sys.pass_active = true;
    sys.pass_index = 3;
    sys.shadow_image_layouts[3] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    try testing.expectEqual(@as(u32, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL), sys.shadow_image_layouts[3]);

    sys.endPass(null);
    try testing.expectEqual(@as(u32, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL), sys.shadow_image_layouts[3]);
}

test "ShadowSystem endPass with inactive pass is no-op" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    try testing.expect(!sys.pass_active);

    sys.endPass(null);

    try testing.expect(!sys.pass_active);
}

test "computeCascades respects aspect ratio" {
    const cascades1 = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        true,
    );

    const cascades2 = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        4.0 / 3.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades1.isValid());
    try testing.expect(cascades2.isValid());

    var texel_sizes_same = true;
    for (0..CASCADE_COUNT) |i| {
        if (cascades1.texel_sizes[i] != cascades2.texel_sizes[i]) {
            texel_sizes_same = false;
            break;
        }
    }
    try testing.expect(!texel_sizes_same);
}

test "computeCascades returns valid cascades with far much larger than near" {
    const cascades = computeCascades(
        512,
        std.math.degreesToRadians(70.0),
        16.0 / 9.0,
        0.05,
        2000.0,
        Vec3.init(0.5, -0.866, 0.0).normalize(),
        Mat4.identity,
        false,
    );

    try testing.expect(cascades.isValid());
    for (0..CASCADE_COUNT) |i| {
        try testing.expect(cascades.cascade_splits[i] > 0.0);
        try testing.expect(cascades.texel_sizes[i] > 0.0);
    }
}
