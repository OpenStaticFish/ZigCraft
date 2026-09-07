//! Regression tests for engine-core job_system.
//!
//! These live under src/ (rather than alongside modules/engine-core/src/
//! job_system.zig) because Zig 0.16 lazy compilation does not collect test
//! blocks from module sub-files reached only through namespace references
//! like `_ = @import("engine-core").job_system;`. Importing the public API
//! types into a local src/ test file forces analysis and ensures these
//! regressions actually execute under `zig build test`.

const std = @import("std");
const testing = std.testing;
const engine_core = @import("engine-core");
const Job = engine_core.Job;
const JobQueue = engine_core.JobQueue;
const JobType = engine_core.JobType;
const ServiceWheel = engine_core.job_system.ServiceWheel;

// --- Test helpers -----------------------------------------------------------

var test_cleanup_count: usize = 0;

fn testNopProcess(ctx: *anyopaque) void {
    _ = ctx;
}

fn testCountingCleanup(ctx: *anyopaque) void {
    _ = ctx;
    test_cleanup_count += 1;
}

fn makeCountingCleanupJob() Job {
    return Job{
        .type = .generic,
        .priority = 0,
        .data = .{
            .generic = .{
                .context = undefined,
                .process_fn = testNopProcess,
                .cleanup_fn = testCountingCleanup,
            },
        },
    };
}

fn expectEqualJob(expected: Job, actual: Job) !void {
    try testing.expectEqual(expected.type, actual.type);
    try testing.expectEqual(expected.priority, actual.priority);
    try testing.expectEqual(expected.dist_sq, actual.dist_sq);
    try testing.expectEqual(expected.service_lane, actual.service_lane);
    try testing.expectEqual(expected.service_sequence, actual.service_sequence);
    // Job's payload is untagged, so compare only the active member.
    switch (expected.type) {
        .generic => try testing.expectEqualDeep(expected.data.generic, actual.data.generic),
        .chunk_generation, .chunk_meshing => try testing.expectEqualDeep(expected.data.chunk, actual.data.chunk),
    }
}

// --- Regression tests for the doReprioritize double-cleanup fix ------------

test "Job.cleanup nullifies cleanup_fn to prevent double-cleanup" {
    // Regression for the doReprioritize OOM double-cleanup issue: after
    // cleanup() runs, cleanup_fn must be cleared so any subsequent call
    // (e.g. if the same Job value is later re-added and the queue is
    // drained) is a no-op rather than a double-free.
    test_cleanup_count = 0;
    var job = makeCountingCleanupJob();
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
    try testing.expect(job.data.generic.cleanup_fn == null);
    // Subsequent cleanup must not re-invoke the cleanup function.
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
}

test "Job.cleanup idempotency survives queue drain after OOM-style drop" {
    // Simulates the doReprioritize OOM pattern at the Job level: a job is
    // dropped via the OOM catch arm (cleanup invoked), then the same Job
    // value is later re-added to a queue that is drained via stop(). With
    // the fix, cleanup_fn is null after the first cleanup, so the queue
    // drain must not trigger a second invocation.
    test_cleanup_count = 0;
    var job = makeCountingCleanupJob();

    // Emulate the doReprioritize OOM drop: cleanup is invoked on the job
    // that failed to be re-added.
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);

    // The caller still holds the (now-cleaned) Job value and re-adds it.
    // Without the fix, cleanup_fn would still be set here.
    try testing.expect(job.data.generic.cleanup_fn == null);

    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    queue.push(job) catch unreachable;

    // Draining the queue must not double-invoke cleanup.
    queue.stop();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
}

test "JobQueue.stop calls cleanup exactly once per generic job" {
    test_cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeCountingCleanupJob()) catch unreachable;
    queue.push(makeCountingCleanupJob()) catch unreachable;

    queue.stop();
    try testing.expectEqual(@as(usize, 2), test_cleanup_count);
}

test "Job.cleanup is no-op for chunk jobs (signature change)" {
    // Sanity check that the *Job signature change for cleanup() compiles
    // and works for chunk-type jobs (which have no cleanup_fn).
    test_cleanup_count = 0;
    var job = Job{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 1 } },
    };
    job.cleanup();
    try testing.expectEqual(@as(usize, 0), test_cleanup_count);
}

test "JobQueue retains explicit bootstrap priorities" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    try queue.push(.{
        .type = .chunk_generation,
        .dist_sq = 7,
        .data = .{ .chunk = .{ .x = 100, .z = 0, .job_token = 1, .preserve_priority = true } },
    });
    try queue.updatePlayerPos(100, 0);

    const job = queue.pop() orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(i32, 7), job.dist_sq);
}

test "ServiceWheel copies weighted order and wraps at fixed capacity" {
    var order = [_]u3{ 0, 1, 3, 2, 4, 3 };
    var wheel = ServiceWheel.init(&order);
    order[0] = 7;
    for (0..3) |_| {
        for ([_]u3{ 0, 1, 3, 2, 4, 3 }) |lane| {
            try testing.expectEqual(lane, wheel.next());
        }
    }
    var full = ServiceWheel.init(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0 });
    for (0..2) |_| {
        for ([_]u3{ 0, 1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0 }) |lane| {
            try testing.expectEqual(lane, full.next());
        }
    }
    var single = ServiceWheel.init(&.{7});
    try testing.expectEqual(@as(u3, 7), single.next());
    try testing.expectEqual(@as(u3, 7), single.next());
}

test "JobQueue service lanes bound near and horizon progress under coarse replenishment" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    const order = [_]u3{ 0, 1, 3, 2, 4, 3 };
    queue.enableServiceLanes(&order);
    // Coarse work has strictly better heap priority, including high bias bits.
    for (0..5) |lane| {
        try testing.expect(try queue.tryPush(.{
            .type = .chunk_generation,
            .service_lane = @intCast(lane),
            .dist_sq = if (lane == 3) 0 else 0x40000000,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = @intCast(lane) } },
        }));
    }
    for (0..4) |_| {
        var serviced: [5]usize = @splat(0);
        for (order, 0..) |lane, i| {
            // Exercise the worker-facing blocking path as well as tryPop.
            const job = (if (i % 2 == 0) queue.tryPop() else queue.pop()) orelse return error.TestExpectedEqual;
            try testing.expectEqual(lane, job.service_lane);
            serviced[job.service_lane] += 1;
            try testing.expect(try queue.tryPush(job));
        }
        try testing.expectEqualSlices(usize, &.{ 1, 1, 1, 2, 1 }, &serviced);
    }
}

test "JobQueue service lanes are FIFO despite higher priority arrivals and caller tickets" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    queue.enableServiceLanes(&.{2});
    for (0..3) |i| {
        const job: Job = .{
            .type = .chunk_meshing,
            .service_lane = 2,
            .service_sequence = 99,
            .dist_sq = @intCast(100 - i),
            .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = @intCast(i) } },
        };
        try testing.expect(try queue.tryPush(job));
        try testing.expectEqual(@as(u64, 99), job.service_sequence);
    }
    for (0..3) |i| {
        const job = queue.tryPop() orelse return error.TestExpectedEqual;
        try testing.expectEqual(@as(u32, @intCast(i)), job.data.chunk.job_token);
        try testing.expectEqual(@as(u64, @intCast(i)), job.service_sequence);
        try testing.expect(try queue.tryPush(.{
            .type = .chunk_meshing,
            .service_lane = 2,
            .dist_sq = 0,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = @intCast(3 + i) } },
        }));
    }
    for (3..6) |i| {
        const job = queue.tryPop() orelse return error.TestExpectedEqual;
        try testing.expectEqual(@as(u32, @intCast(i)), job.data.chunk.job_token);
        try testing.expectEqual(@as(u64, @intCast(i)), job.service_sequence);
    }
    try testing.expect(queue.tryPop() == null);
}

test "JobQueue service lanes yield empty slots and preserve one opportunity across calls" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    queue.enableServiceLanes(&.{ 0, 1, 3, 2, 4, 3 });
    try testing.expect(queue.tryPop() == null);
    const job: Job = .{
        .type = .chunk_generation,
        .service_lane = 3,
        .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 0 } },
    };
    try queue.push(job);
    try testing.expectEqual(@as(u3, 3), queue.tryPop().?.service_lane);
    try testing.expect(queue.tryPop() == null);
    var next_job = job;
    for ([_]u3{ 0, 2, 3 }) |lane| {
        next_job.service_lane = lane;
        try queue.push(next_job);
    }
    // Resume after the first coarse opportunity, not at the start of the wheel.
    for ([_]u3{ 2, 3, 0 }) |lane| {
        try testing.expectEqual(lane, queue.tryPop().?.service_lane);
    }
}

test "JobQueue service lanes preserve tickets and wheel through immediate and lazy movement" {
    for ([_]usize{ 1, engine_core.REPRIORITIZE_THRESHOLD }) |threshold| {
        var queue = JobQueue.init(testing.allocator);
        defer queue.deinit();
        queue.reprioritize_threshold = threshold;
        queue.enableServiceLanes(&.{ 0, 1, 3, 2, 4, 3 });
        for ([_]u3{ 0, 1, 1, 0 }, 0..) |lane, i| {
            try queue.push(.{
                .type = .chunk_generation,
                .service_lane = lane,
                .dist_sq = 0x40000000,
                .data = .{ .chunk = .{ .x = @intCast(i * 10), .z = 0, .job_token = @intCast(i) } },
            });
        }
        try testing.expectEqual(@as(u64, 0), queue.tryPop().?.service_sequence);
        try queue.updatePlayerPos(20, 0);
        for ([_]u64{ 1, 3, 2 }) |sequence| {
            const job = queue.tryPop() orelse return error.TestExpectedEqual;
            try testing.expectEqual(sequence, job.service_sequence);
            try testing.expectEqual(@as(u32, @intCast(sequence)), job.data.chunk.job_token);
            const expected_distance: i32 = if (sequence == 2) 0 else 100;
            try testing.expectEqual(0x40000000 | expected_distance, job.dist_sq);
        }
    }
}

test "JobQueue service lanes preserve pause cancellation cleanup and stopped rejection" {
    test_cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    queue.enableServiceLanes(&.{ 0, 1 });
    var job = makeCountingCleanupJob();
    try testing.expect(try queue.tryPush(job));
    var processed = queue.tryPop().?;
    processed.cleanup();
    try testing.expectEqual(@as(u64, 0), processed.service_sequence);
    try queue.push(job);
    queue.setPaused(true);
    try testing.expect(queue.abort_worker);
    try testing.expectEqual(@as(usize, 2), test_cleanup_count);
    try testing.expect(!(try queue.tryPush(job)));
    try queue.push(job); // Preserve the existing silent rejection contract.
    try queue.updatePlayerPos(10, 20);
    try testing.expectEqual(@as(i32, 0), queue.player_cx);
    try testing.expect(queue.tryPop() == null);
    try testing.expectEqual(@as(usize, 2), test_cleanup_count);
    queue.setPaused(false);
    try testing.expect(!queue.abort_worker);
    try queue.push(job);
    job.service_lane = 1;
    try queue.push(job);
    processed = queue.tryPop().?;
    try testing.expectEqual(@as(u3, 1), processed.service_lane);
    try testing.expectEqual(@as(u64, 3), processed.service_sequence);
    processed.cleanup();
    queue.clear();
    queue.clear();
    try testing.expect(queue.tryPop() == null);
    try testing.expectEqual(@as(usize, 4), test_cleanup_count);
    try queue.push(job);
    queue.stop();
    queue.stop();
    try testing.expect(queue.abort_worker);
    try testing.expect(!(try queue.tryPush(job)));
    try testing.expect(queue.tryPop() == null);
    try testing.expect(queue.pop() == null);
    try testing.expectEqual(@as(usize, 5), test_cleanup_count);
}

test "JobQueue default priority and movement leave submitted service fields unchanged" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    var context: u8 = 0;
    const generic: Job = .{
        .type = .generic,
        .priority = -1,
        .service_lane = 7,
        .service_sequence = 123,
        .data = .{ .generic = .{ .context = &context, .process_fn = testNopProcess } },
    };
    const spatial: Job = .{
        .type = .chunk_generation,
        .dist_sq = 100,
        .data = .{ .chunk = .{ .x = 10, .z = 0, .job_token = 1 } },
    };
    var closer = spatial;
    closer.dist_sq = 1;
    closer.data.chunk.x = 1;
    try queue.push(spatial);
    try queue.push(closer);
    try queue.push(generic);
    try expectEqualJob(generic, queue.tryPop().?);
    try expectEqualJob(closer, queue.pop().?);
    try expectEqualJob(spatial, queue.tryPop().?);
    for ([_]usize{ 1, engine_core.REPRIORITIZE_THRESHOLD }) |threshold| {
        queue.reprioritize_threshold = threshold;
        try queue.updatePlayerPos(0, 0);
        try queue.push(spatial);
        try queue.push(closer);
        try queue.updatePlayerPos(10, 0);
        var expected = spatial;
        expected.dist_sq = 0;
        try expectEqualJob(expected, queue.tryPop().?);
        expected = closer;
        expected.dist_sq = 81;
        try expectEqualJob(expected, queue.tryPop().?);
    }
    try testing.expect(queue.tryPop() == null);
}
