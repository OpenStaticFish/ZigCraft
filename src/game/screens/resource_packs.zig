const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Settings = @import("../state.zig").Settings;
const TextureAtlas = @import("../../engine/graphics/texture_atlas.zig").TextureAtlas;

const PANEL_WIDTH_MAX = 750.0;
const PANEL_HEIGHT_MAX = 800.0;
const BG_COLOR = Color.rgba(0.12, 0.14, 0.18, 0.95);
const BORDER_COLOR = Color.rgba(0.28, 0.33, 0.42, 1.0);

pub const ResourcePacksScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*ResourcePacksScreen {
        const self = try allocator.create(ResourcePacksScreen);
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
            self.context.saveSettings();
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const settings = ctx.settings;
        const manager = ctx.resource_pack_manager;

        // Draw background screen if it exists
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

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

        const pw: f32 = @min(screen_w * 0.75, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 40.0, PANEL_HEIGHT_MAX * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawTextCentered(ui, "RESOURCE PACKS", screen_w * 0.5, py + 25.0 * ui_scale, title_scale, Color.white);

        var sy: f32 = py + 100.0 * ui_scale;
        const btn_width: f32 = pw - 100.0 * ui_scale;
        const btn_height: f32 = 50.0 * ui_scale;
        const btn_x: f32 = px + 50.0 * ui_scale;

        // Default pack button
        const is_default = std.mem.eql(u8, settings.texture_pack, "default");
        const def_label = if (is_default) "Default (Built-in) [SELECTED]" else "Default (Built-in)";

        if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, def_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const prev_pack = settings.texture_pack;
            if (!std.mem.eql(u8, prev_pack, "default")) {
                try settings.setTexturePack(ctx.allocator, "default");
                try manager.setActivePack("default");
                try self.reloadAtlas();
            }
        }
        sy += btn_height + 10.0 * ui_scale;

        // Available packs
        const packs = manager.getPackNames();
        var buffer: [128]u8 = undefined;
        for (packs) |pack| {
            const is_selected = std.mem.eql(u8, settings.texture_pack, pack.name);
            const label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ pack.name, if (is_selected) " [SELECTED]" else "" });

            if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                if (!is_selected) {
                    try settings.setTexturePack(ctx.allocator, pack.name);
                    try manager.setActivePack(pack.name);
                    try self.reloadAtlas();
                }
            }
            sy += btn_height + 10.0 * ui_scale;
        }

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 70.0 * ui_scale, .width = 150.0 * ui_scale, .height = 50.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    fn reloadAtlas(self: *@This()) !void {
        const ctx = self.context;
        ctx.rhi.*.waitIdle();
        ctx.atlas.deinit();
        ctx.atlas.* = try TextureAtlas.init(ctx.allocator, ctx.rhi.*, ctx.resource_pack_manager, ctx.settings.max_texture_resolution);
        ctx.atlas.bind(1);
        ctx.atlas.bindNormal(6);
        ctx.atlas.bindRoughness(7);
        ctx.atlas.bindDisplacement(8);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
