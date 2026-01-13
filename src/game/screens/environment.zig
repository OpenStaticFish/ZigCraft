const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Settings = @import("../state.zig").Settings;
const Texture = @import("../../engine/graphics/texture.zig").Texture;
const log = @import("../../engine/core/log.zig");

pub const EnvironmentScreen = struct {
    context: EngineContext,

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*EnvironmentScreen {
        const self = try allocator.create(EnvironmentScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *EnvironmentScreen = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *EnvironmentScreen = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.settings.save(self.context.allocator);
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *EnvironmentScreen = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const settings = ctx.settings;

        // Draw background screen if it exists
        if (ctx.screen_manager.stack.items.len > 1) {
            try ctx.screen_manager.stack.items[ctx.screen_manager.stack.items.len - 2].draw(ui);
        }

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);

        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * settings.ui_scale;
        const title_scale: f32 = 3.5 * ui_scale;
        const btn_scale: f32 = 2.0 * ui_scale;

        const pw: f32 = @min(screen_w * 0.75, 750.0 * ui_scale);
        const ph: f32 = @min(screen_h - 40.0, 800.0 * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.95));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0 * ui_scale);
        Font.drawTextCentered(ui, "ENVIRONMENT MAPS", screen_w * 0.5, py + 25.0 * ui_scale, title_scale, Color.white);

        var sy: f32 = py + 100.0 * ui_scale;
        const btn_width: f32 = pw - 100.0 * ui_scale;
        const btn_height: f32 = 50.0 * ui_scale;
        const btn_x: f32 = px + 50.0 * ui_scale;

        // Default (None) button
        const is_default = std.mem.eql(u8, settings.environment_map, "default");
        const def_label = if (is_default) "None (Default) [SELECTED]" else "None (Default)";

        if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, def_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (!is_default) {
                try settings.setEnvironmentMap(ctx.allocator, "default");
                try self.reloadEnvMap();
            }
        }
        sy += btn_height + 10.0 * ui_scale;

        // Scan for files
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        var buf: [128]u8 = undefined;

        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            const is_exr = std.mem.endsWith(u8, entry.name, ".exr");
            const is_hdr = std.mem.endsWith(u8, entry.name, ".hdr");
            if (!is_exr and !is_hdr) continue;

            if (is_hdr and std.mem.endsWith(u8, entry.name, ".exr.hdr")) continue;

            const is_selected = std.mem.eql(u8, settings.environment_map, entry.name);
            const label = try std.fmt.bufPrint(&buf, "{s}{s}", .{ entry.name, if (is_selected) " [SELECTED]" else "" });

            if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                if (!is_selected) {
                    try settings.setEnvironmentMap(ctx.allocator, entry.name);
                    try self.reloadEnvMap();
                }
            }
            sy += btn_height + 10.0 * ui_scale;

            if (sy > py + ph - 100.0 * ui_scale) break;
        }

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 70.0 * ui_scale, .width = 150.0 * ui_scale, .height = 50.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.save(ctx.allocator);
            ctx.screen_manager.popScreen();
        }
    }

    fn reloadEnvMap(self: *EnvironmentScreen) !void {
        const ctx = self.context;
        ctx.rhi.waitIdle();
        if (ctx.env_map.*) |*t| t.deinit();
        ctx.env_map.* = null;

        if (!std.mem.eql(u8, ctx.settings.environment_map, "default")) {
            if (ctx.resource_pack_manager.loadImageFileFloat(ctx.settings.environment_map)) |tex_data| {
                ctx.env_map.* = Texture.initFloat(ctx.rhi, tex_data.width, tex_data.height, tex_data.pixels);
                ctx.env_map.*.?.bind(9);
                log.log.info("Loaded Environment Map: {s}", .{ctx.settings.environment_map});
                var td = tex_data;
                td.deinit(ctx.allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{ctx.settings.environment_map});
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                ctx.env_map.* = Texture.initFloat(ctx.rhi, 1, 1, &white_pixel);
                ctx.env_map.*.?.bind(9);
            }
        } else {
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            ctx.env_map.* = Texture.initFloat(ctx.rhi, 1, 1, &white_pixel);
            ctx.env_map.*.?.bind(9);
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn onExit(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn screen(self: *EnvironmentScreen) IScreen {
        return .{
            .ptr = self,
            .vtable = &.{
                .deinit = deinit,
                .update = update,
                .draw = draw,
                .onEnter = onEnter,
                .onExit = onExit,
            },
        };
    }
};
