//! Reduces immutable canonical columns once, directly over each scene footprint.
const std = @import("std");
const world_core = @import("world-core");
const scene = world_core.lod_scene;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const PackedLight = world_core.PackedLight;
const LODSimplifiedData = world_core.LODSimplifiedData;
const ChunkSummary = scene.ChunkSummary;
const SceneGrid = scene.SceneGrid;
const SceneSpan = scene.SceneSpan;
pub const AtomicBool = std.atomic.Value(bool);

pub const Lease = struct {
    summary: *const ChunkSummary,
    ptr: *anyopaque,
    release_fn: *const fn (*anyopaque) void,

    pub fn release(self: Lease) void {
        self.release_fn(self.ptr);
    }
};

// A 512-block LOD4 tile plus its halo exceeds 32x32 chunks. The coarsest
// supported density needs 48x48; leave bounded room for unaligned callers too.
pub const max_snapshot_chunks: usize = 4096;

pub const OwnedSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Z-major, including unknown coordinates as null leases.
    leases: []?Lease,
    min_cx: i32,
    min_cz: i32,
    width: usize,
    height: usize,
    /// Capture-start marker, never a newer epoch sampled after split acquisition.
    source_epoch: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32) !OwnedSnapshot {
        const width = @as(i64, max_cx) - min_cx + 1;
        const height = @as(i64, max_cz) - min_cz + 1;
        if (width <= 0 or height <= 0) return error.InvalidSnapshotBounds;
        if (width > max_snapshot_chunks or height > max_snapshot_chunks or width * height > max_snapshot_chunks) return error.SnapshotTooLarge;
        const leases = try allocator.alloc(?Lease, @intCast(width * height));
        @memset(leases, null);
        return .{ .allocator = allocator, .leases = leases, .min_cx = min_cx, .min_cz = min_cz, .width = @intCast(width), .height = @intCast(height) };
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        for (self.leases) |lease| if (lease) |pinned| pinned.release();
        self.allocator.free(self.leases);
        self.* = undefined;
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    /// Inclusive chunk bounds, including the entire one-cell halo. Runs unlocked.
    prepare_fn: *const fn (ptr: *anyopaque, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32, exact: bool, cancel: ?*const AtomicBool) anyerror!void,
    lock_fn: *const fn (ptr: *anyopaque) void,
    unlock_fn: *const fn (ptr: *anyopaque) void,
    /// Called under lock: no allocation or I/O. Pin immutable storage until release.
    acquire_fn: *const fn (ptr: *anyopaque, cx: i32, cz: i32) ?Lease,
    /// Called under the same lock as all acquisitions in this snapshot.
    epoch_fn: *const fn (ptr: *anyopaque) u64,
    /// Runs unlocked and returns owned pins acquired during preparation, not later.
    snapshot_fn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, min_cx: i32, min_cz: i32, max_cx: i32, max_cz: i32, exact: bool, cancel: ?*const AtomicBool) anyerror!OwnedSnapshot = null,
};

/// Plants must remain distinct from solid terrain: their source block denotes a
/// billboard root, rather than a volume which the scene mesher may greedily
/// merge.  Coarse projection retains one bounded representative per band.
pub const RenderClass = enum(u3) { water, canopy, trunk, @"opaque", plant };
const render_class_count = @typeInfo(RenderClass).@"enum".fields.len;

pub fn renderClass(block: BlockType) ?RenderClass {
    if (block == .air) return null;
    const def = world_core.getBlockDefinition(block);
    switch (def.render_shape) {
        .cube => {},
        .cross, .tall_cross => return .plant,
        .custom_mesh => switch (def.render_shape_data.custom_mesh) {
            .slab, .stairs => {},
            else => return null,
        },
        else => return null,
    }
    return switch (block) {
        .water => .water,
        .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .red_mushroom_block, .brown_mushroom_block => .canopy,
        .wood, .mangrove_log, .jungle_log, .acacia_log, .birch_log, .spruce_log, .mangrove_roots, .mushroom_stem => .trunk,
        else => .@"opaque",
    };
}

const Moments = struct {
    count: u32 = 0,
    // Twice the cell-relative column center; exact even for negative world origins.
    x2: u64 = 0,
    z2: u64 = 0,
    // Twice each boundary's sum; top and bottom never darken one another.
    light2: [4]u64 = @splat(0),
    bottom2: [4]u64 = @splat(0),
};

/// Constant-size worker scratch, not a cache of lossy scene spans. Child column
/// coordinates must be relative to the SAME final footprint before reduction.
/// Validated runs, in-footprint coordinates, and disjoint partitions of a valid
/// SceneGrid cell (side <= 32768) are the caller's contract.
pub const Accumulator = struct {
    counts: [256][256]u32 = @splat(@splat(0)),
    moments: [256][render_class_count]Moments = @splat(@splat(.{})),
    biomes: [256]u32 = @splat(0),
    known_area: u32 = 0,
    approximate: bool = false,

    pub fn addColumn(self: *Accumulator, runs: []const scene.Run, biome: BiomeId, x: u32, z: u32) void {
        self.known_area += 1;
        self.biomes[@intFromEnum(biome)] += 1;
        for (runs) |run| {
            const kind = renderClass(run.block) orelse continue;
            if (world_core.getBlockDefinition(run.block).render_shape != .cube) self.approximate = true;
            const top = lightChannels(run.light_top);
            const bottom = lightChannels(run.light_bottom);
            for (run.min_y..run.max_y) |y| {
                self.counts[y][@intFromEnum(run.block)] += 1;
                const m = &self.moments[y][@intFromEnum(kind)];
                m.count += 1;
                m.x2 += @as(u64, x) * 2 + 1;
                m.z2 += @as(u64, z) * 2 + 1;
                for (&m.light2, &m.bottom2, top, bottom) |*top_sum, *bottom_sum, a, b| {
                    top_sum.* += @as(u64, a) * 2;
                    bottom_sum.* += @as(u64, b) * 2;
                }
            }
        }
    }

    /// Integer addition is associative and commutative; never feed SceneSpan back in.
    pub fn reduceChildren(self: *Accumulator, children: []const *const Accumulator) void {
        for (children) |child| {
            self.known_area += child.known_area;
            self.approximate = self.approximate or child.approximate;
            for (&self.biomes, child.biomes) |*a, b| a.* += b;
            for (&self.counts, &child.counts) |*row, child_row| {
                for (row, child_row) |*a, b| a.* += b;
            }
            for (&self.moments, &child.moments) |*row, child_row| {
                for (row, child_row) |*a, b| {
                    a.count += b.count;
                    a.x2 += b.x2;
                    a.z2 += b.z2;
                    for (&a.light2, b.light2) |*sum, value| sum.* += value;
                    for (&a.bottom2, b.bottom2) |*sum, value| sum.* += value;
                }
            }
        }
    }
};

fn lightChannels(light: PackedLight) [4]u4 {
    return .{ light.sky_light, light.block_light_r, light.block_light_g, light.block_light_b };
}

// Fallback statistics never enter the exact integer accumulator. Each class/Y
// has only one estimated material because a cell uses one fallback sample.
const Estimate = struct {
    block: BlockType = .air,
    weight: f64 = 0,
    x: f64 = 0,
    z: f64 = 0,
};

const Fallback = struct {
    bands: [256][render_class_count]Estimate = @splat(@splat(.{})),
    biome: BiomeId,
    light: PackedLight,
    missing_area: u32 = 0,

    fn addBand(self: *Fallback, min: u16, max: u16, block: BlockType, weight: f64, x: f64, z: f64) void {
        const kind = renderClass(block) orelse return;
        if (weight <= 0) return;
        for (min..max) |y| {
            const e = &self.bands[y][@intFromEnum(kind)];
            std.debug.assert(e.block == .air or e.block == block);
            e.block = block;
            e.weight += weight;
            e.x += x * weight;
            e.z += z * weight;
        }
    }

    fn addColumn(self: *Fallback, data: *const LODSimplifiedData, index: usize, size: u32, x: u32, z: u32) !void {
        self.missing_area += 1;
        const height = data.heightmap[index];
        const water = data.water[index];
        const tree = data.vegetation[index];
        for ([_]f32{ height, water.surface_height, water.depth, water.coverage, tree.tree_coverage, tree.avg_tree_height, tree.offset_x, tree.offset_z }) |value| {
            if (!std.math.isFinite(value)) return error.InvalidFallback;
        }
        var layers = data.material_layers[index];
        for ([_]BlockType{ layers.surface, layers.subsurface, layers.foundation, data.top_blocks[index], tree.trunk, tree.leaves }) |block| {
            if (world_core.getBlockDefinition(block).id != block) return error.InvalidFallback;
        }
        if (layers.surface == .air) layers.surface = data.top_blocks[index];
        const wet = water.is_surface and water.coverage > 0;
        const water_top = faceY(water.surface_height);
        // A water-valued height sample describes the surface, not the seafloor.
        const terrain_top = if (wet and layers.surface == .water)
            faceY(water.surface_height - @max(water.depth, 0))
        else
            faceY(height);
        if (wet and layers.surface == .water) {
            layers.surface = if (layers.subsurface != .air and layers.subsurface != .water) layers.subsurface else layers.foundation;
        }
        if (layers.subsurface == .air or layers.subsurface == .water) layers.subsurface = layers.surface;
        if (layers.foundation == .air or layers.foundation == .water) layers.foundation = layers.subsurface;
        const fx: f64 = @as(f64, @floatFromInt(x)) + 0.5;
        const fz: f64 = @as(f64, @floatFromInt(z)) + 0.5;
        // A deliberately thin guessed cap, never claimed to be measured strata.
        const sub_top = terrain_top -| 1;
        const base_top = sub_top -| 3;
        self.addBand(0, base_top, layers.foundation, 1, fx, fz);
        self.addBand(base_top, sub_top, layers.subsurface, 1, fx, fz);
        self.addBand(sub_top, terrain_top, layers.surface, 1, fx, fz);
        if (wet) self.addBand(@min(terrain_top, water_top), water_top, .water, std.math.clamp(water.coverage, 0, 1), fx, fz);

        if (tree.tree_coverage <= 0 or tree.avg_tree_height <= 0) return;
        const side: f64 = @floatFromInt(size);
        const coverage: f64 = std.math.clamp(tree.tree_coverage, 0, 1);
        const crown_side = side * @sqrt(coverage);
        const cx = std.math.clamp((0.5 + @as(f64, tree.offset_x)) * side, crown_side / 2, side - crown_side / 2);
        const cz = std.math.clamp((0.5 + @as(f64, tree.offset_z)) * side, crown_side / 2, side - crown_side / 2);
        const tree_top = boundedY(@as(f64, @floatFromInt(terrain_top)) + @ceil(tree.avg_tree_height));
        const crown_bottom = @max(terrain_top, boundedY(@as(f64, @floatFromInt(tree_top)) - @ceil(@max(tree.avg_tree_height * 0.45, 1))));
        // Integrate a square crown over missing unit columns, including fractional
        // intersections. Coverage is footprint area, not a per-root probability.
        const widths = [_]f64{ crown_side, @min(crown_side, @max(1, crown_side * 0.15)) };
        const materials = [_]BlockType{ tree.leaves, tree.trunk };
        for (widths, materials, 0..) |extent, block, kind| {
            const lo_x = @max(fx - 0.5, cx - extent / 2);
            const hi_x = @min(fx + 0.5, cx + extent / 2);
            const lo_z = @max(fz - 0.5, cz - extent / 2);
            const hi_z = @min(fz + 0.5, cz + extent / 2);
            const weight = @max(0, hi_x - lo_x) * @max(0, hi_z - lo_z);
            self.addBand(if (kind == 0) crown_bottom else terrain_top, if (kind == 0) tree_top else crown_bottom, block, weight, (lo_x + hi_x) / 2, (lo_z + hi_z) / 2);
        }
    }
};

fn boundedY(y: f64) u16 {
    return @intFromFloat(std.math.clamp(y, 0, 256));
}

fn faceY(block_index: f32) u16 {
    return boundedY(@floor(@as(f64, block_index)) + 1);
}

/// Independently merged material streams, finally ordered by min Y then class.
/// Plant roots deliberately do not merge vertically: a single RLE run may
/// encode many billboard roots. No vertical quantization is necessary.
fn project(acc: *const Accumulator, provisional: *const Fallback, size: u32, output: *[256 * render_class_count]SceneSpan) usize {
    const area: f64 = @floatFromInt(size * size);
    const side: f64 = @floatFromInt(size);
    var biome: BiomeId = provisional.biome;
    var biome_count: u32 = 0;
    for (acc.biomes, 0..) |count, id| {
        const weight = count + if (id == @intFromEnum(provisional.biome)) provisional.missing_area else @as(u32, 0);
        if (weight > biome_count) {
            biome_count = weight;
            biome = @enumFromInt(id);
        }
    }
    var count: usize = 0;
    var previous: [render_class_count]?usize = @splat(null);
    const fallback_light = lightChannels(provisional.light);
    for (0..256) |y| {
        var winners: [render_class_count]BlockType = @splat(.air);
        var votes: [render_class_count]f64 = @splat(0);
        for (acc.counts[y], 0..) |n, id| {
            const block: BlockType = @enumFromInt(id);
            if (n == 0) continue;
            const kind = @intFromEnum(renderClass(block).?);
            const e = provisional.bands[y][kind];
            const weight = @as(f64, @floatFromInt(n)) + if (e.block == block) e.weight else @as(f64, 0);
            if (weight > votes[kind]) {
                winners[kind] = block;
                votes[kind] = weight;
            }
        }
        for (0..render_class_count) |kind| {
            const e = provisional.bands[y][kind];
            if (e.weight > votes[kind] or (e.weight > 0 and e.weight == votes[kind] and @intFromEnum(e.block) < @intFromEnum(winners[kind]))) {
                winners[kind] = e.block;
            }
            const m = acc.moments[y][kind];
            const weight = @as(f64, @floatFromInt(m.count)) + e.weight;
            if (weight == 0) continue;
            const coverage: f32 = @floatCast(weight / area);
            if (coverage == 0) continue; // Unrepresentably small provisional hints.
            var channels: [4]u4 = undefined;
            var bottom_channels: [4]u4 = undefined;
            for (&channels, &bottom_channels, m.light2, m.bottom2, fallback_light) |*channel, *bottom_channel, sum, bottom_sum, hint| {
                channel.* = @intFromFloat(std.math.clamp(@round((@as(f64, @floatFromInt(sum)) / 2 + e.weight * @as(f64, @floatFromInt(hint))) / weight), 0, 15));
                bottom_channel.* = @intFromFloat(std.math.clamp(@round((@as(f64, @floatFromInt(bottom_sum)) / 2 + e.weight * @as(f64, @floatFromInt(hint))) / weight), 0, 15));
            }
            const span: SceneSpan = .{
                .min_y = @floatFromInt(y),
                .max_y = @floatFromInt(y + 1),
                .block = winners[kind],
                .biome = biome,
                .coverage = coverage,
                .center_x = @floatCast((@as(f64, @floatFromInt(m.x2)) / 2 + e.x) / (weight * side)),
                .center_z = @floatCast((@as(f64, @floatFromInt(m.z2)) / 2 + e.z) / (weight * side)),
                .light = PackedLight.initRGB(channels[0], channels[1], channels[2], channels[3]),
                .light_bottom = if (m.count != 0) PackedLight.initRGB(bottom_channels[0], bottom_channels[1], bottom_channels[2], bottom_channels[3]) else null,
            };
            if (kind != @intFromEnum(RenderClass.plant)) {
                if (previous[kind]) |index| {
                    var adjacent = output[index];
                    adjacent.min_y = span.min_y;
                    adjacent.max_y = span.max_y;
                    if (output[index].max_y == span.min_y and std.meta.eql(adjacent, span)) {
                        output[index].max_y = span.max_y;
                        continue;
                    }
                }
            }
            previous[kind] = count;
            output[count] = span;
            count += 1;
        }
    }
    // Creation order is already (min_y, class); extending a band doesn't change it.
    return count;
}

fn checkCancel(cancel: ?*const AtomicBool) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
}

pub fn build(allocator: std.mem.Allocator, fallback: *const LODSimplifiedData, origin_x: i32, origin_z: i32, region_size: u32, provider: Provider, exact: bool, cancel: ?*const AtomicBool) !SceneGrid {
    try checkCancel(cancel);
    if (fallback.width < 2 or fallback.width > 257) return error.InvalidGridSize;
    const width = fallback.width - 1;
    if (region_size == 0 or region_size % width != 0) return error.InvalidCellSize;
    const size = region_size / width;
    const samples: usize = @as(usize, fallback.width) * fallback.width;
    inline for (.{ "heightmap", "biomes", "top_blocks", "material_layers", "water", "lighting", "vegetation" }) |field| {
        if (@field(fallback, field).len < samples) return error.InvalidFallback;
    }
    var grid = try SceneGrid.init(allocator, origin_x, origin_z, size, width);
    errdefer grid.deinit();
    // SceneGrid checked the widened halo coordinates before these casts.
    const min = world_core.worldToChunk(@intCast(@as(i64, origin_x) - size), @intCast(@as(i64, origin_z) - size));
    const max = world_core.worldToChunk(@intCast(@as(i64, origin_x) + region_size + size - 1), @intCast(@as(i64, origin_z) + region_size + size - 1));
    const chunks_x: usize = @intCast(@as(i64, max.chunk_x) - min.chunk_x + 1);
    const chunks_z: usize = @intCast(@as(i64, max.chunk_z) - min.chunk_z + 1);
    if (try std.math.mul(usize, chunks_x, chunks_z) > max_snapshot_chunks) return error.SnapshotTooLarge;
    var snapshot = if (provider.snapshot_fn) |capture|
        try capture(provider.ptr, allocator, min.chunk_x, min.chunk_z, max.chunk_x, max.chunk_z, exact, cancel)
    else blk: {
        var result = try OwnedSnapshot.init(allocator, min.chunk_x, min.chunk_z, max.chunk_x, max.chunk_z);
        errdefer result.deinit();
        try provider.prepare_fn(provider.ptr, min.chunk_x, min.chunk_z, max.chunk_x, max.chunk_z, exact, cancel);
        try checkCancel(cancel);
        provider.lock_fn(provider.ptr);
        defer provider.unlock_fn(provider.ptr);
        result.source_epoch = provider.epoch_fn(provider.ptr);
        for (result.leases, 0..) |*lease, index| {
            try checkCancel(cancel);
            lease.* = provider.acquire_fn(provider.ptr, @intCast(@as(i64, min.chunk_x) + @as(i64, @intCast(index % chunks_x))), @intCast(@as(i64, min.chunk_z) + @as(i64, @intCast(index / chunks_x))));
        }
        break :blk result;
    };
    defer snapshot.deinit();
    if (snapshot.min_cx != min.chunk_x or snapshot.min_cz != min.chunk_z or snapshot.width != chunks_x or snapshot.height != chunks_z or snapshot.leases.len != chunks_x * chunks_z) return error.InvalidSnapshotBounds;
    const leases = snapshot.leases;
    grid.source_epoch = snapshot.source_epoch;
    for (leases, 0..) |lease, index| {
        try checkCancel(cancel);
        if (lease) |pinned| {
            if (pinned.summary.chunk_x != @as(i64, min.chunk_x) + @as(i64, @intCast(index % chunks_x)) or pinned.summary.chunk_z != @as(i64, min.chunk_z) + @as(i64, @intCast(index / chunks_x))) return error.InvalidSourceCoordinates;
            try pinned.summary.validate();
            // Validated snapshot slots are already unique and sorted by (cz, cx).
            try grid.known_chunks.append(allocator, .{ .cx = pinned.summary.chunk_x, .cz = pinned.summary.chunk_z });
        }
    }
    // Known unit cells need only run copies. Allocate reusable reduction scratch
    // on demand, rather than charging every near refresh for a material histogram.
    var accumulator: ?*Accumulator = null;
    defer if (accumulator) |acc| allocator.destroy(acc);
    var fallback_scratch: ?*Fallback = null;
    defer if (fallback_scratch) |provisional| allocator.destroy(provisional);
    var output: [256 * render_class_count]SceneSpan = undefined;
    for (0..width + 2) |iz| {
        const gz: i32 = @as(i32, @intCast(iz)) - 1;
        for (0..width + 2) |ix| {
            try checkCancel(cancel);
            const gx: i32 = @as(i32, @intCast(ix)) - 1;
            const start_x = @as(i64, origin_x) + @as(i64, gx) * size;
            const start_z = @as(i64, origin_z) + @as(i64, gz) * size;
            if (size == 1) {
                const wx: i32 = @intCast(start_x);
                const wz: i32 = @intCast(start_z);
                const chunk = world_core.worldToChunk(wx, wz);
                const index = @as(usize, @intCast(chunk.chunk_z - min.chunk_z)) * chunks_x + @as(usize, @intCast(chunk.chunk_x - min.chunk_x));
                if (leases[index]) |lease| {
                    const local = world_core.worldToLocal(wx, wz);
                    const biome = lease.summary.columns[local.z * 16 + local.x].biome;
                    var count: usize = 0;
                    var approximate = false;
                    for (lease.summary.column(local.x, local.z)) |run| {
                        if (renderClass(run.block) == null) continue;
                        approximate = approximate or world_core.getBlockDefinition(run.block).render_shape != .cube;
                        output[count] = .{
                            .min_y = @floatFromInt(run.min_y),
                            .max_y = @floatFromInt(run.max_y),
                            .block = run.block,
                            .biome = biome,
                            .light = run.light_top,
                            .light_bottom = run.light_bottom,
                        };
                        count += 1;
                    }
                    try grid.appendColumn(gx, gz, output[0..count], 1, 1, approximate);
                    continue;
                }
            }
            if (accumulator == null) accumulator = try allocator.create(Accumulator);
            const acc = accumulator.?;
            if (fallback_scratch == null) fallback_scratch = try allocator.create(Fallback);
            const provisional = fallback_scratch.?;
            acc.* = .{};
            // Only fallback estimates clamp to available samples, never ownership.
            const sample = @as(usize, @intCast(@max(gz, 0))) * fallback.width + @as(usize, @intCast(@max(gx, 0)));
            const lighting = fallback.lighting[sample];
            provisional.* = .{ .biome = fallback.biomes[sample], .light = PackedLight.init(@intCast(@min(lighting.sky_light, 15)), @intCast(@min(lighting.block_light, 15))) };
            for (0..size) |z| {
                for (0..size) |x| {
                    // At most sixteen columns (4096 Y samples) between checks.
                    if (x % 16 == 0) try checkCancel(cancel);
                    const wx: i32 = @intCast(start_x + @as(i64, @intCast(x)));
                    const wz: i32 = @intCast(start_z + @as(i64, @intCast(z)));
                    const chunk = world_core.worldToChunk(wx, wz);
                    const index = @as(usize, @intCast(chunk.chunk_z - min.chunk_z)) * chunks_x + @as(usize, @intCast(chunk.chunk_x - min.chunk_x));
                    if (leases[index]) |lease| {
                        const local = world_core.worldToLocal(wx, wz);
                        acc.addColumn(lease.summary.column(local.x, local.z), lease.summary.columns[local.z * 16 + local.x].biome, @intCast(x), @intCast(z));
                    } else {
                        try provisional.addColumn(fallback, sample, size, @intCast(x), @intCast(z));
                    }
                }
            }
            const count = project(acc, provisional, size, &output);
            try grid.appendColumn(gx, gz, output[0..count], acc.known_area, size * size, provisional.missing_area != 0 or acc.approximate or (size > 1 and count != 0));
        }
    }
    try checkCancel(cancel);
    return grid;
}

const testing = std.testing;

const TestProvider = struct {
    summaries: []const *const ChunkSummary = &.{},
    locked: bool = false,
    prepared: bool = false,
    bounds: [4]i32 = undefined,
    exact: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    fail_prepare: bool = false,
    cancel_acquire: ?*AtomicBool = null,
    cancel_unlock: ?*AtomicBool = null,

    fn provider(self: *TestProvider) Provider {
        return .{ .ptr = self, .prepare_fn = prepare, .lock_fn = lock, .unlock_fn = unlock, .acquire_fn = acquire, .epoch_fn = epoch };
    }

    fn from(ptr: *anyopaque) *TestProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn prepare(ptr: *anyopaque, min_x: i32, min_z: i32, max_x: i32, max_z: i32, exact: bool, cancel: ?*const AtomicBool) !void {
        const self = from(ptr);
        std.debug.assert(!self.locked);
        try checkCancel(cancel);
        if (self.fail_prepare) return error.PrepareFailed;
        self.bounds = .{ min_x, min_z, max_x, max_z };
        self.exact = exact;
        self.prepared = true;
    }

    fn lock(ptr: *anyopaque) void {
        const self = from(ptr);
        std.debug.assert(self.prepared and !self.locked);
        self.locked = true;
    }

    fn unlock(ptr: *anyopaque) void {
        const self = from(ptr);
        std.debug.assert(self.locked);
        self.locked = false;
        if (self.cancel_unlock) |flag| flag.store(true, .release);
    }

    fn acquire(ptr: *anyopaque, cx: i32, cz: i32) ?Lease {
        const self = from(ptr);
        std.debug.assert(self.locked);
        for (self.summaries) |summary| {
            if (summary.chunk_x == cx and summary.chunk_z == cz) {
                self.acquired += 1;
                if (self.cancel_acquire) |flag| flag.store(true, .release);
                return .{ .summary = summary, .ptr = ptr, .release_fn = release };
            }
        }
        return null;
    }

    fn epoch(ptr: *anyopaque) u64 {
        std.debug.assert(from(ptr).locked);
        return 73;
    }

    fn release(ptr: *anyopaque) void {
        const self = from(ptr);
        std.debug.assert(!self.locked and self.released < self.acquired);
        self.released += 1;
    }
};

test "SceneBuilder integer reduction is associative across all child permutations" {
    const children = try testing.allocator.alloc(Accumulator, 4);
    defer testing.allocator.free(children);
    const direct = try testing.allocator.create(Accumulator);
    defer testing.allocator.destroy(direct);
    const reduced = try testing.allocator.create(Accumulator);
    defer testing.allocator.destroy(reduced);
    direct.* = .{};
    const blocks = [_]BlockType{ .dirt, .stone, .birch_leaves, .water };
    for (children, blocks, 0..) |*child, block, i| {
        child.* = .{};
        const run: scene.Run = .{
            .min_y = 7,
            .max_y = 11,
            .block = block,
            .light_top = if (i == 1) PackedLight.initRGB(11, 7, 1, 9) else PackedLight.initRGB(15, 3, 5, 7),
            .light_bottom = if (i == 1) PackedLight.initRGB(3, 1, 9, 5) else PackedLight.initRGB(1, 7, 3, 1),
        };
        const biome: BiomeId = if (i < 2) .forest else .plains;
        child.addColumn(&.{run}, biome, @intCast(i % 2), @intCast(i / 2));
        direct.addColumn(&.{run}, biome, @intCast(i % 2), @intCast(i / 2));
    }
    for (0..4) |a| for (0..4) |b| for (0..4) |c| for (0..4) |d| {
        if (a == b or a == c or a == d or b == c or b == d or c == d) continue;
        reduced.* = .{};
        reduced.reduceChildren(&.{ &children[a], &children[b] });
        reduced.reduceChildren(&.{ &children[c], &children[d] });
        try testing.expectEqualDeep(direct.*, reduced.*);
    };
    var provisional: Fallback = .{ .biome = .ocean, .light = .{} };
    var output: [256 * render_class_count]SceneSpan = undefined;
    const count = project(reduced, &provisional, 2, &output);
    try testing.expectEqual(@as(usize, 3), count);
    const terrain = output[2];
    try testing.expectEqual(BlockType.stone, terrain.block); // Lowest material ID wins ties.
    try testing.expectEqual(BiomeId.plains, terrain.biome);
    try testing.expectEqual(@as(f32, 0.5), terrain.coverage);
    try testing.expectEqual(@as(f32, 0.25), terrain.center_z);
    try testing.expectEqual(PackedLight.initRGB(13, 5, 3, 8), terrain.light);
    try testing.expectEqual(PackedLight.initRGB(2, 4, 6, 3), terrain.light_bottom.?);
}

test "SceneBuilder known unit cells match reduction and source lights within a 16 KiB quota" {
    var chunk = world_core.Chunk.init(-1, -1);
    for (1..5) |z| {
        for (1..5) |x| {
            if (x == 4 and z == 4) continue; // Known air in the positive halo.
            const lx: u32 = @intCast(x);
            const lz: u32 = @intCast(z);
            chunk.setBiome(lx, lz, if (x % 2 == 0) .forest else .swamp);
            for (0..3) |y| chunk.setBlock(lx, @intCast(y), lz, .stone);
            chunk.setBlock(lx, 3, lz, .dirt);
            chunk.setBlock(lx, 4, lz, .grass);
            for (7..9) |y| chunk.setBlock(lx, @intCast(y), lz, .water);
            for (10..12) |y| chunk.setBlock(lx, @intCast(y), lz, .birch_leaves);
            chunk.setBlock(lx, 13, lz, .birch_leaves);
            chunk.setBlock(lx, 14, lz, .spruce_leaves);
            chunk.setBlock(lx, 16, lz, .flower_red);
            chunk.setBlock(lx, 17, lz, .stone_slab);
            chunk.setBlock(lx, 18, lz, .stone_stairs);
            chunk.setBlock(lx, 255, lz, .leaves);
            for (0..256) |y| chunk.setLight(lx, @intCast(y), lz, PackedLight.initRGB(@intCast(y % 16), @intCast((y + 3) % 16), @intCast((y + 5) % 16), @intCast((y + 7) % 16)));
        }
    }
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 3);
    defer data.deinit();
    @memset(data.heightmap, std.math.nan(f32)); // Known cells must not consult estimates.
    var backing: [16 * 1024]u8 = undefined;
    var quota = std.heap.FixedBufferAllocator.init(&backing);
    // Neither the histogram nor the provisional scratch can fit in this quota.
    var grid = try build(quota.allocator(), &data, -14, -14, 2, source.provider(), true, null);
    defer grid.deinit();
    try testing.expectEqual([4]i32{ -1, -1, -1, -1 }, source.bounds);
    try testing.expectEqual(@as(usize, 1), source.acquired);
    try testing.expectEqual(source.acquired, source.released);

    try testing.expectEqualSlices(scene.KnownChunk, &.{.{ .cx = -1, .cz = -1 }}, grid.known_chunks.items);

    const acc = try testing.allocator.create(Accumulator);
    defer testing.allocator.destroy(acc);
    const provisional: Fallback = .{ .biome = .plains, .light = .{} };
    var output: [256 * render_class_count]SceneSpan = undefined;
    for (0..4) |iz| {
        for (0..4) |ix| {
            const gx: i32 = @as(i32, @intCast(ix)) - 1;
            const gz: i32 = @as(i32, @intCast(iz)) - 1;
            const lx: u32 = @intCast(ix + 1);
            const lz: u32 = @intCast(iz + 1);
            const runs = summary.column(lx, lz);
            acc.* = .{};
            acc.addColumn(runs, summary.columns[lz * 16 + lx].biome, 0, 0);
            const count = project(acc, &provisional, 1, &output);
            const spans = grid.column(gx, gz);
            try testing.expectEqualDeep(output[0..count], spans);
            try testing.expectEqual(acc.approximate, grid.columnInfo(gx, gz).approximate);
            try testing.expectEqual(@as(u32, 1), grid.columnInfo(gx, gz).known_area);
            var index: usize = 0;
            for (runs) |run| {
                if (renderClass(run.block) == null) continue;
                try testing.expectEqual(run.block, spans[index].block);
                try testing.expectEqual(@as(f32, @floatFromInt(run.min_y)), spans[index].min_y);
                try testing.expectEqual(@as(f32, @floatFromInt(run.max_y)), spans[index].max_y);
                try testing.expectEqual(run.light_top, spans[index].light);
                try testing.expectEqual(run.light_bottom, spans[index].light_bottom.?);
                index += 1;
            }
            try testing.expectEqual(index, spans.len);
        }
    }
    try testing.expectEqual(@as(usize, 11), grid.column(-1, -1).len);
    try testing.expectEqual(@as(usize, 0), grid.column(2, 2).len);
}

test "SceneBuilder near cells preserve strata cliff depths gaps known air and actual shapes" {
    var chunk = world_core.Chunk.init(0, 0);
    for (0..30) |y| chunk.setBlock(0, @intCast(y), 0, .stone);
    for (30..39) |y| chunk.setBlock(0, @intCast(y), 0, .dirt);
    chunk.setBlock(0, 39, 0, .grass);
    chunk.setBlock(0, 44, 0, .stone_slab);
    chunk.setBlock(0, 48, 0, .stone_stairs);
    chunk.setBlock(0, 50, 0, .flower_red);
    for (60..80) |y| chunk.setBlock(0, @intCast(y), 0, if (y % 2 == 0) .red_sand else .terracotta);
    chunk.setBlock(1, 0, 0, .bedrock);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 3);
    defer data.deinit();
    @memset(data.heightmap, 200);
    @memset(data.top_blocks, .sand);
    var grid = try build(testing.allocator, &data, 0, 0, 2, source.provider(), true, null);
    defer grid.deinit();
    const column = grid.column(0, 0);
    try testing.expectEqual(@as(usize, 26), column.len);
    try testing.expectEqual(@as(f32, 30), column[0].max_y);
    try testing.expectEqual(@as(f32, 30), column[1].min_y);
    try testing.expectEqual(@as(f32, 39), column[1].max_y);
    try testing.expectEqual(BlockType.grass, column[2].block);
    try testing.expectEqual(@as(f32, 40), column[2].max_y);
    try testing.expectEqual(BlockType.stone_slab, column[3].block);
    try testing.expectEqual(@as(f32, 44), column[3].min_y);
    try testing.expectEqual(BlockType.stone_stairs, column[4].block);
    try testing.expectEqual(BlockType.flower_red, column[5].block);
    try testing.expectEqual(@as(f32, 50), column[5].min_y);
    try testing.expectEqual(@as(f32, 60), column[6].min_y);
    try testing.expectEqual(@as(f32, 1), grid.column(1, 0)[0].max_y);
    try testing.expectEqual(@as(usize, 0), grid.column(0, 1).len);
    try testing.expectEqual(@as(u32, 1), grid.columnInfo(0, 1).known_area);
    try testing.expect(!grid.columnInfo(0, 1).approximate);
    try testing.expect(grid.columnInfo(0, 0).approximate);
    try testing.expect(source.exact);
    try testing.expectEqual(@as(u64, 73), grid.source_epoch);
    try testing.expectEqual(source.acquired, source.released);
}

test "SceneBuilder exact cells retain cross roots tall roots gaps and source lights" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBiome(0, 0, .forest);
    chunk.setBlock(0, 3, 0, .stone);
    // One RLE run means two separately rendered cross roots, not a prism.
    chunk.setBlock(0, 40, 0, .flower_red);
    chunk.setBlock(0, 41, 0, .flower_red);
    // tall_cross has no upper companion block; this root reaches Y=257.
    chunk.setBlock(0, 255, 0, .tall_grass);
    chunk.setLight(0, 42, 0, PackedLight.initRGB(9, 2, 5, 11));
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 2);
    defer data.deinit();
    var grid = try build(testing.allocator, &data, 0, 0, 1, source.provider(), true, null);
    defer grid.deinit();

    const runs = summary.column(0, 0);
    const spans = grid.column(0, 0);
    try testing.expectEqual(@as(usize, 3), spans.len);
    for (runs, spans) |run, scene_span| {
        try testing.expectEqual(run.block, scene_span.block);
        try testing.expectEqual(@as(f32, @floatFromInt(run.min_y)), scene_span.min_y);
        try testing.expectEqual(@as(f32, @floatFromInt(run.max_y)), scene_span.max_y);
        try testing.expectEqual(run.light_top, scene_span.light);
        try testing.expectEqual(run.light_bottom, scene_span.light_bottom.?);
    }
    try testing.expectEqual(BlockType.flower_red, spans[1].block);
    try testing.expectEqual(@as(f32, 40), spans[1].min_y);
    try testing.expectEqual(@as(f32, 42), spans[1].max_y);
    try testing.expectEqual(PackedLight.initRGB(9, 2, 5, 11), spans[1].light);
    try testing.expectEqual(BlockType.tall_grass, spans[2].block);
    try testing.expectEqual(@as(f32, 256), spans[2].max_y);
    try testing.expect(grid.columnInfo(0, 0).approximate);
    try testing.expectEqual(source.acquired, source.released);
}

test "SceneBuilder projects all four same Y classes and sparse leaf-only coverage" {
    var chunk = world_core.Chunk.init(0, 0);
    const blocks = [_]BlockType{ .water, .brown_mushroom_block, .mangrove_roots, .glass };
    for (blocks, 0..) |block, i| {
        for (10..14) |y| chunk.setBlock(@intCast(i % 2), @intCast(y), @intCast(i / 2), block);
    }
    chunk.setBlock(2, 40, 0, .birch_leaves);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 3);
    defer data.deinit();
    var grid = try build(testing.allocator, &data, 0, 0, 4, source.provider(), false, null);
    defer grid.deinit();
    try testing.expectEqual(@as(usize, 4), grid.column(0, 0).len);
    for (grid.column(0, 0), blocks, 0..) |span, block, i| {
        try testing.expectEqual(block, span.block);
        try testing.expectEqual(@as(f32, 10), span.min_y);
        try testing.expectEqual(@as(f32, 14), span.max_y);
        try testing.expectEqual(@as(f32, 0.25), span.coverage);
        try testing.expectEqual(if (i % 2 == 0) @as(f32, 0.25) else @as(f32, 0.75), span.center_x);
    }
    const leaves = grid.column(1, 0);
    try testing.expectEqual(@as(usize, 1), leaves.len);
    try testing.expectEqual(BlockType.birch_leaves, leaves[0].block);
    try testing.expectEqual(@as(f32, 0.25), leaves[0].coverage);
    try testing.expectEqual(@as(u32, 4), grid.columnInfo(1, 0).known_area);

    @memset(&chunk.blocks, .air);
    for (0..256) |y| {
        for (blocks, 0..) |block, x| {
            chunk.setBlock(@intCast(x), @intCast(y), 0, block);
            if (y % 2 == 0) chunk.setBlock(@intCast(x), @intCast(y), 1, block);
        }
    }
    var worst = try ChunkSummary.capture(testing.allocator, &chunk);
    defer worst.deinit();
    source.summaries = &.{&worst};
    var bounded = try build(testing.allocator, &data, 0, 0, 8, source.provider(), false, null);
    defer bounded.deinit();
    const maximum = bounded.column(0, 0);
    try testing.expectEqual(@as(usize, 1024), maximum.len);
    for (maximum, 0..) |span, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i / 4)), span.min_y);
        try testing.expectEqual(@as(f32, @floatFromInt(i / 4 + 1)), span.max_y);
        try testing.expectEqual(blocks[i % 4], span.block);
    }
}

test "SceneBuilder negative crossing footprint and halo ignore provider insertion order" {
    var chunk = world_core.Chunk.init(0, 0);
    var summaries: [4]ChunkSummary = undefined;
    var initialized: usize = 0;
    defer for (summaries[0..initialized]) |*summary| summary.deinit();
    const blocks = [_]BlockType{ .dirt, .stone, .water, .leaves };
    for (&summaries, blocks, 0..) |*summary, block, i| {
        chunk.chunk_x = @as(i32, @intCast(i % 2)) - 1;
        chunk.chunk_z = @as(i32, @intCast(i / 2)) - 1;
        chunk.fillLayer(9, block);
        summary.* = try ChunkSummary.capture(testing.allocator, &chunk);
        initialized += 1;
    }
    var forward: TestProvider = .{ .summaries = &.{ &summaries[0], &summaries[1], &summaries[2], &summaries[3] } };
    var reverse: TestProvider = .{ .summaries = &.{ &summaries[3], &summaries[2], &summaries[1], &summaries[0] } };
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 2);
    defer data.deinit();
    var a = try build(testing.allocator, &data, -1, -1, 2, forward.provider(), true, null);
    defer a.deinit();
    var b = try build(testing.allocator, &data, -1, -1, 2, reverse.provider(), true, null);
    defer b.deinit();
    try testing.expectEqualDeep(a.columns, b.columns);
    try testing.expectEqualDeep(a.spans.items, b.spans.items);
    try testing.expectEqualSlices(scene.KnownChunk, &.{ .{ .cx = -1, .cz = -1 }, .{ .cx = 0, .cz = -1 }, .{ .cx = -1, .cz = 0 }, .{ .cx = 0, .cz = 0 } }, a.known_chunks.items);
    try testing.expectEqualDeep(a.known_chunks.items, b.known_chunks.items);
    try testing.expectEqual([4]i32{ -1, -1, 0, 0 }, forward.bounds);
    for (a.columns) |info| try testing.expectEqual(@as(u32, 4), info.known_area);
    try testing.expectEqual(BlockType.dirt, a.column(-1, -1)[0].block);
    try testing.expectEqual(BlockType.leaves, a.column(1, 1)[0].block);
    try testing.expectEqual(@as(usize, 3), a.column(0, 0).len);
    try testing.expectEqual(BlockType.stone, a.column(0, 0)[2].block);
    try testing.expectEqual(@as(f32, 0.5), a.column(0, 0)[2].coverage);
    try testing.expectEqual(@as(usize, 4), forward.acquired);
    try testing.expectEqual(forward.acquired, forward.released);

    var unit = try build(testing.allocator, &data, 0, 0, 1, forward.provider(), true, null);
    defer unit.deinit();
    const corners = [_][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
    for (corners, blocks) |corner, block| {
        const spans = unit.column(corner[0], corner[1]);
        try testing.expectEqual(@as(usize, 1), spans.len);
        try testing.expectEqual(block, spans[0].block);
        try testing.expectEqual(@as(f32, 1), spans[0].coverage);
    }
    for (unit.columns) |info| {
        try testing.expectEqual(@as(u32, 1), info.known_area);
        try testing.expect(!info.approximate);
    }
    try testing.expectEqual(forward.acquired, forward.released);
}

test "SceneBuilder same canonical footprint is invariant across LOD and density grids" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 10, 0, .stone);
    chunk.setBlock(1, 10, 1, .dirt);
    chunk.setBlock(0, 20, 1, .leaves);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var small = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 2);
    defer small.deinit();
    var dense = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod4, 3);
    defer dense.deinit();
    @memset(small.heightmap, 250);
    @memset(dense.heightmap, 1);
    var a = try build(testing.allocator, &small, 0, 0, 2, source.provider(), true, null);
    defer a.deinit();
    var b = try build(testing.allocator, &dense, 0, 0, 4, source.provider(), false, null);
    defer b.deinit();
    try testing.expectEqualDeep(a.column(0, 0), b.column(0, 0));
    try testing.expectEqual(@as(usize, 2), a.column(0, 0).len);
    try testing.expectEqual(@as(f32, 0.5), a.column(0, 0)[0].coverage);
    try testing.expectEqual(@as(f32, 0.25), a.column(0, 0)[1].coverage);
}

test "SceneBuilder provisional soil water and trees use face Y and footprint coverage" {
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 2);
    defer data.deinit();
    for (0..2) |z| for (0..2) |x| {
        data.setColumn(@intCast(x), @intCast(z), 20.75, .swamp, .{ .surface = .water, .subsurface = .sand, .foundation = .stone }, 0, .{ .is_surface = true, .surface_height = 20.75, .depth = 4, .coverage = 0.5 }, .daylight, .{ .tree_coverage = 0.0625, .avg_tree_height = 8, .offset_x = 0, .offset_z = 0, .trunk = .air, .leaves = .birch_leaves });
    };
    var source: TestProvider = .{};
    var grid = try build(testing.allocator, &data, 0, 0, 4, source.provider(), false, null);
    defer grid.deinit();
    const spans = grid.column(0, 0);
    try testing.expectEqual(@as(usize, 4), spans.len);
    try testing.expectEqual(BlockType.stone, spans[0].block);
    try testing.expectEqual(@as(f32, 13), spans[0].max_y);
    try testing.expectEqual(BlockType.sand, spans[1].block);
    try testing.expectEqual(@as(f32, 17), spans[1].max_y);
    try testing.expectEqual(BlockType.water, spans[2].block);
    try testing.expectEqual(@as(f32, 17), spans[2].min_y);
    try testing.expectEqual(@as(f32, 21), spans[2].max_y);
    try testing.expectEqual(@as(f32, 0.5), spans[2].coverage);
    try testing.expectEqual(BlockType.birch_leaves, spans[3].block);
    try testing.expectEqual(@as(f32, 25), spans[3].max_y);
    try testing.expectEqual(@as(f32, 0.0625), spans[3].coverage);
    for (grid.columns) |info| {
        try testing.expectEqual(@as(u32, 0), info.known_area);
        try testing.expectEqual(@as(u32, 16), info.total_area);
        try testing.expect(info.approximate);
    }
    try testing.expectEqualDeep(spans, grid.column(-1, -1));
    try testing.expectEqual(@as(usize, 0), grid.known_chunks.items.len);
    for (spans) |span| {
        try testing.expectEqual(PackedLight.init(15, 0), span.light);
        try testing.expect(span.light_bottom == null);
    }

    var chunk = world_core.Chunk.init(0, 0); // Only one quarter of cell (15,15) is known air.
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    source.summaries = &.{&summary};
    var partial = try build(testing.allocator, &data, 15, 15, 2, source.provider(), false, null);
    defer partial.deinit();
    try testing.expectEqual(@as(u32, 1), partial.columnInfo(0, 0).known_area);
    try testing.expectEqualSlices(scene.KnownChunk, &.{.{ .cx = 0, .cz = 0 }}, partial.known_chunks.items);
    try testing.expectEqual(@as(f32, 0.75), partial.column(0, 0)[0].coverage);
    try testing.expectEqual(@as(f32, 0.375), partial.column(0, 0)[2].coverage);
    try testing.expectEqual(@as(f32, 0.0625 * 0.75), partial.column(0, 0)[3].coverage);
}

test "SceneBuilder cancellation prepare errors invalid sources and allocation failures release leases" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 2);
    defer data.deinit();
    var source: TestProvider = .{ .summaries = &.{&summary} };
    var cancel: AtomicBool = .init(true);
    try testing.expectError(error.Cancelled, build(testing.allocator, &data, 0, 0, 1, source.provider(), true, &cancel));
    try testing.expect(!source.prepared);
    cancel.store(false, .release);
    source.fail_prepare = true;
    try testing.expectError(error.PrepareFailed, build(testing.allocator, &data, 0, 0, 1, source.provider(), true, null));
    try testing.expectEqual(@as(usize, 0), source.acquired);
    source.fail_prepare = false;
    source.cancel_acquire = &cancel;
    summary.chunk_x = -1;
    summary.chunk_z = -1;
    try testing.expectError(error.Cancelled, build(testing.allocator, &data, -1, -1, 1, source.provider(), true, &cancel));
    try testing.expectEqual(@as(usize, 1), source.acquired);
    try testing.expectEqual(source.acquired, source.released);
    try testing.expect(!source.locked);
    summary.chunk_x = 0;
    summary.chunk_z = 0;
    source.cancel_acquire = null;
    source.cancel_unlock = &cancel;
    cancel.store(false, .release);
    try testing.expectError(error.Cancelled, build(testing.allocator, &data, 0, 0, 1, source.provider(), true, &cancel));
    try testing.expectEqual(source.acquired, source.released);
    source.cancel_unlock = null;
    summary.runs[0].max_y = 257;
    try testing.expectError(error.InvalidRunBounds, build(testing.allocator, &data, 0, 0, 1, source.provider(), true, null));
    try testing.expectEqual(source.acquired, source.released);
    summary.runs[0].max_y = 1;
    var succeeded = false;
    for (0..20) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var grid = build(failing.allocator(), &data, 0, 0, 1, source.provider(), true, null) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(source.acquired, source.released);
            try testing.expect(!source.locked);
            continue;
        };
        grid.deinit();
        succeeded = true;
        break;
    }
    try testing.expect(succeeded);
    try testing.expectEqual(source.acquired, source.released);
}

test "SceneBuilder rejects invalid grid arithmetic and nonfinite fallback without leaked leases" {
    var data = try LODSimplifiedData.initWithGridSize(testing.allocator, .lod0, 3);
    defer data.deinit();
    var source: TestProvider = .{};
    try testing.expectError(error.InvalidCellSize, build(testing.allocator, &data, 0, 0, 3, source.provider(), false, null));
    try testing.expectError(error.InvalidCellSize, build(testing.allocator, &data, 0, 0, 6, source.provider(), false, null));
    try testing.expectError(error.InvalidCellSize, build(testing.allocator, &data, 0, 0, 131072, source.provider(), false, null));
    try testing.expectError(error.InvalidGridCoordinates, build(testing.allocator, &data, std.math.minInt(i32), 0, 2, source.provider(), false, null));
    try testing.expectError(error.InvalidGridCoordinates, build(testing.allocator, &data, 0, std.math.maxInt(i32), 2, source.provider(), false, null));
    try testing.expect(!source.prepared);
    data.heightmap[0] = std.math.nan(f32);
    try testing.expectError(error.InvalidFallback, build(testing.allocator, &data, 0, 0, 2, source.provider(), false, null));
    data.heightmap[0] = 0;
    data.top_blocks[0] = @enumFromInt(255);
    try testing.expectError(error.InvalidFallback, build(testing.allocator, &data, 0, 0, 2, source.provider(), false, null));
    try testing.expect(!source.locked);
}
