const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Rect = Theme.Rect;
const Color = Theme.Color;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const seed_gen = @import("game-core").seed;
const text_input = @import("game-core").text_input;
const log = @import("engine-core").log;
const registry = @import("world-worldgen").registry;
const WorldScreen = @import("world.zig").WorldScreen;
const wizard = @import("singleplayer_wizard.zig");
const world_save = @import("world_save.zig");

pub const SingleplayerScreen = struct {
    context: EngineContext,
    step: wizard.Step,
    details_field: wizard.DetailsField,
    seed_input: std.ArrayListUnmanaged(u8),
    name_input: std.ArrayListUnmanaged(u8),
    selected_generator_index: usize,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*SingleplayerScreen {
        const self = try allocator.create(SingleplayerScreen);
        self.* = .{
            .context = context,
            .step = .details,
            .details_field = .name,
            .seed_input = .empty,
            .name_input = .empty,
            .selected_generator_index = 0,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.seed_input.deinit(self.context.allocator);
        self.name_input.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        const ctx = self.context;
        const input = ctx.input;

        if (ctx.input_mapper.isActionPressed(input, .ui_back)) {
            self.goBack();
            return;
        }

        switch (self.step) {
            .details => {
                if (input.isKeyPressed(.tab)) self.details_field = wizard.nextField(self.details_field);
                if (self.details_field == .name) {
                    try text_input.handleTextTyping(&self.name_input, ctx.allocator, input, 32);
                } else {
                    try text_input.handleTextTyping(&self.seed_input, ctx.allocator, input, 32);
                }
            },
            .terrain => {
                const generator_count = registry.getGeneratorCount();
                const scale = Theme.scaleFor(@floatFromInt(input.getWindowHeight()), ctx.settings.ui_scale);
                const columns: usize = if (@as(f32, @floatFromInt(input.getWindowWidth())) >= 920.0 * scale) 2 else 1;
                if (input.isKeyPressed(.tab)) self.selected_generator_index = wizard.nextGenerator(self.selected_generator_index, generator_count);
                if (input.isKeyPressed(.left_arrow)) self.selected_generator_index = wizard.moveGenerator(self.selected_generator_index, generator_count, columns, .left);
                if (input.isKeyPressed(.right_arrow)) self.selected_generator_index = wizard.moveGenerator(self.selected_generator_index, generator_count, columns, .right);
                if (input.isKeyPressed(.up)) self.selected_generator_index = wizard.moveGenerator(self.selected_generator_index, generator_count, columns, .up);
                if (input.isKeyPressed(.down)) self.selected_generator_index = wizard.moveGenerator(self.selected_generator_index, generator_count, columns, .down);
            },
            .review => {},
        }

        if (ctx.input_mapper.isActionPressed(input, .ui_confirm)) try self.confirmStep();
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        try ctx.screen_manager.drawBackgroundFor(ptr, ui);

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mx: f32 = @floatFromInt(mouse_pos.x);
        const my: f32 = @floatFromInt(mouse_pos.y);
        const clicked = ctx.input.isMouseButtonPressed(.left);
        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const scale = Theme.scaleFor(screen_h, ctx.settings.ui_scale);
        Theme.drawBackdrop(ui, screen_w, screen_h, scale, .create);

        const margin = 32.0 * scale;
        const frame_w = @min(screen_w - margin * 2.0, 980.0 * scale);
        const frame_h = @min(screen_h - margin * 2.0, 700.0 * scale);
        const frame_x = (screen_w - frame_w) * 0.5;
        const frame_y = (screen_h - frame_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = frame_x, .y = frame_y, .width = frame_w, .height = frame_h }, scale, "NEW WORLD", "CREATE WORLD", stepSubtitle(self.step));

        const progress_h = 58.0 * scale;
        drawProgress(ui, .{ .x = shell.content.x, .y = shell.content.y, .width = shell.content.width, .height = progress_h }, self.step, scale);
        const body = Rect{
            .x = shell.content.x,
            .y = shell.content.y + progress_h + 18.0 * scale,
            .width = shell.content.width,
            .height = shell.content.height - progress_h - 18.0 * scale,
        };
        const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;

        switch (self.step) {
            .details => try self.drawDetails(ui, body, mx, my, clicked, cursor_visible, scale),
            .terrain => self.drawTerrain(ui, body, mx, my, clicked, scale),
            .review => self.drawReview(ui, body, scale),
        }

        const button_h = 46.0 * scale;
        const button_w = 156.0 * scale;
        const back_label: []const u8 = if (self.step == .details) "CANCEL" else "BACK";
        if (Theme.drawButton(ui, .{ .x = shell.content.x, .y = shell.footer_y, .width = button_w, .height = button_h }, back_label, 1.06 * scale, mx, my, clicked, .ghost, scale)) self.goBack();

        const confirm_label: []const u8 = if (self.step == .review) "CREATE WORLD" else "CONTINUE";
        const confirm_w: f32 = if (self.step == .review) 190.0 * scale else button_w;
        if (Theme.drawButton(ui, .{ .x = shell.content.x + shell.content.width - confirm_w, .y = shell.footer_y, .width = confirm_w, .height = button_h }, confirm_label, 1.06 * scale, mx, my, clicked, .primary, scale)) try self.confirmStep();
    }

    fn drawDetails(self: *@This(), ui: *UISystem, body: Rect, mx: f32, my: f32, clicked: bool, cursor_visible: bool, scale: f32) !void {
        const content_w = @min(body.width, 720.0 * scale);
        const x = body.x + (body.width - content_w) * 0.5;
        var y = body.y + 10.0 * scale;
        Theme.drawSectionLabel(ui, x, y, "WORLD DETAILS", scale);
        y += 38.0 * scale;

        Font.drawText(ui, "WORLD NAME", x, y, 0.92 * scale, Theme.signal);
        y += 24.0 * scale;
        const name_rect = Rect{ .x = x, .y = y, .width = content_w, .height = 58.0 * scale };
        Theme.drawTextInput(ui, name_rect, self.name_input.items, "ENTER A WORLD NAME", 1.20 * scale, self.details_field == .name, cursor_visible, scale);
        y += 82.0 * scale;

        Font.drawText(ui, "SEED", x, y, 0.92 * scale, Theme.signal);
        y += 24.0 * scale;
        const random_w = 146.0 * scale;
        const seed_rect = Rect{ .x = x, .y = y, .width = content_w - random_w - 12.0 * scale, .height = 58.0 * scale };
        const random_rect = Rect{ .x = seed_rect.x + seed_rect.width + 12.0 * scale, .y = y, .width = random_w, .height = seed_rect.height };
        Theme.drawTextInput(ui, seed_rect, self.seed_input.items, "LEAVE BLANK FOR RANDOM", 1.04 * scale, self.details_field == .seed, cursor_visible, scale);
        if (Theme.drawButton(ui, random_rect, "RANDOMIZE", 0.94 * scale, mx, my, clicked, .secondary, scale)) {
            try seed_gen.setSeedInput(&self.seed_input, self.context.allocator, seed_gen.randomSeedValue());
            self.details_field = .seed;
        }

        if (clicked) {
            if (name_rect.contains(mx, my)) self.details_field = .name;
            if (seed_rect.contains(mx, my)) self.details_field = .seed;
        }
        Font.drawText(ui, "TAB switches fields. A blank seed creates a new random world.", x, y + 76.0 * scale, 0.92 * scale, Theme.muted);
    }

    fn drawTerrain(self: *@This(), ui: *UISystem, body: Rect, mx: f32, my: f32, clicked: bool, scale: f32) void {
        const content_w = @min(body.width, 780.0 * scale);
        const x = body.x + (body.width - content_w) * 0.5;
        var y = body.y + 8.0 * scale;
        Theme.drawSectionLabel(ui, x, y, "CHOOSE TERRAIN", scale);
        y += 36.0 * scale;
        Font.drawText(ui, "Pick the generator that will shape this world.", x, y, 1.02 * scale, Theme.text);
        y += 34.0 * scale;

        const count = registry.getGeneratorCount();
        const columns: usize = if (content_w >= 700.0 * scale) 2 else 1;
        const gap = 12.0 * scale;
        const row_w = (content_w - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
        const row_h = 92.0 * scale;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const column = index % columns;
            const row = index / columns;
            const rect = Rect{
                .x = x + @as(f32, @floatFromInt(column)) * (row_w + gap),
                .y = y + @as(f32, @floatFromInt(row)) * (row_h + gap),
                .width = row_w,
                .height = row_h,
            };
            const hovered = rect.contains(mx, my);
            drawTerrainRow(ui, rect, registry.getGeneratorInfo(index), self.selected_generator_index == index, hovered, scale);
            if (clicked and hovered) self.selected_generator_index = index;
        }
    }

    fn drawReview(self: *@This(), ui: *UISystem, body: Rect, scale: f32) void {
        const content_w = @min(body.width, 720.0 * scale);
        const x = body.x + (body.width - content_w) * 0.5;
        var y = body.y + 8.0 * scale;
        Theme.drawSectionLabel(ui, x, y, "READY TO CREATE", scale);
        y += 40.0 * scale;
        const card = Rect{ .x = x, .y = y, .width = content_w, .height = @min(body.height - 48.0 * scale, 292.0 * scale) };
        Theme.drawListRail(ui, card, scale);
        const inner_x = card.x + 24.0 * scale;
        var fact_y = card.y + 24.0 * scale;
        drawReviewFact(ui, inner_x, fact_y, "WORLD NAME", wizard.displayWorldName(self.name_input.items), scale);
        fact_y += 72.0 * scale;
        drawReviewFact(ui, inner_x, fact_y, "TERRAIN", registry.getGeneratorInfo(self.selected_generator_index).name, scale);
        fact_y += 72.0 * scale;
        drawReviewFact(ui, inner_x, fact_y, "SEED", if (self.seed_input.items.len == 0) "Random on creation" else self.seed_input.items, scale);
        ui.drawRect(.{ .x = inner_x, .y = card.y + card.height - 54.0 * scale, .width = card.width - 48.0 * scale, .height = 1.0 * scale }, Color.rgba(Theme.signal.r, Theme.signal.g, Theme.signal.b, 0.24));
        Font.drawText(ui, "This world will be stored locally in My Worlds.", inner_x, card.y + card.height - 34.0 * scale, 0.94 * scale, Theme.muted);
    }

    fn goBack(self: *@This()) void {
        switch (wizard.backAction(self.step)) {
            .show => |step| self.step = step,
            .exit_wizard => self.context.screen_manager.popScreen(),
        }
    }

    fn confirmStep(self: *@This()) !void {
        switch (wizard.confirmAction(self.step)) {
            .show => |step| self.step = step,
            .create_world => try self.finishCreation(),
        }
    }

    fn finishCreation(self: *@This()) !void {
        const ctx = self.context;
        const seed = try seed_gen.resolveSeed(&self.seed_input, ctx.allocator);
        const world_name = wizard.displayWorldName(self.name_input.items);
        const generator = registry.getGeneratorInfo(self.selected_generator_index);
        log.log.info("World seed: {} | Type: {s} | Name: {s}", .{ seed, generator.name, world_name });
        const save_path = try world_save.saveNewWorld(ctx.allocator, seed, self.selected_generator_index, world_name);
        defer ctx.allocator.free(save_path);
        const world_screen = try WorldScreen.initPersistent(ctx.allocator, ctx, seed, self.selected_generator_index, save_path);
        errdefer world_screen.deinit(world_screen);
        ctx.screen_manager.setScreen(world_screen.screen());
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn stepSubtitle(step: wizard.Step) []const u8 {
    return switch (step) {
        .details => "Name the world and choose how its seed is generated.",
        .terrain => "Choose the terrain generator that fits this world.",
        .review => "Review the choices below before generating the world.",
    };
}

fn stepIndex(step: wizard.Step) usize {
    return switch (step) {
        .details => 0,
        .terrain => 1,
        .review => 2,
    };
}

fn drawProgress(ui: *UISystem, rect: Rect, active_step: wizard.Step, scale: f32) void {
    const labels = [_][]const u8{ "01  DETAILS", "02  TERRAIN", "03  REVIEW" };
    const gap = 8.0 * scale;
    const segment_w = (rect.width - gap * 2.0) / 3.0;
    const active_index = stepIndex(active_step);
    for (labels, 0..) |label, index| {
        const segment = Rect{ .x = rect.x + @as(f32, @floatFromInt(index)) * (segment_w + gap), .y = rect.y, .width = segment_w, .height = rect.height };
        const completed = index < active_index;
        const active = index == active_index;
        ui.drawRect(segment, if (active) Color.rgba(Theme.signal.r, Theme.signal.g, Theme.signal.b, 0.16) else Color.rgba(0, 0, 0, 0.16));
        ui.drawRect(.{ .x = segment.x, .y = segment.y + segment.height - 2.0 * scale, .width = segment.width, .height = 2.0 * scale }, if (active or completed) Theme.signal else Color.rgba(Theme.signal.r, Theme.signal.g, Theme.signal.b, 0.16));
        Font.drawTextCenteredFit(ui, label, segment.x + segment.width * 0.5, segment.y + 19.0 * scale, 0.88 * scale, segment.width - 16.0 * scale, if (active) Theme.title else if (completed) Theme.signal else Theme.muted);
    }
}

fn drawTerrainRow(ui: *UISystem, rect: Rect, info: anytype, selected: bool, hovered: bool, scale: f32) void {
    Theme.drawOptionRow(ui, rect, info.name, info.description, 1.12 * scale, selected or hovered, scale);
    if (selected) {
        const label = "SELECTED";
        const label_w = Font.measureTextWidth(label, 0.86 * scale);
        Font.drawText(ui, label, rect.x + rect.width - label_w - 16.0 * scale, rect.y + 17.0 * scale, 0.86 * scale, Theme.signal);
    }
}

fn drawReviewFact(ui: *UISystem, x: f32, y: f32, label: []const u8, value: []const u8, scale: f32) void {
    Font.drawText(ui, label, x, y, 0.90 * scale, Theme.signal);
    Font.drawText(ui, value, x, y + 24.0 * scale, 1.30 * scale, Theme.title);
}
