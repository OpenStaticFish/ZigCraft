const std = @import("std");
const App = @import("game/app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
