const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;

const GpuPass = enum {
    shadow_0,
    shadow_1,
    shadow_2,
    shadow_3,
    g_pass,
    ssao,
    lpv_compute,
    sky,
    opaque_pass,
    bloom,
    fxaa,
    post_process,

    pub const COUNT = 12;
};

pub const PASS_COUNT = GpuPass.COUNT;
pub const QUERY_COUNT_PER_FRAME = GpuPass.COUNT * 2;

fn mapPassName(name: []const u8) ?GpuPass {
    if (std.mem.eql(u8, name, "ShadowPass0")) return .shadow_0;
    if (std.mem.eql(u8, name, "ShadowPass1")) return .shadow_1;
    if (std.mem.eql(u8, name, "ShadowPass2")) return .shadow_2;
    if (std.mem.eql(u8, name, "ShadowPass3")) return .shadow_3;
    if (std.mem.eql(u8, name, "GPass")) return .g_pass;
    if (std.mem.eql(u8, name, "SSAOPass")) return .ssao;
    if (std.mem.eql(u8, name, "LPVPass")) return .lpv_compute;
    if (std.mem.eql(u8, name, "SkyPass")) return .sky;
    if (std.mem.eql(u8, name, "OpaquePass")) return .opaque_pass;
    if (std.mem.eql(u8, name, "BloomPass")) return .bloom;
    if (std.mem.eql(u8, name, "FXAAPass")) return .fxaa;
    if (std.mem.eql(u8, name, "PostProcessPass")) return .post_process;
    return null;
}

pub fn beginPassTiming(ctx: anytype, pass_name: []const u8) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    ctx.timing.pass_written[ctx.frames.current_frame][@intFromEnum(pass)] = true;
    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, ctx.timing.query_pool, query_index);
}

pub fn endPassTiming(ctx: anytype, pass_name: []const u8) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2 + 1;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, ctx.timing.query_pool, query_index);
}

pub fn resetFrameTiming(ctx: anytype, frame: usize) void {
    ctx.timing.pass_written[frame] = .{false} ** PASS_COUNT;
}

fn readPassMs(ctx: anytype, frame: usize, pass: GpuPass, period: f32) ?f32 {
    if (!ctx.timing.pass_written[frame][@intFromEnum(pass)]) return 0.0;

    const query_index = frame * QUERY_COUNT_PER_FRAME + @as(usize, @intFromEnum(pass)) * 2;
    var results: [2]u64 = .{ 0, 0 };
    const res = c.vkGetQueryPoolResults(
        ctx.vulkan_device.vk_device,
        ctx.timing.query_pool,
        @intCast(query_index),
        results.len,
        @sizeOf(@TypeOf(results)),
        &results,
        @sizeOf(u64),
        c.VK_QUERY_RESULT_64_BIT,
    );

    if (res != c.VK_SUCCESS) return null;
    return @as(f32, @floatFromInt(results[1] -% results[0])) * period / 1e6;
}

pub fn processTimingResults(ctx: anytype) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;
    if (ctx.runtime.frame_index < rhi.MAX_FRAMES_IN_FLIGHT) return;

    const frame = ctx.frames.current_frame;
    const period = ctx.vulkan_device.timestamp_period;

    const shadow_0 = readPassMs(ctx, frame, .shadow_0, period) orelse return;
    const shadow_1 = readPassMs(ctx, frame, .shadow_1, period) orelse return;
    const shadow_2 = readPassMs(ctx, frame, .shadow_2, period) orelse return;
    const shadow_3 = readPassMs(ctx, frame, .shadow_3, period) orelse return;
    const g_pass = readPassMs(ctx, frame, .g_pass, period) orelse return;
    const ssao = readPassMs(ctx, frame, .ssao, period) orelse return;
    const lpv = readPassMs(ctx, frame, .lpv_compute, period) orelse return;
    const sky = readPassMs(ctx, frame, .sky, period) orelse return;
    const opaque_ms = readPassMs(ctx, frame, .opaque_pass, period) orelse return;
    const bloom = readPassMs(ctx, frame, .bloom, period) orelse return;
    const fxaa = readPassMs(ctx, frame, .fxaa, period) orelse return;
    const post_process = readPassMs(ctx, frame, .post_process, period) orelse return;

    ctx.timing.timing_results.shadow_pass_ms[0] = shadow_0;
    ctx.timing.timing_results.shadow_pass_ms[1] = shadow_1;
    ctx.timing.timing_results.shadow_pass_ms[2] = shadow_2;
    ctx.timing.timing_results.shadow_pass_ms[3] = shadow_3;
    ctx.timing.timing_results.g_pass_ms = g_pass;
    ctx.timing.timing_results.ssao_pass_ms = ssao;
    ctx.timing.timing_results.lpv_pass_ms = lpv;
    ctx.timing.timing_results.sky_pass_ms = sky;
    ctx.timing.timing_results.opaque_pass_ms = opaque_ms;
    ctx.timing.timing_results.bloom_pass_ms = bloom;
    ctx.timing.timing_results.fxaa_pass_ms = fxaa;
    ctx.timing.timing_results.post_process_pass_ms = post_process;

    ctx.timing.timing_results.main_pass_ms = ctx.timing.timing_results.sky_pass_ms + ctx.timing.timing_results.opaque_pass_ms;
    ctx.timing.timing_results.validate();

    ctx.timing.timing_results.total_gpu_ms = 0;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[0];
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[1];
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[2];
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[3];
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.g_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.ssao_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.lpv_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.main_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.bloom_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.fxaa_pass_ms;
    ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.post_process_pass_ms;
}
