//! RmlUi implementation of the saved-world library.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const registry = @import("world-worldgen").registry;
const fs = @import("fs");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Page = @import("../rml_page.zig").Page;
const markup = @import("../rml_markup.zig");
const world_list = @import("world_list.zig");
const world_save = @import("world_save.zig");
const WorldScreen = @import("world.zig").WorldScreen;
const RmlCreateWorldScreen = @import("rml_create_world.zig").RmlCreateWorldScreen;

const Modal = enum { none, rename, delete, clear };

pub const RmlWorldListScreen = struct {
    context: EngineContext,
    page: Page,
    worlds: []world_list.WorldEntry,
    selected: ?usize = null,
    modal: Modal = .none,
    error_message: ?[]const u8 = null,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlWorldListScreen {
        const self = try allocator.create(RmlWorldListScreen);
        errdefer allocator.destroy(self);

        const worlds = world_list.scanWorlds(allocator) catch try allocator.alloc(world_list.WorldEntry, 0);
        errdefer freeWorlds(allocator, worlds);
        self.* = .{
            .context = context,
            .page = undefined,
            .worlds = worlds,
            .selected = if (worlds.len > 0) 0 else null,
        };
        self.page = try Page.init(context, "assets/ui/rmlui/world_library.rml", self, onDocumentAction);
        errdefer self.page.deinit();
        try self.render();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.deinit();
        freeWorlds(self.context.allocator, self.worlds);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (!self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) return;

        if (self.modal != .none) {
            self.closeModal();
        } else {
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        self.page.draw(ui);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onEnter();
        self.rescan() catch |err| self.showError(err);
        self.render() catch |err| self.showError(err);
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
            // The rename input is intentionally read only when confirmed. The
            // change event still documents its target for future validation.
            if (std.mem.eql(u8, target_id, "rename-input")) return;
            return;
        }
        if (!std.mem.eql(u8, event_type, "click")) return;

        self.handleClick(target_id) catch |err| self.showError(err);
    }

    fn handleClick(self: *@This(), target_id: []const u8) !void {
        if (std.mem.eql(u8, target_id, "library-back")) {
            if (self.modal == .none) self.context.screen_manager.popScreen() else self.closeModal();
            return;
        }
        if (std.mem.eql(u8, target_id, "new-world")) {
            if (self.modal == .none) try self.openCreateWorld();
            return;
        }
        if (std.mem.eql(u8, target_id, "clear-worlds")) {
            if (self.modal == .none and self.worlds.len > 0) try self.openModal(.clear);
            return;
        }
        if (std.mem.eql(u8, target_id, "detail-play")) {
            if (self.modal == .none) try self.loadSelectedWorld();
            return;
        }
        if (std.mem.eql(u8, target_id, "detail-rename")) {
            if (self.modal == .none and self.selected != null) try self.openModal(.rename);
            return;
        }
        if (std.mem.eql(u8, target_id, "detail-delete")) {
            if (self.modal == .none and self.selected != null) try self.openModal(.delete);
            return;
        }
        if (std.mem.eql(u8, target_id, "modal-cancel")) {
            self.closeModal();
            return;
        }
        if (std.mem.eql(u8, target_id, "modal-confirm")) {
            try self.confirmModal();
            return;
        }
        if (std.mem.startsWith(u8, target_id, "world-")) {
            const index = std.fmt.parseInt(usize, target_id[6..], 10) catch return;
            if (index < self.worlds.len and self.modal == .none) {
                self.selected = index;
                try self.render();
            }
        }
    }

    fn render(self: *@This()) !void {
        try self.renderWorldList();
        try self.renderDetails();
        try self.renderModal();

        var count_markup = std.ArrayList(u8).empty;
        defer count_markup.deinit(self.context.allocator);
        var count_buffer: [48]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{} WORLDS", .{self.worlds.len}) catch "WORLDS";
        try count_markup.appendSlice(self.context.allocator, count);
        _ = self.page.backend.setInnerRml(self.page.document, "world-count", try markup.sentinel(&count_markup, self.context.allocator));
        _ = self.page.backend.setDisabled(self.page.document, "clear-worlds", self.worlds.len == 0 or self.modal != .none);
        // Keep the generated rail independently scrollable as its content grows.
        _ = self.page.backend.setProperty(self.page.document, "world-list", "overflow", "auto");
    }

    fn renderWorldList(self: *@This()) !void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.context.allocator);

        if (self.worlds.len == 0) {
            try out.appendSlice(self.context.allocator, "<div class=\"empty\">NO WORLDS YET<br/>CREATE A NEW WORLD TO BEGIN.</div>");
        } else for (self.worlds, 0..) |world, index| {
            var id_buffer: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buffer, "world-{}", .{index}) catch unreachable;
            try out.appendSlice(self.context.allocator, "<button id=\"");
            try out.appendSlice(self.context.allocator, id);
            try out.appendSlice(self.context.allocator, "\" class=\"row");
            if (self.selected == index) try out.appendSlice(self.context.allocator, " selected");
            try out.appendSlice(self.context.allocator, "\"><strong>");
            try markup.appendEscaped(&out, self.context.allocator, world.name);
            try out.appendSlice(self.context.allocator, "</strong><span>SEED: ");
            try appendUnsigned(&out, self.context.allocator, world.seed);
            try out.appendSlice(self.context.allocator, "</span><em>OPEN</em></button>");
        }

        const document_rml = try markup.sentinel(&out, self.context.allocator);
        _ = self.page.backend.setInnerRml(self.page.document, "world-list", document_rml);
    }

    fn renderDetails(self: *@This()) !void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.context.allocator);

        if (self.selected) |index| {
            if (index < self.worlds.len) {
                const world = self.worlds[index];
                try out.appendSlice(self.context.allocator, "<h2>");
                try markup.appendEscaped(&out, self.context.allocator, world.name);
                try out.appendSlice(self.context.allocator, "</h2><span class=\"detail-label\">TERRAIN</span><span class=\"detail-value\">");
                try markup.appendEscaped(&out, self.context.allocator, registry.getGeneratorInfo(world.generator_index).name);
                try out.appendSlice(self.context.allocator, "</span><span class=\"detail-label\">SEED</span><span class=\"detail-value\">");
                try appendUnsigned(&out, self.context.allocator, world.seed);
                try out.appendSlice(self.context.allocator, "</span><span class=\"detail-label\">LAST PLAYED</span><span class=\"detail-value\">");
                try appendSigned(&out, self.context.allocator, world.last_played);
                try out.appendSlice(self.context.allocator, "</span><div class=\"detail-actions\"><button id=\"detail-play\" class=\"primary\">PLAY WORLD</button><div class=\"action-pair\"><button id=\"detail-rename\">RENAME</button><button id=\"detail-delete\" class=\"danger\">DELETE</button></div></div>");
            }
        }
        if (out.items.len == 0) try out.appendSlice(self.context.allocator, "<p class=\"copy\">Select a world to see its details and actions.</p>");

        const document_rml = try markup.sentinel(&out, self.context.allocator);
        _ = self.page.backend.setInnerRml(self.page.document, "world-detail", document_rml);
    }

    fn renderModal(self: *@This()) !void {
        const visible = self.modal != .none;
        _ = self.page.backend.setClass(self.page.document, "modal-layer", "visible", visible);
        if (!visible) return;

        const title: [:0]const u8 = switch (self.modal) {
            .rename => "RENAME WORLD",
            .delete => "DELETE WORLD?",
            .clear => "CLEAR ALL WORLDS?",
            .none => unreachable,
        };
        const copy: [:0]const u8 = switch (self.modal) {
            .rename => "Update the display name in level.dat.",
            .delete => "This cannot be undone.",
            .clear => "Every saved world will be removed.",
            .none => unreachable,
        };
        _ = self.page.backend.setInnerRml(self.page.document, "modal-title", title);
        _ = self.page.backend.setInnerRml(self.page.document, "modal-copy", copy);
        const body: [:0]const u8 = switch (self.modal) {
            .rename => "<label for=\"rename-input\">NEW NAME</label><input id=\"rename-input\" type=\"text\" maxlength=\"32\" />",
            .delete => "<p>Delete the selected world and all of its saved data?</p>",
            .clear => "<p>Delete every saved world and all of their data?</p>",
            .none => unreachable,
        };
        const confirm_label: [:0]const u8 = if (self.modal == .rename) "SAVE NAME" else "CONFIRM";
        _ = self.page.backend.setInnerRml(self.page.document, "modal-body", body);
        _ = self.page.backend.setInnerRml(self.page.document, "modal-confirm", confirm_label);
    }

    fn openModal(self: *@This(), modal: Modal) !void {
        self.modal = modal;
        try self.render();
        if (modal == .rename) {
            if (self.selected) |index| {
                var value = std.ArrayList(u8).empty;
                defer value.deinit(self.context.allocator);
                try value.appendSlice(self.context.allocator, self.worlds[index].name);
                const name = try markup.sentinel(&value, self.context.allocator);
                _ = self.page.backend.setValue(self.page.document, "rename-input", name);
            }
        }
        if (modal == .rename) _ = self.page.backend.focus(self.page.document, "rename-input", true);
    }

    fn closeModal(self: *@This()) void {
        self.modal = .none;
        _ = self.page.backend.setClass(self.page.document, "modal-layer", "visible", false);
    }

    fn confirmModal(self: *@This()) !void {
        switch (self.modal) {
            .none => {},
            .rename => try self.renameSelectedWorld(),
            .delete => try self.deleteSelectedWorld(),
            .clear => try self.clearAllWorlds(),
        }
    }

    fn openCreateWorld(self: *@This()) !void {
        const create_screen = try RmlCreateWorldScreen.init(self.context.allocator, self.context);
        errdefer create_screen.deinit(create_screen);
        self.context.screen_manager.pushScreen(create_screen.screen());
    }

    fn loadSelectedWorld(self: *@This()) !void {
        const index = self.selected orelse return;
        if (index >= self.worlds.len) return;
        const world = self.worlds[index];
        const world_screen = try WorldScreen.initPersistent(self.context.allocator, self.context, world.seed, world.generator_index, world.dir_path);
        errdefer world_screen.deinit(world_screen);
        self.context.screen_manager.setScreen(world_screen.screen());
    }

    fn renameSelectedWorld(self: *@This()) !void {
        const index = self.selected orelse return;
        if (index >= self.worlds.len) return;
        var value_buffer: [128]u8 = undefined;
        const value = self.page.backend.getValue(self.page.document, "rename-input", &value_buffer) orelse return error.RenameValueUnavailable;
        const name = std.mem.trim(u8, value, " \t\r\n");
        if (name.len == 0) return error.EmptyWorldName;

        const world = &self.worlds[index];
        var save_dir = try fs.openDirAbsolute(world.dir_path, .{});
        defer save_dir.close();
        try world_save.writeLevelDat(self.context.allocator, save_dir, name, world.seed, world.generator_index, world.last_played);
        const name_copy = try self.context.allocator.dupe(u8, name);
        self.context.allocator.free(world.name);
        world.name = name_copy;
        self.modal = .none;
        self.error_message = null;
        try self.render();
    }

    fn deleteSelectedWorld(self: *@This()) !void {
        const index = self.selected orelse return;
        if (index >= self.worlds.len) return;
        try world_list.deleteWorld(self.worlds[index].dir_path);
        self.modal = .none;
        try self.rescan();
        try self.render();
    }

    fn clearAllWorlds(self: *@This()) !void {
        for (self.worlds) |world| try world_list.deleteWorld(world.dir_path);
        self.modal = .none;
        try self.rescan();
        try self.render();
    }

    fn rescan(self: *@This()) !void {
        const worlds = try world_list.scanWorlds(self.context.allocator);
        freeWorlds(self.context.allocator, self.worlds);
        self.worlds = worlds;
        self.selected = if (worlds.len > 0) 0 else null;
        self.modal = .none;
    }

    fn showError(self: *@This(), err: anyerror) void {
        log.log.err("RmlUi World Library action failed: {}", .{err});
        self.error_message = "The requested world action failed. Check logs.";
        _ = self.page.backend.setInnerRml(self.page.document, "modal-title", "WORLD LIBRARY ERROR");
        _ = self.page.backend.setInnerRml(self.page.document, "modal-copy", "The requested world action failed. Check logs.");
        _ = self.page.backend.setInnerRml(self.page.document, "modal-body", "<p>Nothing was changed unless the operation completed.</p>");
        _ = self.page.backend.setClass(self.page.document, "modal-layer", "visible", true);
    }
};

fn freeWorlds(allocator: std.mem.Allocator, worlds: []world_list.WorldEntry) void {
    for (worlds) |world| {
        allocator.free(world.name);
        if (world.dir_path.len > 0) allocator.free(world.dir_path);
    }
    allocator.free(worlds);
}

fn appendUnsigned(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{}", .{value}));
}

fn appendSigned(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var buffer: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{}", .{value}));
}
