const std = @import("std");

const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const hotbar = @import("hotbar.zig");
const region_pkg = @import("world-worldgen").region;
const worldToChunkFromFloat = @import("world-core").worldToChunkFromFloat;

const TELEMETRY_PANEL_Y: f32 = 50.0;
const TELEMETRY_ROW_OFFSET: f32 = 5.0;
const TELEMETRY_ROW_HEIGHT: f32 = 20.0;

const TelemetryRow = enum(u8) {
    position,
    chunks,
    visible,
    queued_gen,
    queued_mesh,
    pending_upload,
    time,
    sun,
    role,
    gpu_faults,
};

fn telemetryRowY(row: TelemetryRow) f32 {
    return TELEMETRY_PANEL_Y + TELEMETRY_ROW_OFFSET +
        @as(f32, @floatFromInt(@intFromEnum(row))) * TELEMETRY_ROW_HEIGHT;
}

fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
    const scale = 1.0 / 255.0;
    return Color.rgba(
        @as(f32, @floatFromInt(r)) * scale,
        @as(f32, @floatFromInt(g)) * scale,
        @as(f32, @floatFromInt(b)) * scale,
        @as(f32, @floatFromInt(a)) * scale,
    );
}

pub fn draw(session: anytype, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
    const world = session.world.interface();
    const telemetry = world.telemetry();

    if (session.map_controller.show_map) {
        try session.map_controller.draw(ui, screen_w, screen_h, &session.world_map, &session.world_map_texture, session.world, telemetry.getGenerator(), session.camera.position);
        return;
    }

    if (session.debug_show_fps) {
        ui.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
        Font.drawNumber(ui, @intFromFloat(fps), 15, 15, Color.white);

        const stats = telemetry.getStats();
        const rs = telemetry.getRenderStats();
        const pc = worldToChunkFromFloat(session.camera.position.x, session.camera.position.z);
        const fault_count = session.rhi.query().getFaultCount();
        const hud_h: f32 = if (fault_count > 0) 210 else 190;
        ui.drawRect(.{ .x = 10, .y = TELEMETRY_PANEL_Y, .width = 220, .height = hud_h }, Color.rgba(0, 0, 0, 0.6));
        Font.drawText(ui, "POS:", 15, telemetryRowY(.position), 1.5, Color.white);
        Font.drawNumber(ui, pc.chunk_x, 120, telemetryRowY(.position), Color.white);
        Font.drawNumber(ui, pc.chunk_z, 170, telemetryRowY(.position), Color.white);
        Font.drawText(ui, "CHUNKS:", 15, telemetryRowY(.chunks), 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.chunks_loaded), 140, telemetryRowY(.chunks), Color.white);
        Font.drawText(ui, "VISIBLE:", 15, telemetryRowY(.visible), 1.5, Color.white);
        Font.drawNumber(ui, @intCast(rs.chunks_rendered), 140, telemetryRowY(.visible), Color.white);

        Font.drawText(ui, "QUEUED GEN:", 15, telemetryRowY(.queued_gen), 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.gen_queue), 140, telemetryRowY(.queued_gen), Color.white);
        Font.drawText(ui, "QUEUED MESH:", 15, telemetryRowY(.queued_mesh), 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.mesh_queue), 140, telemetryRowY(.queued_mesh), Color.white);
        Font.drawText(ui, "PENDING UP:", 15, telemetryRowY(.pending_upload), 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.upload_queue), 140, telemetryRowY(.pending_upload), Color.white);
        const h = session.atmosphere.getHours();
        const hr = @as(i32, @intFromFloat(h));
        const mn = @as(i32, @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0));
        Font.drawText(ui, "TIME:", 15, telemetryRowY(.time), 1.5, Color.white);
        Font.drawNumber(ui, hr, 100, telemetryRowY(.time), Color.white);
        Font.drawText(ui, ":", 125, telemetryRowY(.time), 1.5, Color.white);
        Font.drawNumber(ui, mn, 140, telemetryRowY(.time), Color.white);
        Font.drawText(ui, "SUN:", 15, telemetryRowY(.sun), 1.5, Color.white);
        Font.drawNumber(ui, @intFromFloat(session.atmosphere.sun_intensity * 100.0), 100, telemetryRowY(.sun), Color.white);

        const px_i: i32 = @intFromFloat(session.camera.position.x);
        const pz_i: i32 = @intFromFloat(session.camera.position.z);
        const region = telemetry.getRegionInfo(px_i, pz_i);
        const c3 = region_pkg.getRoleColor(region.role);
        Font.drawText(ui, "ROLE:", 15, telemetryRowY(.role), 1.5, Color.rgba(c3[0], c3[1], c3[2], 1.0));
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}", .{@tagName(region.role)}) catch "???";
        Font.drawText(ui, label, 100, telemetryRowY(.role), 1.5, Color.white);

        if (fault_count > 0) {
            var buf_f: [32]u8 = undefined;
            const fault_text = std.fmt.bufPrint(&buf_f, "GPU FAULTS: {d}", .{fault_count}) catch "GPU FAULTS: ???";
            Font.drawText(ui, fault_text, 15, telemetryRowY(.gpu_faults), 1.5, Color.red);
        }
    }

    if (session.debug_show_block_info) {
        if (session.player.target_block) |target| {
            const block_type = telemetry.getBlock(target.x, target.y, target.z);
            const tiles = atlas.getTilesForBlock(@intFromEnum(block_type));
            const ux = screen_w - 390;
            var uy: f32 = 10;
            const panel_height: f32 = 130;
            ui.drawRect(.{ .x = ux - 10, .y = uy, .width = 390, .height = panel_height }, Color.rgba(0, 0, 0, 0.7));
            var buf2: [160]u8 = undefined;
            const pos_text = std.fmt.bufPrint(&buf2, "BLOCK: {s} FACE:{s} ({}, {}, {})", .{ @tagName(block_type), @tagName(target.face), target.x, target.y, target.z }) catch "BLOCK: ???";
            Font.drawText(ui, pos_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const face_offset = target.face.getOffset();
            const face_x = target.x + face_offset.x;
            const face_y = target.y + face_offset.y;
            const face_z = target.z + face_offset.z;
            const target_light = telemetry.getDebugLightInfo(target.x, target.y, target.z);
            const face_light = telemetry.getDebugLightInfo(face_x, face_y, face_z);
            const target_light_text = if (target_light) |l| std.fmt.bufPrint(&buf2, "TARGET S:{} B:{}", .{ l.sky, l.block }) catch "TARGET: ???" else "TARGET: missing";
            Font.drawText(ui, target_light_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const face_light_text = if (face_light) |l| std.fmt.bufPrint(&buf2, "FACE AIR S:{} B:{} ({}, {}, {})", .{ l.sky, l.block, face_x, face_y, face_z }) catch "FACE AIR: ???" else "FACE AIR: missing";
            Font.drawText(ui, face_light_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const tiles_text = std.fmt.bufPrint(&buf2, "TILES: T:{} B:{} S:{}", .{ tiles.top, tiles.bottom, tiles.side }) catch "TILES: ???";
            Font.drawText(ui, tiles_text, ux, uy + 5, 1.5, Color.white);
            uy += 25;
            const pack_name = if (active_pack) |ap| ap else "Default";
            const pack_text = std.fmt.bufPrint(&buf2, "PACK: {s}", .{pack_name}) catch "PACK: ???";
            Font.drawText(ui, pack_text, ux, uy + 5, 1.5, Color.white);
        }
    }

    if (!session.inventory_ui_state.visible) {
        const cx = screen_w / 2.0;
        const cy = screen_h / 2.0;
        ui.drawRect(.{ .x = cx - 10, .y = cy - 1, .width = 20, .height = 2 }, Color.white);
        ui.drawRect(.{ .x = cx - 1, .y = cy - 10, .width = 2, .height = 20 }, Color.white);
    }

    if (!session.inventory_ui_state.visible) hotbar.drawDefault(ui, &session.inventory, screen_w, screen_h);

    if (session.inventory_ui_state.visible) {
        const time_action = session.inventory_ui_state.draw(ui, &session.inventory, mouse_x, mouse_y, mouse_clicked, screen_w, screen_h);
        if (time_action) |time_idx| {
            const times = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
            if (time_idx < 4) session.atmosphere.setTimeOfDay(times[time_idx]);
        }
    }

    if (session.creative_mode) {
        Font.drawText(ui, "CREATIVE", screen_w - 100, 10, 1.5, rgba8(100, 200, 255, 200));
        if (session.player.fly_mode) Font.drawText(ui, "FLYING", screen_w - 80, 25, 1.5, rgba8(150, 255, 150, 200));
    }
}

test "telemetry rows do not overlap" {
    const testing = std.testing;

    try testing.expect(telemetryRowY(.sun) < telemetryRowY(.role));
    try testing.expect(telemetryRowY(.role) < telemetryRowY(.gpu_faults));
    try testing.expectEqual(@as(f32, 235.0), telemetryRowY(.role));
    try testing.expectEqual(@as(f32, 255.0), telemetryRowY(.gpu_faults));
}

test "rgba8 normalizes color channels" {
    const testing = std.testing;
    const color = rgba8(100, 200, 255, 200);

    try testing.expectApproxEqAbs(@as(f32, 100.0 / 255.0), color.r, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), color.g, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), color.b, 0.000_001);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), color.a, 0.000_001);
}
