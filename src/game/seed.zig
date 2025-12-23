const std = @import("std");
const c = @import("../c.zig").c;

pub fn randomSeedValue() u64 {
    const t: u64 = @intCast(c.SDL_GetTicks());
    const p: u64 = @intCast(c.SDL_GetPerformanceCounter());
    var s = p ^ (t << 32);
    s ^= s >> 33;
    s *%= 0xff51afd7ed558ccd;
    s ^= s >> 33;
    s *%= 0xc4ceb9fe1a85ec53;
    s ^= s >> 33;
    return s;
}

pub fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (bytes) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

pub fn seedFromText(text: []const u8) u64 {
    var all = true;
    for (text) |ch| {
        if (ch < '0' or ch > '9') {
            all = false;
            break;
        }
    }
    if (all) return std.fmt.parseUnsigned(u64, text, 10) catch fnv1a64(text);
    return fnv1a64(text);
}

pub fn resolveSeed(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !u64 {
    const trimmed = std.mem.trim(u8, seed_input.items, " \t");
    if (trimmed.len == 0) {
        const gen = randomSeedValue();
        try setSeedInput(seed_input, allocator, gen);
        return gen;
    }
    return seedFromText(trimmed);
}

pub fn setSeedInput(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    var buf: [32]u8 = undefined;
    const wr = try std.fmt.bufPrint(&buf, "{d}", .{val});
    seed_input.clearRetainingCapacity();
    try seed_input.appendSlice(allocator, wr);
}
