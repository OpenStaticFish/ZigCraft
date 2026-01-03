//! Job system for asynchronous chunk operations.

const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const Chunk = @import("../../world/chunk.zig").Chunk;
const log = @import("log.zig");

pub const JobType = enum {
    generation,
    meshing,
};

pub const Job = struct {
    type: JobType,
    chunk_x: i32,
    chunk_z: i32,
    job_token: u32,
    dist_sq: i32, // Priority: closer is smaller

    // Comparison for min-heap (lower dist = higher priority)
    pub fn compare(a: Job, b: Job) std.math.Order {
        return std.math.order(a.dist_sq, b.dist_sq);
    }
};

pub const JobQueue = struct {
    mutex: Mutex,
    cond: Condition,
    jobs: std.PriorityQueue(Job, void, compareJobs),
    stopped: bool,
    paused: bool = false,
    abort_worker: bool = false,
    allocator: std.mem.Allocator,
    // Current player chunk for dynamic re-prioritization
    player_cx: i32 = 0,
    player_cz: i32 = 0,
    // Lazy re-prioritization: mark dirty instead of immediate rebuild
    needs_reprioritize: bool = false,
    // Threshold: only reprioritize if queue has this many items
    reprioritize_threshold: usize = 16,

    fn compareJobs(context: void, a: Job, b: Job) std.math.Order {
        _ = context;
        return a.compare(b);
    }

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{
            .mutex = Mutex{},
            .cond = Condition{},
            .jobs = std.PriorityQueue(Job, void, compareJobs).init(allocator, {}),
            .stopped = false,
            .paused = false,
            .abort_worker = false,
            .allocator = allocator,
            .needs_reprioritize = false,
            .reprioritize_threshold = 16,
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.jobs.deinit();
    }

    pub fn push(self: *JobQueue, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.paused) return;
        try self.jobs.add(job);
        self.cond.signal();
    }

    pub fn pop(self: *JobQueue) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.count() == 0 and !self.stopped) {
            self.cond.wait(&self.mutex);
        }

        if (self.stopped and self.jobs.count() == 0) return null;

        // Lazy reprioritization: only rebuild if marked dirty and queue is large
        if (self.needs_reprioritize and self.jobs.count() >= self.reprioritize_threshold) {
            self.doReprioritize();
            self.needs_reprioritize = false;
        }

        return self.jobs.removeOrNull();
    }

    /// Internal: rebuild queue with updated distances (called under lock)
    fn doReprioritize(self: *JobQueue) void {
        const count = self.jobs.count();
        if (count == 0) return;

        var temp = std.ArrayListUnmanaged(Job).empty;
        defer temp.deinit(self.allocator);

        // Extract all jobs
        while (self.jobs.removeOrNull()) |job| {
            // Recalculate distance from current player position
            const dx = job.chunk_x - self.player_cx;
            const dz = job.chunk_z - self.player_cz;
            var updated_job = job;
            updated_job.dist_sq = dx * dx + dz * dz;
            temp.append(self.allocator, updated_job) catch {
                log.log.warn("Job queue: dropped job during priority update (allocation failed)", .{});
                continue;
            };
        }

        // Re-add with updated priorities
        for (temp.items) |job| {
            self.jobs.add(job) catch {
                log.log.warn("Job queue: failed to re-add job after priority update", .{});
                continue;
            };
        }
    }

    /// Update player position and mark queue for lazy re-prioritization.
    /// The actual rebuild happens on next pop() if the queue is large enough.
    pub fn updatePlayerPos(self: *JobQueue, cx: i32, cz: i32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.paused) return;

        // Only mark for reprioritization if player moved
        if (cx == self.player_cx and cz == self.player_cz) return;
        self.player_cx = cx;
        self.player_cz = cz;

        // Mark for lazy reprioritization instead of immediate rebuild
        // For small queues, the overhead of tracking dirty state isn't worth it
        if (self.jobs.count() >= self.reprioritize_threshold) {
            self.needs_reprioritize = true;
        } else if (self.jobs.count() > 0) {
            // For small queues, just do it immediately
            self.doReprioritize();
        }
    }

    pub fn clear(self: *JobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs.removeOrNull()) |_| {}
    }

    pub fn setPaused(self: *JobQueue, paused: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.paused = paused;
        self.abort_worker = paused or self.stopped;
        if (paused) {
            while (self.jobs.removeOrNull()) |_| {}
        } else {
            self.cond.broadcast();
        }
    }

    pub fn stop(self: *JobQueue) void {
        self.mutex.lock();
        self.stopped = true;
        self.abort_worker = true;
        // Clear all pending jobs to allow workers to exit immediately
        while (self.jobs.removeOrNull()) |_| {}
        self.mutex.unlock();
        self.cond.broadcast();
    }
};

pub const WorkerPool = struct {
    threads: []Thread,
    allocator: std.mem.Allocator,
    context: *anyopaque,

    // Callbacks
    process_job_fn: *const fn (*anyopaque, Job) void,

    pub fn init(allocator: std.mem.Allocator, count: usize, queue: *JobQueue, context: *anyopaque, process_fn: *const fn (*anyopaque, Job) void) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        const threads = try allocator.alloc(Thread, count);

        pool.* = WorkerPool{
            .threads = threads,
            .allocator = allocator,
            .context = context,
            .process_job_fn = process_fn,
        };

        for (threads) |*t| {
            t.* = try Thread.spawn(.{}, workerThread, .{ queue, pool });
        }

        return pool;
    }

    pub fn deinit(self: *WorkerPool) void {
        for (self.threads) |t| {
            t.join();
        }
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    fn workerThread(queue: *JobQueue, pool: *WorkerPool) void {
        while (true) {
            const job = queue.pop() orelse break;
            pool.process_job_fn(pool.context, job);
        }
    }
};
