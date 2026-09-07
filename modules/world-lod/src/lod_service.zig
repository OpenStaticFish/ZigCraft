//! Manager-owned lifetime service accounting. Lanes are frozen at admission.
const std = @import("std");

pub const Class = enum(u3) { local_fallback, near0, near1, horizon, refinement };
pub const CLASS_COUNT: usize = 5;
pub const WHEEL = [_]u3{ 0, 1, 3, 2, 4, 3 };
pub const Event = enum { admitted, dispatched, started, renderable };

/// Initial memory policy: reserve 25% of the global budget for local fallback
/// and near lanes (0/1/2). Background admission and upload growth (3/4) may use
/// only 75%, rounded down; urgent lanes retain the full hard limit. Zero means
/// unlimited. This gates logical reservations and known upload peaks, not worker
/// allocations: source/mesh builds can outgrow their admission estimates.
pub fn memoryLimit(lane: u3, budget_bytes: usize) usize {
    std.debug.assert(lane < CLASS_COUNT);
    if (budget_bytes == 0) return std.math.maxInt(usize);
    if (lane < @intFromEnum(Class.horizon)) return budget_bytes;
    const reserve = budget_bytes / 4 + @intFromBool(budget_bytes % 4 != 0);
    return budget_bytes - reserve;
}

/// Background lanes retain only the *unconsumed* portion of the near reserve.
/// Accounted, exclusively owned local/near allocations have already claimed
/// that reserve, so charging it again would strand feasible horizon uploads
/// below the hard cap. Shared pools and canonical source-cache capacity are
/// deliberately excluded from `near_exclusive_bytes`: neither belongs solely
/// to a near service lane.
pub fn memoryLimitWithNearUsage(lane: u3, budget_bytes: usize, near_exclusive_bytes: usize) usize {
    const soft_limit = memoryLimit(lane, budget_bytes);
    if (budget_bytes == 0 or lane < @intFromEnum(Class.horizon)) return soft_limit;
    const reserve = budget_bytes -| soft_limit;
    return soft_limit +| @min(reserve, near_exclusive_bytes);
}

pub const Snapshot = struct {
    admitted: [CLASS_COUNT]u64 = @splat(0),
    dispatched: [CLASS_COUNT]u64 = @splat(0),
    started: [CLASS_COUNT]u64 = @splat(0),
    renderable: [CLASS_COUNT]u64 = @splat(0),
};

pub const Counters = struct {
    const Atomic = std.atomic.Value(u64);
    admitted: [CLASS_COUNT]Atomic = @splat(Atomic.init(0)),
    dispatched: [CLASS_COUNT]Atomic = @splat(Atomic.init(0)),
    started: [CLASS_COUNT]Atomic = @splat(Atomic.init(0)),
    renderable: [CLASS_COUNT]Atomic = @splat(Atomic.init(0)),

    pub fn record(self: *Counters, event: Event, lane: u3) void {
        std.debug.assert(lane < CLASS_COUNT);
        switch (event) {
            inline else => |tag| _ = @field(self, @tagName(tag))[lane].fetchAdd(1, .monotonic),
        }
    }

    /// Each value is atomic; concurrent events need not appear in the same snapshot.
    pub fn snapshot(self: *const Counters) Snapshot {
        var result: Snapshot = undefined;
        inline for (std.meta.fields(Snapshot)) |field| {
            for (0..CLASS_COUNT) |lane| {
                @field(result, field.name)[lane] = @field(self, field.name)[lane].load(.monotonic);
            }
        }
        return result;
    }
};

test "service counters retain independent lifetime events across snapshots" {
    var counters: Counters = .{};
    inline for (std.meta.fields(Event)) |field| {
        const event: Event = @enumFromInt(field.value);
        for (0..CLASS_COUNT) |lane| {
            try std.testing.expectEqual(@as(u64, 0), @field(counters.snapshot(), field.name)[lane]);
            for (0..lane + 1) |_| counters.record(event, @intCast(lane));
        }
    }
    const before = counters.snapshot();
    counters.record(.started, @intFromEnum(Class.horizon));
    const after = counters.snapshot();
    inline for (std.meta.fields(Event)) |field| {
        for (0..CLASS_COUNT) |lane| {
            try std.testing.expectEqual(@as(u64, @intCast(lane + 1)), @field(before, field.name)[lane]);
            const extra: u64 = if (field.value == @intFromEnum(Event.started) and lane == @intFromEnum(Class.horizon)) 1 else 0;
            try std.testing.expectEqual(@field(before, field.name)[lane] + extra, @field(after, field.name)[lane]);
        }
    }
}

test "background memory limit discounts only consumed near reserve" {
    const MiB = 1024 * 1024;
    const budget = 256 * MiB;
    const horizon = @intFromEnum(Class.horizon);
    try std.testing.expectEqual(@as(usize, 192 * MiB), memoryLimitWithNearUsage(horizon, budget, 0));
    try std.testing.expectEqual(@as(usize, 236 * MiB), memoryLimitWithNearUsage(horizon, budget, 44 * MiB));
    try std.testing.expectEqual(budget, memoryLimitWithNearUsage(horizon, budget, 64 * MiB));
    try std.testing.expectEqual(budget, memoryLimitWithNearUsage(horizon, budget, 128 * MiB));
}
