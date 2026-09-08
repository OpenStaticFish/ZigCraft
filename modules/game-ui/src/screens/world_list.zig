const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Rect = @import("engine-ui").Rect;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const WorldScreen = @import("world.zig").WorldScreen;
const log = @import("engine-core").log;
const fs = @import("fs");
const text_input = @import("game-core").text_input;
const registry = @import("world-worldgen").registry;
const world_save = @import("world_save.zig");
const SingleplayerScreen = @import("singleplayer.zig").SingleplayerScreen;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const PANEL_WIDTH_MAX = 1120.0;
const PANEL_HEIGHT_BASE = 720.0;
pub const SAVE_DIR = world_save.SAVE_DIR;

pub const WorldEntry = struct {
    name: []const u8,
    seed: u64,
    last_played: i64,
    generator_index: usize,
    dir_path: []const u8,
};

pub const LevelDat = struct {
    name: []const u8,
    seed: u64,
    last_played: i64,
    generator_index: usize,
};

pub const writeLevelDat = world_save.writeLevelDat;

pub fn readLevelDat(allocator: std.mem.Allocator, save_dir: fs.Dir) ?LevelDat {
    var saved = @import("world-persistence").LevelData.loadFromFile(allocator, save_dir) catch return null;
    defer saved.deinit(allocator);
    const identity = if (saved.generator_id.len > 0) saved.generator_id else saved.generator_name;
    if (saved.name.len == 0 and identity.len == 0) return null;
    const saved_index = saved.generator_index orelse 0;
    var generator_index = if (saved_index < registry.getGeneratorCount()) saved_index else 0;
    if (identity.len > 0) {
        generator_index = registry.findGeneratorIndex(identity) orelse blk: {
            for (0..registry.getGeneratorCount()) |i| {
                if (std.ascii.eqlIgnoreCase(identity, registry.getGeneratorInfo(i).name)) break :blk i;
            }
            return null;
        };
    }
    const name_copy = allocator.dupe(u8, if (saved.name.len > 0) saved.name else "World") catch return null;
    return .{
        .name = name_copy,
        .seed = saved.seed,
        .last_played = saved.last_played_timestamp,
        .generator_index = generator_index,
    };
}

pub fn scanWorlds(allocator: std.mem.Allocator) ![]WorldEntry {
    const home = getenv("HOME") orelse return allocator.alloc(WorldEntry, 0);
    return scanWorldsInHome(allocator, home);
}

pub fn scanWorldsInHome(allocator: std.mem.Allocator, home: []const u8) ![]WorldEntry {
    var home_dir = fs.openDirAbsolute(home, .{}) catch return allocator.alloc(WorldEntry, 0);
    defer home_dir.close();
    home_dir.makePath(SAVE_DIR) catch {};
    var saves_dir = home_dir.openDir(SAVE_DIR, .{ .iterate = true }) catch return allocator.alloc(WorldEntry, 0);
    defer saves_dir.close();
    var entries = std.ArrayList(WorldEntry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.dir_path);
        }
        entries.deinit(allocator);
    }
    var iter = saves_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const name_alloc = allocator.dupe(u8, entry.name) catch continue;
        errdefer allocator.free(name_alloc);
        const level = blk: {
            var world_dir = saves_dir.openDir(entry.name, .{}) catch break :blk null;
            defer world_dir.close();
            break :blk readLevelDat(allocator, world_dir);
        };
        const dir_buf = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, SAVE_DIR, entry.name }) catch {
            allocator.free(name_alloc);
            continue;
        };
        errdefer allocator.free(dir_buf);
        if (level) |ld| {
            try entries.append(allocator, .{
                .name = ld.name,
                .seed = ld.seed,
                .last_played = ld.last_played,
                .generator_index = ld.generator_index,
                .dir_path = dir_buf,
            });
            allocator.free(name_alloc);
        } else {
            try entries.append(allocator, .{
                .name = name_alloc,
                .seed = 0,
                .last_played = 0,
                .generator_index = 0,
                .dir_path = dir_buf,
            });
        }
    }
    std.sort.block(WorldEntry, entries.items, {}, compareWorldsByLastPlayed);
    return try entries.toOwnedSlice(allocator);
}

fn compareWorldsByLastPlayed(_: void, a: WorldEntry, b: WorldEntry) bool {
    return a.last_played > b.last_played;
}

/// Deletes a world directory. Caller owns and frees dir_path.
pub fn deleteWorld(dir_path: []const u8) !void {
    const parent_path = fs.path.dirname(dir_path) orelse return error.InvalidSavePath;
    const base = fs.path.basename(dir_path);
    var parent = try fs.openDirAbsolute(parent_path, .{ .iterate = true });
    defer parent.close();
    try parent.deleteTree(base);
}

pub const WorldListScreen = struct {
    context: EngineContext,
    worlds: []WorldEntry,
    selected: ?usize,
    scroll_offset: f32,
    confirm_delete: bool,
    confirm_clear_all: bool,
    confirm_rename: bool,
    rename_buffer: std.ArrayListUnmanaged(u8),
    rename_focused: bool,
    error_message: ?[]const u8,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*WorldListScreen {
        const self = try allocator.create(WorldListScreen);
        errdefer allocator.destroy(self);
        const worlds = scanWorlds(allocator) catch try allocator.alloc(WorldEntry, 0);
        self.* = .{
            .context = context,
            .worlds = worlds,
            .selected = if (worlds.len > 0) 0 else null,
            .scroll_offset = 0.0,
            .confirm_delete = false,
            .confirm_clear_all = false,
            .confirm_rename = false,
            .rename_buffer = std.ArrayListUnmanaged(u8).empty,
            .rename_focused = false,
            .error_message = null,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        for (self.worlds) |e| {
            self.context.allocator.free(e.name);
            if (e.dir_path.len > 0) self.context.allocator.free(e.dir_path);
        }
        self.context.allocator.free(self.worlds);
        self.rename_buffer.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            if (self.confirm_rename) {
                self.confirm_rename = false;
                self.rename_buffer.clearRetainingCapacity();
            } else if (self.confirm_delete) {
                self.confirm_delete = false;
            } else if (self.confirm_clear_all) {
                self.confirm_clear_all = false;
            } else {
                self.error_message = null;
                self.context.screen_manager.popScreen();
            }
        }
        if (self.confirm_rename and self.rename_focused) {
            try text_input.handleTextTyping(&self.rename_buffer, self.context.allocator, self.context.input, 32);
        }
        if (!self.confirm_delete and !self.confirm_clear_all and !self.confirm_rename and self.worlds.len > 0) {
            const input = self.context.input;
            if (input.isKeyPressed(.down)) self.selected = if (self.selected) |idx| (idx + 1) % self.worlds.len else 0;
            if (input.isKeyPressed(.up)) self.selected = if (self.selected) |idx| if (idx == 0) self.worlds.len - 1 else idx - 1 else self.worlds.len - 1;
            if (self.context.input_mapper.isActionPressed(input, .ui_confirm)) {
                if (self.selected) |idx| try self.loadWorld(idx);
            }
        } else if (!self.confirm_delete and !self.confirm_clear_all and !self.confirm_rename and self.context.input_mapper.isActionPressed(self.context.input, .ui_confirm)) {
            try self.openCreateWizard();
        }
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
        const mc = ctx.input.isMouseButtonPressed(.left);
        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const ui_scale = Theme.scaleFor(screen_h, ctx.settings.ui_scale);
        const modal_open = self.confirm_delete or self.confirm_clear_all or self.confirm_rename;

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .library);

        const margin: f32 = 42.0 * ui_scale;
        const pw: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - margin * 2.0, PANEL_HEIGHT_BASE * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, ui_scale, "PLAY", "WORLD LIBRARY", "Choose an existing world or create something new.");

        if (self.error_message) |message| {
            const banner = Rect{ .x = shell.content.x + 12.0 * ui_scale, .y = shell.content.y + 8.0 * ui_scale, .width = shell.content.width - 24.0 * ui_scale, .height = 34.0 * ui_scale };
            ui.drawRect(banner, Theme.Color.rgba(0.18, 0.04, 0.05, 0.92));
            ui.drawRectOutline(banner, Theme.danger, 1.0 * ui_scale);
            Font.drawText(ui, message, banner.x + 12.0 * ui_scale, banner.y + 9.0 * ui_scale, 0.90 * ui_scale, Theme.text);
        }

        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{} WORLDS", .{self.worlds.len}) catch "?";
        const count_w = Font.measureTextWidth(count_text, 0.94 * ui_scale);
        Font.drawText(ui, count_text, shell.rect.x + shell.rect.width - 34.0 * ui_scale - count_w, shell.rect.y + 86.0 * ui_scale, 0.94 * ui_scale, Theme.signal);

        const detail_layout = shell.content.width >= 720.0 * ui_scale;
        const detail_gap: f32 = 18.0 * ui_scale;
        const list_rect = Rect{
            .x = shell.content.x,
            .y = shell.content.y,
            .width = if (detail_layout) shell.content.width * 0.58 else shell.content.width,
            .height = shell.content.height,
        };
        const detail_rect = Rect{
            .x = list_rect.x + list_rect.width + detail_gap,
            .y = shell.content.y,
            .width = shell.content.width - list_rect.width - detail_gap,
            .height = shell.content.height,
        };

        const scroll_dy = ctx.input.getScrollDelta().y;
        self.scroll_offset -= scroll_dy * 30.0 * ui_scale;
        const list_top: f32 = list_rect.y;
        const list_bottom: f32 = list_rect.y + list_rect.height;
        const row_h: f32 = 68.0 * ui_scale;
        const max_scroll = @max(0.0, @as(f32, @floatFromInt(self.worlds.len)) * row_h - (list_bottom - list_top));
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));

        Theme.drawListRail(ui, list_rect, ui_scale);
        Theme.drawScrollbar(ui, list_rect.x + list_rect.width - 12.0 * ui_scale, list_top + 12.0 * ui_scale, list_rect.height - 24.0 * ui_scale, @as(f32, @floatFromInt(self.worlds.len)) * row_h, list_rect.height, self.scroll_offset, max_scroll, ui_scale);

        if (self.worlds.len == 0) {
            Font.drawTextCentered(ui, "NO WORLDS YET", list_rect.x + list_rect.width * 0.5, list_top + (list_bottom - list_top) * 0.40, 1.35 * ui_scale, Theme.title);
            Font.drawTextCentered(ui, "PRESS ENTER OR CHOOSE NEW WORLD", list_rect.x + list_rect.width * 0.5, list_top + (list_bottom - list_top) * 0.40 + 32.0 * ui_scale, 0.92 * ui_scale, Theme.muted);
        }

        var i: usize = 0;
        while (i < self.worlds.len) : (i += 1) {
            const ry: f32 = list_top + @as(f32, @floatFromInt(i)) * row_h - self.scroll_offset;
            if (ry + row_h < list_top or ry > list_bottom) continue;
            const world = self.worlds[i];
            const row_rect = Rect{ .x = list_rect.x + 16.0 * ui_scale, .y = ry, .width = list_rect.width - 42.0 * ui_scale, .height = row_h - 8.0 * ui_scale };
            const row_hovered = row_rect.contains(mx, my);
            const is_selected = self.selected == i;
            if (mc and row_hovered and !modal_open) {
                self.selected = i;
            }
            var seed_buf: [64]u8 = undefined;
            const seed_text = std.fmt.bufPrint(&seed_buf, "SEED: {}", .{world.seed}) catch "SEED: ???";
            const last_text = formatTimestamp(world.last_played);
            var desc_buf: [128]u8 = undefined;
            const description = std.fmt.bufPrint(&desc_buf, "{s}  //  LAST PLAYED: {s}", .{ seed_text, last_text }) catch seed_text;
            Theme.drawOptionRow(ui, row_rect, world.name, description, 1.28 * ui_scale, is_selected or row_hovered, ui_scale);
        }

        if (detail_layout) drawWorldDetails(ui, detail_rect, self, ui_scale);

        const btn_h: f32 = 46.0 * ui_scale;
        const byy: f32 = shell.footer_y;
        const btn_gap: f32 = 10.0 * ui_scale;
        const bx_base: f32 = shell.content.x;
        const btn_scale: f32 = 1.04 * ui_scale;
        const footer_button_w = 150.0 * ui_scale;

        if (Theme.drawButton(ui, .{ .x = bx_base, .y = byy, .width = footer_button_w, .height = btn_h }, "BACK", btn_scale, mx, my, mc, .ghost, ui_scale)) {
            ctx.screen_manager.popScreen();
        }

        const clear_enabled = self.worlds.len > 0 and !modal_open;
        const clear_rect = Rect{ .x = bx_base + footer_button_w + btn_gap, .y = byy, .width = footer_button_w, .height = btn_h };
        if (detail_layout and Theme.drawButton(ui, clear_rect, "CLEAR ALL", btn_scale, mx, my, mc, if (clear_enabled) .danger else .disabled, ui_scale)) self.confirm_clear_all = true;

        const new_world_w = 180.0 * ui_scale;
        const new_world_rect = Rect{ .x = shell.content.x + shell.content.width - new_world_w, .y = byy, .width = new_world_w, .height = btn_h };
        if (Theme.drawButton(ui, new_world_rect, "NEW WORLD", btn_scale, mx, my, mc, if (modal_open) .disabled else .primary, ui_scale)) try self.openCreateWizard();

        const load_enabled = self.selected != null and !modal_open;
        const compact_action_w = (shell.content.width - new_world_w - footer_button_w - btn_gap * 4.0) / 3.0;
        const load_rect = if (detail_layout) Rect{ .x = detail_rect.x + 18.0 * ui_scale, .y = detail_rect.y + detail_rect.height - 168.0 * ui_scale, .width = detail_rect.width - 36.0 * ui_scale, .height = 44.0 * ui_scale } else Rect{ .x = bx_base + footer_button_w + btn_gap, .y = byy, .width = compact_action_w, .height = btn_h };
        if (Theme.drawButton(ui, load_rect, "PLAY WORLD", btn_scale, mx, my, mc, if (load_enabled) .primary else .disabled, ui_scale)) {
            if (self.selected) |idx| try self.loadWorld(idx);
        }

        const rename_enabled = self.selected != null and !modal_open;
        const rename_rect = if (detail_layout) Rect{ .x = detail_rect.x + 18.0 * ui_scale, .y = detail_rect.y + detail_rect.height - 114.0 * ui_scale, .width = (detail_rect.width - 46.0 * ui_scale) * 0.5, .height = 42.0 * ui_scale } else Rect{ .x = load_rect.x + compact_action_w + btn_gap, .y = byy, .width = compact_action_w, .height = btn_h };
        if (Theme.drawButton(ui, rename_rect, "RENAME", btn_scale, mx, my, mc, if (rename_enabled) .secondary else .disabled, ui_scale)) {
            if (self.selected) |idx| {
                self.rename_buffer.clearRetainingCapacity();
                try self.rename_buffer.appendSlice(self.context.allocator, self.worlds[idx].name);
                self.confirm_rename = true;
                self.rename_focused = true;
            }
        }

        const del_enabled = self.selected != null and !modal_open;
        const delete_rect = if (detail_layout) Rect{ .x = rename_rect.x + rename_rect.width + 10.0 * ui_scale, .y = rename_rect.y, .width = rename_rect.width, .height = rename_rect.height } else Rect{ .x = rename_rect.x + compact_action_w + btn_gap, .y = byy, .width = compact_action_w, .height = btn_h };
        if (Theme.drawButton(ui, delete_rect, "DELETE", btn_scale, mx, my, mc, if (del_enabled) .danger else .disabled, ui_scale)) {
            self.confirm_delete = true;
        }

        if (self.confirm_delete) {
            if (self.selected) |idx| {
                const cw: f32 = 460.0 * ui_scale;
                const ch: f32 = 220.0 * ui_scale;
                const cx: f32 = (screen_w - cw) * 0.5;
                const cy: f32 = (screen_h - ch) * 0.5;
                Theme.drawModal(ui, screen_w, screen_h, .{ .x = cx, .y = cy, .width = cw, .height = ch }, ui_scale, "DELETE WORLD?", "This cannot be undone.", true);
                var name_buf: [128]u8 = undefined;
                const confirm_msg = std.fmt.bufPrint(&name_buf, "'{s}'", .{self.worlds[idx].name}) catch "'?'";
                Font.drawTextCentered(ui, confirm_msg, cx + cw * 0.5, cy + 104.0 * ui_scale, 1.12 * ui_scale, Theme.text);
                const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
                const cby: f32 = cy + ch - 55.0 * ui_scale;
                if (Theme.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc, .ghost, ui_scale)) {
                    self.confirm_delete = false;
                }
                if (Theme.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CONFIRM", btn_scale, mx, my, mc, .danger, ui_scale)) {
                    self.confirmDelete(idx) catch |err| {
                        log.log.err("Failed to delete world '{s}': {}", .{ self.worlds[idx].name, err });
                        self.error_message = "Failed to delete world. Check logs.";
                    };
                }
            }
        }

        if (self.confirm_clear_all) {
            const cw: f32 = 480.0 * ui_scale;
            const ch: f32 = 220.0 * ui_scale;
            const cx: f32 = (screen_w - cw) * 0.5;
            const cy: f32 = (screen_h - ch) * 0.5;
            Theme.drawModal(ui, screen_w, screen_h, .{ .x = cx, .y = cy, .width = cw, .height = ch }, ui_scale, "CLEAR ALL WORLDS?", "Every saved world will be removed.", true);
            var count_buf2: [64]u8 = undefined;
            const count_msg = std.fmt.bufPrint(&count_buf2, "THIS WILL DELETE {} WORLDS", .{self.worlds.len}) catch "?";
            Font.drawTextCentered(ui, count_msg, cx + cw * 0.5, cy + 104.0 * ui_scale, 1.04 * ui_scale, Theme.text);
            const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
            const cby: f32 = cy + ch - 55.0 * ui_scale;
            if (Theme.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc, .ghost, ui_scale)) {
                self.confirm_clear_all = false;
            }
            if (Theme.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CONFIRM", btn_scale, mx, my, mc, .danger, ui_scale)) {
                self.clearAllWorlds() catch |err| {
                    log.log.err("Failed to clear all worlds: {}", .{err});
                    self.error_message = "Failed to clear worlds. Check logs.";
                };
            }
        }

        if (self.confirm_rename) {
            if (self.selected) |idx| {
                const cw: f32 = 500.0 * ui_scale;
                const ch: f32 = 230.0 * ui_scale;
                const cx: f32 = (screen_w - cw) * 0.5;
                const cy: f32 = (screen_h - ch) * 0.5;
                Theme.drawModal(ui, screen_w, screen_h, .{ .x = cx, .y = cy, .width = cw, .height = ch }, ui_scale, "RENAME WORLD", "Update the display name in level.dat.", false);
                var name_buf2: [128]u8 = undefined;
                const current_msg = std.fmt.bufPrint(&name_buf2, "CURRENT: '{s}'", .{self.worlds[idx].name}) catch "'?'";
                Font.drawTextCentered(ui, current_msg, cx + cw * 0.5, cy + 92.0 * ui_scale, 0.92 * ui_scale, Theme.muted);
                const input_h: f32 = 46.0 * ui_scale;
                const input_y: f32 = cy + 116.0 * ui_scale;
                const input_rect = Rect{ .x = cx + 20.0 * ui_scale, .y = input_y, .width = cw - 40.0 * ui_scale, .height = input_h };
                const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
                if (mc) {
                    self.rename_focused = input_rect.contains(mx, my);
                }
                Theme.drawTextInput(ui, input_rect, self.rename_buffer.items, "ENTER NEW NAME", 1.18 * ui_scale, self.rename_focused, cursor_visible, ui_scale);
                const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
                const cby: f32 = cy + ch - 52.0 * ui_scale;
                if (Theme.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 42.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc, .ghost, ui_scale)) {
                    self.confirm_rename = false;
                    self.rename_buffer.clearRetainingCapacity();
                }
                if (Theme.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 42.0 * ui_scale }, "OK", btn_scale, mx, my, mc, .primary, ui_scale)) {
                    self.renameWorld(idx) catch |err| {
                        log.log.err("Failed to rename world '{s}': {}", .{ self.worlds[idx].name, err });
                        self.error_message = "Failed to rename world. Check logs.";
                    };
                }
            }
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }

    fn openCreateWizard(self: *@This()) !void {
        const create_screen = try SingleplayerScreen.init(self.context.allocator, self.context);
        errdefer create_screen.deinit(create_screen);
        self.context.screen_manager.pushScreen(create_screen.screen());
    }

    fn loadWorld(self: *@This(), idx: usize) !void {
        const world = self.worlds[idx];
        const world_screen = try WorldScreen.initPersistent(self.context.allocator, self.context, world.seed, world.generator_index, world.dir_path);
        errdefer world_screen.deinit(world_screen);
        self.context.screen_manager.setScreen(world_screen.screen());
    }

    fn confirmDelete(self: *@This(), idx: usize) !void {
        const allocator = self.context.allocator;
        const dir_path = self.worlds[idx].dir_path;
        try deleteWorld(dir_path);
        const old_worlds = self.worlds;
        const empty_worlds = try allocator.alloc(WorldEntry, 0);
        self.worlds = empty_worlds;
        for (old_worlds) |e| {
            allocator.free(e.name);
            if (e.dir_path.len > 0) allocator.free(e.dir_path);
        }
        allocator.free(old_worlds);
        if (scanWorlds(allocator)) |new_worlds| {
            allocator.free(empty_worlds);
            self.worlds = new_worlds;
        } else |_| {}
        self.selected = if (self.worlds.len > 0) 0 else null;
        self.confirm_delete = false;
        self.scroll_offset = 0.0;
        self.error_message = null;
    }

    fn renameWorld(self: *@This(), idx: usize) !void {
        const allocator = self.context.allocator;
        const trimmed = std.mem.trim(u8, self.rename_buffer.items, " \t\r\n");
        if (trimmed.len == 0) return;
        const new_name = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(new_name);
        const world = self.worlds[idx];
        var save_dir = try fs.openDirAbsolute(world.dir_path, .{});
        defer save_dir.close();
        try writeLevelDat(allocator, save_dir, trimmed, world.seed, world.generator_index, world.last_played);
        allocator.free(self.worlds[idx].name);
        self.worlds[idx].name = new_name;
        self.confirm_rename = false;
        self.rename_buffer.clearRetainingCapacity();
        self.error_message = null;
    }

    fn clearAllWorlds(self: *@This()) !void {
        const allocator = self.context.allocator;
        const new_worlds = try allocator.alloc(WorldEntry, 0);
        errdefer allocator.free(new_worlds);
        for (self.worlds) |e| {
            try deleteWorld(e.dir_path);
        }
        for (self.worlds) |e| {
            allocator.free(e.name);
            if (e.dir_path.len > 0) allocator.free(e.dir_path);
        }
        allocator.free(self.worlds);
        self.worlds = new_worlds;
        self.selected = null;
        self.confirm_clear_all = false;
        self.scroll_offset = 0.0;
        self.error_message = null;
    }
};

fn drawWorldDetails(ui: *UISystem, rect: Rect, self: *WorldListScreen, scale: f32) void {
    Theme.drawListRail(ui, rect, scale);
    Font.drawText(ui, "WORLD DETAILS", rect.x + 18.0 * scale, rect.y + 18.0 * scale, 0.90 * scale, Theme.signal);
    ui.drawRect(.{ .x = rect.x + 18.0 * scale, .y = rect.y + 44.0 * scale, .width = rect.width - 36.0 * scale, .height = 1.0 * scale }, Theme.outline);
    if (self.selected) |idx| {
        const world = self.worlds[idx];
        Font.drawText(ui, world.name, rect.x + 18.0 * scale, rect.y + 64.0 * scale, 1.36 * scale, Theme.title);
        Font.drawText(ui, registry.getGeneratorInfo(world.generator_index).name, rect.x + 18.0 * scale, rect.y + 100.0 * scale, 1.00 * scale, Theme.text);
        var seed_buf: [64]u8 = undefined;
        const seed_text = std.fmt.bufPrint(&seed_buf, "Seed  {}", .{world.seed}) catch "Seed  unknown";
        Font.drawText(ui, seed_text, rect.x + 18.0 * scale, rect.y + 132.0 * scale, 0.90 * scale, Theme.muted);
        Font.drawText(ui, "Use Play World to resume this save.", rect.x + 18.0 * scale, rect.y + 176.0 * scale, 0.90 * scale, Theme.muted);
    } else {
        Font.drawText(ui, "Select a world", rect.x + 18.0 * scale, rect.y + 68.0 * scale, 1.10 * scale, Theme.title);
        Font.drawText(ui, "Its details and actions will appear here.", rect.x + 18.0 * scale, rect.y + 102.0 * scale, 0.90 * scale, Theme.muted);
    }
}

fn formatTimestamp(ts: i64) []const u8 {
    if (ts <= 0) return "NEVER";
    const now = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const diff = now - ts;
    if (diff < 0) return "NEVER";
    if (diff < 60000) return "JUST NOW";
    if (diff < 3600000) return "EARLIER";
    if (diff < 86400000) return "TODAY";
    if (diff < 172800000) return "YESTERDAY";
    return "OLDER";
}
