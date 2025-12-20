//! Job system for asynchronous chunk operations.

const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const Chunk = @import("../../world/chunk.zig").Chunk;

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
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.jobs.deinit();
    }

    pub fn push(self: *JobQueue, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
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
        return self.jobs.removeOrNull();
    }

    pub fn stop(self: *JobQueue) void {
        self.mutex.lock();
        self.stopped = true;
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
