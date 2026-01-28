const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Rect = @import("../../engine/ui/ui_system.zig").Rect;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const seed_gen = @import("../seed.zig");
const log = @import("../../engine/core/log.zig");
const Key = @import("../../engine/core/interfaces.zig").Key;
const IRawInputProvider = @import("../../engine/input/interfaces.zig").IRawInputProvider;
const Input = @import("../../engine/input/input.zig").Input;
const WorldScreen = @import("world.zig").WorldScreen;
const registry = @import("../../world/worldgen/registry.zig");
const gen_interface = @import("../../world/worldgen/generator_interface.zig");

const PANEL_WIDTH_MAX = 650.0;
const PANEL_HEIGHT_BASE = 400.0;
const BG_COLOR = Color.rgba(0.12, 0.14, 0.18, 0.92);
const BORDER_COLOR = Color.rgba(0.28, 0.33, 0.42, 1.0);
const TITLE_COLOR = Color.rgba(0.92, 0.94, 0.97, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.78, 0.86, 1.0);

pub const SingleplayerScreen = struct {
    context: EngineContext,
    seed_input: std.ArrayListUnmanaged(u8),
    seed_focused: bool,
    selected_generator_index: usize,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*SingleplayerScreen {
        const self = try allocator.create(SingleplayerScreen);
        self.* = .{
            .context = context,
            .seed_input = std.ArrayListUnmanaged(u8).empty,
            .seed_focused = true,
            .selected_generator_index = 0,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.seed_input.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.screen_manager.popScreen();
            return;
        }

        if (self.seed_focused) {
            try handleSeedTyping(&self.seed_input, self.context.allocator, self.context.input, 32);
        }
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

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());

        // Scale UI based on screen height
        const ui_scale: f32 = @max(1.0, screen_h / 720.0);
        const title_scale: f32 = 3.5 * ui_scale;
        const label_scale: f32 = 2.5 * ui_scale;
        const btn_scale: f32 = 2.2 * ui_scale;
        const input_scale: f32 = 2.5 * ui_scale;

        const pw: f32 = @min(screen_w * 0.7, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = PANEL_HEIGHT_BASE * ui_scale;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = screen_h * 0.24;
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawTextCentered(ui, "CREATE WORLD", screen_w * 0.5, py + 22.0 * ui_scale, title_scale, TITLE_COLOR);
        const ly: f32 = py + 90.0 * ui_scale;
        Font.drawText(ui, "SEED", px + 30.0 * ui_scale, ly, label_scale, LABEL_COLOR);
        const ih: f32 = 52.0 * ui_scale;
        const iy: f32 = ly + 28.0 * ui_scale;
        const rw: f32 = 150.0 * ui_scale;
        const iw: f32 = pw - 30.0 * ui_scale - rw - 15.0 * ui_scale - 30.0 * ui_scale;
        const ix: f32 = px + 30.0 * ui_scale;
        const rx: f32 = ix + iw + 15.0 * ui_scale;
        const seed_rect = Rect{ .x = ix, .y = iy, .width = iw, .height = ih };
        const random_rect = Rect{ .x = rx, .y = iy, .width = rw, .height = ih };
        if (mouse_clicked) self.seed_focused = seed_rect.contains(mouse_x, mouse_y);

        const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
        Widgets.drawTextInput(ui, seed_rect, self.seed_input.items, "LEAVE BLANK FOR RANDOM", input_scale, self.seed_focused, cursor_visible);

        if (Widgets.drawButton(ui, random_rect, "RANDOM", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const gen = seed_gen.randomSeedValue();
            try seed_gen.setSeedInput(&self.seed_input, ctx.allocator, gen);
            self.seed_focused = true;
        }

        const gy: f32 = iy + ih + 20.0 * ui_scale;
        Font.drawText(ui, "WORLD TYPE", px + 30.0 * ui_scale, gy, label_scale, LABEL_COLOR);
        const g_rect = Rect{ .x = px + 30.0 * ui_scale, .y = gy + 28.0 * ui_scale, .width = pw - 60.0 * ui_scale, .height = ih };
        const g_info = registry.getGeneratorInfo(self.selected_generator_index);
        var g_label_buf: [128]u8 = undefined;
        const g_label = try std.fmt.bufPrint(&g_label_buf, "{s} ({}/{})", .{ g_info.name, self.selected_generator_index + 1, registry.getGeneratorCount() });
        if (Widgets.drawButton(ui, g_rect, g_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            self.selected_generator_index = (self.selected_generator_index + 1) % registry.getGeneratorCount();
        }
        Font.drawText(ui, g_info.description, px + 30.0 * ui_scale, g_rect.y + g_rect.height + 10.0 * ui_scale, label_scale * 0.7, LABEL_COLOR);

        const byy: f32 = py + ph - 80.0 * ui_scale;
        const hw: f32 = (pw - 30.0 * ui_scale - 15.0 * ui_scale - 30.0 * ui_scale) / 2.0;
        const btn_h: f32 = 50.0 * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = px + 30.0 * ui_scale, .y = byy, .width = hw, .height = btn_h }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.screen_manager.popScreen();
        }
        if (Widgets.drawButton(ui, .{ .x = px + 30.0 * ui_scale + hw + 15.0 * ui_scale, .y = byy, .width = hw, .height = btn_h }, "CREATE", btn_scale, mouse_x, mouse_y, mouse_clicked) or ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm)) {
            // Seed is a 64-bit unsigned integer. If left blank, a random one is generated.
            const seed = try seed_gen.resolveSeed(&self.seed_input, ctx.allocator);
            log.log.info("World seed: {} | Type: {s}", .{ seed, registry.getGeneratorInfo(self.selected_generator_index).name });
            const world_screen = try WorldScreen.init(ctx.allocator, ctx, seed, self.selected_generator_index);
            errdefer world_screen.deinit(world_screen);
            ctx.screen_manager.setScreen(world_screen.screen());
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn handleSeedTyping(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: IRawInputProvider, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (seed_input.items.len > 0) _ = seed_input.pop();
    }
    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);
    const letters = [_]Key{ .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z };
    inline for (letters) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) {
        var ch: u8 = @intCast(@intFromEnum(key));
        if (shift) ch = std.ascii.toUpper(ch);
        try seed_input.append(allocator, ch);
    };
    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) try seed_input.append(allocator, @intCast(@intFromEnum(key)));
    if (input.isKeyPressed(.space) and seed_input.items.len < max_len) try seed_input.append(allocator, ' ');
}
