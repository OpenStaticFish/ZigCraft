const std = @import("std");
const testing = std.testing;

const screen_mod = @import("screen.zig");
const WorldStats = @import("engine-ui").WorldStats;

const MockScreen = struct {
    update_count: u32 = 0,
    enter_count: u32 = 0,
    exit_count: u32 = 0,
    deinit_count: u32 = 0,
    background_draw_count: u32 = 0,
    last_dt: f32 = 0.0,

    pub const vtable = screen_mod.IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .onExit = onExit,
        .getWorldStats = getWorldStats,
    };

    fn asScreen(self: *@This()) screen_mod.IScreen {
        return screen_mod.makeScreen(MockScreen, self);
    }

    fn cast(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn deinit(ptr: *anyopaque) void {
        cast(ptr).deinit_count += 1;
    }

    fn update(ptr: *anyopaque, dt: f32) anyerror!void {
        const self = cast(ptr);
        self.update_count += 1;
        self.last_dt = dt;
    }

    fn drawBackground(ptr: *anyopaque, ui: *@import("engine-ui").UISystem) anyerror!void {
        _ = ui;
        cast(ptr).background_draw_count += 1;
    }

    fn onEnter(ptr: *anyopaque) void {
        cast(ptr).enter_count += 1;
    }

    fn onExit(ptr: *anyopaque) void {
        cast(ptr).exit_count += 1;
    }

    fn getWorldStats(ptr: *anyopaque) ?WorldStats {
        _ = ptr;
        return .{
            .chunks_total = 4,
            .chunks_rendered = 4,
            .chunks_culled = 0,
            .vertices_rendered = 64,
            .gen_queue = 0,
            .mesh_queue = 0,
            .upload_queue = 0,
        };
    }
};

test "IScreen forwards optional update and stats callbacks" {
    var mock = MockScreen{};
    const screen = mock.asScreen();

    try screen.update(0.25);
    const stats = screen.getWorldStats().?;

    try testing.expectEqual(@as(u32, 1), mock.update_count);
    try testing.expectEqual(@as(f32, 0.25), mock.last_dt);
    try testing.expectEqual(@as(u32, 4), stats.chunks_total);
}

test "IScreen tolerates missing optional callbacks" {
    const Bare = struct {
        pub const vtable = screen_mod.IScreen.VTable{ .deinit = deinit };
        fn deinit(ptr: *anyopaque) void {
            _ = ptr;
        }
    };
    var bare = Bare{};
    const screen = screen_mod.makeScreen(Bare, &bare);

    try screen.update(1.0);
    screen.onEnter();
    screen.onExit();

    try testing.expectEqual(@as(?WorldStats, null), screen.getWorldStats());
}

test "ScreenManager push enters and updates top screen" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var first = MockScreen{};

    manager.pushScreen(first.asScreen());
    try manager.update(0.5);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 1), first.enter_count);
    try testing.expectEqual(@as(u32, 1), first.update_count);
    try testing.expectEqual(@as(f32, 0.5), first.last_dt);
}

test "ScreenManager push exits previous screen and enters child" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var parent = MockScreen{};
    var child = MockScreen{};

    manager.pushScreen(parent.asScreen());
    try manager.update(0.1);
    manager.pushScreen(child.asScreen());
    try manager.update(0.2);

    try testing.expectEqual(@as(usize, 2), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 1), parent.exit_count);
    try testing.expectEqual(@as(u32, 1), child.enter_count);
    try testing.expectEqual(@as(u32, 1), child.update_count);
}

test "ScreenManager pop deinitializes child and re-enters parent" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var parent = MockScreen{};
    var child = MockScreen{};

    manager.pushScreen(parent.asScreen());
    try manager.update(0.1);
    manager.pushScreen(child.asScreen());
    try manager.update(0.2);
    manager.popScreen();
    try manager.update(0.3);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 2), parent.enter_count);
    try testing.expectEqual(@as(u32, 1), child.exit_count);
    try testing.expectEqual(@as(u32, 1), child.deinit_count);
}

test "ScreenManager replace exits and deinitializes existing stack" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var first = MockScreen{};
    var replacement = MockScreen{};

    manager.pushScreen(first.asScreen());
    try manager.update(0.1);
    manager.setScreen(replacement.asScreen());
    try manager.update(0.2);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 1), first.exit_count);
    try testing.expectEqual(@as(u32, 1), first.deinit_count);
    try testing.expectEqual(@as(u32, 1), replacement.enter_count);
}

test "ScreenManager replaces pending push with deinit" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var abandoned = MockScreen{};
    var replacement = MockScreen{};

    manager.pushScreen(abandoned.asScreen());
    manager.setScreen(replacement.asScreen());
    try manager.update(0.1);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 1), abandoned.deinit_count);
    try testing.expectEqual(@as(u32, 1), replacement.enter_count);
}

test "ScreenManager pop on empty stack is a no-op" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();

    manager.popScreen();
    try manager.update(0.1);

    try testing.expectEqual(@as(usize, 0), manager.stack.items.len);
}

test "ScreenManager interface queues screen transitions" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var first = MockScreen{};

    const iface = manager.interface();
    iface.pushScreen(first.asScreen().handle());
    try manager.update(0.1);

    try testing.expectEqual(@as(usize, 1), manager.stack.items.len);
    try testing.expectEqual(@as(u32, 1), first.enter_count);
}

test "ScreenManager draws the nearest background provider below a child" {
    var manager = screen_mod.ScreenManager.init(testing.allocator);
    defer manager.deinit();
    var parent = MockScreen{};
    var child = MockScreen{};

    manager.pushScreen(parent.asScreen());
    try manager.update(0.1);
    manager.pushScreen(child.asScreen());
    try manager.update(0.1);

    var ui: @import("engine-ui").UISystem = undefined;
    try manager.drawBackgroundFor(&child, &ui);

    try testing.expectEqual(@as(u32, 1), parent.background_draw_count);
    try testing.expectEqual(@as(u32, 0), child.background_draw_count);
}
