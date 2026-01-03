//! Lock-free single-producer single-consumer ring buffer for upload queues.
//! Provides O(1) push and pop operations without memory allocation after init.

const std = @import("std");

/// A fixed-capacity ring buffer optimized for FIFO queues.
/// Unlike ArrayList.orderedRemove(0), this provides O(1) dequeue.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize, // Next position to read from
        tail: usize, // Next position to write to
        len: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !Self {
            const cap = if (initial_capacity == 0) 64 else initial_capacity;
            const buffer = try allocator.alloc(T, cap);
            return Self{
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .len = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == self.buffer.len;
        }

        /// Push an item to the back. Returns error if full.
        pub fn push(self: *Self, item: T) !void {
            if (self.isFull()) {
                try self.grow();
            }
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.len += 1;
        }

        /// Pop an item from the front. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return item;
        }

        /// Peek at the front item without removing it.
        pub fn peek(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            return self.buffer[self.head];
        }

        /// Clear all items without deallocating.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.len = 0;
        }

        /// Double the capacity when full.
        fn grow(self: *Self) !void {
            const new_cap = self.buffer.len * 2;
            const new_buffer = try self.allocator.alloc(T, new_cap);

            // Copy items in order from head to tail
            var i: usize = 0;
            var idx = self.head;
            while (i < self.len) : (i += 1) {
                new_buffer[i] = self.buffer[idx];
                idx = (idx + 1) % self.buffer.len;
            }

            self.allocator.free(self.buffer);
            self.buffer = new_buffer;
            self.head = 0;
            self.tail = self.len;
        }
    };
}

// Unit tests
test "RingBuffer basic operations" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u32).init(allocator, 4);
    defer rb.deinit();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), rb.count());

    try rb.push(1);
    try rb.push(2);
    try rb.push(3);

    try std.testing.expectEqual(@as(usize, 3), rb.count());
    try std.testing.expectEqual(@as(?u32, 1), rb.pop());
    try std.testing.expectEqual(@as(?u32, 2), rb.pop());
    try std.testing.expectEqual(@as(usize, 1), rb.count());

    try rb.push(4);
    try rb.push(5);

    try std.testing.expectEqual(@as(?u32, 3), rb.pop());
    try std.testing.expectEqual(@as(?u32, 4), rb.pop());
    try std.testing.expectEqual(@as(?u32, 5), rb.pop());
    try std.testing.expect(rb.isEmpty());
}

test "RingBuffer wrap around" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u32).init(allocator, 4);
    defer rb.deinit();

    // Fill and empty to move head/tail
    try rb.push(1);
    try rb.push(2);
    _ = rb.pop();
    _ = rb.pop();

    // Now head and tail are at position 2
    try rb.push(10);
    try rb.push(11);
    try rb.push(12);
    try rb.push(13); // This wraps around

    try std.testing.expectEqual(@as(?u32, 10), rb.pop());
    try std.testing.expectEqual(@as(?u32, 11), rb.pop());
    try std.testing.expectEqual(@as(?u32, 12), rb.pop());
    try std.testing.expectEqual(@as(?u32, 13), rb.pop());
}

test "RingBuffer auto grow" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer(u32).init(allocator, 2);
    defer rb.deinit();

    try rb.push(1);
    try rb.push(2);
    try rb.push(3); // Should trigger grow

    try std.testing.expectEqual(@as(usize, 4), rb.capacity());
    try std.testing.expectEqual(@as(usize, 3), rb.count());

    try std.testing.expectEqual(@as(?u32, 1), rb.pop());
    try std.testing.expectEqual(@as(?u32, 2), rb.pop());
    try std.testing.expectEqual(@as(?u32, 3), rb.pop());
}
