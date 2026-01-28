//! Thread-safe chunk storage for World.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;

pub const ChunkKey = struct {
    x: i32,
    z: i32,

    pub fn hash(self: ChunkKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.x));
        const uz: u64 = @bitCast(@as(i64, self.z));
        return ux ^ (uz *% 0x9e3779b97f4a7c15);
    }

    pub fn eql(a: ChunkKey, b: ChunkKey) bool {
        return a.x == b.x and a.z == b.z;
    }
};

const ChunkKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkKey) u64 {
        _ = self;
        return key.hash();
    }

    pub fn eql(self: @This(), a: ChunkKey, b: ChunkKey) bool {
        _ = self;
        return a.eql(b);
    }
};

pub const ChunkData = struct {
    chunk: Chunk,
    mesh: ChunkMesh,
};

pub const ChunkStorage = struct {
    chunks: std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80),
    chunks_mutex: std.Thread.RwLock,
    allocator: std.mem.Allocator,
    next_job_token: u32,

    pub fn init(allocator: std.mem.Allocator) ChunkStorage {
        return .{
            .chunks = std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80).init(allocator),
            .chunks_mutex = .{},
            .allocator = allocator,
            .next_job_token = 1,
        };
    }

    pub fn deinit(self: *ChunkStorage, vertex_allocator: anytype) void {
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.mesh.deinit(vertex_allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.chunks.deinit();
    }

    pub fn deinitWithoutRHI(self: *ChunkStorage) void {
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.mesh.deinitWithoutRHI();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.chunks.deinit();
    }

    pub fn count(self: *const ChunkStorage) usize {
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();
        return self.chunks.count();
    }

    pub fn get(self: *ChunkStorage, cx: i32, cz: i32) ?*ChunkData {
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();
        return self.chunks.get(ChunkKey{ .x = cx, .z = cz });
    }

    pub fn getOrCreate(self: *ChunkStorage, cx: i32, cz: i32) !*ChunkData {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        const key = ChunkKey{ .x = cx, .z = cz };
        if (self.chunks.get(key)) |data| return data;

        const data = try self.allocator.create(ChunkData);
        data.* = .{
            .chunk = Chunk.init(cx, cz),
            .mesh = ChunkMesh.init(self.allocator),
        };
        data.chunk.job_token = self.next_job_token;
        self.next_job_token += 1;
        try self.chunks.put(key, data);
        return data;
    }

    pub fn remove(self: *ChunkStorage, cx: i32, cz: i32, vertex_allocator: anytype) bool {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();
        return self.removeUnlocked(cx, cz, vertex_allocator);
    }

    /// Remove a chunk without acquiring the lock.
    /// SAFETY: Caller must hold chunks_mutex (exclusive lock)!
    pub fn removeUnlocked(self: *ChunkStorage, cx: i32, cz: i32, vertex_allocator: anytype) bool {
        const key = ChunkKey{ .x = cx, .z = cz };
        if (self.chunks.fetchRemove(key)) |entry| {
            entry.value.*.mesh.deinit(vertex_allocator);
            self.allocator.destroy(entry.value);
            return true;
        }
        return false;
    }

    /// Unsafe iterator - caller must hold chunks_mutex!
    /// Using next() on the returned iterator is not thread-safe without external locking.
    pub fn iteratorUnsafe(self: *ChunkStorage) std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80).Iterator {
        return self.chunks.iterator();
    }

    pub fn isChunkRenderable(cx: i32, cz: i32, ctx: *anyopaque) bool {
        const self: *ChunkStorage = @ptrCast(@alignCast(ctx));
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();

        if (self.chunks.get(.{ .x = cx, .z = cz })) |data| {
            return data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.fluid_allocation != null;
        }
        return false;
    }
};
