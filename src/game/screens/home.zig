const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const SingleplayerScreen = @import("singleplayer.zig").SingleplayerScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const ResourcePacksScreen = @import("resource_packs.zig").ResourcePacksScreen;
const EnvironmentScreen = @import("environment.zig").EnvironmentScreen;

const TITLE_COLOR = Color.rgba(0.95, 0.96, 0.98, 1.0);
const BUTTON_WIDTH_MAX = 450.0;
const BUTTON_HEIGHT_BASE = 60.0;
const BUTTON_SPACING_BASE = 18.0;

pub const HomeScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*HomeScreen {
        const self = try allocator.create(HomeScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);

        // Scale UI based on screen height for better readability at high resolutions
        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * ctx.settings.ui_scale;
        const title_scale: f32 = 5.0 * ui_scale;
        const btn_scale: f32 = 2.8 * ui_scale;
        const btn_height: f32 = BUTTON_HEIGHT_BASE * ui_scale;
        const btn_spacing: f32 = BUTTON_SPACING_BASE * ui_scale;

        Font.drawTextCentered(ui, "ZIG VOXEL ENGINE", screen_w * 0.5, screen_h * 0.16, title_scale, TITLE_COLOR);
        const bw: f32 = @min(screen_w * 0.5, BUTTON_WIDTH_MAX * ui_scale);
        const bx: f32 = (screen_w - bw) * 0.5;
        var by: f32 = screen_h * 0.4;

        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SINGLEPLAYER", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const sp_screen = try SingleplayerScreen.init(ctx.allocator, ctx);
            errdefer sp_screen.deinit(sp_screen);
            ctx.screen_manager.pushScreen(sp_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "TEXTURE PACKS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const rp_screen = try ResourcePacksScreen.init(ctx.allocator, ctx);
            errdefer rp_screen.deinit(rp_screen);
            ctx.screen_manager.pushScreen(rp_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "ENVIRONMENT", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const env_screen = try EnvironmentScreen.init(ctx.allocator, ctx);
            errdefer env_screen.deinit(env_screen);
            ctx.screen_manager.pushScreen(env_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            errdefer settings_screen.deinit(settings_screen);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "QUIT", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.input.should_quit = true;
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
