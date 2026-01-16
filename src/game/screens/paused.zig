const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const HomeScreen = @import("home.zig").HomeScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;

const PAUSED_OVERLAY_ALPHA = 0.5;
const PAUSED_OVERLAY_COLOR = Color.rgba(0, 0, 0, PAUSED_OVERLAY_ALPHA);
const BUTTON_WIDTH = 300.0;
const BUTTON_HEIGHT = 48.0;
const BUTTON_SPACING = 16.0;

pub const PausedScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*PausedScreen {
        const self = try allocator.create(PausedScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        // Draw the world in the background (the screen below us in the stack)
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, PAUSED_OVERLAY_COLOR);
        const pw: f32 = BUTTON_WIDTH;
        const ph: f32 = BUTTON_HEIGHT;
        const px: f32 = (screen_w - pw) * 0.5;
        var py: f32 = screen_h * 0.35;
        Font.drawTextCentered(ui, "PAUSED", screen_w * 0.5, py - 60.0, 3.0, Color.white);

        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            ctx.screen_manager.popScreen();
        }
        py += ph + BUTTON_SPACING;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            errdefer settings_screen.deinit(settings_screen);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        py += ph + BUTTON_SPACING;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            const home_screen = try HomeScreen.init(ctx.allocator, ctx);
            errdefer home_screen.deinit(home_screen);
            ctx.screen_manager.setScreen(home_screen.screen());
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn onExit(ptr: *anyopaque) void {
        _ = ptr;
        // No longer capturing here, as the parent screen (World) will capture in its onEnter()
        // and child screens (Settings) don't want the mouse captured.
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
