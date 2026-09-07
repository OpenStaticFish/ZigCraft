const std = @import("std");
const sync = @import("sync");

/// Every nonempty allocation owns a reference, independently of the job that
/// created it. Mesh objects additionally retain one reference after upload.
pub const BudgetAllocator = struct {
    pub const default_quota_bytes = 16 * 1024 * 1024;
    pub const admission_bytes = 24 * 1024 * 1024;

    parent: std.mem.Allocator,
    limit_bytes: usize,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: sync.Mutex = .{},
    used_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn init(parent: std.mem.Allocator, limit_bytes: usize) !*BudgetAllocator {
        const self = try parent.create(BudgetAllocator);
        self.* = .{ .parent = parent, .limit_bytes = limit_bytes };
        return self;
    }

    pub fn retain(self: *BudgetAllocator) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *BudgetAllocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.used_bytes == 0);
        self.parent.destroy(self);
    }

    pub fn releaseOwner(ptr: *anyopaque) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ptr));
        self.release();
    }

    pub fn snapshot(self: *BudgetAllocator) struct { used: usize, peak: usize, refs: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .used = self.used_bytes, .peak = self.peak_bytes, .refs = self.refs.load(.acquire) };
    }

    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (len > self.limit_bytes -| self.used_bytes) return null;
        const memory = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.used_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.used_bytes);
        self.retain();
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (new_len -| memory.len > self.limit_bytes -| self.used_bytes) return false;
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.used_bytes = self.used_bytes - memory.len + new_len;
        self.peak_bytes = @max(self.peak_bytes, self.used_bytes);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // Never forward relocating remap: its hidden old+new transient could
        // exceed quota. Allocator.realloc's fallback charges both allocations.
        return if (resize(ptr, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        self.parent.rawFree(memory, alignment, ret_addr);
        self.used_bytes -= memory.len;
        self.mutex.unlock();
        self.release();
    }
};

test "canonical quota charges realloc overlap and allocations retain the owner" {
    const NonResizing = struct {
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret_addr);
        }
    };
    var context: u8 = 0;
    const parent = std.mem.Allocator{ .ptr = &context, .vtable = &.{ .alloc = NonResizing.alloc, .free = NonResizing.free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    const quota = try BudgetAllocator.init(parent, 96);
    const allocator = quota.allocator();
    var memory = try allocator.alloc(u8, 48);
    @memset(memory, 7);
    try std.testing.expectError(error.OutOfMemory, allocator.realloc(memory, 80));
    try std.testing.expectEqual(@as(usize, 48), quota.snapshot().used);
    memory = try allocator.realloc(memory, 32);
    try std.testing.expectEqual(@as(usize, 80), quota.snapshot().peak);
    try std.testing.expectEqual(@as(usize, 32), quota.snapshot().used);
    try std.testing.expectEqual(@as(u8, 7), memory[0]);
    quota.release();
    try std.testing.expectEqual(@as(usize, 1), quota.snapshot().refs);
    allocator.free(memory); // Last allocation destroys the owner, leak-checked.
}

test "canonical quota tracks in place resize and remap without exceeding peak" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const quota = try BudgetAllocator.init(fixed.allocator(), 128);
    defer quota.release();
    const allocator = quota.allocator();
    var memory = try allocator.alloc(u8, 64);
    try std.testing.expect(allocator.resize(memory, 128));
    memory = memory.ptr[0..128];
    try std.testing.expect(!allocator.resize(memory, 129));
    try std.testing.expect(allocator.resize(memory, 32));
    memory = memory.ptr[0..32];
    memory = allocator.remap(memory, 96).?;
    try std.testing.expectEqual(@as(usize, 96), quota.snapshot().used);
    try std.testing.expectEqual(@as(usize, 128), quota.snapshot().peak);
    allocator.free(memory);
    try std.testing.expectEqual(@as(usize, 0), quota.snapshot().used);
    try std.testing.expectEqual(@as(usize, 1), quota.snapshot().refs);
}
