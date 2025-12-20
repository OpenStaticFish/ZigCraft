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
    allocator: std.mem.Allocator,
    // Current player chunk for dynamic re-prioritization
    player_cx: i32 = 0,
    player_cz: i32 = 0,

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
            .allocator = allocator,
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

    /// Update player position and rebuild priority queue with new distances
    pub fn updatePlayerPos(self: *JobQueue, cx: i32, cz: i32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Only rebuild if player moved
        if (cx == self.player_cx and cz == self.player_cz) return;
        self.player_cx = cx;
        self.player_cz = cz;

        // Rebuild queue with updated priorities
        const count = self.jobs.count();
        if (count == 0) return;

        var temp = std.ArrayListUnmanaged(Job).empty;
        defer temp.deinit(self.allocator);

        // Extract all jobs
        while (self.jobs.removeOrNull()) |job| {
            // Recalculate distance
            const dx = job.chunk_x - cx;
            const dz = job.chunk_z - cz;
            var updated_job = job;
            updated_job.dist_sq = dx * dx + dz * dz;
            temp.append(self.allocator, updated_job) catch continue;
        }

        // Re-add with updated priorities
        for (temp.items) |job| {
            self.jobs.add(job) catch continue;
        }
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
