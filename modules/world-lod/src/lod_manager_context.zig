const std = @import("std");
const engine_core = @import("engine-core");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const LODColumnProvenance = world_core.LODColumnProvenance;
const ServiceWheel = engine_core.job_system.ServiceWheel;

pub const ChunkCoordKey = struct {
    cx: i32,
    cz: i32,

    pub fn hash(self: ChunkCoordKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.cx));
        const uz: u64 = @bitCast(@as(i64, self.cz));
        return ux ^ (uz *% 0x9e3779b97f4a7c15);
    }
    pub fn eql(a: ChunkCoordKey, b: ChunkCoordKey) bool {
        return a.cx == b.cx and a.cz == b.cz;
    }
};

pub const ChunkCoordKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkCoordKey) u64 {
        _ = self;
        return key.hash();
    }
    pub fn eql(self: @This(), a: ChunkCoordKey, b: ChunkCoordKey) bool {
        _ = self;
        return a.eql(b);
    }
};

pub const PendingIngestion = struct {
    cx: i32,
    cz: i32,
    provenance: LODColumnProvenance,
    pending_levels: u8,
    /// Retained for wire/API compatibility with the former expiring queue.
    /// Deferred ingestion is now durable for the manager lifetime, so this is
    /// always zero and must not be decremented into deletion.
    ttl: u16 = 0,
};

pub const GenerationCandidate = struct {
    key: LODRegionKey,
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
    coord_scale: i32,
    job_token: u32,
    lod_radius: i32,
    want_spans: bool,
};

pub const MeshCandidate = struct {
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
    coord_scale: i32,
    job_token: u32,
    lod_radius: i32,
};

pub const UploadCandidate = struct {
    chunk: *LODChunk,
    encoded_priority: i32,
    level: u3,
};

/// A lifecycle record is deliberately value-only: maps remain the source of
/// truth and the token is checked when popped.  This makes superseded work
/// cheap to leave in the heap while edits, teleports, and remeshes advance a
/// region token/revision.
pub const LifecycleStage = enum { generation, mesh, upload, fade };

pub const LifecycleToken = struct {
    key: LODRegionKey,
    job_token: u32,
    source_revision: u32,
    priority: i32,
    stage: LifecycleStage,
    service_lane: u3 = 4,
    /// Assigned by the queue, not the producer, to retain FIFO within a lane.
    service_sequence: u64 = 0,

    /// Map records are authoritative; queued copies are accepted only while
    /// both lifecycle and source revisions still match.
    pub fn matches(self: LifecycleToken, chunk: *const LODChunk) bool {
        return self.job_token == chunk.job_token and self.source_revision == chunk.source_revision;
    }
};

pub const LifecyclePushResult = enum { primary, overflow };

pub const LifecycleQueue = struct {
    const Heap = std.PriorityQueue(LifecycleToken, void, compare);
    const ServiceHeap = std.PriorityQueue(LifecycleToken, void, compareSequence);

    mutex: sync.Mutex = .{},
    heap: Heap = Heap.initContext({}),
    overflow_heap: Heap = Heap.initContext({}),
    /// Bounds transition work independently of the number of resident maps.
    capacity: usize = MAX_LIFECYCLE_TOKENS,
    /// A bounded overflow heap retains accepted work immediately rather than
    /// abandoning it until reconciliation. It is large enough to hold several
    /// stale generations for every resident region while remaining bounded.
    overflow_capacity: usize = MAX_LIFECYCLE_OVERFLOW_TOKENS,
    overflow_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    service_wheel: ServiceWheel = .{},
    service_heaps: [8]ServiceHeap = @splat(ServiceHeap.initContext({})),
    service_count: usize = 0,
    next_sequence: u64 = 0,

    fn compare(_: void, a: LifecycleToken, b: LifecycleToken) std.math.Order {
        return std.math.order(a.priority, b.priority);
    }

    fn compareSequence(_: void, a: LifecycleToken, b: LifecycleToken) std.math.Order {
        return std.math.order(a.service_sequence, b.service_sequence);
    }

    /// Opt in before producers start. Default/fade queues retain priority semantics.
    pub fn enableServiceLanes(self: *LifecycleQueue, order: []const u3) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.heap.count() + self.overflow_heap.count() + self.service_count == 0);
        self.service_wheel = ServiceWheel.init(order);
    }

    pub fn deinit(self: *LifecycleQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.heap.deinit(allocator);
        self.overflow_heap.deinit(allocator);
        for (&self.service_heaps) |*heap| heap.deinit(allocator);
    }

    /// All heap mutations are serialized because workers publish transitions
    /// while the main thread consumes them. Overflow work stays prioritized and
    /// is consumed on the next pop rather than waiting for reconciliation.
    pub fn push(self: *LifecycleQueue, allocator: std.mem.Allocator, token: LifecycleToken) !LifecyclePushResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.service_wheel.len != 0) {
            const overflow = self.service_count >= self.capacity;
            if (overflow and self.service_count - self.capacity >= self.overflow_capacity) return error.LifecycleQueueFull;
            var queued = token;
            queued.service_sequence = self.next_sequence;
            try self.service_heaps[queued.service_lane].push(allocator, queued);
            self.next_sequence +%= 1;
            self.service_count += 1;
            if (overflow) _ = self.overflow_events.fetchAdd(1, .monotonic);
            return if (overflow) .overflow else .primary;
        }
        if (self.heap.count() < self.capacity) {
            try self.heap.push(allocator, token);
            return .primary;
        }
        if (self.overflow_heap.count() >= self.overflow_capacity) return error.LifecycleQueueFull;
        try self.overflow_heap.push(allocator, token);
        _ = self.overflow_events.fetchAdd(1, .monotonic);
        return .overflow;
    }

    pub fn pop(self: *LifecycleQueue) ?LifecycleToken {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.service_wheel.len != 0) {
            if (self.service_count == 0) return null;
            for (0..self.service_wheel.len) |_| {
                const lane = self.service_wheel.next();
                if (self.service_heaps[lane].pop()) |token| {
                    self.service_count -= 1;
                    return token;
                }
            }
            // Partial orders must not strand tokens from unscheduled lanes.
            var oldest_lane: ?usize = null;
            for (&self.service_heaps, 0..) |*heap, lane| {
                const token = heap.peek() orelse continue;
                if (oldest_lane == null or token.service_sequence < self.service_heaps[oldest_lane.?].peek().?.service_sequence) oldest_lane = lane;
            }
            self.service_count -= 1;
            return self.service_heaps[oldest_lane.?].pop();
        }
        const primary = self.heap.peek();
        const overflow = self.overflow_heap.peek();
        if (primary == null) return self.overflow_heap.pop();
        if (overflow == null) return self.heap.pop();
        return if (compare({}, overflow.?, primary.?) == .lt)
            self.overflow_heap.pop()
        else
            self.heap.pop();
    }

    pub fn count(self: *LifecycleQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.heap.count() + self.overflow_heap.count() + self.service_count;
    }

    pub fn overflowEvents(self: *const LifecycleQueue) u64 {
        return self.overflow_events.load(.monotonic);
    }
};

pub const PlayerChunkPos = struct {
    cx: i32,
    cz: i32,
};

/// Persistent bounded concentric-scan cursor for one LOD level.
pub const LODScanState = struct {
    player_rx: i32 = 0,
    player_rz: i32 = 0,
    effective_radius: i32 = -1,
    next_ring: i64 = 0,
    ring_index: i64 = 0,
    last_examined: usize = 0,
};

pub const ChunkResolver = struct {
    ptr: *anyopaque,
    resolve_fn: *const fn (ptr: *anyopaque, cx: i32, cz: i32) ?*const Chunk,
    capture_near_fn: ?*const fn (ptr: *anyopaque, cx: i32, cz: i32) ?@import("lod_near_source.zig").NearChunkSummary = null,

    pub fn resolve(self: ChunkResolver, cx: i32, cz: i32) ?*const Chunk {
        return self.resolve_fn(self.ptr, cx, cz);
    }
};

pub const MAX_LOD_REGIONS = 2048;
/// Conservative logical reservation made before a region has source data or a
/// mesh. It bounds cold-cache admissions against the configured total LOD
/// memory cap; exact accounting remains available in diagnostics.
pub const LOGICAL_LOD_REGION_RESERVATION_BYTES: usize = 1024 * 1024;
/// Local/near services scan a small overlap beyond full-detail coverage. Memory
/// eviction must preserve this same collar or it can evict a region that the
/// near service is responsible for replacing, then shrink that service out of
/// the region before it gets another turn.
pub const LOCAL_SERVICE_COLLAR_CHUNKS: i32 = 4;
// Bound queued and in-flight regions so a cold cache cannot bury the horizon
// fallback behind thousands of expensive generation jobs.
pub const MAX_PENDING_LOD_REGIONS: usize = 64;
pub const CHUNK_COVERAGE_PADDING: i32 = 1;
pub const LOD_UPDATE_DIVISOR: u32 = 2;
// WorldStreamer reserves these workers from its foreground pools whenever LOD
// is enabled, so horizon generation can be fast without oversubscribing CPUs.
pub const MIN_LOD_WORKERS: usize = 1;
pub const MAX_LOD_WORKERS: usize = 8;
pub const MAX_MEMORY_EVICTIONS_PER_UPDATE: usize = 32;
pub const MAX_MESH_DELETIONS_PER_SWEEP: usize = 64;
pub const DELETION_SWEEP_SECONDS: f32 = 1.0;
pub const DEFAULT_LOD_UPLOAD_BUDGET_BYTES: usize = 32 * 1024 * 1024;
pub const LOD_UPLOAD_BUDGET_ENV = "ZIGCRAFT_LOD_UPLOAD_BUDGET_MB";
pub const MAX_CACHE_LOADS_PER_UPDATE: usize = 8;
pub const MAX_PENDING_INGESTIONS: usize = 4096;
pub const EDIT_FLUSH_COOLDOWN: f32 = 1.0;
pub const LOD_FRAME_DT_APPROX: f32 = 0.016;
pub const MAX_LIFECYCLE_TOKENS: usize = 256;
pub const MAX_LIFECYCLE_OVERFLOW_TOKENS: usize = MAX_LOD_REGIONS * 4;
pub const MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE: usize = 48;
/// This is an explicit safety net for lost/overflowed tokens, not normal
/// scheduling. Keep it rare so resident map size does not drive frame work.
pub const LIFECYCLE_RECONCILIATION_INTERVAL: u32 = 240;

pub fn lodUploadBudgetBytes() usize {
    const raw = engine_core.getenv(LOD_UPLOAD_BUDGET_ENV) orelse return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    const mb = std.fmt.parseUnsigned(usize, raw, 10) catch return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    if (mb == 0) return std.math.maxInt(usize);
    return std.math.mul(usize, mb, 1024 * 1024) catch DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
}

pub fn wouldExceedUploadBudget(uploaded_bytes: usize, pending_bytes: usize, budget_bytes: usize) bool {
    if (budget_bytes == 0 or budget_bytes == std.math.maxInt(usize)) return false;
    if (pending_bytes == 0) return false;
    if (uploaded_bytes >= budget_bytes) return true;
    return pending_bytes > budget_bytes - uploaded_bytes;
}

pub fn isUploadPressureError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.PendingCopyOverflow => true,
        else => false,
    };
}

test "LifecycleQueue bounds transition work independently of resident regions" {
    var queue = LifecycleQueue{ .capacity = 2, .overflow_capacity = 2 };
    defer queue.deinit(std.testing.allocator);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };

    try std.testing.expectEqual(LifecyclePushResult.primary, try queue.push(std.testing.allocator, .{ .key = key, .job_token = 1, .source_revision = 0, .priority = 20, .stage = .mesh }));
    try std.testing.expectEqual(LifecyclePushResult.primary, try queue.push(std.testing.allocator, .{ .key = key, .job_token = 2, .source_revision = 1, .priority = 4, .stage = .mesh }));
    try std.testing.expectEqual(LifecyclePushResult.overflow, try queue.push(std.testing.allocator, .{ .key = key, .job_token = 3, .source_revision = 2, .priority = 1, .stage = .mesh }));
    try std.testing.expectEqual(@as(usize, 3), queue.count());
    try std.testing.expectEqual(@as(u64, 1), queue.overflowEvents());
    try std.testing.expectEqual(@as(u32, 3), queue.pop().?.job_token);
}

test "LifecycleToken rejects stale lifecycle and source revisions" {
    var chunk = LODChunk.init(0, 0, .lod3);
    chunk.job_token = 8;
    chunk.source_revision = 3;
    const current = LifecycleToken{ .key = chunk.key(), .job_token = 8, .source_revision = 3, .priority = 0, .stage = .mesh };
    const stale_job = LifecycleToken{ .key = chunk.key(), .job_token = 7, .source_revision = 3, .priority = 0, .stage = .mesh };
    const stale_source = LifecycleToken{ .key = chunk.key(), .job_token = 8, .source_revision = 2, .priority = 0, .stage = .mesh };
    try std.testing.expect(current.matches(&chunk));
    try std.testing.expect(!stale_job.matches(&chunk));
    try std.testing.expect(!stale_source.matches(&chunk));
}

test "LifecycleQueue service lanes retain weighted FIFO across overflow" {
    const service = @import("lod_service.zig");
    var queue = LifecycleQueue{ .capacity = 2, .overflow_capacity = 10 };
    defer queue.deinit(std.testing.allocator);
    queue.enableServiceLanes(&service.WHEEL);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    for (0..service.CLASS_COUNT) |lane| {
        const count: usize = if (lane == @intFromEnum(service.Class.horizon)) 4 else 2;
        for (0..count) |i| {
            _ = try queue.push(std.testing.allocator, .{
                .key = key,
                .job_token = @intCast(lane * 10 + i),
                .source_revision = 0,
                .priority = -@as(i32, @intCast(lane * 10 + i)),
                .stage = .mesh,
                .service_lane = @intCast(lane),
                .service_sequence = 100 - i,
            });
        }
    }
    try std.testing.expectEqual(@as(usize, 12), queue.count());
    try std.testing.expectEqual(@as(u64, 10), queue.overflowEvents());
    try std.testing.expectError(error.LifecycleQueueFull, queue.push(std.testing.allocator, .{
        .key = key,
        .job_token = 99,
        .source_revision = 0,
        .priority = -1000,
        .stage = .mesh,
    }));
    var consumed: [service.CLASS_COUNT]u32 = @splat(0);
    for (0..2) |_| {
        for (service.WHEEL) |lane| {
            const token = queue.pop().?;
            try std.testing.expectEqual(lane, token.service_lane);
            try std.testing.expectEqual(@as(u32, lane) * 10 + consumed[lane], token.job_token);
            consumed[lane] += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    const cursor = queue.service_wheel.cursor;
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectEqual(cursor, queue.service_wheel.cursor);
}

test "LifecycleQueue default ignores service lanes and retains priority order" {
    var queue: LifecycleQueue = .{};
    defer queue.deinit(std.testing.allocator);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    _ = try queue.push(std.testing.allocator, .{ .key = key, .job_token = 1, .source_revision = 0, .priority = 20, .stage = .fade, .service_lane = 0 });
    _ = try queue.push(std.testing.allocator, .{ .key = key, .job_token = 2, .source_revision = 0, .priority = 1, .stage = .fade, .service_lane = 4 });
    try std.testing.expectEqual(@as(u32, 2), queue.pop().?.job_token);
    try std.testing.expectEqual(@as(u32, 1), queue.pop().?.job_token);
}

test "LifecycleQueue serializes concurrent production push and pop operations" {
    const Producer = struct {
        fn run(queue: *LifecycleQueue, base: i32) void {
            const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod4 };
            for (0..64) |i| {
                _ = queue.push(std.heap.page_allocator, .{ .key = key, .job_token = @intCast(i + 1), .source_revision = 0, .priority = base + @as(i32, @intCast(i)), .stage = .mesh }) catch unreachable;
            }
        }
    };
    var queue = LifecycleQueue{ .capacity = 128 };
    defer queue.deinit(std.heap.page_allocator);
    var first = try std.Thread.spawn(.{}, Producer.run, .{ &queue, @as(i32, 64) });
    var second = try std.Thread.spawn(.{}, Producer.run, .{ &queue, @as(i32, 0) });
    first.join();
    second.join();
    try std.testing.expectEqual(@as(usize, 128), queue.count());

    const Consumer = struct {
        fn run(queue_ptr: *LifecycleQueue, consumed_ptr: *std.atomic.Value(u32)) void {
            while (queue_ptr.pop()) |_| {
                _ = consumed_ptr.fetchAdd(1, .monotonic);
            }
        }
    };
    var consumed = std.atomic.Value(u32).init(0);
    var consumer_a = try std.Thread.spawn(.{}, Consumer.run, .{ &queue, &consumed });
    var consumer_b = try std.Thread.spawn(.{}, Consumer.run, .{ &queue, &consumed });
    consumer_a.join();
    consumer_b.join();
    try std.testing.expectEqual(@as(u32, 128), consumed.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

comptime {
    if (LODLevel.count < 2) {
        @compileError("LOD system requires at least two levels (LOD0 and at least one simplified level)");
    }
}
