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

pub const PausedScreen = struct {
    context: EngineContext,

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*PausedScreen {
        const self = try allocator.create(PausedScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *PausedScreen = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *PausedScreen = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *PausedScreen = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        // Draw the world in the background (the screen below us in the stack)
        if (ctx.screen_manager.stack.items.len > 1) {
            try ctx.screen_manager.stack.items[ctx.screen_manager.stack.items.len - 2].draw(ui);
        }

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
        const pw: f32 = 300.0;
        const ph: f32 = 48.0;
        const px: f32 = (screen_w - pw) * 0.5;
        var py: f32 = screen_h * 0.35;
        Font.drawTextCentered(ui, "PAUSED", screen_w * 0.5, py - 60.0, 3.0, Color.white);

        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            ctx.screen_manager.popScreen();
        }
        py += ph + 16.0;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        py += ph + 16.0;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
            const home_screen = try HomeScreen.init(ctx.allocator, ctx);
            ctx.screen_manager.setScreen(home_screen.screen());
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *PausedScreen = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn onExit(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn screen(self: *PausedScreen) IScreen {
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
