//! Thread-safe chunk storage for World.

const std = @import("std");
const sync = @import("sync");
const Chunk = @import("world-core").Chunk;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;

pub const IChunkStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, cx: i32, cz: i32) ?*ChunkData,
        count: *const fn (ptr: *anyopaque) usize,
        totalVertexCount: *const fn (ptr: *anyopaque) u64,
        isChunkRenderable: *const fn (ptr: *anyopaque, cx: i32, cz: i32) bool,
    };

    pub fn get(self: IChunkStorage, cx: i32, cz: i32) ?*ChunkData {
        return self.vtable.get(self.ptr, cx, cz);
    }

    pub fn count(self: IChunkStorage) usize {
        return self.vtable.count(self.ptr);
    }

    pub fn totalVertexCount(self: IChunkStorage) u64 {
        return self.vtable.totalVertexCount(self.ptr);
    }

    pub fn isChunkRenderable(self: IChunkStorage, cx: i32, cz: i32) bool {
        return self.vtable.isChunkRenderable(self.ptr, cx, cz);
    }
};

pub const ChunkKey = @import("world-core").ChunkKey;

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

pub const RenderPayload = struct {
    mesh: ChunkMesh,
};

pub const ChunkData = struct {
    chunk: Chunk,
    render: RenderPayload,

    pub fn getMesh(self: *ChunkData) *ChunkMesh {
        return &self.render.mesh;
    }

    pub fn getMeshConst(self: *const ChunkData) *const ChunkMesh {
        return &self.render.mesh;
    }
};

pub const ChunkStorage = struct {
    const CHUNK_POOL_CAPACITY = 256;

    chunks: std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80),
    free_list: std.ArrayListUnmanaged(*ChunkData),
    /// Guards membership, lifecycle/state flags, and published chunk metadata.
    /// Pins protect lifetime only, not the contents of a resident chunk.
    chunks_mutex: sync.RwLock,
    /// Guards resident block/light/biome data. When both locks are needed,
    /// acquire lighting_mutex before chunks_mutex. Generate and mesh private
    /// data outside these locks; copy inputs/publish results under the locks.
    lighting_mutex: sync.Mutex,
    allocator: std.mem.Allocator,
    next_job_token: u32,
    map_surface_revision: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) ChunkStorage {
        return .{
            .chunks = std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80).init(allocator),
            .free_list = .empty,
            .chunks_mutex = .{},
            .lighting_mutex = .{},
            .allocator = allocator,
            .next_job_token = 1,
            .map_surface_revision = .init(0),
        };
    }

    pub fn interface(self: *ChunkStorage) IChunkStorage {
        return .{ .ptr = self, .vtable = &ICHUNKSTORAGE_VTABLE };
    }

    const ICHUNKSTORAGE_VTABLE = IChunkStorage.VTable{
        .get = iget,
        .count = icount,
        .totalVertexCount = itotalVertexCount,
        .isChunkRenderable = iisChunkRenderable,
    };

    fn iget(ptr: *anyopaque, cx: i32, cz: i32) ?*ChunkData {
        const self: *ChunkStorage = @ptrCast(@alignCast(ptr));
        return self.get(cx, cz);
    }

    fn icount(ptr: *anyopaque) usize {
        const self: *ChunkStorage = @ptrCast(@alignCast(ptr));
        return self.count();
    }

    fn itotalVertexCount(ptr: *anyopaque) u64 {
        const self: *ChunkStorage = @ptrCast(@alignCast(ptr));
        return self.totalVertexCount();
    }

    fn iisChunkRenderable(ptr: *anyopaque, cx: i32, cz: i32) bool {
        return isChunkRenderable(cx, cz, ptr);
    }

    pub fn deinit(self: *ChunkStorage, vertex_allocator: anytype) void {
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.render.mesh.deinit(vertex_allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        for (self.free_list.items) |data| {
            self.allocator.destroy(data);
        }
        self.free_list.deinit(self.allocator);
        self.chunks.deinit();
    }

    pub fn deinitWithoutRHI(self: *ChunkStorage) void {
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.render.mesh.deinitWithoutRHI();
            self.allocator.destroy(entry.value_ptr.*);
        }
        for (self.free_list.items) |data| {
            self.allocator.destroy(data);
        }
        self.free_list.deinit(self.allocator);
        self.chunks.deinit();
    }

    pub fn count(self: *ChunkStorage) usize {
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();
        return self.chunks.count();
    }

    pub fn markMapSurfaceChanged(self: *ChunkStorage) void {
        _ = self.map_surface_revision.fetchAdd(1, .release);
    }

    pub fn getMapSurfaceRevision(self: *const ChunkStorage) u64 {
        return self.map_surface_revision.load(.acquire);
    }

    /// Sum total vertex count across all chunk meshes
    pub fn totalVertexCount(self: *ChunkStorage) u64 {
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();
        var total: u64 = 0;
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            const mesh = &entry.value_ptr.*.render.mesh;
            if (mesh.solid_allocation) |alloc| total += alloc.count;
            if (mesh.cutout_allocation) |alloc| total += alloc.count;
            if (mesh.fluid_allocation) |alloc| total += alloc.count;
        }
        return total;
    }

    /// The returned pointer is not pinned. Background users must look up and
    /// pin under chunks_mutex; content readers additionally need lighting_mutex.
    pub fn get(self: *ChunkStorage, cx: i32, cz: i32) ?*ChunkData {
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();
        return self.chunks.get(ChunkKey{ .x = cx, .z = cz });
    }

    pub fn getOrCreate(self: *ChunkStorage, cx: i32, cz: i32) !*ChunkData {
        const key = ChunkKey{ .x = cx, .z = cz };

        self.chunks_mutex.lockShared();
        if (self.chunks.get(key)) |data| {
            self.chunks_mutex.unlockShared();
            return data;
        }
        self.chunks_mutex.unlockShared();

        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        if (self.chunks.get(key)) |data| return data;

        const data = try self.createChunkDataUnlocked(cx, cz);
        errdefer self.allocator.destroy(data);
        try self.chunks.put(key, data);
        return data;
    }

    /// Create a fresh or pooled chunk data object without acquiring the lock.
    /// SAFETY: Caller must hold chunks_mutex (exclusive lock) and insert the
    /// returned pointer or destroy/re-pool it on failure.
    pub fn createChunkDataUnlocked(self: *ChunkStorage, cx: i32, cz: i32) !*ChunkData {
        const data = if (self.free_list.items.len > 0) blk: {
            const last_index = self.free_list.items.len - 1;
            const pooled = self.free_list.items[last_index];
            self.free_list.items.len = last_index;
            break :blk pooled;
        } else try self.allocator.create(ChunkData);
        data.* = .{
            .chunk = Chunk.init(cx, cz),
            .render = .{
                .mesh = ChunkMesh.init(self.allocator),
            },
        };
        data.chunk.job_token = self.next_job_token;
        self.next_job_token += 1;
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
        const data = self.chunks.get(key) orelse return false;
        if (data.chunk.isPinned()) return false;
        if (self.chunks.fetchRemove(key)) |entry| {
            entry.value.*.render.mesh.deinit(vertex_allocator);
            // Retain the large ChunkData allocation for future chunks. The mesh
            // has been fully deinitialized above; replace it with an empty mesh
            // so pooled entries are safe to destroy directly during storage
            // shutdown without double-freeing stale pointers.
            entry.value.*.render.mesh = ChunkMesh.init(self.allocator);
            if (self.free_list.items.len < CHUNK_POOL_CAPACITY) {
                self.free_list.append(self.allocator, entry.value) catch self.allocator.destroy(entry.value);
            } else {
                self.allocator.destroy(entry.value);
            }
            self.markMapSurfaceChanged();
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
            return data.chunk.state == .renderable and data.render.mesh.ready;
        }
        return false;
    }

    /// Diagnostic: get chunk state as a string for logging (not for hot path).
    pub fn getChunkState(cx: i32, cz: i32, ctx: *anyopaque) ?Chunk.State {
        const self: *ChunkStorage = @ptrCast(@alignCast(ctx));
        self.chunks_mutex.lockShared();
        defer self.chunks_mutex.unlockShared();

        if (self.chunks.get(.{ .x = cx, .z = cz })) |data| {
            return data.chunk.state;
        }
        return null; // not in storage
    }
};

test "ChunkStorage removal refuses pinned chunks before pooling or destruction" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data = try storage.getOrCreate(0, 0);
    const token = data.chunk.job_token;
    data.chunk.pin();
    defer data.chunk.unpin();

    // No GPU resources exist, and the pin must reject removal before deinit.
    var vertex_allocator: @import("chunk_allocator.zig").GlobalVertexAllocator = undefined;
    try testing.expect(!storage.remove(0, 0, &vertex_allocator));
    try testing.expectEqual(@as(usize, 1), storage.count());
    try testing.expectEqual(@as(usize, 0), storage.free_list.items.len);
    try testing.expect(storage.get(0, 0).? == data);
    try testing.expectEqual(token, data.chunk.job_token);
    try testing.expectEqual(@as(u64, 0), storage.getMapSurfaceRevision());
}
