const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const rhi = @import("engine-rhi").rhi;
const RenderDeviceStats = @import("engine-rhi").render_device.Stats;
const font = @import("font.zig");

pub const TimingOverlay = struct {
    enabled: bool = false,

    pub fn draw(self: *TimingOverlay, ui: *UISystem, data: PerformanceData) void {
        if (!self.enabled) return;

        const x: f32 = 12;
        var y: f32 = 12;
        const width: f32 = 360;
        const line_height: f32 = 15;
        const scale: f32 = 1.0;
        const label_x = x + 14;
        const value_x = x + width - 14;

        comptime std.debug.assert(rhi.SHADOW_CASCADE_COUNT >= 3);

        var num_lines: f32 = 2 + 1 + 12 + 1 + 6 + 1 + 4 + 1;
        if (data.world != null) {
            num_lines += 1 + 6;
        }
        const padding: f32 = 25;

        const panel_h = num_lines * line_height + padding;
        drawPanel(ui, x, y, width, panel_h);
        y += 10;

        drawSectionHeader(ui, "PERFORMANCE", label_x, &y, scale, Color.rgba(1.0, 0.93, 0.76, 1.0));
        {
            var buf: [32]u8 = undefined;
            const cpu_str = std.fmt.bufPrint(&buf, "CPU: {d:.2}MS  FPS: {d:.0}", .{ data.cpu_frame_ms, data.fps }) catch "";
            font.drawText(ui, cpu_str, label_x, y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
            y += line_height + 3;
        }
        if (data.resolution_scale < 0.999) {
            var scale_buf: [32]u8 = undefined;
            const scale_str = std.fmt.bufPrint(&scale_buf, "RES SCALE: {d:.0}%", .{data.resolution_scale * 100.0}) catch "";
            font.drawText(ui, scale_str, x + 10, y, scale, Color.rgba(1.0, 0.7, 0.3, 1.0));
            y += line_height + 3;
        }

        const muted = Color.rgba(0.62, 0.74, 0.84, 0.92);
        drawSectionHeader(ui, "GPU PASSES (MS)", label_x, &y, scale, Color.rgba(0.44, 0.76, 0.94, 1.0));
        drawGpuLine(ui, "SHADOW 0:", data.gpu.shadow_pass_ms[0], label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "SHADOW 1:", data.gpu.shadow_pass_ms[1], label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "SHADOW 2:", data.gpu.shadow_pass_ms[2], label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "SHADOW 3:", data.gpu.shadow_pass_ms[3], label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "G-PASS:", data.gpu.g_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "SSAO:", data.gpu.ssao_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "LPV:", data.gpu.lpv_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "SKY:", data.gpu.sky_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "OPAQUE:", data.gpu.opaque_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "MAIN:", data.gpu.main_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "BLOOM:", data.gpu.bloom_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "FXAA:", data.gpu.fxaa_pass_ms, label_x, value_x, &y, scale, muted);
        drawGpuLine(ui, "POST PROC:", data.gpu.post_process_pass_ms, label_x, value_x, &y, scale, muted);
        y += 3;
        drawGpuLine(ui, "TOTAL GPU:", data.gpu.total_gpu_ms, label_x, value_x, &y, scale, Color.rgba(1.0, 0.93, 0.76, 1.0));

        if (data.world) |ws| {
            drawSectionHeader(ui, "RENDER STATS", label_x, &y, scale, Color.rgba(0.44, 0.76, 0.94, 1.0));
            drawStatLine(ui, "CHUNKS:", ws.chunks_rendered, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
            drawStatLine(ui, "CHUNKS T:", ws.chunks_total, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
            drawStatLine(ui, "CULLED:", ws.chunks_culled, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
            drawStatLine(ui, "VERTS:", ws.vertices_rendered, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
            drawQueueLine(ui, "QUEUES:", ws.gen_queue, ws.mesh_queue, ws.upload_queue, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
        }

        drawSectionHeader(ui, "GPU MEMORY", label_x, &y, scale, Color.rgba(0.95, 0.62, 0.24, 1.0));
        drawMemoryLine(ui, "BUFS:", data.gpu_stats.buffer_count, data.gpu_stats.total_buffer_memory, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
        drawMemoryLine(ui, "TEX:", data.gpu_stats.texture_count, data.gpu_stats.total_texture_memory, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
        drawStatLine(ui, "SHADERS:", data.gpu_stats.shader_count, label_x, value_x, &y, scale, Color.rgba(0.92, 0.97, 1.0, 1.0));
    }

    fn drawPanel(ui: *UISystem, x: f32, y: f32, width: f32, height: f32) void {
        ui.drawRect(.{ .x = x, .y = y, .width = width, .height = height }, Color.rgba(0.010, 0.020, 0.030, 0.78));
        ui.drawRect(.{ .x = x, .y = y, .width = 5.0, .height = height }, Color.rgba(0.95, 0.62, 0.24, 0.92));
        ui.drawRect(.{ .x = x, .y = y, .width = width, .height = 28.0 }, Color.rgba(0.10, 0.20, 0.28, 0.62));
        ui.drawRectOutline(.{ .x = x, .y = y, .width = width, .height = height }, Color.rgba(0.42, 0.66, 0.82, 0.68), 1.0);
    }

    fn drawSectionHeader(ui: *UISystem, label: []const u8, x: f32, y: *f32, scale: f32, color: Color) void {
        font.drawText(ui, label, x, y.*, scale, color);
        y.* += 18;
    }

    fn drawGpuLine(ui: *UISystem, label: []const u8, value: f32, label_x: f32, right_x: f32, y: *f32, scale: f32, color: Color) void {
        font.drawText(ui, label, label_x, y.*, scale, color);
        if (value >= 0.0) {
            var buf: [16]u8 = undefined;
            const val_str = std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch "0.00";
            const val_w = font.measureTextWidth(val_str, scale);
            font.drawText(ui, val_str, right_x - val_w, y.*, scale, color);
        }
        y.* += 15;
    }

    fn drawStatLine(ui: *UISystem, label: []const u8, value: u64, label_x: f32, right_x: f32, y: *f32, scale: f32, color: Color) void {
        font.drawText(ui, label, label_x, y.*, scale, color);
        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
        const val_w = font.measureTextWidth(val_str, scale);
        font.drawText(ui, val_str, right_x - val_w, y.*, scale, color);
        y.* += 15;
    }

    fn drawQueueLine(ui: *UISystem, label: []const u8, g: usize, m: usize, u: usize, label_x: f32, right_x: f32, y: *f32, scale: f32, color: Color) void {
        font.drawText(ui, label, label_x, y.*, scale, color);
        var buf: [48]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d}/{d}/{d}", .{ g, m, u }) catch "";
        const val_w = font.measureTextWidth(val_str, scale);
        font.drawText(ui, val_str, right_x - val_w, y.*, scale, color);
        y.* += 15;
    }

    fn drawMemoryLine(ui: *UISystem, label: []const u8, count: u32, bytes: usize, label_x: f32, right_x: f32, y: *f32, scale: f32, color: Color) void {
        font.drawText(ui, label, label_x, y.*, scale, color);
        const mb = @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        var buf: [32]u8 = undefined;
        const val_str = std.fmt.bufPrint(&buf, "{d} ({d:.1}MB)", .{ count, mb }) catch "";
        const val_w = font.measureTextWidth(val_str, scale);
        font.drawText(ui, val_str, right_x - val_w, y.*, scale, color);
        y.* += 15;
    }

    pub fn toggle(self: *TimingOverlay) void {
        self.enabled = !self.enabled;
    }
};

pub const PerformanceData = struct {
    gpu: rhi.GpuTimingResults,
    cpu_frame_ms: f32,
    fps: f32,
    resolution_scale: f32 = 1.0,
    world: ?WorldStats,
    gpu_stats: RenderDeviceStats,
};

pub const WorldStats = struct {
    chunks_total: u32,
    chunks_rendered: u32,
    chunks_culled: u32,
    vertices_rendered: u64,
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};
