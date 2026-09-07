//! Immutable exact chunk sources. No manager locks or callbacks are used here.
const std = @import("std");
const sync = @import("sync");
const world_core = @import("world-core");
const scene = world_core.lod_scene;
const ChunkSummary = scene.ChunkSummary;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const JobQueue = @import("engine-core").job_system.JobQueue;
const builder = @import("lod_scene_builder.zig");
const store = @import("world-persistence").summary_store;
const AtomicBool = std.atomic.Value(bool);

pub const ChunkCoord = struct { cx: i32, cz: i32 };

pub const SourceHierarchy = struct {
    pub const Lease = builder.Lease;
    pub const max_background_jobs = 32;
    pub const max_changes = 1024;
    /// Full block capture, worst-case runs, codec buffers and generator scratch.
    pub const scratch_reservation_bytes = 4 * 1024 * 1024;

    const Accounting = struct {
        allocator: std.mem.Allocator,
        refs: std.atomic.Value(usize) = .init(1),
        bytes: std.atomic.Value(usize) = .init(0),

        fn release(self: *Accounting) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
        }
    };

    const Entry = struct {
        summary: ChunkSummary,
        accounting: *Accounting,
        refs: std.atomic.Value(usize) = .init(1),

        fn retain(self: *Entry) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        fn lease(self: *Entry) builder.Lease {
            self.retain();
            return .{ .summary = &self.summary, .ptr = self, .release_fn = release };
        }

        fn release(ptr: *anyopaque) void {
            const self: *Entry = @ptrCast(@alignCast(ptr));
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            const accounting = self.accounting;
            const bytes = @sizeOf(Entry) + self.summary.runs.len * @sizeOf(scene.Run);
            self.summary.deinit();
            accounting.allocator.destroy(self);
            _ = accounting.bytes.fetchSub(bytes, .release);
            accounting.release();
        }
    };

    const Stamp = struct {
        saved_epoch: u64,
        persistence: u64,
    };

    const Record = struct {
        entry: ?*Entry = null,
        validated: ?Stamp = null,
        absent: bool = false,
        revision: u64 = 0,
        /// Snapshot/capture order, never the arrival time of a disk revalidation.
        light_order: u64 = 0,
        latest_committed_revision: u64 = 0,
        committed_fingerprint: ?u64 = null,
        history_floor: u64 = 0,
        fingerprint: ?u64 = null,
        lighting_hash: u64 = 0,
        origin: scene.Origin = .generated,
        requested_revision: u64 = 0,
        preparing: usize = 0,
        /// A saved source was accepted but its sidecar has not yet completed.
        /// This is metadata only: a later strict read re-establishes authority.
        persistence_pending: bool = false,
        touched: u64 = 0,
    };

    const Work = struct {
        owner: *SourceHierarchy,
        busy: bool = false,
        coord: ChunkCoord = .{ .cx = 0, .cz = 0 },
        revision: u64 = 0,
        stamp: Stamp = .{ .saved_epoch = 0, .persistence = 0 },
        entry: ?*Entry = null,
        cancel: AtomicBool = .init(false),
        /// Queue cleanup must retain a saved sidecar obligation unless this
        /// worker observed a successful durable write.
        persistence_required: bool = false,

        fn cleanup(ptr: *anyopaque) void {
            const self: *Work = @ptrCast(@alignCast(ptr));
            const owner = self.owner;
            owner.mutex.lock();
            defer owner.mutex.unlock();
            if (self.entry) |entry| {
                if (self.persistence_required and entry.summary.origin == .saved) {
                    if (owner.records.getPtr(self.coord)) |record| {
                        if (record.entry != null and record.entry.?.summary.origin == .saved) record.persistence_pending = true;
                    }
                }
                Entry.release(entry);
            }
            self.entry = null;
            self.busy = false;
            _ = owner.makeRoom(0, null);
        }

        fn process(ptr: *anyopaque) void {
            const self: *Work = @ptrCast(@alignCast(ptr));
            // `cleanup` makes this storage reusable. Capture everything needed
            // afterwards before calling it; in particular never retain a
            // pointer to this slot's cancellation flag.
            const owner = self.owner;
            const coord = self.coord;
            const saved_persistence = if (self.entry) |entry| entry.summary.origin == .saved else false;
            if (self.cancel.load(.acquire)) {
                cleanup(ptr);
                if (saved_persistence) owner.repairSavedPersistence(coord);
                return;
            }
            if (self.entry) |entry| {
                const result = owner.persist(entry, self.stamp, &self.cancel);
                self.persistence_required = result != .written;
                // Return this slot before a revalidation queues its replacement.
                // The hierarchy can intentionally permit only one writer.
                cleanup(ptr);
                if (saved_persistence and result != .written) {
                    // A different chunk committed while this sidecar write was
                    // queued, or cancellation prevented admission. Revalidate
                    // this coordinate without the released slot's cancel flag;
                    // never persist the old snapshot across an epoch change.
                    owner.repairSavedPersistence(coord);
                }
                return;
            }
            defer cleanup(ptr);
            owner.generate(coord, self.revision, self.stamp, &self.cancel, self, null) catch {};
        }
    };

    allocator: std.mem.Allocator,
    generator: LODGenerator,
    queue: *JobQueue,
    cache_budget_bytes: usize,
    mutex: sync.Mutex = .{},
    /// Lock order is io_mutex -> mutex. Never hold mutex across I/O or queue calls.
    io_mutex: sync.Mutex = .{},
    /// Serialize callback sampling without invoking backend code under mutex.
    validation_mutex: sync.Mutex = .{},
    records: std.AutoHashMapUnmanaged(ChunkCoord, Record) = .empty,
    accounting: *Accounting,
    works: [max_background_jobs]Work = undefined,
    next_revision: std.atomic.Value(u64) = .init(1),
    /// Bounded history fence when compact per-coordinate authority is forgotten.
    retired_revision: u64 = 0,
    source_epoch: std.atomic.Value(u64) = .init(0),
    saved_epoch: u64 = 0,
    persistence_generation: u64 = 0,
    save_dir: ?[]u8 = null,
    root_bytes: usize = 0,
    clock: u64 = 0,
    prepares_active: usize = 0,
    changes: [max_changes]ChunkCoord = undefined,
    change_head: usize = 0,
    change_count: usize = 0,
    invalidate_all: bool = false,

    /// Allocators must support concurrent use and outlive their last leased summary.
    /// Live sources and synchronous capture scratch may exceed the cache budget.
    pub fn init(allocator: std.mem.Allocator, generator: LODGenerator, queue: *JobQueue, cache_budget_bytes: usize) !*SourceHierarchy {
        const self = try allocator.create(SourceHierarchy);
        errdefer allocator.destroy(self);
        const accounting = try allocator.create(Accounting);
        accounting.* = .{ .allocator = allocator };
        self.* = .{
            .allocator = allocator,
            .generator = generator,
            .queue = queue,
            .cache_budget_bytes = cache_budget_bytes,
            .accounting = accounting,
        };
        for (&self.works) |*work| work.* = .{ .owner = self };
        self.saved_epoch = self.backendEpoch();
        return self;
    }

    /// Producers must be stopped and queue workers joined first. Leases may outlive us.
    pub fn deinit(self: *SourceHierarchy) void {
        for (&self.works) |*work| std.debug.assert(!work.busy);
        std.debug.assert(self.prepares_active == 0);
        var it = self.records.valueIterator();
        while (it.next()) |record| if (record.entry) |entry| Entry.release(entry);
        self.records.deinit(self.allocator);
        if (self.save_dir) |root| self.allocator.free(root);
        self.accounting.release();
        self.allocator.destroy(self);
    }

    pub fn reserveRevision(self: *SourceHierarchy) u64 {
        return self.next_revision.fetchAdd(1, .monotonic);
    }

    /// Always consumes summary, including rejection and allocation failure.
    pub fn submit(self: *SourceHierarchy, summary: ChunkSummary) void {
        _ = self.trySubmit(summary);
    }

    /// Always consumes the value. False preserves the caller's obligation to
    /// recapture an edited resident chunk after allocation/admission recovers.
    pub fn trySubmit(self: *SourceHierarchy, summary: ChunkSummary) bool {
        const accepted = (self.publish(summary, null, .observation, null) catch return false) orelse return true;
        defer Entry.release(accepted);
        if (accepted.summary.origin == .generated) self.enqueueWrite(accepted, null);
        return true;
    }

    /// Fence a durable snapshot before any fallible capture/publication. A null
    /// fingerprint means capture has not succeeded yet, not confirmed absence.
    pub fn noteCommitted(self: *SourceHierarchy, coord: ChunkCoord, revision: u64, fingerprint: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelOlder(coord, .saved, revision);
        const record = (self.recordFor(coord, true) catch null) orelse {
            // There is no cached entry at this coordinate. Block late captures
            // through the bounded absence fence and let strict demand repair it.
            self.retired_revision = @max(self.retired_revision, revision);
            self.invalidateLocked();
            return;
        };
        if (revision < record.latest_committed_revision) return;
        if (revision > record.latest_committed_revision) {
            record.latest_committed_revision = revision;
            record.committed_fingerprint = fingerprint;
            if (record.origin == .generated or revision > record.revision or revision > record.light_order) {
                record.validated = null;
                self.changed(coord);
            }
        } else if (fingerprint != null) record.committed_fingerprint = fingerprint;
    }

    /// Called by the block-source writer after its successful durable write.
    /// summary.revision MUST be reserved at snapshot time, not callback arrival.
    /// The optional observation write is synchronous here, never in submit().
    pub fn commitSaved(self: *SourceHierarchy, summary: ChunkSummary) void {
        var saved = summary;
        saved.origin = .saved;
        self.noteCommitted(.{ .cx = saved.chunk_x, .cz = saved.chunk_z }, saved.revision, saved.fingerprint());
        self.io_mutex.lock();
        const retry = blk: {
            defer self.io_mutex.unlock();
            const stamp = self.refreshStamp();
            const accepted = (self.publish(saved, stamp, .committed, null) catch {
                // Blocks have committed even if their observation cannot be cached.
                // Force demand-driven repair instead of leaving old grids current.
                self.mutex.lock();
                self.invalidateLocked();
                self.mutex.unlock();
                return;
            }) orelse return;
            defer Entry.release(accepted);
            self.mutex.lock();
            self.prepares_active += 1;
            self.mutex.unlock();
            defer {
                self.mutex.lock();
                self.prepares_active -= 1;
                self.mutex.unlock();
            }
            break :blk self.persistLocked(accepted, stamp, null);
        };
        if (retry != .written) self.repairSavedPersistence(.{ .cx = saved.chunk_x, .cz = saved.chunk_z });
    }

    pub fn setPersistence(self: *SourceHierarchy, save_dir: []const u8) !void {
        const root = try self.allocator.dupe(u8, save_dir);
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.save_dir) |old| self.allocator.free(old);
        self.save_dir = root;
        self.root_bytes = root.len;
        self.persistence_generation +%= 1;
        for (&self.works) |*work| if (work.busy) work.cancel.store(true, .release);
        self.invalidateLocked();
    }

    pub fn provider(self: *SourceHierarchy) builder.Provider {
        return .{
            .ptr = self,
            .prepare_fn = prepareAdapter,
            .lock_fn = lockAdapter,
            .unlock_fn = unlockAdapter,
            .acquire_fn = acquireAdapter,
            .epoch_fn = epochAdapter,
            .snapshot_fn = snapshotAdapter,
        };
    }

    pub fn drainChanges(self: *SourceHierarchy, out: *std.ArrayListUnmanaged(ChunkCoord), limit: usize) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(limit, self.change_count);
        try out.ensureUnusedCapacity(self.allocator, count);
        for (0..count) |_| {
            out.appendAssumeCapacity(self.changes[self.change_head]);
            self.change_head = (self.change_head + 1) % max_changes;
        }
        self.change_count -= count;
        const all = self.invalidate_all;
        self.invalidate_all = false;
        return all;
    }

    pub fn memoryBytes(self: *SourceHierarchy) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.memoryLocked();
    }

    pub fn countKnown(self: *SourceHierarchy) usize {
        return self.countKnownInBounds(std.math.minInt(i32), std.math.minInt(i32), std.math.maxInt(i32), std.math.maxInt(i32));
    }

    pub fn countKnownInBounds(self: *SourceHierarchy, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.records.iterator();
        while (it.next()) |item| {
            const coord = item.key_ptr.*;
            if (coord.cx >= min_cx and coord.cx <= max_cx and coord.cz >= min_cz and coord.cz <= max_cz and self.usable(item.value_ptr)) count += 1;
        }
        return count;
    }

    pub fn epoch(self: *SourceHierarchy) u64 {
        return self.source_epoch.load(.acquire);
    }

    fn backendEpoch(self: *SourceHierarchy) u64 {
        const callback = self.generator.saved_source_epoch orelse return 0;
        return callback(self.generator.summary_context orelse self.generator.ptr);
    }

    fn stampLocked(self: *SourceHierarchy) Stamp {
        return .{ .saved_epoch = self.saved_epoch, .persistence = self.persistence_generation };
    }

    fn refreshStamp(self: *SourceHierarchy) Stamp {
        self.validation_mutex.lock();
        defer self.validation_mutex.unlock();
        const saved_epoch = self.backendEpoch();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (saved_epoch != self.saved_epoch) {
            self.saved_epoch = saved_epoch;
            self.invalidateLocked();
        }
        return self.stampLocked();
    }

    fn usable(self: *SourceHierarchy, record: *const Record) bool {
        const entry = record.entry orelse return false;
        if (record.origin == .generated and record.latest_committed_revision != 0) return false;
        if (record.revision < record.latest_committed_revision or record.light_order < record.latest_committed_revision) return false;
        return entry.summary.origin == .live or (record.validated != null and std.meta.eql(record.validated.?, self.stampLocked()));
    }

    fn memoryLocked(self: *SourceHierarchy) usize {
        var scratch = self.prepares_active;
        for (&self.works) |*work| if (work.busy) {
            scratch += 1;
        };
        // Hash table control bytes, alignment and allocation header are rounded up.
        return @sizeOf(SourceHierarchy) + @sizeOf(Accounting) + self.root_bytes +
            @as(usize, self.records.capacity()) * (@sizeOf(ChunkCoord) + @sizeOf(Record) + 32) +
            self.accounting.bytes.load(.acquire) + scratch * scratch_reservation_bytes;
    }

    fn touch(self: *SourceHierarchy, record: *Record) void {
        self.clock +%= 1;
        record.touched = self.clock;
    }

    fn invalidateLocked(self: *SourceHierarchy) void {
        self.invalidate_all = true;
        self.change_count = 0;
        self.change_head = 0;
        _ = self.source_epoch.fetchAdd(1, .release);
    }

    fn changed(self: *SourceHierarchy, coord: ChunkCoord) void {
        _ = self.source_epoch.fetchAdd(1, .release);
        if (self.invalidate_all) return;
        if (self.change_count == max_changes) {
            self.invalidate_all = true;
            self.change_count = 0;
            self.change_head = 0;
            return;
        }
        self.changes[(self.change_head + self.change_count) % max_changes] = coord;
        self.change_count += 1;
    }

    fn evictOne(self: *SourceHierarchy, protected: ?ChunkCoord) bool {
        var oldest: ?ChunkCoord = null;
        var age: u64 = std.math.maxInt(u64);
        var has_payload = false;
        var it = self.records.iterator();
        while (it.next()) |item| {
            if (protected) |coord| if (std.meta.eql(coord, item.key_ptr.*)) continue;
            if (item.value_ptr.preparing != 0) continue;
            // An evicted saved payload can be re-read, but dropping this compact
            // metadata would silently lose its bounded sidecar obligation.
            if (item.value_ptr.persistence_pending and item.value_ptr.entry == null) continue;
            if (item.value_ptr.entry) |entry| if (entry.summary.origin == .live and item.value_ptr.revision >= item.value_ptr.latest_committed_revision) continue;
            const payload = item.value_ptr.entry != null;
            if (oldest == null or (payload and !has_payload) or (payload == has_payload and item.value_ptr.touched <= age)) {
                oldest = item.key_ptr.*;
                age = item.value_ptr.touched;
                has_payload = payload;
            }
        }
        const coord = oldest orelse return false;
        const record = self.records.getPtr(coord).?;
        if (record.entry) |entry| {
            // Residency is not content. Keep compact authority until metadata
            // itself needs eviction; snapshots own independent immutable pins.
            record.entry = null;
            Entry.release(entry);
            return true;
        }
        self.retired_revision = @max(self.retired_revision, @max(record.history_floor, @max(record.revision, record.latest_committed_revision)));
        _ = self.records.remove(coord);
        if (self.records.count() == 0) {
            self.records.deinit(self.allocator);
            self.records = .empty;
        } else if (self.records.count() < self.records.capacity() / 8) {
            // Live entries can grow past budget. Reclaim that table high-water
            // mark once successful saves make their entries safely evictable.
            var smaller: @TypeOf(self.records) = .empty;
            smaller.ensureTotalCapacity(self.allocator, self.records.count()) catch return true;
            var remaining = self.records.iterator();
            while (remaining.next()) |item| smaller.putAssumeCapacity(item.key_ptr.*, item.value_ptr.*);
            self.records.deinit(self.allocator);
            self.records = smaller;
        }
        return true;
    }

    fn makeRoom(self: *SourceHierarchy, bytes: usize, protected: ?ChunkCoord) bool {
        while (self.memoryLocked() > self.cache_budget_bytes or bytes > self.cache_budget_bytes -| self.memoryLocked()) {
            if (!self.evictOne(protected)) return false;
        }
        return true;
    }

    fn recordFor(self: *SourceHierarchy, coord: ChunkCoord, live: bool) !?*Record {
        if (self.records.getPtr(coord)) |record| return record;
        // Preflight the next table growth rather than allocating unbounded negatives.
        const capacity: usize = self.records.capacity();
        const growth = if (self.records.count() + 1 > capacity / 5 * 4)
            (@max(capacity, 8) * 2) * (@sizeOf(ChunkCoord) + @sizeOf(Record) + 32)
        else
            0;
        if (!live and !self.makeRoom(growth, coord)) return null;
        const result = try self.records.getOrPut(self.allocator, coord);
        if (!result.found_existing) result.value_ptr.* = .{ .history_floor = self.retired_revision };
        self.touch(result.value_ptr);
        return result.value_ptr;
    }

    fn dataEqual(a: *const ChunkSummary, b: *const ChunkSummary) bool {
        if (!std.meta.eql(a.columns, b.columns) or a.runs.len != b.runs.len) return false;
        for (a.runs, b.runs) |ar, br| if (!std.meta.eql(ar, br)) return false;
        return true;
    }

    fn lightingHash(summary: *const ChunkSummary) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (summary.runs) |run| {
            const top = run.light_top;
            const bottom = run.light_bottom;
            hash.update(&[_]u8{ top.sky_light, top.block_light_r, top.block_light_g, top.block_light_b, bottom.sky_light, bottom.block_light_r, bottom.block_light_g, bottom.block_light_b });
        }
        return hash.final();
    }

    const Publication = enum { observation, committed, revalidate };

    /// Returns an additional pin for persistence; cache ownership is independent.
    fn publish(self: *SourceHierarchy, value: ChunkSummary, stamp: ?Stamp, publication: Publication, cancel: ?*const AtomicBool) !?*Entry {
        var summary = value;
        var consumed = false;
        defer if (!consumed) summary.deinit();
        try summary.validate();
        const fingerprint = summary.fingerprint();
        const coord: ChunkCoord = .{ .cx = summary.chunk_x, .cz = summary.chunk_z };
        self.mutex.lock();
        defer self.mutex.unlock();
        try checkCancel(cancel);
        if (stamp) |expected| if (!std.meta.eql(expected, self.stampLocked())) return error.SourceChanged;
        const committed = publication == .committed;
        const revalidate = publication == .revalidate;
        const existing = self.records.getPtr(coord);
        const floor = if (existing) |record| record.history_floor else self.retired_revision;
        // Missing metadata cannot prove an old live capture is superseded. The
        // caller must recapture at a fresh order, not silently lose a real edit.
        if (!revalidate and summary.revision <= floor and floor != 0) return error.SourceUnavailable;
        var light_order = summary.revision;
        if (existing) |record| {
            if (summary.origin == .generated and (summary.revision < record.requested_revision or record.latest_committed_revision != 0)) return null;
            if (!revalidate and summary.revision < record.latest_committed_revision) return null;
            if (summary.origin == .live and record.latest_committed_revision != 0 and summary.revision == record.latest_committed_revision) return null;
            if (publication == .observation and record.origin != .generated and summary.revision < record.revision) return null;
            const same_geometry = record.fingerprint == fingerprint;
            const saved_repair = summary.origin == .saved and record.latest_committed_revision != 0 and
                record.latest_committed_revision >= record.revision and
                (committed or revalidate or record.committed_fingerprint == null or record.committed_fingerprint == fingerprint);
            const downgrade = summary.origin == .saved and same_geometry and (committed or revalidate or
                (record.latest_committed_revision != 0 and (record.committed_fingerprint == null or record.committed_fingerprint == fingerprint)));
            if (record.fingerprint != null) {
                if (@intFromEnum(summary.origin) < @intFromEnum(record.origin) and !saved_repair and !downgrade) return null;
                if (summary.revision < record.revision and record.origin != .generated and !downgrade and !(revalidate and record.origin != .live)) return null;
                if (revalidate and record.revision > summary.revision and !same_geometry) return null;
            }
            if (revalidate) {
                // A strict read validates disk authority; it does not observe
                // newly computed lighting at this lookup's reservation order.
                summary.revision = record.latest_committed_revision;
                light_order = record.latest_committed_revision;
                record.committed_fingerprint = if (record.latest_committed_revision != 0) fingerprint else null;
            }
            if (same_geometry and record.entry != null and
                ((revalidate and record.light_order >= record.latest_committed_revision) or
                    (committed and record.light_order > summary.revision)))
            {
                const old = record.entry.?;
                var copy = try old.summary.clone(self.allocator);
                copy.origin = summary.origin;
                copy.revision = record.revision;
                summary.deinit();
                summary = copy;
                light_order = record.light_order;
            }
        } else if (revalidate) {
            summary.revision = 0;
            light_order = 0;
        }
        var equal = false;
        if (existing) |record| if (record.entry) |old| {
            equal = dataEqual(&old.summary, &summary);
            if (equal and old.summary.origin == summary.origin) {
                record.revision = @max(record.revision, summary.revision);
                record.light_order = light_order;
                if (stamp) |expected| record.validated = expected;
                self.touch(record);
                self.cancelOlder(coord, summary.origin, summary.revision);
                old.retain();
                return old;
            }
        };
        const light_hash = lightingHash(&summary);
        const previous = (try self.recordFor(coord, summary.origin == .live or committed)) orelse return error.SourceUnavailable;
        if (previous.entry == null) equal = previous.fingerprint == fingerprint and previous.lighting_hash == light_hash;
        const bytes = @sizeOf(Entry) + summary.runs.len * @sizeOf(scene.Run);
        const reclaimable = if (previous.entry) |old|
            if (old.refs.load(.acquire) == 1) @sizeOf(Entry) + old.summary.runs.len * @sizeOf(scene.Run) else 0
        else
            0;
        if (summary.origin != .live and !committed and !self.makeRoom(bytes -| reclaimable, coord)) return error.SourceUnavailable;
        // Eviction can compact the table; reacquire the protected coordinate.
        const record = self.records.getPtr(coord).?;
        const entry = try self.allocator.create(Entry);
        entry.* = .{ .summary = summary, .accounting = self.accounting };
        consumed = true;
        _ = self.accounting.refs.fetchAdd(1, .monotonic);
        _ = self.accounting.bytes.fetchAdd(bytes, .release);
        if (record.entry) |old| Entry.release(old);
        record.entry = entry;
        record.revision = summary.revision;
        record.light_order = light_order;
        record.fingerprint = fingerprint;
        record.lighting_hash = light_hash;
        record.origin = summary.origin;
        if (summary.origin != .saved) record.persistence_pending = false;
        record.validated = stamp orelse if (self.generator.load_chunk_summary == null) self.stampLocked() else null;
        record.absent = summary.origin == .generated;
        self.touch(record);
        if (!equal) self.changed(coord);
        // Cancel older jobs even if this entry is subsequently evicted. A job's
        // cancellation fence outlives the bounded per-coordinate metadata.
        self.cancelOlder(coord, summary.origin, summary.revision);
        entry.retain();
        _ = self.makeRoom(0, null);
        return entry;
    }

    fn cancelOlder(self: *SourceHierarchy, coord: ChunkCoord, origin: scene.Origin, revision: u64) void {
        for (&self.works) |*work| {
            if (!work.busy or !std.meta.eql(work.coord, coord)) continue;
            if (origin != .generated or work.revision < revision) work.cancel.store(true, .release);
        }
    }

    fn lockAdapter(ptr: *anyopaque) void {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
    }

    fn unlockAdapter(ptr: *anyopaque) void {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        self.mutex.unlock();
    }

    /// Provider callers hold lock_fn across the snapshot's acquisitions and epoch.
    fn acquireAdapter(ptr: *anyopaque, cx: i32, cz: i32) ?builder.Lease {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        const record = self.records.getPtr(.{ .cx = cx, .cz = cz }) orelse return null;
        if (!self.usable(record)) return null;
        const entry = record.entry.?;
        self.touch(record);
        return entry.lease();
    }

    fn epochAdapter(ptr: *anyopaque) u64 {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        return self.epoch();
    }

    fn prepareAdapter(ptr: *anyopaque, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32, exact: bool, cancel: ?*const AtomicBool) anyerror!void {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        // i64 iterators also handle inclusive maxInt(i32) without overflow.
        var z: i64 = min_cz;
        while (z <= max_cz) : (z += 1) {
            var x: i64 = min_cx;
            while (x <= max_cx) : (x += 1) {
                try checkCancel(cancel);
                try self.prepareOne(.{ .cx = @intCast(x), .cz = @intCast(z) }, exact, cancel, null);
            }
        }
    }

    fn checkCancel(cancel: ?*const AtomicBool) !void {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
    }

    fn snapshotAdapter(ptr: *anyopaque, allocator: std.mem.Allocator, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32, exact: bool, cancel: ?*const AtomicBool) anyerror!builder.OwnedSnapshot {
        const self: *SourceHierarchy = @ptrCast(@alignCast(ptr));
        try checkCancel(cancel);
        var snapshot = try builder.OwnedSnapshot.init(allocator, min_cx, min_cz, max_cx, max_cz);
        errdefer snapshot.deinit();
        _ = self.refreshStamp();
        // Reserve in the same sequence as content publication, before any leases
        // or I/O. A later mutation must compare newer than this split snapshot.
        snapshot.source_epoch = self.source_epoch.fetchAdd(1, .acq_rel) + 1;
        for (snapshot.leases, 0..) |*lease, index| {
            try checkCancel(cancel);
            try self.prepareOne(.{
                .cx = @intCast(@as(i64, min_cx) + @as(i64, @intCast(index % snapshot.width))),
                .cz = @intCast(@as(i64, min_cz) + @as(i64, @intCast(index / snapshot.width))),
            }, exact, cancel, lease);
        }
        try checkCancel(cancel);
        return snapshot;
    }

    fn retainPrepared(self: *SourceHierarchy, coord: ChunkCoord, accepted: ?*Entry, out: ?*?builder.Lease) !void {
        if (accepted) |entry| {
            if (out) |lease| lease.* = entry.lease();
            return;
        }
        // A newer live source can legitimately reject the captured summary.
        // Acquire that winner atomically, rather than reporting false absence.
        self.mutex.lock();
        const current = acquireAdapter(self, coord.cx, coord.cz);
        self.mutex.unlock();
        const lease = current orelse return error.SourceUnavailable;
        if (out) |result| result.* = lease else lease.release();
    }

    fn prepareOne(self: *SourceHierarchy, coord: ChunkCoord, exact: bool, cancel: ?*const AtomicBool, out: ?*?builder.Lease) !void {
        const stamp = self.refreshStamp();
        var confirmed_absent = false;
        var known_observation = false;
        self.mutex.lock();
        if (self.records.getPtr(coord)) |record| {
            if (self.usable(record)) {
                self.touch(record);
                if (out) |lease| lease.* = record.entry.?.lease();
                const persistence_entry = if (record.persistence_pending and record.entry.?.summary.origin == .saved) record.entry.? else null;
                if (persistence_entry) |entry| entry.retain();
                self.mutex.unlock();
                if (persistence_entry) |entry| {
                    self.enqueueWrite(entry, null);
                    Entry.release(entry);
                }
                return;
            }
            confirmed_absent = record.absent and record.validated != null and std.meta.eql(record.validated.?, stamp);
            known_observation = record.fingerprint != null;
        }
        // Keep revision authority while a synchronous lookup/capture is outside
        // the lock, including the gap before a background producer calls tryPush.
        const revision = self.reserveRevision();
        const preparing = (self.recordFor(coord, exact) catch |err| {
            self.mutex.unlock();
            return err;
        }) orelse {
            self.mutex.unlock();
            if (out != null or exact) return error.SourceUnavailable;
            return;
        };
        preparing.preparing += 1;
        if (exact) preparing.requested_revision = revision;
        self.prepares_active += 1;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            self.records.getPtr(coord).?.preparing -= 1;
            self.prepares_active -= 1;
            _ = self.makeRoom(0, null);
            self.mutex.unlock();
        }
        if (!confirmed_absent) if (self.generator.load_chunk_summary) |load| {
            if (try load(self.generator.summary_context orelse self.generator.ptr, coord.cx, coord.cz, self.allocator)) |value| {
                var summary = value;
                summary.origin = .saved;
                summary.revision = revision;
                if (summary.chunk_x != coord.cx or summary.chunk_z != coord.cz) {
                    summary.deinit();
                    return error.InvalidSourceCoordinates;
                }
                try checkCancelOwned(&summary, cancel);
                summary.validate() catch |err| {
                    summary.deinit();
                    return err;
                };
                if (!std.meta.eql(stamp, self.refreshStamp())) {
                    summary.deinit();
                    return error.SourceChanged;
                }
                const accepted = try self.publish(summary, stamp, .revalidate, cancel);
                defer if (accepted) |entry| Entry.release(entry);
                try self.retainPrepared(coord, accepted, out);
                if (accepted) |entry| {
                    self.enqueueWrite(entry, stamp);
                }
                return;
            }
        };
        try checkCancel(cancel);
        if (!std.meta.eql(stamp, self.refreshStamp())) return error.SourceChanged;
        // Only a confirmed absent block source permits generated observations.
        self.mutex.lock();
        if (!std.meta.eql(stamp, self.stampLocked())) {
            self.mutex.unlock();
            return error.SourceChanged;
        }
        if (self.records.getPtr(coord)) |record| {
            if (record.entry) |entry| {
                if (entry.summary.origin == .live and self.usable(record)) {
                    if (out) |lease| lease.* = entry.lease();
                    self.mutex.unlock();
                    return;
                }
                if (entry.summary.origin == .generated) {
                    record.validated = stamp;
                    record.absent = true;
                    self.touch(record);
                    if (out) |lease| lease.* = entry.lease();
                    self.mutex.unlock();
                    return;
                }
                if (record.revision > revision) {
                    self.mutex.unlock();
                    return self.retainPrepared(coord, null, out);
                }
                record.entry = null;
                Entry.release(entry);
                self.changed(coord);
            }
            // Confirmed block absence supersedes saved-sidecar provenance even
            // if its payload was already evicted. Retain hashes for no-op reloads.
            record.history_floor = @max(record.history_floor, @max(record.revision, record.latest_committed_revision));
            if (record.origin != .generated) {
                record.origin = .generated;
                record.revision = 0;
            }
            record.latest_committed_revision = 0;
            record.committed_fingerprint = null;
        }
        self.mutex.unlock();
        // A negative block-source stamp is not a negative sidecar lookup once a
        // known observation's payload has been evicted from memory.
        if (!confirmed_absent or known_observation) if (try self.readGenerated(coord, stamp)) |value| {
            var summary = value;
            summary.revision = revision;
            const accepted = try self.publish(summary, stamp, .observation, cancel);
            defer if (accepted) |entry| Entry.release(entry);
            try self.retainPrepared(coord, accepted, out);
            return;
        };
        self.mutex.lock();
        if (!std.meta.eql(stamp, self.stampLocked())) {
            self.mutex.unlock();
            return error.SourceChanged;
        }
        if (self.records.getPtr(coord)) |record| if (self.usable(record)) {
            if (out) |lease| lease.* = record.entry.?.lease();
            self.mutex.unlock();
            return;
        };
        if (self.recordFor(coord, false) catch null) |record| {
            record.validated = stamp;
            record.absent = true;
        }
        if (exact) for (&self.works) |*work| {
            if (work.busy and work.revision < revision and std.meta.eql(work.coord, coord)) work.cancel.store(true, .release);
        };
        self.mutex.unlock();
        if (self.generator.generate_chunk_summary == null) return;
        if (exact) {
            try self.generate(coord, revision, stamp, cancel, null, out);
        } else {
            self.enqueueGeneration(coord, revision, stamp);
            if (out) |lease| {
                self.mutex.lock();
                lease.* = acquireAdapter(self, coord.cx, coord.cz);
                self.mutex.unlock();
            }
        }
    }

    fn checkCancelOwned(summary: *ChunkSummary, cancel: ?*const AtomicBool) !void {
        checkCancel(cancel) catch |err| {
            summary.deinit();
            return err;
        };
    }

    fn generate(self: *SourceHierarchy, coord: ChunkCoord, revision: u64, stamp: Stamp, cancel: ?*const AtomicBool, work: ?*Work, out: ?*?builder.Lease) !void {
        try checkCancel(cancel);
        if (!std.meta.eql(stamp, self.refreshStamp())) return error.SourceChanged;
        const callback = self.generator.generate_chunk_summary orelse return;
        var summary = try callback(self.generator.summary_context orelse self.generator.ptr, coord.cx, coord.cz, self.allocator, cancel);
        if (summary.chunk_x != coord.cx or summary.chunk_z != coord.cz) {
            summary.deinit();
            return error.InvalidSourceCoordinates;
        }
        try checkCancelOwned(&summary, cancel);
        summary.validate() catch |err| {
            summary.deinit();
            return err;
        };
        if (!std.meta.eql(stamp, self.refreshStamp())) {
            summary.deinit();
            return error.SourceChanged;
        }
        summary.origin = .generated;
        summary.revision = revision;
        const accepted = try self.publish(summary, stamp, .observation, cancel);
        defer if (accepted) |entry| Entry.release(entry);
        try self.retainPrepared(coord, accepted, out);
        if (accepted) |entry| {
            if (work != null) {
                try checkCancel(cancel);
                _ = self.persist(entry, stamp, cancel);
            } else self.enqueueWrite(entry, stamp);
        }
    }

    fn freeWork(self: *SourceHierarchy) ?*Work {
        var busy: usize = 0;
        for (&self.works) |*work| if (work.busy) {
            busy += 1;
        };
        if (busy >= @min(max_background_jobs, self.cache_budget_bytes / 4 / scratch_reservation_bytes)) return null;
        for (&self.works) |*work| if (!work.busy) return work;
        return null;
    }

    fn enqueueGeneration(self: *SourceHierarchy, coord: ChunkCoord, revision: u64, stamp: Stamp) void {
        self.mutex.lock();
        if (!std.meta.eql(stamp, self.stampLocked())) {
            self.mutex.unlock();
            return;
        }
        if (self.records.getPtr(coord)) |record| {
            if (self.usable(record) or record.requested_revision > revision) {
                self.mutex.unlock();
                return;
            }
        }
        for (&self.works) |*work| {
            if (work.busy and work.entry == null and std.meta.eql(work.coord, coord)) {
                self.mutex.unlock();
                return;
            }
        }
        const work = self.freeWork() orelse {
            self.mutex.unlock();
            return;
        };
        if (!self.makeRoom(scratch_reservation_bytes, coord)) {
            self.mutex.unlock();
            return;
        }
        work.* = .{ .owner = self, .busy = true, .coord = coord, .revision = revision, .stamp = stamp };
        self.mutex.unlock();
        self.pushWork(work);
    }

    fn enqueueWrite(self: *SourceHierarchy, entry: *Entry, expected: ?Stamp) void {
        const coord: ChunkCoord = .{ .cx = entry.summary.chunk_x, .cz = entry.summary.chunk_z };
        self.mutex.lock();
        if (self.save_dir == null) {
            self.mutex.unlock();
            return;
        }
        if (entry.summary.origin == .saved) {
            const record = self.records.getPtr(coord) orelse {
                self.mutex.unlock();
                return;
            };
            if (record.entry != entry or record.entry.?.summary.origin != .saved) {
                self.mutex.unlock();
                return;
            }
            record.persistence_pending = true;
        }
        const stamp = expected orelse blk: {
            const record = self.records.getPtr(coord) orelse {
                self.mutex.unlock();
                return;
            };
            if (record.entry != entry or !self.usable(record)) {
                self.mutex.unlock();
                return;
            }
            break :blk record.validated orelse self.stampLocked();
        };
        if (!std.meta.eql(stamp, self.stampLocked())) {
            self.mutex.unlock();
            return;
        }
        for (&self.works) |*pending| {
            if (pending.busy and pending.entry == entry and !pending.cancel.load(.acquire)) {
                self.mutex.unlock();
                return;
            }
        }
        const work = self.freeWork() orelse {
            self.mutex.unlock();
            return;
        };
        if (!self.makeRoom(scratch_reservation_bytes, coord)) {
            self.mutex.unlock();
            return;
        }
        entry.retain();
        work.* = .{
            .owner = self,
            .busy = true,
            .entry = entry,
            .coord = coord,
            .revision = entry.summary.revision,
            .stamp = stamp,
            .persistence_required = entry.summary.origin == .saved,
        };
        self.mutex.unlock();
        self.pushWork(work);
    }

    fn pushWork(self: *SourceHierarchy, work: *Work) void {
        // Queue rejection does not consume a generic context. Queue cleanup may
        // take mutex, so this call must be outside every hierarchy critical section.
        const accepted = self.queue.tryPush(.{
            .type = .generic,
            .service_lane = 4,
            .priority = std.math.maxInt(i32),
            .data = .{ .generic = .{ .context = work, .process_fn = Work.process, .cleanup_fn = Work.cleanup } },
        }) catch false;
        if (!accepted) Work.cleanup(work);
    }

    fn identity(self: *SourceHierarchy) store.Identity {
        return .{ .seed = self.generator.seed, .generator_hash = self.generator.identity_hash, .generator_version = self.generator.version };
    }

    fn readGenerated(self: *SourceHierarchy, coord: ChunkCoord, stamp: Stamp) !?ChunkSummary {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.mutex.lock();
        const valid = std.meta.eql(stamp, self.stampLocked());
        self.mutex.unlock();
        if (!valid) return error.SourceChanged;
        const root = self.save_dir orelse return null;
        var summary = (store.read(self.allocator, root, self.identity(), coord.cx, coord.cz) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        }) orelse return null;
        if (summary.origin != .generated) {
            summary.deinit();
            return null;
        }
        return summary;
    }

    const PersistResult = enum { written, retry_saved, pending };

    fn persist(self: *SourceHierarchy, entry: *Entry, stamp: Stamp, cancel: ?*const AtomicBool) PersistResult {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        return self.persistLocked(entry, stamp, cancel);
    }

    fn persistLocked(self: *SourceHierarchy, entry: *Entry, stamp: Stamp, cancel: ?*const AtomicBool) PersistResult {
        const saved = entry.summary.origin == .saved;
        // Without a configured directory, persistence is deliberately disabled;
        // do not pin metadata for an obligation that cannot be scheduled.
        const persistence_enabled = self.save_dir != null;
        if (!persistence_enabled) return .written;
        if (saved and persistence_enabled) {
            self.mutex.lock();
            if (self.records.getPtr(.{ .cx = entry.summary.chunk_x, .cz = entry.summary.chunk_z })) |record| {
                if (record.entry == entry and record.entry.?.summary.origin == .saved) record.persistence_pending = true;
            }
            self.mutex.unlock();
        }
        checkCancel(cancel) catch return if (saved) .pending else .written;
        // A saved-source change can precede its commit callback while that writer
        // waits for io_mutex. Do not rely on the last prepare's sampled epoch.
        const refreshed = self.refreshStamp();
        if (!std.meta.eql(stamp, refreshed)) {
            // A saved entry can be repaired by re-reading its authoritative block
            // payload. Generated observations intentionally retain the existing
            // stale-write rejection: they do not establish block authority.
            return if (saved and stamp.persistence == refreshed.persistence) .retry_saved else if (saved) .pending else .written;
        }
        self.mutex.lock();
        const coord: ChunkCoord = .{ .cx = entry.summary.chunk_x, .cz = entry.summary.chunk_z };
        const record = self.records.getPtr(coord);
        const valid = std.meta.eql(stamp, self.stampLocked()) and
            (record == null or record.?.entry == null or record.?.entry == entry);
        const confirmed_absent = record != null and record.?.absent and
            record.?.validated != null and std.meta.eql(record.?.validated.?, self.stampLocked());
        self.mutex.unlock();
        if (!valid) return if (saved) .pending else .written;
        const root = self.save_dir orelse return .written;
        if (entry.summary.origin == .generated and confirmed_absent) {
            store.writeAfterConfirmedAbsence(self.allocator, root, self.identity(), &entry.summary) catch return .written;
        } else {
            store.write(self.allocator, root, self.identity(), &entry.summary) catch return if (saved) .pending else .written;
        }
        if (saved) {
            self.mutex.lock();
            if (self.records.getPtr(coord)) |current| {
                if (current.entry == entry and current.entry.?.summary.origin == .saved) current.persistence_pending = false;
            }
            self.mutex.unlock();
        }
        return .written;
    }

    /// Called after a worker releases its reusable slot. A refreshed exact read
    /// either writes current block authority or retains the bounded record-local
    /// obligation for a future prepare; it cannot revive the stale queue entry.
    fn repairSavedPersistence(self: *SourceHierarchy, coord: ChunkCoord) void {
        self.prepareOne(coord, true, null, null) catch {};
    }
};

const TestSource = struct {
    loads: usize = 0,
    generations: usize = 0,
    saved_epoch: u64 = 0,
    saved: bool = false,
    fail_load: bool = false,
    publish_live_during_generation: ?*SourceHierarchy = null,
    hierarchy: ?*SourceHierarchy = null,
    on_load: ?*const fn (*TestSource, i32, i32) anyerror!void = null,

    fn generator(self: *TestSource) LODGenerator {
        return .{
            .ptr = self,
            .generate_heightmap_only = heightmap,
            .maybe_recenter_cache = recenter,
            .seed = 42,
            .identity_hash = 123,
            .version = 7,
            .summary_context = self,
            .load_chunk_summary = load,
            .generate_chunk_summary = generate,
            .saved_source_epoch = savedEpoch,
        };
    }

    fn heightmap(_: *anyopaque, _: *@import("lod_chunk.zig").LODSimplifiedData, _: i32, _: i32, _: @import("lod_types.zig").LODLevel, _: ?*const AtomicBool) void {}
    fn recenter(_: *anyopaque, _: i32, _: i32) bool {
        return false;
    }

    fn savedEpoch(ptr: *anyopaque) u64 {
        const self: *TestSource = @ptrCast(@alignCast(ptr));
        return self.saved_epoch;
    }

    fn load(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator) !?ChunkSummary {
        const self: *TestSource = @ptrCast(@alignCast(ptr));
        self.loads += 1;
        if (self.on_load) |hook| try hook(self, cx, cz);
        if (self.fail_load) return error.BrokenSavedSource;
        if (!self.saved) return null;
        return try summary(allocator, cx, cz, .saved, 0, .water);
    }

    fn generate(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator, cancel: ?*const AtomicBool) !ChunkSummary {
        const self: *TestSource = @ptrCast(@alignCast(ptr));
        try SourceHierarchy.checkCancel(cancel);
        self.generations += 1;
        if (self.publish_live_during_generation) |hierarchy| {
            self.publish_live_during_generation = null;
            hierarchy.submit(try summary(allocator, cx, cz, .live, hierarchy.reserveRevision(), .water));
        }
        return summary(allocator, cx, cz, .generated, 0, .stone);
    }

    fn summary(allocator: std.mem.Allocator, cx: i32, cz: i32, origin: scene.Origin, revision: u64, block: world_core.BlockType) !ChunkSummary {
        var chunk = world_core.Chunk.init(cx, cz);
        chunk.setBlock(0, 0, 0, block);
        var result = try ChunkSummary.capture(allocator, &chunk);
        result.origin = origin;
        result.revision = revision;
        return result;
    }

    fn acquire(hierarchy: *SourceHierarchy, cx: i32, cz: i32) ?builder.Lease {
        const provider = hierarchy.provider();
        provider.lock_fn(provider.ptr);
        defer provider.unlock_fn(provider.ptr);
        return provider.acquire_fn(provider.ptr, cx, cz);
    }

    fn prepare(hierarchy: *SourceHierarchy, min: i32, max: i32, exact: bool) !void {
        const provider = hierarchy.provider();
        try provider.prepare_fn(provider.ptr, min, 0, max, 0, exact, null);
    }

    fn runQueued(queue: *JobQueue) void {
        while (queue.tryPop()) |job| job.data.generic.process_fn(job.data.generic.context);
    }
};

test "SourceHierarchy residency eviction preserves content epochs and compact reload authority" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var generator = source.generator();
    generator.load_chunk_summary = null;
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, generator, &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    hierarchy.submit(try TestSource.summary(a, 0, 0, .generated, hierarchy.reserveRevision(), .stone));
    var changes: std.ArrayListUnmanaged(ChunkCoord) = .empty;
    defer changes.deinit(a);
    _ = try hierarchy.drainChanges(&changes, 1024);
    changes.clearRetainingCapacity();
    const epoch = hierarchy.epoch();
    const bytes = hierarchy.memoryBytes();
    hierarchy.mutex.lock();
    const evicted = hierarchy.evictOne(null);
    hierarchy.mutex.unlock();
    try std.testing.expect(evicted);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.countKnown());
    try std.testing.expect(hierarchy.memoryBytes() < bytes);
    try std.testing.expect(hierarchy.records.get(.{ .cx = 0, .cz = 0 }).?.fingerprint != null);
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    try std.testing.expect(!try hierarchy.drainChanges(&changes, 1024));
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
    hierarchy.submit(try TestSource.summary(a, 0, 0, .generated, hierarchy.reserveRevision(), .stone));
    try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnown());
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    var relit = try TestSource.summary(a, 0, 0, .generated, hierarchy.reserveRevision(), .stone);
    relit.runs[0].light_top = world_core.PackedLight.init(2, 9);
    hierarchy.submit(relit);
    try std.testing.expectEqual(epoch + 1, hierarchy.epoch());
}

test "SourceHierarchy owned snapshot retains 300 prepared sources through eviction and uses capture start epoch" {
    const a = std.testing.allocator;
    const Hooks = struct {
        fn evictPrevious(source: *TestSource, _: i32, _: i32) !void {
            const hierarchy = source.hierarchy.?;
            hierarchy.mutex.lock();
            while (hierarchy.evictOne(null)) {}
            hierarchy.mutex.unlock();
            if (source.loads == 2) hierarchy.submit(try TestSource.summary(std.testing.allocator, 0, 0, .live, hierarchy.reserveRevision(), .grass));
        }
    };
    var source: TestSource = .{ .saved = true, .on_load = Hooks.evictPrevious };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    source.hierarchy = hierarchy;
    const provider = hierarchy.provider();
    const start = hierarchy.epoch();
    const entry_bytes = @sizeOf(SourceHierarchy.Entry) + @sizeOf(scene.Run);
    {
        var snapshot = try provider.snapshot_fn.?(provider.ptr, a, 0, 0, 19, 14, false, null);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(usize, 300), source.loads);
        try std.testing.expectEqual(@as(usize, 300), snapshot.leases.len);
        try std.testing.expectEqual(start + 1, snapshot.source_epoch);
        try std.testing.expect(snapshot.source_epoch < hierarchy.epoch());
        for (snapshot.leases, 0..) |maybe, index| {
            const lease = maybe orelse return error.MissingPreparedSource;
            try std.testing.expectEqual(@as(i32, @intCast(index % 20)), lease.summary.chunk_x);
            try std.testing.expectEqual(@as(i32, @intCast(index / 20)), lease.summary.chunk_z);
            try std.testing.expectEqual(world_core.BlockType.water, lease.summary.runs[0].block);
        }
        try std.testing.expectEqual(@as(usize, 2), hierarchy.countKnown());
        const current = TestSource.acquire(hierarchy, 0, 0).?;
        defer current.release();
        try std.testing.expectEqual(world_core.BlockType.grass, current.summary.runs[0].block);
        const epoch = hierarchy.epoch();
        hierarchy.cache_budget_bytes = 0;
        hierarchy.mutex.lock();
        _ = hierarchy.makeRoom(0, null);
        hierarchy.mutex.unlock();
        try std.testing.expectEqual(epoch, hierarchy.epoch());
        try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnown());
        try std.testing.expectEqual(301 * entry_bytes, hierarchy.accounting.bytes.load(.acquire));
    }
    try std.testing.expectEqual(entry_bytes, hierarchy.accounting.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), hierarchy.prepares_active);
}

test "SourceHierarchy snapshot errors release partial leases and distinguish unavailable captures from absence" {
    const a = std.testing.allocator;
    const Hooks = struct {
        fn failThird(source: *TestSource, _: i32, _: i32) !void {
            if (source.loads == 3) return error.BrokenSavedSource;
        }
        fn failEntryAllocation(source: *TestSource, _: i32, _: i32) !void {
            const failing: *std.testing.FailingAllocator = @ptrCast(@alignCast(source.hierarchy.?.allocator.ptr));
            // capture allocates the runs; publication then allocates the Entry.
            failing.fail_index = failing.alloc_index + 1;
        }
    };
    var source: TestSource = .{ .saved = true, .on_load = Hooks.failThird };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    const provider = hierarchy.provider();
    var failing_array = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, provider.snapshot_fn.?(provider.ptr, failing_array.allocator(), 0, 0, 3, 0, true, null));
    try std.testing.expectError(error.SnapshotTooLarge, provider.snapshot_fn.?(provider.ptr, a, 0, 0, @intCast(builder.max_snapshot_chunks), 0, true, null));
    try std.testing.expectEqual(@as(usize, 0), source.loads);
    try std.testing.expectError(error.BrokenSavedSource, provider.snapshot_fn.?(provider.ptr, a, 0, 0, 3, 0, true, null));
    var it = hierarchy.records.valueIterator();
    while (it.next()) |record| {
        try std.testing.expectEqual(@as(usize, 0), record.preparing);
        if (record.entry) |entry| try std.testing.expectEqual(@as(usize, 1), entry.refs.load(.acquire));
    }
    source.on_load = null;
    hierarchy.cache_budget_bytes = 0;
    try std.testing.expectError(error.SourceUnavailable, provider.snapshot_fn.?(provider.ptr, a, 20, 0, 20, 0, true, null));
    try std.testing.expectEqual(@as(usize, 4), source.loads);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.accounting.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), hierarchy.prepares_active);

    var failing_entry = std.testing.FailingAllocator.init(a, .{});
    var entry_source: TestSource = .{ .saved = true, .on_load = Hooks.failEntryAllocation };
    const other = try SourceHierarchy.init(failing_entry.allocator(), entry_source.generator(), &queue, 64 * 1024 * 1024);
    defer other.deinit();
    entry_source.hierarchy = other;
    const entry_provider = other.provider();
    try std.testing.expectError(error.OutOfMemory, entry_provider.snapshot_fn.?(entry_provider.ptr, a, 0, 0, 0, 0, true, null));
    try std.testing.expectEqual(@as(usize, 1), entry_source.loads);
    try std.testing.expectEqual(@as(usize, 0), other.accounting.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), other.prepares_active);
}

test "SourceHierarchy background scratch uses at most a quarter budget without dropping live sources" {
    const a = std.testing.allocator;
    for ([_]usize{ 8, 16, 64, 512 }) |megabytes| {
        var source: TestSource = .{};
        var queue = JobQueue.init(a);
        defer queue.deinit();
        const budget = megabytes * 1024 * 1024;
        const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, budget);
        defer hierarchy.deinit();
        defer queue.stop();
        hierarchy.submit(try TestSource.summary(a, -1, 0, .live, hierarchy.reserveRevision(), .grass));
        try TestSource.prepare(hierarchy, 0, 63, false);
        const expected: usize = @min(SourceHierarchy.max_background_jobs, budget / 4 / SourceHierarchy.scratch_reservation_bytes);
        try std.testing.expectEqual(expected, queue.count());
        try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnown());
        try std.testing.expect(hierarchy.memoryBytes() <= budget);
        const before_stop = hierarchy.memoryBytes();
        queue.stop();
        try std.testing.expectEqual(before_stop - expected * SourceHierarchy.scratch_reservation_bytes, hierarchy.memoryBytes());
        const live = TestSource.acquire(hierarchy, -1, 0).?;
        defer live.release();
        try std.testing.expectEqual(scene.Origin.live, live.summary.origin);
    }
}

test "SourceHierarchy snapshot order preserves newer live lighting despite later callback arrival" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try hierarchy.setPersistence(root);
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    chunk.setLight(0, 1, 0, world_core.PackedLight.init(15, 0));
    const saved_revision = hierarchy.reserveRevision();
    var old_save = try ChunkSummary.capture(a, &chunk);
    var old_owned = true;
    defer if (old_owned) old_save.deinit();
    old_save.revision = saved_revision;
    hierarchy.submit(try old_save.clone(a));
    const light_b = world_core.PackedLight.initRGB(2, 9, 7, 5);
    chunk.setLight(0, 1, 0, light_b);
    const live_revision = hierarchy.reserveRevision();
    var fresh = try ChunkSummary.capture(a, &chunk);
    fresh.revision = live_revision;
    hierarchy.submit(fresh);
    const live = TestSource.acquire(hierarchy, 0, 0).?;
    defer live.release();
    const epoch = hierarchy.epoch();
    hierarchy.commitSaved(try TestSource.summary(a, 0, 0, .saved, saved_revision - 1, .water));
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    try std.testing.expect((try store.read(a, root, hierarchy.identity(), 0, 0)) == null);
    hierarchy.commitSaved(old_save);
    old_owned = false;
    const committed = TestSource.acquire(hierarchy, 0, 0).?;
    defer committed.release();
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    try std.testing.expectEqual(scene.Origin.saved, committed.summary.origin);
    try std.testing.expectEqual(live_revision, committed.summary.revision);
    try std.testing.expectEqualDeep(light_b, committed.summary.runs[0].light_top);
    try std.testing.expectEqual(scene.Origin.live, live.summary.origin);
    var persisted = (try store.read(a, root, hierarchy.identity(), 0, 0)).?;
    defer persisted.deinit();
    try std.testing.expectEqualDeep(light_b, persisted.runs[0].light_top);
}

test "SourceHierarchy consumes submissions preserves live authority and avoids data-equal epoch churn" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();

    const first_revision = hierarchy.reserveRevision();
    hierarchy.submit(try TestSource.summary(a, -1, 0, .live, first_revision, .stone));
    const first = TestSource.acquire(hierarchy, -1, 0).?;
    defer first.release();
    const epoch = hierarchy.epoch();
    const newer = hierarchy.reserveRevision();
    hierarchy.submit(try TestSource.summary(a, -1, 0, .live, newer, .stone));
    hierarchy.submit(try TestSource.summary(a, -1, 0, .live, first_revision, .water));
    hierarchy.submit(try TestSource.summary(a, -1, 0, .saved, hierarchy.reserveRevision(), .water));
    hierarchy.submit(try TestSource.summary(a, -1, 0, .generated, hierarchy.reserveRevision(), .water));
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnownInBounds(-1, 0, -1, 0));

    var lit = try TestSource.summary(a, -1, 0, .live, hierarchy.reserveRevision(), .stone);
    lit.runs[0].light_top = world_core.PackedLight.init(3, 7);
    hierarchy.submit(lit);
    const lit_epoch = hierarchy.epoch();
    try std.testing.expectEqual(epoch + 1, lit_epoch);
    hierarchy.commitSaved(try TestSource.summary(a, -1, 0, .saved, first_revision, .stone));
    try std.testing.expectEqual(lit_epoch, hierarchy.epoch());
    const saved = TestSource.acquire(hierarchy, -1, 0).?;
    defer saved.release();
    try std.testing.expectEqual(scene.Origin.saved, saved.summary.origin);
    try std.testing.expectEqualDeep(world_core.PackedLight.init(3, 7), saved.summary.runs[0].light_top);
    try std.testing.expectEqual(scene.Origin.live, first.summary.origin);
    try std.testing.expect(!std.meta.eql(first.summary.runs[0].light_top, saved.summary.runs[0].light_top));
}

test "SourceHierarchy eviction retains leased bytes and leases can outlive the service" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var generator = source.generator();
    generator.load_chunk_summary = null;
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, generator, &queue, 1024 * 1024);
    var alive = true;
    defer if (alive) hierarchy.deinit();
    hierarchy.submit(try TestSource.summary(a, 0, 0, .generated, hierarchy.reserveRevision(), .stone));
    const old = TestSource.acquire(hierarchy, 0, 0).?;
    var old_owned = true;
    defer if (old_owned) old.release();
    hierarchy.cache_budget_bytes = 0;
    hierarchy.submit(try TestSource.summary(a, 1, 0, .live, hierarchy.reserveRevision(), .water));
    try std.testing.expect(TestSource.acquire(hierarchy, 0, 0) == null);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnown());
    try std.testing.expectEqual(world_core.BlockType.stone, old.summary.runs[0].block);
    const bytes_with_old = hierarchy.memoryBytes();
    const extra = TestSource.acquire(hierarchy, 1, 0).?;
    defer extra.release();
    try std.testing.expectEqual(bytes_with_old, hierarchy.memoryBytes());
    try std.testing.expect(hierarchy.accounting.bytes.load(.acquire) >= 2 * @sizeOf(SourceHierarchy.Entry));
    const old_bytes = @sizeOf(SourceHierarchy.Entry) + old.summary.runs.len * @sizeOf(scene.Run);
    old.release();
    old_owned = false;
    try std.testing.expectEqual(bytes_with_old - old_bytes, hierarchy.memoryBytes());
    queue.stop();
    hierarchy.deinit();
    alive = false;
    try std.testing.expectEqual(world_core.BlockType.water, extra.summary.runs[0].block);
}

test "SourceHierarchy bounds queued and active refinements and releases shutdown reservations" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 512 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();

    queue.setPaused(true);
    try TestSource.prepare(hierarchy, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    for (&hierarchy.works) |*work| try std.testing.expect(!work.busy);
    queue.setPaused(false);
    try TestSource.prepare(hierarchy, 0, 63, false);
    try std.testing.expectEqual(@as(usize, SourceHierarchy.max_background_jobs), queue.count());
    try std.testing.expectEqual(@as(usize, 64), source.loads);
    try TestSource.prepare(hierarchy, 0, 63, false);
    try std.testing.expectEqual(@as(usize, 64), source.loads);
    try std.testing.expectEqual(@as(usize, 0), source.generations);
    const before = hierarchy.memoryBytes();
    var active = queue.tryPop().?;
    try std.testing.expectEqual(@as(u3, 4), active.service_lane);
    try std.testing.expectEqual(before, hierarchy.memoryBytes());
    try TestSource.prepare(hierarchy, 64, 64, false);
    try std.testing.expectEqual(@as(usize, 31), queue.count());
    const before_stop = hierarchy.memoryBytes();
    queue.stop();
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(before_stop - 31 * SourceHierarchy.scratch_reservation_bytes, hierarchy.memoryBytes());
    active.cleanup();
    for (&hierarchy.works) |*work| try std.testing.expect(!work.busy);
    try std.testing.expectEqual(before_stop - 32 * SourceHierarchy.scratch_reservation_bytes, hierarchy.memoryBytes());
    try std.testing.expectEqual(@as(usize, 0), hierarchy.accounting.bytes.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), hierarchy.accounting.refs.load(.acquire));
}

test "SourceHierarchy strict saved failure never generates and saved epochs invalidate absence" {
    const a = std.testing.allocator;
    var source: TestSource = .{ .fail_load = true };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try std.testing.expectError(error.BrokenSavedSource, TestSource.prepare(hierarchy, 0, 0, true));
    try std.testing.expectEqual(@as(usize, 0), source.generations);
    source.fail_load = false;
    try TestSource.prepare(hierarchy, 0, 0, false);
    source.saved_epoch += 1;
    source.fail_load = true;
    try std.testing.expectError(error.BrokenSavedSource, TestSource.prepare(hierarchy, 0, 0, true));
    TestSource.runQueued(&queue);
    try std.testing.expectEqual(@as(usize, 0), source.generations);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.countKnown());
    source.fail_load = false;
    source.saved = true;
    try TestSource.prepare(hierarchy, 0, 0, true);
    const saved = TestSource.acquire(hierarchy, 0, 0).?;
    defer saved.release();
    try std.testing.expectEqual(scene.Origin.saved, saved.summary.origin);
    try std.testing.expectEqual(world_core.BlockType.water, saved.summary.runs[0].block);
    try std.testing.expectEqual(@as(usize, 0), source.generations);
}

test "SourceHierarchy exact preparation supersedes queued generation without waiting" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try TestSource.prepare(hierarchy, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try TestSource.prepare(hierarchy, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 1), source.generations);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.countKnown());
    const epoch = hierarchy.epoch();
    TestSource.runQueued(&queue);
    try std.testing.expectEqual(@as(usize, 1), source.generations);
    try std.testing.expectEqual(epoch, hierarchy.epoch());
    const provider = hierarchy.provider();
    const cancel = AtomicBool.init(true);
    try std.testing.expectError(error.Cancelled, provider.prepare_fn(provider.ptr, 1, 0, 1, 0, true, &cancel));
    try std.testing.expectEqual(@as(usize, 1), source.generations);
    source.publish_live_during_generation = hierarchy;
    try TestSource.prepare(hierarchy, 1, 1, true);
    const live = TestSource.acquire(hierarchy, 1, 0).?;
    defer live.release();
    try std.testing.expectEqual(scene.Origin.live, live.summary.origin);
    try std.testing.expectEqual(world_core.BlockType.water, live.summary.runs[0].block);
}

test "SourceHierarchy persistence reads generated observations ignores orphan saved caches and repairs saved records" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try TestSource.prepare(hierarchy, 0, 0, false);
    const owned_root = try a.dupe(u8, root);
    defer a.free(owned_root);
    try hierarchy.setPersistence(owned_root);
    @memset(owned_root, 'x');
    var generated = try TestSource.summary(a, 0, 0, .generated, 9999, .grass);
    defer generated.deinit();
    try store.write(a, root, hierarchy.identity(), &generated);
    try TestSource.prepare(hierarchy, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 2), source.loads);
    try std.testing.expectEqual(@as(usize, 0), source.generations);
    const cached = TestSource.acquire(hierarchy, 0, 0).?;
    defer cached.release();
    try std.testing.expectEqual(world_core.BlockType.grass, cached.summary.runs[0].block);
    try std.testing.expect(cached.summary.revision < generated.revision);

    var orphan = try TestSource.summary(a, 1, 0, .saved, 0, .water);
    defer orphan.deinit();
    try store.write(a, root, hierarchy.identity(), &orphan);
    try TestSource.prepare(hierarchy, 1, 1, true);
    const absent = TestSource.acquire(hierarchy, 1, 0).?;
    defer absent.release();
    try std.testing.expectEqual(scene.Origin.generated, absent.summary.origin);
    try std.testing.expectEqual(world_core.BlockType.stone, absent.summary.runs[0].block);
    TestSource.runQueued(&queue);
    var orphan_repaired = (try store.read(a, root, hierarchy.identity(), 1, 0)).?;
    defer orphan_repaired.deinit();
    try std.testing.expectEqual(scene.Origin.generated, orphan_repaired.origin);
    try std.testing.expectEqual(world_core.BlockType.stone, orphan_repaired.runs[0].block);
    const before_reload = hierarchy.epoch();
    hierarchy.mutex.lock();
    const evicted_observation = hierarchy.evictOne(.{ .cx = 0, .cz = 0 });
    hierarchy.mutex.unlock();
    try std.testing.expect(evicted_observation);
    try std.testing.expect(hierarchy.records.get(.{ .cx = 1, .cz = 0 }).?.entry == null);
    try TestSource.prepare(hierarchy, 1, 1, false);
    try std.testing.expectEqual(before_reload, hierarchy.epoch());
    try std.testing.expectEqual(@as(usize, 1), source.generations);
    try std.testing.expectEqual(@as(usize, 0), queue.count());

    try TestSource.prepare(hierarchy, 4, 4, true);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    hierarchy.cache_budget_bytes = 0;
    hierarchy.submit(try TestSource.summary(a, 5, 0, .live, hierarchy.reserveRevision(), .grass));
    try std.testing.expect(TestSource.acquire(hierarchy, 4, 0) == null);
    TestSource.runQueued(&queue);
    hierarchy.cache_budget_bytes = 64 * 1024 * 1024;
    var written_after_eviction = (try store.read(a, root, hierarchy.identity(), 4, 0)).?;
    defer written_after_eviction.deinit();
    try std.testing.expectEqual(scene.Origin.generated, written_after_eviction.origin);

    const corrupt_dir = try dir.makeOpenPath("summaries/v1/r.0.0", .{});
    defer corrupt_dir.close();
    {
        const corrupt = try corrupt_dir.createFile("c.6.0.zsum", .{});
        defer corrupt.close();
        try corrupt.writeAll("invalid summary");
    }
    try TestSource.prepare(hierarchy, 6, 6, false);
    TestSource.runQueued(&queue);
    var generated_repaired = (try store.read(a, root, hierarchy.identity(), 6, 0)).?;
    defer generated_repaired.deinit();
    try std.testing.expectEqual(scene.Origin.generated, generated_repaired.origin);
    try std.testing.expectEqual(world_core.BlockType.stone, generated_repaired.runs[0].block);
    hierarchy.cache_budget_bytes = 0;
    hierarchy.submit(try TestSource.summary(a, 7, 0, .live, hierarchy.reserveRevision(), .grass));
    try std.testing.expect(TestSource.acquire(hierarchy, 6, 0) == null);
    hierarchy.cache_budget_bytes = 64 * 1024 * 1024;
    try TestSource.prepare(hierarchy, 6, 6, true);
    try std.testing.expectEqual(@as(usize, 3), source.generations);
    try std.testing.expectEqual(@as(usize, 0), queue.count());

    source.saved = true;
    source.saved_epoch += 1;
    {
        const corrupt = try corrupt_dir.createFile("c.2.0.zsum", .{});
        defer corrupt.close();
        try corrupt.writeAll("invalid summary");
    }
    try TestSource.prepare(hierarchy, 2, 2, true);
    TestSource.runQueued(&queue);
    var repaired = (try store.read(a, root, hierarchy.identity(), 2, 0)).?;
    defer repaired.deinit();
    try std.testing.expectEqual(scene.Origin.saved, repaired.origin);
    try std.testing.expectEqual(world_core.BlockType.water, repaired.runs[0].block);
    try std.testing.expectEqual(@as(usize, 3), source.generations);

    const revision = hierarchy.reserveRevision();
    hierarchy.submit(try TestSource.summary(a, 3, 0, .live, revision, .grass));
    try std.testing.expect((try store.read(a, root, hierarchy.identity(), 3, 0)) == null);
    hierarchy.commitSaved(try TestSource.summary(a, 3, 0, .saved, revision, .grass));
    var committed = (try store.read(a, root, hierarchy.identity(), 3, 0)).?;
    defer committed.deinit();
    try std.testing.expectEqual(world_core.BlockType.grass, committed.runs[0].block);
}

test "SourceHierarchy retries saved sidecar repair after an unrelated save epoch change" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{ .saved = true };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 16 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try hierarchy.setPersistence(root);

    // The first exact read queues a saved sidecar. A different block commit
    // advances the global epoch before its worker gets to persist it.
    try TestSource.prepare(hierarchy, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    source.saved_epoch += 1;
    TestSource.runQueued(&queue);

    var repaired = (try store.read(a, root, hierarchy.identity(), 0, 0)).?;
    defer repaired.deinit();
    try std.testing.expectEqual(scene.Origin.saved, repaired.origin);
    try std.testing.expectEqual(world_core.BlockType.water, repaired.runs[0].block);
    // The stale queued entry was not written: source was read again first.
    try std.testing.expectEqual(@as(usize, 2), source.loads);
    try std.testing.expectEqual(@as(usize, 0), source.generations);
}

test "SourceHierarchy retains a cancelled saved sidecar obligation with one writer" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{ .saved = true };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 16 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try hierarchy.setPersistence(root);

    try TestSource.prepare(hierarchy, 0, 0, true);
    const active = queue.tryPop().?;
    // Model a newer exact observation cancelling the active writer while the
    // only persistence slot is still occupied. The replacement cannot enqueue.
    hierarchy.works[0].cancel.store(true, .release);
    try TestSource.prepare(hierarchy, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    active.data.generic.process_fn(active.data.generic.context);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    TestSource.runQueued(&queue);

    var persisted = (try store.read(a, root, hierarchy.identity(), 0, 0)).?;
    defer persisted.deinit();
    try std.testing.expectEqual(scene.Origin.saved, persisted.origin);
    try std.testing.expect(!hierarchy.records.get(.{ .cx = 0, .cz = 0 }).?.persistence_pending);
}

test "SourceHierarchy preserves a saved sidecar obligation when repair reuses its slot" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    const Hooks = struct {
        fn reuseWriter(source: *TestSource, _: i32, _: i32) !void {
            if (source.loads != 2) return;
            source.on_load = null;
            // The stale repair has released its only writer. Consume it before
            // that repair can admit A's replacement sidecar write.
            try TestSource.prepare(source.hierarchy.?, 1, 1, true);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{ .saved = true };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 16 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    source.hierarchy = hierarchy;
    try hierarchy.setPersistence(root);

    try TestSource.prepare(hierarchy, 0, 0, true);
    source.saved_epoch += 1;
    source.on_load = Hooks.reuseWriter;
    TestSource.runQueued(&queue);

    // B used A's released slot. A remains a valid in-memory strict source, but
    // its sidecar obligation must survive the failed admission without looping.
    try std.testing.expect((try store.read(a, root, hierarchy.identity(), 0, 0)) == null);
    try std.testing.expect(hierarchy.records.get(.{ .cx = 0, .cz = 0 }).?.persistence_pending);
    hierarchy.cache_budget_bytes = 0;
    hierarchy.mutex.lock();
    _ = hierarchy.makeRoom(0, null);
    hierarchy.mutex.unlock();
    try std.testing.expect(hierarchy.records.get(.{ .cx = 0, .cz = 0 }).?.persistence_pending);
    hierarchy.cache_budget_bytes = 16 * 1024 * 1024;
    try TestSource.prepare(hierarchy, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    TestSource.runQueued(&queue);

    var persisted = (try store.read(a, root, hierarchy.identity(), 0, 0)).?;
    defer persisted.deinit();
    try std.testing.expectEqual(scene.Origin.saved, persisted.origin);
    try std.testing.expectEqual(@as(usize, 4), source.loads);
    try std.testing.expect(!hierarchy.records.get(.{ .cx = 0, .cz = 0 }).?.persistence_pending);
}

test "SourceHierarchy sidecar repair rejects stale absence strict source errors and live submissions" {
    const a = std.testing.allocator;
    const fs = @import("fs");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &path_buf);
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    try hierarchy.setPersistence(root);

    for (0..2) |i| {
        const cx: i32 = @intCast(i);
        var orphan = try TestSource.summary(a, cx, 0, .saved, 0, .water);
        defer orphan.deinit();
        try store.write(a, root, hierarchy.identity(), &orphan);
        try TestSource.prepare(hierarchy, cx, cx, true);
        try std.testing.expectEqual(@as(usize, 1), queue.count());
        if (i == 0) {
            // No prepare refreshes the hierarchy between this change and the write.
            source.saved_epoch += 1;
        } else {
            try hierarchy.setPersistence(root);
        }
        TestSource.runQueued(&queue);
        var unchanged = (try store.read(a, root, hierarchy.identity(), cx, 0)).?;
        defer unchanged.deinit();
        try std.testing.expectEqual(scene.Origin.saved, unchanged.origin);
        try std.testing.expectEqual(orphan.fingerprint(), unchanged.fingerprint());
    }
    try std.testing.expectEqual(@as(usize, 2), source.generations);
    {
        const corrupt = try dir.createFile("summaries/v1/r.0.0/c.2.0.zsum", .{});
        defer corrupt.close();
        try corrupt.writeAll("corrupt");
    }
    source.fail_load = true;
    try std.testing.expectError(error.BrokenSavedSource, TestSource.prepare(hierarchy, 2, 2, true));
    TestSource.runQueued(&queue);
    try std.testing.expectEqual(@as(usize, 2), source.generations);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    const corrupt_bytes = try dir.readFileAlloc("summaries/v1/r.0.0/c.2.0.zsum", a, 128);
    defer a.free(corrupt_bytes);
    try std.testing.expectEqualStrings("corrupt", corrupt_bytes);
    hierarchy.submit(try TestSource.summary(a, 3, 0, .live, hierarchy.reserveRevision(), .grass));
    TestSource.runQueued(&queue);
    try std.testing.expect((try store.read(a, root, hierarchy.identity(), 3, 0)) == null);

    source.fail_load = false;
    try TestSource.prepare(hierarchy, 4, 4, true);
    source.saved = true;
    source.saved_epoch += 1;
    hierarchy.commitSaved(try TestSource.summary(a, 4, 0, .saved, hierarchy.reserveRevision(), .water));
    TestSource.runQueued(&queue);
    var committed = (try store.read(a, root, hierarchy.identity(), 4, 0)).?;
    defer committed.deinit();
    try std.testing.expectEqual(scene.Origin.saved, committed.origin);
    try std.testing.expectEqual(world_core.BlockType.water, committed.runs[0].block);
    const lease = TestSource.acquire(hierarchy, 4, 0).?;
    defer lease.release();
    try std.testing.expectEqual(scene.Origin.saved, lease.summary.origin);
}

test "SourceHierarchy change overflow invalidates all and subsequent drains honor limits" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    for (0..SourceHierarchy.max_changes + 2) |i| {
        hierarchy.submit(try TestSource.summary(a, 0, 0, .live, hierarchy.reserveRevision(), if (i % 2 == 0) .stone else .water));
    }
    var changes: std.ArrayListUnmanaged(ChunkCoord) = .empty;
    defer changes.deinit(a);
    try std.testing.expect(try hierarchy.drainChanges(&changes, 0));
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
    hierarchy.submit(try TestSource.summary(a, -1, 0, .live, hierarchy.reserveRevision(), .grass));
    hierarchy.submit(try TestSource.summary(a, -2, 0, .live, hierarchy.reserveRevision(), .grass));
    try std.testing.expect(!try hierarchy.drainChanges(&changes, 1));
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(@as(i32, -1), changes.items[0].cx);
    try std.testing.expect(!try hierarchy.drainChanges(&changes, 1));
    try std.testing.expectEqual(@as(usize, 2), changes.items.len);
    try std.testing.expectEqual(@as(i32, -2), changes.items[1].cx);
}

test "SourceHierarchy consumes allocation failures and optional backends safely remain unknown" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var generator = source.generator();
    generator.load_chunk_summary = null;
    generator.generate_chunk_summary = null;
    generator.saved_source_epoch = null;
    var queue = JobQueue.init(a);
    defer queue.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 2 });
    const hierarchy = try SourceHierarchy.init(failing.allocator(), generator, &queue, 64 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    hierarchy.submit(try TestSource.summary(a, 0, 0, .live, hierarchy.reserveRevision(), .stone));
    try std.testing.expectEqual(@as(usize, 0), hierarchy.countKnown());
    failing.fail_index = std.math.maxInt(usize);
    try TestSource.prepare(hierarchy, -1, 1, true);
    try std.testing.expectEqual(@as(usize, 0), hierarchy.countKnown());
    try std.testing.expectEqual(@as(usize, 0), source.generations);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    hierarchy.cache_budget_bytes = @sizeOf(SourceHierarchy) + @sizeOf(SourceHierarchy.Accounting) + 4096;
    inline for (.{ false, true }) |exact| {
        try TestSource.prepare(hierarchy, -512, 511, exact);
        try std.testing.expect(hierarchy.records.count() < 1024);
        try std.testing.expect(hierarchy.memoryBytes() <= hierarchy.cache_budget_bytes);
    }
}

test "SourceHierarchy snapshot order fences late live captures after metadata eviction and commit OOM" {
    const a = std.testing.allocator;
    var source: TestSource = .{ .saved = true };
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 16 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    const old_order = hierarchy.reserveRevision();
    const commit_order = hierarchy.reserveRevision();
    hierarchy.commitSaved(try TestSource.summary(a, 0, 0, .saved, commit_order, .water));
    const saved = TestSource.acquire(hierarchy, 0, 0).?;
    defer saved.release();
    hierarchy.mutex.lock();
    while (hierarchy.evictOne(null)) {}
    hierarchy.mutex.unlock();
    try std.testing.expectEqual(@as(u32, 0), hierarchy.records.count());
    try std.testing.expect(!hierarchy.trySubmit(try TestSource.summary(a, 0, 0, .live, old_order, .stone)));
    try TestSource.prepare(hierarchy, 0, 0, true);
    // A re-created record must retain the absence fence as well.
    try std.testing.expect(!hierarchy.trySubmit(try TestSource.summary(a, 0, 0, .live, old_order, .stone)));
    const repaired = TestSource.acquire(hierarchy, 0, 0).?;
    defer repaired.release();
    try std.testing.expectEqual(world_core.BlockType.water, repaired.summary.runs[0].block);

    hierarchy.mutex.lock();
    while (hierarchy.evictOne(null)) {}
    hierarchy.mutex.unlock();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const newer_order = hierarchy.reserveRevision();
    hierarchy.allocator = failing.allocator();
    hierarchy.commitSaved(try TestSource.summary(a, 1, 0, .saved, newer_order, .water));
    hierarchy.allocator = a;
    try std.testing.expect(!hierarchy.trySubmit(try TestSource.summary(a, 1, 0, .live, newer_order - 1, .stone)));
    try TestSource.prepare(hierarchy, 1, 1, true);
    try std.testing.expect(hierarchy.trySubmit(try TestSource.summary(a, 1, 0, .live, hierarchy.reserveRevision(), .grass)));
    const fresh = TestSource.acquire(hierarchy, 1, 0).?;
    defer fresh.release();
    try std.testing.expectEqual(world_core.BlockType.grass, fresh.summary.runs[0].block);
    try std.testing.expectEqual(world_core.BlockType.water, saved.summary.runs[0].block);
    try std.testing.expectEqual(world_core.BlockType.water, repaired.summary.runs[0].block);
}

test "SourceHierarchy snapshot order rejects late saved recapture and duplicate committed live capture" {
    const a = std.testing.allocator;
    var source: TestSource = .{};
    var queue = JobQueue.init(a);
    defer queue.deinit();
    const hierarchy = try SourceHierarchy.init(a, source.generator(), &queue, 16 * 1024 * 1024);
    defer hierarchy.deinit();
    defer queue.stop();
    const commit_order = hierarchy.reserveRevision();
    var delayed = try TestSource.summary(a, 0, 0, .saved, hierarchy.reserveRevision(), .stone);
    var delayed_owned = true;
    defer if (delayed_owned) delayed.deinit();
    var fresh = try TestSource.summary(a, 0, 0, .live, hierarchy.reserveRevision(), .stone);
    const light = world_core.PackedLight.initRGB(2, 9, 7, 5);
    fresh.runs[0].light_top = light;
    try std.testing.expect(hierarchy.trySubmit(fresh));
    const live = TestSource.acquire(hierarchy, 0, 0).?;
    defer live.release();
    hierarchy.commitSaved(try TestSource.summary(a, 0, 0, .saved, commit_order, .stone));
    try std.testing.expect(hierarchy.trySubmit(delayed));
    delayed_owned = false;
    try std.testing.expect(hierarchy.trySubmit(try TestSource.summary(a, 0, 0, .live, commit_order, .stone)));
    const current = TestSource.acquire(hierarchy, 0, 0).?;
    defer current.release();
    try std.testing.expectEqual(scene.Origin.saved, current.summary.origin);
    try std.testing.expectEqualDeep(light, current.summary.runs[0].light_top);
    try std.testing.expectEqual(live.summary.revision, current.summary.revision);
    try std.testing.expectEqual(scene.Origin.live, live.summary.origin);

    // A generated observation is lower authority even if its computation began
    // after the committed snapshot was copied but before its write completed.
    const save_order = hierarchy.reserveRevision();
    hierarchy.submit(try TestSource.summary(a, 1, 0, .generated, hierarchy.reserveRevision(), .stone));
    hierarchy.noteCommitted(.{ .cx = 1, .cz = 0 }, save_order, null);
    try std.testing.expect(TestSource.acquire(hierarchy, 1, 0) == null);
    hierarchy.commitSaved(try TestSource.summary(a, 1, 0, .saved, save_order, .water));
    const saved = TestSource.acquire(hierarchy, 1, 0).?;
    defer saved.release();
    try std.testing.expectEqual(world_core.BlockType.water, saved.summary.runs[0].block);
}
