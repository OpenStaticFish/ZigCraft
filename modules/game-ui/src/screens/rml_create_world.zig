//! RmlUi implementation of the three-step Create World wizard.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const registry = @import("world-worldgen").registry;
const seed_gen = @import("game-core").seed;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Page = @import("../rml_page.zig").Page;
const markup = @import("../rml_markup.zig");
const wizard = @import("singleplayer_wizard.zig");
const world_save = @import("world_save.zig");
const WorldScreen = @import("world.zig").WorldScreen;

pub const RmlCreateWorldScreen = struct {
    context: EngineContext,
    page: Page,
    step: wizard.Step = .details,
    selected_generator_index: usize = 0,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlCreateWorldScreen {
        const self = try allocator.create(RmlCreateWorldScreen);
        errdefer allocator.destroy(self);
        self.* = .{ .context = context, .page = undefined };
        self.page = try Page.init(context, "assets/ui/rmlui/create_world.rml", self, onDocumentAction);
        errdefer self.page.deinit();
        try self.render();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.deinit();
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) self.goBack();
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        self.page.draw(ui);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onEnter();
        self.render() catch |err| self.showError(err);
        if (self.step == .details) _ = self.page.backend.focus(self.page.document, "world-name", true);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onExit();
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }

    fn onDocumentAction(context: *anyopaque, event_type: []const u8, target_id: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, event_type, "change")) {
            // Input values are deliberately owned by RmlUi. They are read at
            // step boundaries so IME and cursor editing remain native controls.
            if (std.mem.eql(u8, target_id, "world-name") or std.mem.eql(u8, target_id, "world-seed")) return;
            return;
        }
        if (!std.mem.eql(u8, event_type, "click")) return;
        self.handleClick(target_id) catch |err| self.showError(err);
    }

    fn handleClick(self: *@This(), target_id: []const u8) !void {
        if (std.mem.eql(u8, target_id, "wizard-back")) {
            self.goBack();
            return;
        }
        if (std.mem.eql(u8, target_id, "wizard-continue")) {
            try self.confirmStep();
            return;
        }
        if (std.mem.eql(u8, target_id, "random-seed")) {
            try self.randomizeSeed();
            return;
        }
        if (std.mem.startsWith(u8, target_id, "terrain-")) {
            const index = std.fmt.parseInt(usize, target_id[8..], 10) catch return;
            if (index < registry.getGeneratorCount()) {
                self.selected_generator_index = index;
                try self.renderTerrainRows();
            }
        }
    }

    fn render(self: *@This()) !void {
        const active_index = stepIndex(self.step);
        _ = self.page.backend.setClass(self.page.document, "details-page", "active", self.step == .details);
        _ = self.page.backend.setClass(self.page.document, "terrain-page", "active", self.step == .terrain);
        _ = self.page.backend.setClass(self.page.document, "review-page", "active", self.step == .review);
        try self.setStepState("step-details", 0, active_index);
        try self.setStepState("step-terrain", 1, active_index);
        try self.setStepState("step-review", 2, active_index);
        _ = self.page.backend.setInnerRml(self.page.document, "wizard-subtitle", stepSubtitle(self.step));
        const back_label: [:0]const u8 = if (self.step == .details) "CANCEL" else "BACK";
        const continue_label: [:0]const u8 = if (self.step == .review) "CREATE WORLD" else "CONTINUE";
        _ = self.page.backend.setInnerRml(self.page.document, "wizard-back", back_label);
        _ = self.page.backend.setInnerRml(self.page.document, "wizard-continue", continue_label);
        _ = self.page.backend.setProperty(self.page.document, "wizard-continue", "min-width", if (self.step == .review) "190dp" else "156dp");
        _ = self.page.backend.setDisabled(self.page.document, "wizard-continue", registry.getGeneratorCount() == 0 and self.step != .details);
        try self.renderTerrainRows();
        if (self.step == .review) try self.renderReview();
    }

    fn setStepState(self: *@This(), id: [*:0]const u8, index: usize, active_index: usize) !void {
        _ = self.page.backend.setClass(self.page.document, id, "active", index == active_index);
        _ = self.page.backend.setClass(self.page.document, id, "complete", index < active_index);
    }

    fn renderTerrainRows(self: *@This()) !void {
        const count = registry.getGeneratorCount();
        if (count > 0 and self.selected_generator_index >= count) self.selected_generator_index = 0;

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.context.allocator);
        if (count == 0) {
            try out.appendSlice(self.context.allocator, "<p class=\"copy\">No terrain generators are available.</p>");
        } else for (0..count) |index| {
            const info = registry.getGeneratorInfo(index);
            var id_buffer: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buffer, "terrain-{}", .{index}) catch unreachable;
            try out.appendSlice(self.context.allocator, "<button id=\"");
            try out.appendSlice(self.context.allocator, id);
            try out.appendSlice(self.context.allocator, "\" class=\"row");
            if (index == self.selected_generator_index) try out.appendSlice(self.context.allocator, " selected");
            try out.appendSlice(self.context.allocator, "\"><strong>");
            try markup.appendEscaped(&out, self.context.allocator, info.name);
            try out.appendSlice(self.context.allocator, "</strong><span>");
            try markup.appendEscaped(&out, self.context.allocator, info.description);
            try out.appendSlice(self.context.allocator, "</span><em>SELECT</em></button>");
        }
        const document_rml = try markup.sentinel(&out, self.context.allocator);
        _ = self.page.backend.setInnerRml(self.page.document, "terrain-rows", document_rml);
    }

    fn renderReview(self: *@This()) !void {
        var name_buffer: [128]u8 = undefined;
        var seed_buffer: [160]u8 = undefined;
        const name_value = self.page.backend.getValue(self.page.document, "world-name", &name_buffer) orelse "";
        const seed_value = self.page.backend.getValue(self.page.document, "world-seed", &seed_buffer) orelse "";
        const generator_name = if (registry.getGeneratorCount() > 0) registry.getGeneratorInfo(self.selected_generator_index).name else "Unavailable";

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.context.allocator);
        try appendSummaryItem(&out, self.context.allocator, "WORLD NAME", wizard.displayWorldName(name_value));
        try appendSummaryItem(&out, self.context.allocator, "TERRAIN", generator_name);
        try appendSummaryItem(&out, self.context.allocator, "SEED", if (std.mem.trim(u8, seed_value, " \t\r\n").len == 0) "Random on creation" else seed_value);
        const document_rml = try markup.sentinel(&out, self.context.allocator);
        _ = self.page.backend.setInnerRml(self.page.document, "review-summary", document_rml);
    }

    fn randomizeSeed(self: *@This()) !void {
        var seed_input = std.ArrayListUnmanaged(u8).empty;
        defer seed_input.deinit(self.context.allocator);
        try seed_gen.setSeedInput(&seed_input, self.context.allocator, seed_gen.randomSeedValue());
        var value = std.ArrayList(u8).empty;
        defer value.deinit(self.context.allocator);
        try value.appendSlice(self.context.allocator, seed_input.items);
        _ = self.page.backend.setValue(self.page.document, "world-seed", try markup.sentinel(&value, self.context.allocator));
        _ = self.page.backend.focus(self.page.document, "world-seed", true);
    }

    fn goBack(self: *@This()) void {
        switch (wizard.backAction(self.step)) {
            .show => |step| {
                self.step = step;
                self.render() catch |err| self.showError(err);
                if (step == .details) _ = self.page.backend.focus(self.page.document, "world-name", true);
            },
            .exit_wizard => self.context.screen_manager.popScreen(),
        }
    }

    fn confirmStep(self: *@This()) !void {
        switch (wizard.confirmAction(self.step)) {
            .show => |step| {
                if (step != .details and registry.getGeneratorCount() == 0) return error.NoTerrainGenerators;
                self.step = step;
                try self.render();
            },
            .create_world => try self.finishCreation(),
        }
    }

    fn finishCreation(self: *@This()) !void {
        if (registry.getGeneratorCount() == 0) return error.NoTerrainGenerators;
        var name_buffer: [128]u8 = undefined;
        var seed_buffer: [160]u8 = undefined;
        const name_input = self.page.backend.getValue(self.page.document, "world-name", &name_buffer) orelse "";
        const seed_input = self.page.backend.getValue(self.page.document, "world-seed", &seed_buffer) orelse "";

        var seed_values = std.ArrayListUnmanaged(u8).empty;
        defer seed_values.deinit(self.context.allocator);
        try seed_values.appendSlice(self.context.allocator, seed_input);
        const seed = try seed_gen.resolveSeed(&seed_values, self.context.allocator);
        const world_name = wizard.displayWorldName(name_input);
        const generator = registry.getGeneratorInfo(self.selected_generator_index);
        log.log.info("World seed: {} | Type: {s} | Name: {s}", .{ seed, generator.name, world_name });
        const save_path = try world_save.saveNewWorld(self.context.allocator, seed, self.selected_generator_index, world_name);
        defer self.context.allocator.free(save_path);
        const world_screen = try WorldScreen.initPersistent(self.context.allocator, self.context, seed, self.selected_generator_index, save_path);
        errdefer world_screen.deinit(world_screen);
        self.context.screen_manager.setScreen(world_screen.screen());
    }

    fn showError(self: *@This(), err: anyerror) void {
        log.log.err("RmlUi Create World action failed: {}", .{err});
        _ = self.page.backend.setInnerRml(self.page.document, "wizard-subtitle", "The requested action failed. Check logs and try again.");
        _ = self.page.backend.setProperty(self.page.document, "wizard-subtitle", "color", "#FFB8C1");
    }
};

fn stepIndex(step: wizard.Step) usize {
    return switch (step) {
        .details => 0,
        .terrain => 1,
        .review => 2,
    };
}

fn stepSubtitle(step: wizard.Step) [:0]const u8 {
    return switch (step) {
        .details => "Name the world and choose how its seed is generated.",
        .terrain => "Choose the terrain generator that fits this world.",
        .review => "Review the choices below before generating the world.",
    };
}

fn appendSummaryItem(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, "<div class=\"summary-item\"><strong>");
    try markup.appendEscaped(out, allocator, label);
    try out.appendSlice(allocator, "</strong><span>");
    try markup.appendEscaped(out, allocator, value);
    try out.appendSlice(allocator, "</span></div>");
}
