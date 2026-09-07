//! Shared per-level vertex pool for distant LOD meshes.

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const lod_mesh = @import("lod_mesh.zig");
const LODMesh = lod_mesh.LODMesh;
const LODMeshResources = lod_mesh.LODMeshResources;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const RhiError = rhi_types.RhiError;
const log = @import("engine-core").log;
const LODStagingCost = @import("lod_mesh_resources.zig").LODStagingCost;

const DEFAULT_INITIAL_CAPACITY_BYTES: usize = 8 * 1024 * 1024;
const COMPACTION_FRAGMENTATION_THRESHOLD: f32 = 0.35;

const FreeBlock = struct {
    offset: usize,
    size: usize,
};

const AllocationRecord = struct {
    mesh: *LODMesh,
    offset: usize,
    size: usize,
};

const RetiredRange = struct {
    offset: usize,
    size: usize,
    serial: u64,
    frame_slot: usize,
};

const RetiredBacking = struct {
    size: usize,
    serial: u64,
    frame_slot: usize,
};

const AllocationPlan = struct {
    new_range: bool = false,
    replacement_capacity: usize = 0,
};

const MeshDrawState = LODMesh.DrawState;

/// Owns one large vertex buffer for a single LOD level and sub-allocates mesh ranges.
pub const LODVertexPool = struct {
    allocator: std.mem.Allocator,
    lod_level: LODLevel,
    buffer_handle: BufferHandle = 0,
    capacity_bytes: usize = 0,
    initial_capacity_bytes: usize = DEFAULT_INITIAL_CAPACITY_BYTES,
    free_blocks: std.ArrayListUnmanaged(FreeBlock) = .empty,
    allocations: std.ArrayListUnmanaged(AllocationRecord) = .empty,
    retired_ranges: std.ArrayListUnmanaged(RetiredRange) = .empty,
    retired_backings: std.ArrayListUnmanaged(RetiredBacking) = .empty,
    current_serial: u64 = 0,
    current_frame_slot: usize = 0,
    last_completed_serial: ?u64 = null,
    shadow: []u8 = &.{},
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, lod_level: LODLevel, initial_capacity_bytes: usize) LODVertexPool {
        return .{
            .allocator = allocator,
            .lod_level = lod_level,
            .initial_capacity_bytes = initial_capacity_bytes,
        };
    }

    pub fn deinit(self: *LODVertexPool, resources: LODMeshResources) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffer_handle != 0) {
            resources.destroyBuffer(self.buffer_handle);
            self.buffer_handle = 0;
        }
        if (self.capacity_bytes != 0) {
            self.allocator.free(self.shadow);
        }
        self.free_blocks.deinit(self.allocator);
        self.allocations.deinit(self.allocator);
        self.retired_ranges.deinit(self.allocator);
        self.retired_backings.deinit(self.allocator);
        self.capacity_bytes = 0;
        self.shadow = &.{};
    }

    pub fn uploadMesh(self: *LODVertexPool, mesh: *LODMesh, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        const pending = mesh.pending_vertices orelse {
            if (mesh.bufferHandle() != 0 and mesh.vertexCount() > 0) {
                mesh.setDrawStateUnlocked(.{
                    .buffer_handle = mesh.bufferHandle(),
                    .vertex_offset = mesh.vertexOffset(),
                    .vertex_count = mesh.vertexCount(),
                    .capacity = @intCast(mesh.byteSize() / @sizeOf(Vertex)),
                    .pooled = mesh.isPooled(),
                    .ready = true,
                });
            }
            return;
        };

        if (pending.len == 0) {
            if (self.findRecordIndexUnlocked(mesh)) |idx| self.retireRecordUnlocked(idx, true, mesh);
            mesh.markEmptyUploadedUnlocked();
            mesh.allocator.free(pending);
            mesh.pending_vertices = null;
            return;
        }

        const bytes = std.mem.sliceAsBytes(pending);

        const plan = self.allocationPlanUnlocked(mesh, bytes.len);
        const old_record_index = self.findRecordIndexUnlocked(mesh);
        var record_index = old_record_index;

        if (plan.new_range) {
            // Reserve publication, rollback, and retirement bookkeeping before
            // a replacement can change any live mesh locations.
            self.allocations.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
            self.free_blocks.ensureTotalCapacity(self.allocator, @max(self.free_blocks.items.len + 1, 2)) catch return error.OutOfMemory;
            if (old_record_index != null) {
                self.retired_ranges.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
            }
            if (plan.replacement_capacity != 0) {
                try self.replaceBackingUnlocked(resources, plan.replacement_capacity, mesh);
            }
            const block_index = self.findBestFitUnlocked(bytes.len) orelse return error.OutOfMemory;
            const offset = self.takeBlockUnlocked(block_index, bytes.len);
            self.allocations.appendAssumeCapacity(.{ .mesh = mesh, .offset = offset, .size = bytes.len });
            record_index = self.allocations.items.len - 1;
        }

        // Replacement preserves record order but relocates offsets. Snapshot
        // the old geometry only now, so a failed payload restores its new home.
        const old_record = if (old_record_index) |idx| self.allocations.items[idx] else null;
        const record = &self.allocations.items[record_index.?];
        lod_mesh.updateBufferChunked(resources, self.buffer_handle, record.offset, bytes) catch |err| {
            if (plan.new_range) {
                self.freeRecordUnlocked(record_index.?, false, mesh);
            }
            if (old_record) |old| {
                applyMeshDrawState(mesh, .{
                    .buffer_handle = self.buffer_handle,
                    .vertex_offset = old.offset,
                    .vertex_count = mesh.vertexCount(),
                    .capacity = @intCast(old.size / @sizeOf(Vertex)),
                    .pooled = true,
                    .ready = true,
                });
            } else {
                clearMeshDrawState(mesh);
            }
            return err;
        };
        @memcpy(self.shadow[record.offset .. record.offset + bytes.len], bytes);

        const new_offset = record.offset;
        const new_size = record.size;
        if (plan.new_range) {
            if (old_record_index) |idx| {
                self.retireRecordUnlocked(idx, false, mesh);
            }
        }

        applyMeshDrawState(mesh, .{
            .buffer_handle = self.buffer_handle,
            .vertex_offset = new_offset,
            .vertex_count = @intCast(pending.len),
            .capacity = @intCast(new_size / @sizeOf(Vertex)),
            .pooled = true,
            .ready = true,
        });
        mesh.allocator.free(pending);
        mesh.pending_vertices = null;
    }

    pub fn destroyMesh(self: *LODVertexPool, mesh: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        self.freeMeshUnlocked(mesh);

        if (mesh.pending_vertices) |pending| {
            mesh.allocator.free(pending);
            mesh.pending_vertices = null;
        }
        mesh.clearDrawStateUnlocked();
    }

    /// Removes a mesh from future submissions while keeping its byte range
    /// unavailable until the frame slot that last referenced it completes.
    pub fn destroyMeshDeferred(self: *LODVertexPool, mesh: *LODMesh, serial: u64, frame_slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        self.current_serial = serial;
        self.current_frame_slot = frame_slot;
        if (self.findRecordIndexUnlocked(mesh)) |idx| self.retireRecordUnlocked(idx, true, mesh);
        if (mesh.pending_vertices) |pending| {
            mesh.allocator.free(pending);
            mesh.pending_vertices = null;
        }
        mesh.clearDrawStateUnlocked();
    }

    /// Call at frame precompute with the backend slot used for subsequent
    /// uploads/destruction. Only a strictly newer matching completion drops debt;
    /// duplicate or regressing serials cannot collect either ranges or backings.
    pub fn collectRetired(self: *LODVertexPool, completed_serial: u64, completed_frame_slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_completed_serial) |last| if (completed_serial <= last) return;
        self.last_completed_serial = completed_serial;
        self.current_serial = completed_serial;
        self.current_frame_slot = completed_frame_slot;

        var i: usize = 0;
        while (i < self.retired_ranges.items.len) {
            const retired = self.retired_ranges.items[i];
            if (retired.frame_slot == completed_frame_slot and completed_serial > retired.serial) {
                self.releaseOffsetUnlocked(retired.offset, retired.size) catch {
                    i += 1;
                    continue;
                };
                _ = self.retired_ranges.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < self.retired_backings.items.len) {
            const retired = self.retired_backings.items[i];
            if (retired.frame_slot == completed_frame_slot and completed_serial > retired.serial) {
                _ = self.retired_backings.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn allocatedBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocatedBytesUnlocked();
    }

    pub fn gpuMemoryBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.capacity_bytes;
    }

    /// GPU bytes handed to deferred destruction, including failed replacements.
    /// These have no retained CPU shadow and are separate from active capacity.
    pub fn retiredGpuMemoryBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var total: usize = 0;
        for (self.retired_backings.items) |backing| total +|= backing.size;
        return total;
    }

    /// Additional peak backing + shadow bytes beyond everything already retained.
    /// Reuse costs zero; initial allocation/replacement costs 2 * target capacity.
    /// Excludes pending payload, staging and allocator bookkeeping.
    /// Callers must serialize planning/admission with pool and mesh mutations.
    pub fn uploadMemoryCost(self: *LODVertexPool, mesh: *LODMesh) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        mesh.mutex.lock();
        defer mesh.mutex.unlock();
        const pending = mesh.pending_vertices orelse return 0;
        const plan = self.allocationPlanUnlocked(mesh, std.mem.sliceAsBytes(pending).len);
        return plan.replacement_capacity *| 2;
    }

    /// Returns every staging byte `uploadMesh` will need for its current
    /// payload. Replacing a pool buffer republishes its CPU shadow, so callers
    /// must reserve the migration writes before beginning the upload.
    pub fn uploadCost(self: *LODVertexPool, mesh: *LODMesh) LODStagingCost {
        self.mutex.lock();
        defer self.mutex.unlock();
        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        const pending = mesh.pending_vertices orelse return .{};
        const payload_bytes = std.mem.sliceAsBytes(pending).len;
        if (payload_bytes == 0) return .{};

        const plan = self.allocationPlanUnlocked(mesh, payload_bytes);
        return .{
            .payload_bytes = payload_bytes,
            .migration_bytes = if (plan.replacement_capacity != 0) self.liveBytesUnlocked() else 0,
        };
    }

    /// Empty backing is releasable only with complete, contiguous free coverage.
    /// Missing retirement bookkeeping deliberately prevents this fast path.
    pub fn reclaimEmpty(self: *LODVertexPool, resources: LODMeshResources) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.capacity_bytes == 0 or self.allocations.items.len != 0 or self.retired_ranges.items.len != 0) return false;
        var cursor: usize = 0;
        for (self.free_blocks.items) |block| {
            if (block.offset != cursor or block.size > self.capacity_bytes - cursor) return false;
            cursor += block.size;
        }
        if (cursor != self.capacity_bytes) return false;
        self.retired_backings.ensureUnusedCapacity(self.allocator, 1) catch return false;
        self.retireBackingUnlocked(resources, self.buffer_handle, self.capacity_bytes);
        self.allocator.free(self.shadow);
        self.buffer_handle = 0;
        self.capacity_bytes = 0;
        self.shadow = &.{};
        self.free_blocks.clearRetainingCapacity();
        return true;
    }

    /// Trim by at least half, retaining a 1 KiB floor and all live ranges.
    /// Budgets are incremental peak backing + shadow bytes and live staging bytes.
    /// Empty pools use reclaimEmpty instead; retired ranges stay on the old GPU.
    pub fn trim(self: *LODVertexPool, resources: LODMeshResources, max_extra_bytes: usize, staging_budget_bytes: usize) RhiError!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const live_bytes = self.liveBytesUnlocked();
        if (live_bytes == 0) return false;
        const min_capacity = @max(live_bytes, 1024);
        var target = self.capacity_bytes;
        while (target / 2 >= min_capacity) target /= 2;
        if (target == self.capacity_bytes or target > max_extra_bytes / 2 or live_bytes > staging_budget_bytes) return false;
        try self.replaceBackingUnlocked(resources, target, null);
        return true;
    }

    pub fn freeBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.freeBytesUnlocked();
    }

    pub fn fragmentationRatio(self: *LODVertexPool) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.fragmentationRatioUnlocked();
    }

    pub fn compact(self: *LODVertexPool, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Do not manufacture free coverage when retirement bookkeeping was lost.
        if (self.allocations.items.len == 0) return;
        try self.replaceBackingUnlocked(resources, self.capacity_bytes, null);
    }

    fn allocationPlanUnlocked(self: *const LODVertexPool, mesh: *const LODMesh, size: usize) AllocationPlan {
        if (size == 0) return .{};
        if (self.findRecordIndexUnlocked(mesh)) |idx| {
            if (self.allocations.items[idx].size >= size and size <= lod_mesh.MAX_STAGING_UPDATE_BYTES) return .{};
        }
        if (self.findBestFitUnlocked(size) != null) return .{ .new_range = true };

        // One packed replacement needs room for every live record AND the fresh
        // payload, even when that payload will supersede one of those records.
        const required = self.liveBytesUnlocked() +| size;
        var target = self.capacity_bytes;
        if (target < required) {
            // A trimmed pool grows from retained capacity, not its startup size.
            target = @max(if (target == 0) self.initial_capacity_bytes else target, @as(usize, 1024));
            while (target < required) target *|= 2;
        }
        return .{ .new_range = true, .replacement_capacity = target };
    }

    fn findBestFitUnlocked(self: *const LODVertexPool, size: usize) ?usize {
        var best_idx: ?usize = null;
        var best_size: usize = std.math.maxInt(usize);
        for (self.free_blocks.items, 0..) |block, idx| {
            if (block.size >= size and block.size < best_size) {
                best_idx = idx;
                best_size = block.size;
                if (block.size == size) break;
            }
        }
        return best_idx;
    }

    fn takeBlockUnlocked(self: *LODVertexPool, idx: usize, size: usize) usize {
        const block = self.free_blocks.items[idx];
        const offset = block.offset;
        if (block.size == size) {
            _ = self.free_blocks.orderedRemove(idx);
        } else {
            self.free_blocks.items[idx].offset += size;
            self.free_blocks.items[idx].size -= size;
        }
        return offset;
    }

    fn freeMeshUnlocked(self: *LODVertexPool, mesh: *LODMesh) void {
        if (self.findRecordIndexUnlocked(mesh)) |idx| {
            self.freeRecordUnlocked(idx, true, mesh);
        }
    }

    fn freeRecordUnlocked(self: *LODVertexPool, idx: usize, reset_mesh: bool, locked_mesh: ?*LODMesh) void {
        const record = self.allocations.items[idx];
        self.releaseOffsetUnlocked(record.offset, record.size) catch |err| {
            log.log.warn("LOD vertex pool failed to release {} bytes at {}: {}", .{ record.size, record.offset, err });
        };
        if (reset_mesh) {
            setMeshDrawState(record.mesh, .empty, locked_mesh);
        }
        _ = self.allocations.orderedRemove(idx);
    }

    fn retireRecordUnlocked(self: *LODVertexPool, idx: usize, reset_mesh: bool, locked_mesh: ?*LODMesh) void {
        const record = self.allocations.items[idx];
        self.retired_ranges.append(self.allocator, .{
            .offset = record.offset,
            .size = record.size,
            .serial = self.current_serial,
            .frame_slot = self.current_frame_slot,
        }) catch {
            // Bookkeeping failure intentionally leaks pool capacity rather than
            // risking an in-flight overwrite.
        };
        if (reset_mesh) setMeshDrawState(record.mesh, .empty, locked_mesh);
        _ = self.allocations.orderedRemove(idx);
    }

    fn releaseOffsetUnlocked(self: *LODVertexPool, offset: usize, size: usize) !void {
        if (size == 0) return;

        var insert_idx = self.free_blocks.items.len;
        for (self.free_blocks.items, 0..) |block, idx| {
            if (block.offset > offset) {
                insert_idx = idx;
                break;
            }
        }
        try self.free_blocks.insert(self.allocator, insert_idx, .{ .offset = offset, .size = size });
        self.coalesceAroundUnlocked(insert_idx);
    }

    fn coalesceAroundUnlocked(self: *LODVertexPool, start_idx: usize) void {
        var idx = start_idx;
        if (idx > 0 and self.free_blocks.items[idx - 1].offset + self.free_blocks.items[idx - 1].size == self.free_blocks.items[idx].offset) {
            self.free_blocks.items[idx - 1].size += self.free_blocks.items[idx].size;
            _ = self.free_blocks.orderedRemove(idx);
            idx -= 1;
        }
        while (idx + 1 < self.free_blocks.items.len and self.free_blocks.items[idx].offset + self.free_blocks.items[idx].size == self.free_blocks.items[idx + 1].offset) {
            self.free_blocks.items[idx].size += self.free_blocks.items[idx + 1].size;
            _ = self.free_blocks.orderedRemove(idx + 1);
        }
    }

    fn replaceBackingUnlocked(self: *LODVertexPool, resources: LODMeshResources, new_capacity: usize, locked_mesh: ?*LODMesh) RhiError!void {
        if (new_capacity < self.liveBytesUnlocked() or new_capacity > std.math.maxInt(usize) / 2) return error.OutOfMemory;
        self.free_blocks.ensureTotalCapacity(self.allocator, 1) catch return error.OutOfMemory;
        // Success retires the old backing; failure retires the new one. Neither
        // path may allocate bookkeeping after creating a GPU resource.
        self.retired_backings.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;

        // Never relocate ranges inside the live backing buffer. Draws already
        // submitted for earlier frames may still read the old offsets while a
        // transfer writes the compacted data. Build a replacement buffer,
        // publish all new locations only after every upload succeeds, and let
        // the RHI retire the old handle through its frame-fence deletion path.
        const new_shadow = self.allocator.alloc(u8, new_capacity) catch return error.OutOfMemory;
        errdefer self.allocator.free(new_shadow);
        @memset(new_shadow, 0);

        const new_handle = try resources.createBuffer(new_capacity, .vertex);
        errdefer self.retireBackingUnlocked(resources, new_handle, new_capacity);

        var cursor: usize = 0;
        for (self.allocations.items) |record| {
            const source = self.shadow[record.offset .. record.offset + record.size];
            @memcpy(new_shadow[cursor .. cursor + record.size], source);
            try lod_mesh.updateBufferChunked(resources, new_handle, cursor, source);
            cursor += record.size;
        }

        const old_handle = self.buffer_handle;
        const old_shadow = self.shadow;
        const old_capacity = self.capacity_bytes;
        self.buffer_handle = new_handle;
        self.shadow = new_shadow;
        self.capacity_bytes = new_capacity;

        cursor = 0;
        for (self.allocations.items) |*record| {
            record.offset = cursor;
            setMeshPoolLocation(record.mesh, new_handle, cursor, locked_mesh);
            cursor += record.size;
        }

        // Retired offsets belonged to the old backing buffer. The replacement
        // is freshly packed and the old handle is fence-retired by the RHI, so
        // only the new packed tail is free here.
        self.retired_ranges.clearRetainingCapacity();
        self.free_blocks.clearRetainingCapacity();
        if (cursor < self.capacity_bytes) {
            self.free_blocks.appendAssumeCapacity(.{ .offset = cursor, .size = self.capacity_bytes - cursor });
        }

        if (old_handle != 0) self.retireBackingUnlocked(resources, old_handle, old_capacity);
        if (old_capacity != 0) self.allocator.free(old_shadow);
    }

    fn retireBackingUnlocked(self: *LODVertexPool, resources: LODMeshResources, handle: BufferHandle, size: usize) void {
        self.retired_backings.appendAssumeCapacity(.{
            .size = size,
            .serial = self.current_serial,
            .frame_slot = self.current_frame_slot,
        });
        // The existing void RHI contract is assumed to accept deferred deletion.
        // This is not strict backend-OOM qualification of its deletion queue.
        resources.destroyBuffer(handle);
    }

    fn findRecordIndexUnlocked(self: *const LODVertexPool, mesh: *const LODMesh) ?usize {
        for (self.allocations.items, 0..) |record, idx| {
            if (record.mesh == mesh) return idx;
        }
        return null;
    }

    fn allocatedBytesUnlocked(self: *const LODVertexPool) usize {
        var total = self.liveBytesUnlocked();
        for (self.retired_ranges.items) |record| total += record.size;
        return total;
    }

    fn liveBytesUnlocked(self: *const LODVertexPool) usize {
        var total: usize = 0;
        for (self.allocations.items) |record| total += record.size;
        return total;
    }

    fn freeBytesUnlocked(self: *const LODVertexPool) usize {
        var total: usize = 0;
        for (self.free_blocks.items) |block| total += block.size;
        return total;
    }

    fn fragmentationRatioUnlocked(self: *const LODVertexPool) f32 {
        const total_free = self.freeBytesUnlocked();
        if (total_free == 0) return 0.0;
        var largest_free: usize = 0;
        for (self.free_blocks.items) |block| largest_free = @max(largest_free, block.size);
        return 1.0 - (@as(f32, @floatFromInt(largest_free)) / @as(f32, @floatFromInt(total_free)));
    }
};

fn clearMeshDrawState(mesh: *LODMesh) void {
    mesh.clearDrawStateUnlocked();
}

fn setMeshPoolLocation(mesh: *LODMesh, buffer_handle: BufferHandle, vertex_offset: usize, locked_mesh: ?*LODMesh) void {
    if (locked_mesh) |locked| {
        if (locked == mesh) {
            mesh.setPoolLocationUnlocked(buffer_handle, vertex_offset);
            return;
        }
    }
    mesh.mutex.lock();
    defer mesh.mutex.unlock();
    mesh.setPoolLocationUnlocked(buffer_handle, vertex_offset);
}

fn setMeshDrawState(mesh: *LODMesh, state: MeshDrawState, locked_mesh: ?*LODMesh) void {
    if (locked_mesh) |locked| {
        if (locked == mesh) {
            mesh.setDrawStateUnlocked(state);
            return;
        }
    }
    mesh.mutex.lock();
    defer mesh.mutex.unlock();
    mesh.setDrawStateUnlocked(state);
}

fn applyMeshDrawState(mesh: *LODMesh, state: MeshDrawState) void {
    mesh.setDrawStateUnlocked(state);
}

fn shouldCompactAfterEviction(pool: *LODVertexPool) bool {
    return pool.fragmentationRatio() > COMPACTION_FRAGMENTATION_THRESHOLD;
}

const TestResources = struct {
    next_handle: BufferHandle = 1,
    created: u32 = 0,
    destroyed: u32 = 0,
    uploaded: u32 = 0,
    updated: u32 = 0,
    total_updated_bytes: usize = 0,
    max_update_bytes: usize = 0,
    last_update_offset: usize = 0,
    wait_idle: u32 = 0,
    fail_updates: bool = false,
    fail_after_updates: ?u32 = null,
    fail_create: bool = false,

    fn resources(self: *TestResources) LODMeshResources {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn createBuffer(ptr: *anyopaque, _: usize, _: rhi_types.BufferUsage) RhiError!BufferHandle {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        if (self.fail_create) return error.OutOfMemory;
        const handle = self.next_handle;
        self.next_handle += 1;
        self.created += 1;
        return handle;
    }

    fn uploadBuffer(ptr: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.uploaded += 1;
    }

    fn updateBuffer(ptr: *anyopaque, _: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        if (self.fail_updates) return error.GpuLost;
        if (self.fail_after_updates) |limit| if (self.updated >= limit) return error.GpuLost;
        self.updated += 1;
        self.total_updated_bytes += data.len;
        self.max_update_bytes = @max(self.max_update_bytes, data.len);
        self.last_update_offset = offset;
    }

    fn destroyBuffer(ptr: *anyopaque, _: BufferHandle) void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.destroyed += 1;
    }

    fn waitIdle(ptr: *anyopaque) void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.wait_idle += 1;
    }

    const vtable = LODMeshResources.VTable{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .waitIdle = waitIdle,
    };
};

fn setPending(mesh: *LODMesh, allocator: std.mem.Allocator, count: usize) !void {
    const vertices = try allocator.alloc(Vertex, count);
    @memset(std.mem.sliceAsBytes(vertices), 0);
    mesh.pending_vertices = vertices;
}

test "LODVertexPool reuses freed ranges" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var first = LODMesh.init(allocator, .lod1);
    var second = LODMesh.init(allocator, .lod1);
    var third = LODMesh.init(allocator, .lod1);
    try setPending(&first, allocator, 4);
    try setPending(&second, allocator, 4);
    try pool.uploadMesh(&first, resources.resources());
    try pool.uploadMesh(&second, resources.resources());

    const reused_offset = first.vertex_offset;
    pool.destroyMesh(&first);
    try setPending(&third, allocator, 4);
    try pool.uploadMesh(&third, resources.resources());

    try std.testing.expectEqual(reused_offset, third.vertex_offset);
    pool.destroyMesh(&second);
    pool.destroyMesh(&third);
}

test "LODVertexPool grows and preserves pooled handles" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 64);
    defer pool.deinit(resources.resources());

    var first = LODMesh.init(allocator, .lod1);
    var second = LODMesh.init(allocator, .lod1);
    try setPending(&first, allocator, 4);
    try pool.uploadMesh(&first, resources.resources());
    const old_handle = first.buffer_handle;

    try setPending(&second, allocator, 64);
    try pool.uploadMesh(&second, resources.resources());

    try std.testing.expect(pool.gpuMemoryBytes() > 64);
    try std.testing.expect(first.buffer_handle != old_handle);
    try std.testing.expectEqual(first.buffer_handle, second.buffer_handle);
    try std.testing.expectEqual(@as(u32, 0), resources.uploaded);
    try std.testing.expect(resources.updated >= 1);
    try std.testing.expectEqual(@as(u32, 0), resources.wait_idle);
    pool.destroyMesh(&first);
    pool.destroyMesh(&second);
}

test "LODVertexPool upload cost includes replacement migration staging" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 64);
    defer pool.deinit(resources.resources());

    var first = LODMesh.init(allocator, .lod1);
    var second = LODMesh.init(allocator, .lod1);
    try setPending(&first, allocator, 1);
    const initial_cost = pool.uploadCost(&first);
    try std.testing.expectEqual(@sizeOf(Vertex), initial_cost.payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), initial_cost.migration_bytes);
    try pool.uploadMesh(&first, resources.resources());

    try setPending(&second, allocator, 64);
    const growth_cost = pool.uploadCost(&second);
    try std.testing.expectEqual(64 * @sizeOf(Vertex), growth_cost.payload_bytes);
    try std.testing.expectEqual(@sizeOf(Vertex), growth_cost.migration_bytes);
    try std.testing.expectEqual(65 * @sizeOf(Vertex), growth_cost.total());
    pool.destroyMesh(&first);
    pool.destroyMesh(&second);
}

test "LODVertexPool splits oversized staging updates" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, lod_mesh.MAX_STAGING_UPDATE_BYTES * 2);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    const vertex_count = lod_mesh.MAX_STAGING_UPDATE_BYTES / @sizeOf(Vertex) + 1;
    try setPending(&mesh, allocator, vertex_count);
    try pool.uploadMesh(&mesh, resources.resources());

    try std.testing.expect(resources.updated >= 2);
    try std.testing.expect(resources.max_update_bytes <= lod_mesh.MAX_STAGING_UPDATE_BYTES);
    try std.testing.expectEqual(vertex_count * @sizeOf(Vertex), resources.total_updated_bytes);
    pool.destroyMesh(&mesh);
}

test "LODVertexPool compacts fragmented ranges" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var a = LODMesh.init(allocator, .lod1);
    var b = LODMesh.init(allocator, .lod1);
    var c = LODMesh.init(allocator, .lod1);
    try setPending(&a, allocator, 4);
    try setPending(&b, allocator, 4);
    try setPending(&c, allocator, 4);
    try pool.uploadMesh(&a, resources.resources());
    try pool.uploadMesh(&b, resources.resources());
    try pool.uploadMesh(&c, resources.resources());

    pool.destroyMesh(&b);
    const old_c_offset = c.vertex_offset;
    const old_handle = c.buffer_handle;
    try pool.compact(resources.resources());

    try std.testing.expect(c.vertex_offset < old_c_offset);
    try std.testing.expect(c.buffer_handle != old_handle);
    try std.testing.expectEqual(c.buffer_handle, a.buffer_handle);
    try std.testing.expectEqual(@as(u32, 2), resources.created);
    try std.testing.expectEqual(@as(u32, 1), resources.destroyed);
    try std.testing.expectEqual(pool.capacity_bytes - pool.allocatedBytes(), pool.freeBytes());
    pool.destroyMesh(&a);
    pool.destroyMesh(&c);
}

test "LODVertexPool compaction failure preserves live allocation locations" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var a = LODMesh.init(allocator, .lod1);
    var b = LODMesh.init(allocator, .lod1);
    var c = LODMesh.init(allocator, .lod1);
    try setPending(&a, allocator, 4);
    try setPending(&b, allocator, 4);
    try setPending(&c, allocator, 4);
    try pool.uploadMesh(&a, resources.resources());
    try pool.uploadMesh(&b, resources.resources());
    try pool.uploadMesh(&c, resources.resources());

    pool.destroyMesh(&b);
    const old_a_handle = a.buffer_handle;
    const old_a_offset = a.vertex_offset;
    const old_c_handle = c.buffer_handle;
    const old_c_offset = c.vertex_offset;
    resources.fail_updates = true;

    try std.testing.expectError(error.GpuLost, pool.compact(resources.resources()));
    try std.testing.expectEqual(old_a_handle, a.buffer_handle);
    try std.testing.expectEqual(old_a_offset, a.vertex_offset);
    try std.testing.expectEqual(old_c_handle, c.buffer_handle);
    try std.testing.expectEqual(old_c_offset, c.vertex_offset);
    try std.testing.expectEqual(@as(u32, 2), resources.created);
    try std.testing.expectEqual(@as(u32, 1), resources.destroyed);

    resources.fail_updates = false;
    pool.destroyMesh(&a);
    pool.destroyMesh(&c);
}

test "LODVertexPool upload failure keeps pending vertices retryable" {
    const allocator = std.testing.allocator;
    var resources = TestResources{ .fail_updates = true };
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    defer if (mesh.pending_vertices) |pending| allocator.free(pending);
    try setPending(&mesh, allocator, 4);
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&mesh, resources.resources()));

    try std.testing.expect(mesh.pending_vertices != null);
    try std.testing.expect(!mesh.ready);
    try std.testing.expectEqual(@as(u32, 0), mesh.vertex_count);
}

test "LODVertexPool upload failure preserves existing renderable allocation" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    defer if (mesh.pending_vertices) |pending| allocator.free(pending);
    try setPending(&mesh, allocator, 4);
    try pool.uploadMesh(&mesh, resources.resources());

    const old_handle = mesh.buffer_handle;
    const old_offset = mesh.vertex_offset;
    const old_count = mesh.vertex_count;
    resources.fail_updates = true;
    try setPending(&mesh, allocator, 4);
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&mesh, resources.resources()));

    try std.testing.expect(mesh.pending_vertices != null);
    try std.testing.expect(mesh.ready);
    try std.testing.expect(mesh.pooled);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expectEqual(old_offset, mesh.vertex_offset);
    try std.testing.expectEqual(old_count, mesh.vertex_count);
    try std.testing.expectEqual(@as(usize, old_count) * @sizeOf(Vertex), pool.allocatedBytes());
}

test "LODVertexPool exposes compaction threshold helper" {
    _ = shouldCompactAfterEviction;
}

test "LODVertexPool defers range reuse until its frame slot completes" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var a = LODMesh.init(allocator, .lod1);
    var b = LODMesh.init(allocator, .lod1);
    try setPending(&a, allocator, 4);
    try setPending(&b, allocator, 4);
    try pool.uploadMesh(&a, resources.resources());
    try pool.uploadMesh(&b, resources.resources());
    const free_before = pool.freeBytes();

    pool.destroyMeshDeferred(&a, 10, 0);
    try std.testing.expectEqual(@as(usize, 1), pool.retired_ranges.items.len);
    try std.testing.expectEqual(free_before, pool.freeBytes());

    pool.collectRetired(10, 1);
    try std.testing.expectEqual(@as(usize, 1), pool.retired_ranges.items.len);
    pool.collectRetired(11, 0);
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items.len);
    try std.testing.expect(pool.freeBytes() > free_before);
    pool.destroyMesh(&b);
}

test "LODVertexPool plans one replacement and exact staging for growth" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());
    var a = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&a);
    var b = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&b);

    try setPending(&a, allocator, 1024 / @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 2048), pool.uploadMemoryCost(&a));
    try pool.uploadMesh(&a, resources.resources());
    try setPending(&a, allocator, 1);
    try std.testing.expectEqual(@as(usize, 0), pool.uploadMemoryCost(&a));
    try pool.uploadMesh(&a, resources.resources());

    // The old grow-then-grow path replaced twice for this request. Migration
    // includes the old allocation's retained slack, not just its vertex count.
    try setPending(&b, allocator, 1536 / @sizeOf(Vertex));
    const staging = pool.uploadCost(&b);
    try std.testing.expectEqual(@as(usize, 1536), staging.payload_bytes);
    try std.testing.expectEqual(@as(usize, 1024), staging.migration_bytes);
    try std.testing.expectEqual(@as(usize, 8192), pool.uploadMemoryCost(&b));
    const before = resources.total_updated_bytes;
    try pool.uploadMesh(&b, resources.resources());
    try std.testing.expectEqual(staging.total(), resources.total_updated_bytes - before);
    try std.testing.expectEqual(@as(u32, 2), resources.created);
    try std.testing.expectEqual(@as(usize, 4096), pool.gpuMemoryBytes());
    try std.testing.expectEqual(pool.gpuMemoryBytes(), pool.shadow.len);
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(u32, 0), resources.wait_idle);
}

test "LODVertexPool empty admission and reclamation retain debt until strict matching completion" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());
    var mesh = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&mesh);

    try std.testing.expectEqual(@as(usize, 0), pool.uploadMemoryCost(&mesh));
    try setPending(&mesh, allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), pool.uploadMemoryCost(&mesh));
    try std.testing.expectEqual(@as(usize, 0), pool.uploadCost(&mesh).total());
    try pool.uploadMesh(&mesh, resources.resources());
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    try std.testing.expect(!try pool.trim(resources.resources(), 0, 0));

    try setPending(&mesh, allocator, 4);
    const pending = mesh.pending_vertices.?.ptr;
    const denied_budget: usize = 2047;
    try std.testing.expect(pool.uploadMemoryCost(&mesh) > denied_budget);
    // Admission is caller-owned: querying a denied request must not allocate,
    // consume pending data, or publish a draw.
    try std.testing.expectEqual(@as(u32, 0), resources.created);
    try std.testing.expectEqual(@as(usize, 0), pool.gpuMemoryBytes());
    try std.testing.expectEqual(pending, mesh.pending_vertices.?.ptr);
    try std.testing.expect(!mesh.isRenderable());
    try pool.uploadMesh(&mesh, resources.resources());
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    pool.destroyMeshDeferred(&mesh, 10, 1);
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    pool.collectRetired(10, 1);
    pool.collectRetired(11, 0);
    pool.collectRetired(11, 1);
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    pool.collectRetired(12, 1);
    try std.testing.expect(pool.reclaimEmpty(resources.resources()));
    try std.testing.expectEqual(@as(usize, 0), pool.gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.shadow.len);
    try std.testing.expectEqual(@as(usize, 0), pool.freeBytes());
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    pool.collectRetired(12, 1);
    pool.collectRetired(13, 0);
    pool.collectRetired(13, 1);
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    pool.collectRetired(14, 1);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(u32, 1), resources.destroyed);
    try std.testing.expectEqual(@as(u32, 0), resources.wait_idle);
}

test "LODVertexPool trim obeys peak and live staging budgets without migrating retired ranges" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 8192);
    defer pool.deinit(resources.resources());
    var dead = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&dead);
    var live = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&live);
    try setPending(&dead, allocator, 32);
    try pool.uploadMesh(&dead, resources.resources());
    try setPending(&live, allocator, 4);
    @memset(std.mem.sliceAsBytes(live.pending_vertices.?), 0x5a);
    try pool.uploadMesh(&live, resources.resources());
    pool.destroyMeshDeferred(&dead, 20, 0);
    try setPending(&live, allocator, 8);
    const pending = live.pending_vertices.?.ptr;
    const live_bytes = 4 * @sizeOf(Vertex);
    const old_handle = live.buffer_handle;
    const before = resources.total_updated_bytes;

    try std.testing.expect(!try pool.trim(resources.resources(), 2047, live_bytes));
    try std.testing.expect(!try pool.trim(resources.resources(), 2048, live_bytes - 1));
    try std.testing.expectEqual(@as(u32, 1), resources.created);
    try std.testing.expectEqual(old_handle, live.buffer_handle);
    try std.testing.expect(try pool.trim(resources.resources(), 2048, live_bytes));
    try std.testing.expectEqual(live_bytes, resources.total_updated_bytes - before);
    try std.testing.expectEqual(@as(usize, 1024), pool.gpuMemoryBytes());
    try std.testing.expectEqual(pool.gpuMemoryBytes(), pool.shadow.len);
    try std.testing.expectEqual(@as(usize, 8192), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items.len);
    try std.testing.expectEqual(live_bytes, pool.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 0), live.vertex_offset);
    try std.testing.expect(live.buffer_handle != old_handle);
    try std.testing.expectEqual(pending, live.pending_vertices.?.ptr);
    for (pool.shadow[0..live_bytes]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expect(!try pool.trim(resources.resources(), 8192, 8192));
    pool.collectRetired(20, 0);
    try std.testing.expectEqual(@as(usize, 8192), pool.retiredGpuMemoryBytes());
    pool.collectRetired(21, 0);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
    try pool.uploadMesh(&live, resources.resources());
    try setPending(&live, allocator, 1536 / @sizeOf(Vertex));
    // Growing after trim must not jump straight back to the 8 KiB startup size.
    try std.testing.expectEqual(@as(usize, 4096), pool.uploadMemoryCost(&live));
    try pool.uploadMesh(&live, resources.resources());
    try std.testing.expectEqual(@as(usize, 2048), pool.gpuMemoryBytes());
}

test "LODVertexPool failed payload after packing keeps relocated old geometry retryable" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());
    var a = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&a);
    var b = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&b);
    var c = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&c);
    var d = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&d);
    for ([_]*LODMesh{ &a, &b, &c }) |mesh| {
        try setPending(mesh, allocator, 128 / @sizeOf(Vertex));
        @memset(std.mem.sliceAsBytes(mesh.pending_vertices.?), 0x5a);
        try pool.uploadMesh(mesh, resources.resources());
    }
    pool.destroyMesh(&a);
    try setPending(&d, allocator, 128 / @sizeOf(Vertex));
    try pool.uploadMesh(&d, resources.resources());
    pool.destroyMesh(&b);
    // Records are now [c at 256, d at 0], deliberately not offset-sorted.
    const old_handle = c.buffer_handle;
    try setPending(&c, allocator, 768 / @sizeOf(Vertex));
    const pending = c.pending_vertices.?.ptr;
    try std.testing.expectEqual(@as(usize, 2048), pool.uploadMemoryCost(&c));
    try std.testing.expectEqual(@as(usize, 256), pool.uploadCost(&c).migration_bytes);
    resources.fail_after_updates = resources.updated + 2;
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&c, resources.resources()));
    try std.testing.expect(c.buffer_handle != old_handle);
    try std.testing.expectEqual(@as(u32, 2), resources.created);
    try std.testing.expectEqual(c.buffer_handle, d.buffer_handle);
    try std.testing.expectEqual(@as(usize, 0), c.vertex_offset);
    try std.testing.expectEqual(@as(usize, 128), d.vertex_offset);
    try std.testing.expectEqual(@as(u32, 128 / @sizeOf(Vertex)), c.vertex_count);
    try std.testing.expect(c.isRenderable());
    try std.testing.expectEqual(pending, c.pending_vertices.?.ptr);
    try std.testing.expectEqual(@as(usize, 256), pool.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 768), pool.freeBytes());
    for (pool.shadow[0..128]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);

    resources.fail_after_updates = null;
    try std.testing.expectEqual(@as(usize, 0), pool.uploadMemoryCost(&c));
    try std.testing.expectEqual(@as(usize, 0), pool.uploadCost(&c).migration_bytes);
    try pool.uploadMesh(&c, resources.resources());
    try std.testing.expectEqual(@as(usize, 256), c.vertex_offset);
    try std.testing.expectEqual(@as(usize, 128), d.vertex_offset);
    try std.testing.expectEqual(@as(usize, 1), pool.retired_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items[0].offset);
    try std.testing.expectEqual(@as(usize, 128), pool.retired_ranges.items[0].size);
}

test "LODVertexPool trim create and partial migration failures preserve publication and charge failed backing" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 8192);
    defer pool.deinit(resources.resources());
    var a = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&a);
    var b = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&b);
    for ([_]*LODMesh{ &a, &b }) |mesh| {
        try setPending(mesh, allocator, 4);
        try pool.uploadMesh(mesh, resources.resources());
    }
    const old_handle = a.buffer_handle;
    const old_b_offset = b.vertex_offset;
    const old_shadow = pool.shadow.ptr;
    const free_before = pool.freeBytes();
    pool.collectRetired(30, 1);
    resources.fail_create = true;
    try std.testing.expectError(error.OutOfMemory, pool.trim(resources.resources(), 2048, 8192));
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(u32, 1), resources.created);
    resources.fail_create = false;
    resources.fail_after_updates = resources.updated + 1;
    try std.testing.expectError(error.GpuLost, pool.trim(resources.resources(), 2048, 8192));
    try std.testing.expectEqual(old_handle, a.buffer_handle);
    try std.testing.expectEqual(old_handle, b.buffer_handle);
    try std.testing.expectEqual(old_b_offset, b.vertex_offset);
    try std.testing.expectEqual(old_shadow, pool.shadow.ptr);
    try std.testing.expectEqual(@as(usize, 8192), pool.shadow.len);
    try std.testing.expectEqual(@as(usize, 8192), pool.gpuMemoryBytes());
    try std.testing.expectEqual(free_before, pool.freeBytes());
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(u32, 1), resources.destroyed);
    try std.testing.expectError(error.GpuLost, pool.trim(resources.resources(), 2048, 8192));
    try std.testing.expectEqual(@as(usize, 2048), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(old_handle, pool.buffer_handle);
    pool.collectRetired(30, 1);
    pool.collectRetired(31, 0);
    try std.testing.expectEqual(@as(usize, 2048), pool.retiredGpuMemoryBytes());
    pool.collectRetired(32, 1);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
}

test "LODVertexPool reserves retirement bookkeeping before GPU create and empty release" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 8192);
    defer pool.deinit(resources.resources());
    var mesh = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&mesh);
    try setPending(&mesh, allocator, 4);
    try pool.uploadMesh(&mesh, resources.resources());
    const old_handle = mesh.buffer_handle;
    // Initial creation reserved a debt slot but did not use it. Remove that
    // spare bookkeeping allocation to force the next reservation to fail.
    try std.testing.expectEqual(@as(usize, 0), pool.retired_backings.items.len);
    pool.retired_backings.deinit(allocator);
    pool.retired_backings = .empty;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    pool.allocator = failing.allocator();
    defer pool.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, pool.trim(resources.resources(), 2048, 8192));
    try std.testing.expectEqual(@as(u32, 1), resources.created);
    try std.testing.expectEqual(@as(u32, 0), resources.destroyed);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expect(mesh.isRenderable());
    try std.testing.expectEqual(@as(usize, 8192), pool.gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());

    try setPending(&mesh, allocator, 8192 / @sizeOf(Vertex) + 1);
    const pending = mesh.pending_vertices.?.ptr;
    try std.testing.expectError(error.OutOfMemory, pool.uploadMesh(&mesh, resources.resources()));
    try std.testing.expectEqual(pending, mesh.pending_vertices.?.ptr);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expect(mesh.isRenderable());
    try std.testing.expectEqual(@as(u32, 1), resources.created);

    pool.allocator = allocator;
    pool.destroyMesh(&mesh);
    pool.allocator = failing.allocator();
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    try std.testing.expectEqual(old_handle, pool.buffer_handle);
    try std.testing.expectEqual(@as(usize, 8192), pool.shadow.len);
    try std.testing.expectEqual(@as(u32, 0), resources.destroyed);
    pool.allocator = allocator;
    try std.testing.expect(pool.reclaimEmpty(resources.resources()));
    try std.testing.expectEqual(@as(usize, 8192), pool.retiredGpuMemoryBytes());
    try setPending(&mesh, allocator, 4);
    pool.allocator = failing.allocator();
    // Existing debt remains charged even when allocating the next shadow fails.
    try std.testing.expectError(error.OutOfMemory, pool.uploadMesh(&mesh, resources.resources()));
    try std.testing.expectEqual(@as(usize, 8192), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.shadow.len);
    try std.testing.expectEqual(@as(u32, 1), resources.created);
}

test "LODVertexPool lost retirement record cannot manufacture full free coverage" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());
    var mesh = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&mesh);
    try setPending(&mesh, allocator, 4);
    try pool.uploadMesh(&mesh, resources.resources());
    const free_before = pool.freeBytes();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    pool.allocator = failing.allocator();
    pool.destroyMeshDeferred(&mesh, 40, 0);
    pool.allocator = allocator;
    try std.testing.expectEqual(@as(usize, 0), pool.allocations.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items.len);
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    pool.collectRetired(41, 0);
    try pool.compact(resources.resources());
    try std.testing.expect(!try pool.trim(resources.resources(), 2048, 1024));
    try std.testing.expect(!pool.reclaimEmpty(resources.resources()));
    try std.testing.expectEqual(free_before, pool.freeBytes());
    try std.testing.expectEqual(@as(usize, 1024), pool.gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 1024), pool.shadow.len);
    try std.testing.expectEqual(@as(u32, 0), resources.destroyed);
}

test "LODVertexPool large update uses a fresh range through partial failure and retry" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 3 * lod_mesh.MAX_STAGING_UPDATE_BYTES);
    defer pool.deinit(resources.resources());
    var mesh = LODMesh.init(allocator, .lod1);
    defer pool.destroyMesh(&mesh);
    const count = lod_mesh.MAX_STAGING_UPDATE_BYTES / @sizeOf(Vertex) + 1;
    try setPending(&mesh, allocator, count);
    try pool.uploadMesh(&mesh, resources.resources());
    const old_handle = mesh.buffer_handle;
    const old_offset = mesh.vertex_offset;
    const free_before = pool.freeBytes();
    try setPending(&mesh, allocator, count);
    @memset(std.mem.sliceAsBytes(mesh.pending_vertices.?), 0x5a);
    try std.testing.expectEqual(@as(usize, 0), pool.uploadMemoryCost(&mesh));
    try std.testing.expectEqual(@as(usize, 0), pool.uploadCost(&mesh).migration_bytes);
    resources.fail_after_updates = resources.updated + 1;
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&mesh, resources.resources()));
    try std.testing.expectEqual(count * @sizeOf(Vertex), resources.last_update_offset);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expectEqual(old_offset, mesh.vertex_offset);
    try std.testing.expectEqual(@as(u32, @intCast(count)), mesh.vertex_count);
    try std.testing.expect(mesh.isRenderable());
    try std.testing.expect(mesh.pending_vertices != null);
    try std.testing.expectEqual(free_before, pool.freeBytes());
    try std.testing.expectEqual(@as(u8, 0), pool.shadow[old_offset]);
    resources.fail_after_updates = null;
    try pool.uploadMesh(&mesh, resources.resources());
    try std.testing.expect(mesh.vertex_offset != old_offset);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expectEqual(@as(usize, 1), pool.retired_ranges.items.len);
    try std.testing.expectEqual(old_offset, pool.retired_ranges.items[0].offset);
    try std.testing.expectEqual(@as(u8, 0x5a), pool.shadow[mesh.vertex_offset]);
    try std.testing.expectEqual(@as(u32, 1), resources.created);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
}
