const std = @import("std");
const sync = @import("sync");
const gen_interface = @import("worldgen-api");
const Generator = gen_interface.Generator;
const ColumnInfo = gen_interface.ColumnInfo;
const MapSample = gen_interface.MapSample;
const MapWaterClassification = gen_interface.MapWaterClassification;
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const block_registry = world_core.block_registry;

pub const WorldMap = struct {
    const COARSE_TARGET_RESOLUTION: u32 = 256;
    const MAX_FULL_RENDER_WORKERS: u32 = 8;

    pub const View = struct {
        center_x: f32,
        center_z: f32,
        scale: f32,
        generation: u64,
    };

    pub const LoadedSurfaceCell = struct {
        height: i16,
        block: BlockType,
    };

    pub const LoadedSurfaceChunk = struct {
        chunk_x: i32,
        chunk_z: i32,
        heights: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
        blocks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BlockType,
    };

    /// Immutable copied live-world data. No chunk pointers cross into the map
    /// worker, so edits and streaming remain synchronized by World capture.
    pub const LoadedSurfaceOverlay = struct {
        allocator: std.mem.Allocator,
        chunks: std.ArrayListUnmanaged(LoadedSurfaceChunk) = .empty,

        pub fn deinit(self: *LoadedSurfaceOverlay) void {
            self.chunks.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn ensureUnusedCapacity(self: *LoadedSurfaceOverlay, count: usize) !void {
            try self.chunks.ensureUnusedCapacity(self.allocator, count);
        }

        pub fn appendAssumeCapacity(self: *LoadedSurfaceOverlay, chunk: LoadedSurfaceChunk) void {
            self.chunks.appendAssumeCapacity(chunk);
        }

        pub fn finish(self: *LoadedSurfaceOverlay) void {
            std.mem.sort(LoadedSurfaceChunk, self.chunks.items, {}, lessThanSurfaceChunk);
        }

        pub fn sample(self: *const LoadedSurfaceOverlay, world_x: i32, world_z: i32) ?LoadedSurfaceCell {
            const chunk_pos = world_core.worldToChunk(world_x, world_z);
            const local = world_core.worldToLocal(world_x, world_z);
            const chunk = self.findChunk(chunk_pos.chunk_x, chunk_pos.chunk_z) orelse return null;
            const index = local.x + local.z * CHUNK_SIZE_X;
            const height = chunk.heights[index];
            if (height < 0) return null;
            return .{ .height = height, .block = chunk.blocks[index] };
        }

        pub fn sampleRepresentative(self: *const LoadedSurfaceOverlay, wx: f32, wz: f32, scale: f32) ?LoadedSurfaceCell {
            const radius = @max(scale * 0.5, 0.5);
            const min_x: i32 = @intFromFloat(@floor(wx - radius));
            const max_x: i32 = @intFromFloat(@ceil(wx + radius) - 1.0);
            const min_z: i32 = @intFromFloat(@floor(wz - radius));
            const max_z: i32 = @intFromFloat(@ceil(wz + radius) - 1.0);

            var best: ?LoadedSurfaceCell = null;
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                var x = min_x;
                while (x <= max_x) : (x += 1) {
                    const cell = self.sample(x, z) orelse continue;
                    if (best == null or cell.height > best.?.height) best = cell;
                }
            }
            return best;
        }

        fn findChunk(self: *const LoadedSurfaceOverlay, chunk_x: i32, chunk_z: i32) ?*const LoadedSurfaceChunk {
            var low: usize = 0;
            var high = self.chunks.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                const chunk = &self.chunks.items[mid];
                if (chunk.chunk_z < chunk_z or (chunk.chunk_z == chunk_z and chunk.chunk_x < chunk_x)) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            if (low >= self.chunks.items.len) return null;
            const chunk = &self.chunks.items[low];
            return if (chunk.chunk_x == chunk_x and chunk.chunk_z == chunk_z) chunk else null;
        }

        fn lessThanSurfaceChunk(_: void, a: LoadedSurfaceChunk, b: LoadedSurfaceChunk) bool {
            return a.chunk_z < b.chunk_z or (a.chunk_z == b.chunk_z and a.chunk_x < b.chunk_x);
        }
    };

    const Request = struct {
        generator: Generator,
        center_x: f32,
        center_z: f32,
        scale: f32,
        generation: u64,
        overlay: ?*LoadedSurfaceOverlay,
    };

    const Pass = enum { coarse, full };

    const RenderSlice = struct {
        map: *WorldMap,
        request: Request,
        sample_step: u32,
        reduction: u8,
        start_slice: u32,
        slice_stride: u32,
        cancelled: *std.atomic.Value(bool),
    };

    allocator: std.mem.Allocator,
    pixels: []u8,
    worker_pixels: []u8,
    worker_heights: []i32,
    worker_water: []MapWaterClassification,
    width: u32,
    height: u32,
    mutex: sync.Mutex = .{},
    work_ready: sync.Condition = .{},
    thread: ?std.Thread = null,
    pending_request: ?Request = null,
    refinement_request: ?Request = null,
    completed: bool = false,
    completed_view: View = .{ .center_x = 0, .center_z = 0, .scale = 1, .generation = 0 },
    latest_generation: u64 = 0,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !WorldMap {
        // Safety: ensure texture size is within typical hardware limits
        const safe_w = @min(width, 4096);
        const safe_h = @min(height, 4096);
        const pixel_bytes = @as(usize, safe_w) * @as(usize, safe_h) * 4;
        const pixels = try allocator.alloc(u8, pixel_bytes);
        errdefer allocator.free(pixels);
        const worker_pixels = try allocator.alloc(u8, pixel_bytes);
        errdefer allocator.free(worker_pixels);
        const worker_heights = try allocator.alloc(i32, @as(usize, safe_w) * @as(usize, safe_h));
        errdefer allocator.free(worker_heights);
        const worker_water = try allocator.alloc(MapWaterClassification, @as(usize, safe_w) * @as(usize, safe_h));
        @memset(pixels, 0);
        @memset(worker_pixels, 0);
        @memset(worker_heights, 0);
        @memset(worker_water, .none);

        return .{
            .allocator = allocator,
            .pixels = pixels,
            .worker_pixels = worker_pixels,
            .worker_heights = worker_heights,
            .worker_water = worker_water,
            .width = safe_w,
            .height = safe_h,
        };
    }

    pub fn createLoadedSurfaceOverlay(self: *WorldMap) !*LoadedSurfaceOverlay {
        const overlay = try self.allocator.create(LoadedSurfaceOverlay);
        overlay.* = .{ .allocator = self.allocator };
        return overlay;
    }

    pub fn deinit(self: *WorldMap) void {
        self.mutex.lock();
        self.stopping = true;
        if (self.pending_request) |request| if (request.overlay) |overlay| overlay.deinit();
        if (self.refinement_request) |request| if (request.overlay) |overlay| overlay.deinit();
        self.pending_request = null;
        self.refinement_request = null;
        self.work_ready.broadcast();
        self.mutex.unlock();

        if (self.thread) |thread| thread.join();

        self.allocator.free(self.worker_water);
        self.allocator.free(self.worker_heights);
        self.allocator.free(self.worker_pixels);
        self.allocator.free(self.pixels);
        self.worker_heights = &.{};
        self.worker_water = &.{};
        self.worker_pixels = &.{};
        self.pixels = &.{};
    }

    /// Coalesces requests so pan/zoom input never queues obsolete map renders.
    /// The worker is spawned lazily after WorldMap has reached its stable owner.
    pub fn requestUpdate(self: *WorldMap, generator: Generator, center_x: f32, center_z: f32, scale: f32, overlay: ?*LoadedSurfaceOverlay) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) {
            if (overlay) |owned| owned.deinit();
            return;
        }

        if (self.pending_request) |request| if (request.overlay) |owned| owned.deinit();
        if (self.refinement_request) |request| if (request.overlay) |owned| owned.deinit();
        self.latest_generation +%= 1;
        self.pending_request = .{
            .generator = generator,
            .center_x = center_x,
            .center_z = center_z,
            .scale = scale,
            .generation = self.latest_generation,
            .overlay = overlay,
        };
        self.refinement_request = null;
        // A completion from an older viewport must never block or overwrite a
        // newer request. It can be safely dropped while holding the mutex.
        self.completed = false;
        if (self.thread == null) self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        self.work_ready.signal();
    }

    /// Copies a completed worker result into the render-thread-owned buffer.
    /// The GPU upload must happen after this returns and must remain on the
    /// render thread.
    pub fn consumeCompleted(self: *WorldMap) ?View {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.completed) return null;

        @memcpy(self.pixels, self.worker_pixels);
        self.completed = false;
        self.work_ready.signal();
        return self.completed_view;
    }

    pub fn reductionForScale(scale: f32) u8 {
        if (scale <= 1.0) return 0;
        if (scale <= 4.0) return 1;
        if (scale <= 16.0) return 2;
        if (scale > 64.0) return 4;
        return 3;
    }

    pub fn coarseSampleStep(self: *const WorldMap) u32 {
        const longest_axis = @max(self.width, self.height);
        return @max((longest_axis + COARSE_TARGET_RESOLUTION - 1) / COARSE_TARGET_RESOLUTION, 1);
    }

    fn workerMain(self: *WorldMap) void {
        while (true) {
            self.mutex.lock();
            while (!self.stopping and (self.completed or (self.pending_request == null and self.refinement_request == null))) {
                self.work_ready.wait(&self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }

            const pass: Pass = if (self.pending_request != null) .coarse else .full;
            const request = if (self.pending_request) |pending| blk: {
                self.pending_request = null;
                break :blk pending;
            } else blk: {
                const refinement = self.refinement_request.?;
                self.refinement_request = null;
                break :blk refinement;
            };
            self.mutex.unlock();

            const sample_step: u32 = if (pass == .coarse) self.coarseSampleStep() else 1;
            const reduction: u8 = if (pass == .coarse) 4 else reductionForScale(request.scale);
            if (!self.render(request, sample_step, reduction)) {
                if (request.overlay) |overlay| overlay.deinit();
                continue;
            }

            self.mutex.lock();
            if (self.stopping) {
                self.mutex.unlock();
                if (request.overlay) |overlay| overlay.deinit();
                return;
            }
            // All passes are latest-wins. Publishing an obsolete preview makes
            // pan/zoom visibly lag and then blocks the latest work until the
            // render thread uploads an image that is already wrong.
            if (request.generation != self.latest_generation) {
                self.mutex.unlock();
                if (request.overlay) |overlay| overlay.deinit();
                continue;
            }
            if (pass == .coarse) self.refinement_request = request;
            self.completed_view = .{
                .center_x = request.center_x,
                .center_z = request.center_z,
                .scale = request.scale,
                .generation = request.generation,
            };
            self.completed = true;
            self.mutex.unlock();
            if (pass == .full) if (request.overlay) |overlay| overlay.deinit();
        }
    }

    fn render(self: *WorldMap, request: Request, sample_step: u32, reduction: u8) bool {
        if (self.height >= 64 and request.generator.vtable.column_info_thread_safe) {
            if (!self.renderParallel(request, sample_step, reduction)) return false;
        } else if (!self.renderRows(request, sample_step, reduction, 0, 1)) {
            return false;
        }
        if (sample_step == 1 and !self.applyTerrainStyling(request)) return false;
        return true;
    }

    fn renderParallel(self: *WorldMap, request: Request, sample_step: u32, reduction: u8) bool {
        const worker_count: u32 = @intCast(@min(@max(std.Thread.getCpuCount() catch 4, 2), MAX_FULL_RENDER_WORKERS));
        var cancelled = std.atomic.Value(bool).init(false);
        var threads: [MAX_FULL_RENDER_WORKERS - 1]?std.Thread = @splat(null);
        var slices: [MAX_FULL_RENDER_WORKERS - 1]RenderSlice = undefined;

        for (1..worker_count) |worker_index| {
            const slot = worker_index - 1;
            slices[slot] = .{
                .map = self,
                .request = request,
                .sample_step = sample_step,
                .reduction = reduction,
                .start_slice = @intCast(worker_index),
                .slice_stride = worker_count,
                .cancelled = &cancelled,
            };
            threads[slot] = std.Thread.spawn(.{}, renderSliceMain, .{slices[slot]}) catch null;
        }

        var rendered = self.renderRows(request, sample_step, reduction, 0, worker_count);
        for (threads[0 .. worker_count - 1]) |thread| if (thread) |running| running.join();

        // Thread creation failure is rare, but rendering the missing slice on
        // this worker preserves a complete map instead of publishing stripes.
        for (threads[0 .. worker_count - 1], 1..) |thread, worker_index| {
            if (thread == null and rendered) {
                rendered = self.renderRows(request, sample_step, reduction, @intCast(worker_index), worker_count);
            }
        }
        return rendered and !cancelled.load(.acquire);
    }

    fn renderSliceMain(slice: RenderSlice) void {
        if (!slice.map.renderRows(slice.request, slice.sample_step, slice.reduction, slice.start_slice, slice.slice_stride)) {
            slice.cancelled.store(true, .release);
        }
    }

    fn renderRows(self: *WorldMap, request: Request, sample_step: u32, reduction: u8, start_slice: u32, slice_stride: u32) bool {
        const hw = @as(f32, @floatFromInt(self.width)) * 0.5;
        const hh = @as(f32, @floatFromInt(self.height)) * 0.5;
        const start_x = request.center_x - (hw * request.scale);
        const start_z = request.center_z - (hh * request.scale);

        var py = start_slice * sample_step;
        var rows_since_cancel_check: u32 = 16;
        while (py < self.height) : (py += sample_step * slice_stride) {
            if (rows_since_cancel_check >= 16) {
                if (self.shouldCancel(request.generation)) return false;
                rows_since_cancel_check = 0;
            }
            rows_since_cancel_check += 1;
            const sample_y = @min(py + sample_step / 2, self.height - 1);
            const wz = start_z + @as(f32, @floatFromInt(sample_y)) * request.scale;
            var px: u32 = 0;
            while (px < self.width) : (px += sample_step) {
                const sample_x = @min(px + sample_step / 2, self.width - 1);
                const wx = start_x + @as(f32, @floatFromInt(sample_x)) * request.scale;

                const live_footprint = @min(request.scale * @as(f32, @floatFromInt(sample_step)), 8.0);
                const live_surface = if (request.overlay) |overlay| overlay.sampleRepresentative(wx, wz, live_footprint) else null;
                const sample = if (live_surface == null) request.generator.getMapSampleReduced(wx, wz, reduction) else null;
                const color = if (live_surface) |surface| colorForLiveBlock(surface.block) else colorForSample(sample.?);
                const rgba: [4]u8 = .{
                    @intFromFloat(color[0] * 255.0),
                    @intFromFloat(color[1] * 255.0),
                    @intFromFloat(color[2] * 255.0),
                    255,
                };

                const end_y = @min(py + sample_step, self.height);
                const end_x = @min(px + sample_step, self.width);
                var fill_y = py;
                while (fill_y < end_y) : (fill_y += 1) {
                    var fill_x = px;
                    while (fill_x < end_x) : (fill_x += 1) {
                        const idx = (@as(usize, fill_x) + @as(usize, fill_y) * @as(usize, self.width)) * 4;
                        @memcpy(self.worker_pixels[idx .. idx + 4], &rgba);
                        self.worker_heights[idx / 4] = if (live_surface) |surface| surface.height else sample.?.terrain_height;
                        self.worker_water[idx / 4] = if (live_surface) |surface|
                            if (surface.block == .water) .inland else .none
                        else
                            sample.?.water;
                    }
                }
            }
        }
        return true;
    }

    /// Applies cartographic relief, contours, and crisp shoreline definition
    /// after all height samples are available. Water stays visually flat while
    /// land receives a normalized NW-lit hillshade.
    fn applyTerrainStyling(self: *WorldMap, request: Request) bool {
        if (self.width < 3 or self.height < 3) return true;
        const width: usize = self.width;
        const height: usize = self.height;
        const stride = width;
        const gradient_scale = 1.0 / @max(request.scale * 2.0, 0.25);
        const contour_interval = contourInterval(request.scale);
        const light_x: f32 = -0.557;
        const light_y: f32 = 0.743;
        const light_z: f32 = -0.371;

        var y: usize = 1;
        while (y + 1 < height) : (y += 1) {
            if (self.shouldCancel(request.generation)) return false;
            var x: usize = 1;
            while (x + 1 < width) : (x += 1) {
                const pixel = x + y * stride;
                if (self.worker_water[pixel] != .none) {
                    const shoreline = self.worker_water[pixel - 1] == .none or
                        self.worker_water[pixel + 1] == .none or
                        self.worker_water[pixel - stride] == .none or
                        self.worker_water[pixel + stride] == .none;
                    if (shoreline) multiplyPixel(self.worker_pixels, pixel, 0.76);
                    continue;
                }

                const slope_x = @as(f32, @floatFromInt(self.worker_heights[pixel + 1] - self.worker_heights[pixel - 1])) * gradient_scale;
                const slope_z = @as(f32, @floatFromInt(self.worker_heights[pixel + stride] - self.worker_heights[pixel - stride])) * gradient_scale;
                const normal_length = @sqrt(slope_x * slope_x + slope_z * slope_z + 1.0);
                const light = (-slope_x * light_x + light_y - slope_z * light_z) / normal_length;
                const relief = std.math.clamp(0.72 + light * 0.42, 0.66, 1.20);
                multiplyPixel(self.worker_pixels, pixel, relief);

                const height_here = self.worker_heights[pixel];
                const contour = @divFloor(height_here, contour_interval);
                const crosses_contour = @divFloor(self.worker_heights[pixel - 1], contour_interval) != contour or
                    @divFloor(self.worker_heights[pixel - stride], contour_interval) != contour;
                if (crosses_contour) {
                    const major = @mod(height_here, contour_interval * 4) == 0;
                    multiplyPixel(self.worker_pixels, pixel, if (major) 0.68 else 0.82);
                }
            }
        }
        return true;
    }

    fn contourInterval(scale: f32) i32 {
        if (scale <= 2.0) return 8;
        if (scale <= 8.0) return 16;
        if (scale <= 32.0) return 32;
        return 64;
    }

    fn multiplyPixel(pixels: []u8, pixel: usize, factor: f32) void {
        const color = pixel * 4;
        inline for (0..3) |channel| {
            pixels[color + channel] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(pixels[color + channel])) * factor, 0.0, 255.0));
        }
    }

    fn shouldCancel(self: *WorldMap, generation: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stopping or generation != self.latest_generation;
    }

    fn getBiomeColor(info: ColumnInfo) [3]f32 {
        if (info.is_ocean) {
            const depth = @as(f32, @floatFromInt(64 - info.height));
            const t = std.math.clamp(depth / 40.0, 0.0, 1.0);
            return .{
                std.math.lerp(0.18, 0.02, t),
                std.math.lerp(0.48, 0.16, t),
                std.math.lerp(0.86, 0.52, t),
            };
        }

        return switch (info.biome) {
            .deep_ocean => .{ 0.03, 0.18, 0.48 },
            .frozen_ocean => .{ 0.62, 0.80, 0.88 },
            .cold_ocean => .{ 0.05, 0.27, 0.55 },
            .ocean => .{ 0.06, 0.34, 0.72 },
            .warm_ocean => .{ 0.08, 0.50, 0.82 },
            .tropical => .{ 0.14, 0.72, 0.58 },
            .river => .{ 0.12, 0.46, 0.86 },
            .frozen_river => .{ 0.66, 0.82, 0.91 },
            .beach, .coastal_plains => .{ 0.90, 0.78, 0.48 },
            .stony_shore => .{ 0.48, 0.49, 0.47 },
            .snowy_beach => .{ 0.86, 0.92, 0.94 },
            .desert => .{ 0.86, 0.66, 0.30 },
            .badlands => .{ 0.76, 0.34, 0.16 },
            .snow_tundra => .{ 0.78, 0.88, 0.92 },
            .snowy_mountains => .{ 0.90, 0.94, 0.98 },
            .mountains => .{ 0.47, 0.38, 0.27 },
            .meadow => .{ 0.40, 0.67, 0.28 },
            .grove => .{ 0.20, 0.36, 0.22 },
            .snowy_slopes => .{ 0.84, 0.90, 0.95 },
            .jagged_peaks => .{ 0.55, 0.55, 0.52 },
            .frozen_peaks => .{ 0.72, 0.87, 0.96 },
            .stony_peaks => .{ 0.58, 0.53, 0.42 },
            .foothills => .{ 0.40, 0.56, 0.26 },
            .plains => .{ 0.38, 0.68, 0.25 },
            .dry_plains => .{ 0.64, 0.62, 0.31 },
            .forest => .{ 0.13, 0.43, 0.17 },
            .birch_forest => .{ 0.20, 0.55, 0.16 },
            .dark_forest => .{ 0.08, 0.26, 0.10 },
            .flower_forest => .{ 0.28, 0.62, 0.20 },
            .jungle => .{ 0.08, 0.50, 0.18 },
            .bamboo_jungle => .{ 0.12, 0.58, 0.10 },
            .sparse_jungle => .{ 0.16, 0.54, 0.16 },
            .taiga => .{ 0.18, 0.38, 0.31 },
            .snowy_taiga => .{ 0.50, 0.64, 0.58 },
            .old_growth_taiga => .{ 0.12, 0.32, 0.22 },
            .savanna => .{ 0.68, 0.66, 0.28 },
            .savanna_plateau => .{ 0.70, 0.67, 0.30 },
            .windswept_savanna => .{ 0.58, 0.58, 0.24 },
            .wooded_badlands => .{ 0.64, 0.39, 0.18 },
            .eroded_badlands => .{ 0.82, 0.30, 0.10 },
            .swamp, .marsh => .{ 0.20, 0.34, 0.18 },
            .mangrove_swamp => .{ 0.16, 0.30, 0.22 },
            .mushroom_fields => .{ 0.56, 0.38, 0.62 },
        };
    }

    fn colorForSample(sample: MapSample) [3]f32 {
        if (sample.water != .none) {
            const frozen = switch (sample.biome) {
                .frozen_ocean, .frozen_river => true,
                else => false,
            };
            if (frozen) return .{ 0.64, 0.82, 0.90 };

            const depth = @as(f32, @floatFromInt(@max(sample.sea_level - sample.terrain_height, 0)));
            const depth_mix = std.math.clamp(depth / 48.0, 0.0, 1.0);
            const shallow: [3]f32 = switch (sample.biome) {
                .warm_ocean, .tropical => .{ 0.08, 0.58, 0.78 },
                .cold_ocean => .{ 0.08, 0.38, 0.65 },
                else => if (sample.water == .inland) .{ 0.12, 0.48, 0.72 } else .{ 0.08, 0.43, 0.76 },
            };
            const deep: [3]f32 = switch (sample.biome) {
                .warm_ocean, .tropical => .{ 0.03, 0.30, 0.58 },
                else => .{ 0.025, 0.16, 0.43 },
            };
            return .{
                std.math.lerp(shallow[0], deep[0], depth_mix),
                std.math.lerp(shallow[1], deep[1], depth_mix),
                std.math.lerp(shallow[2], deep[2], depth_mix),
            };
        }

        const info = ColumnInfo{
            .height = sample.terrain_height,
            .biome = sample.biome,
            .is_ocean = false,
            .temperature = sample.temperature,
            .humidity = sample.humidity,
            .continentalness = sample.continentalness,
        };
        return shadeColor(getBiomeColor(info), sample.terrain_height, sample.sea_level);
    }

    fn colorForLiveBlock(block: BlockType) [3]f32 {
        return switch (block) {
            .grass, .tall_grass, .vine, .flower_red, .flower_yellow => .{ 0.34, 0.66, 0.23 },
            .leaves, .jungle_leaves, .acacia_leaves, .birch_leaves => .{ 0.11, 0.43, 0.13 },
            .spruce_leaves => .{ 0.15, 0.34, 0.27 },
            .mangrove_leaves => .{ 0.13, 0.34, 0.18 },
            .wood, .mangrove_log, .jungle_log, .acacia_log, .birch_log, .spruce_log, .mushroom_stem => .{ 0.38, 0.27, 0.15 },
            .water, .seagrass, .tall_seagrass, .kelp, .seaweed => .{ 0.08, 0.43, 0.76 },
            .sand => .{ 0.90, 0.78, 0.48 },
            .red_sand => .{ 0.76, 0.34, 0.16 },
            .stone, .cobblestone, .mossy_cobblestone, .gravel => .{ 0.48, 0.49, 0.47 },
            .dirt, .coarse_dirt, .rooted_dirt, .podzol => .{ 0.47, 0.36, 0.22 },
            .mud, .mangrove_roots => .{ 0.25, 0.29, 0.20 },
            .snow_block, .snow_layer => .{ 0.88, 0.93, 0.95 },
            .ice, .packed_ice, .blue_ice => .{ 0.64, 0.82, 0.90 },
            else => block_registry.getBlockDefinition(block).default_color,
        };
    }

    fn shadeColor(color: [3]f32, height: i32, sea_level: i32) [3]f32 {
        const elevation = @as(f32, @floatFromInt(@max(height - sea_level, 0)));
        const normalized_height = std.math.clamp(elevation / 128.0, 0.0, 1.0);
        const shade = std.math.lerp(0.92, 1.14, normalized_height);
        return .{
            std.math.clamp(color[0] * shade, 0.0, 1.0),
            std.math.clamp(color[1] * shade, 0.0, 1.0),
            std.math.clamp(color[2] * shade, 0.0, 1.0),
        };
    }
};

test "WorldMap chooses map-appropriate sampling reduction" {
    try std.testing.expectEqual(@as(u8, 0), WorldMap.reductionForScale(0.05));
    try std.testing.expectEqual(@as(u8, 0), WorldMap.reductionForScale(1.0));
    try std.testing.expectEqual(@as(u8, 1), WorldMap.reductionForScale(2.0));
    try std.testing.expectEqual(@as(u8, 1), WorldMap.reductionForScale(4.0));
    try std.testing.expectEqual(@as(u8, 2), WorldMap.reductionForScale(8.0));
    try std.testing.expectEqual(@as(u8, 3), WorldMap.reductionForScale(32.0));
    try std.testing.expectEqual(@as(u8, 4), WorldMap.reductionForScale(128.0));
}

test "WorldMap preview targets a 256 texel grid" {
    var map = try WorldMap.init(std.testing.allocator, 1024, 1024);
    defer map.deinit();
    try std.testing.expectEqual(@as(u32, 4), map.coarseSampleStep());
}

const FakeMapGenerator = struct {
    sample_count: usize = 0,
    last_reduction: u8 = 0,
    block_next_sample: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sample_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release_sample: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn generate(_: *anyopaque, _: *world_core.Chunk, _: ?*const bool) gen_interface.WorldgenError!void {}
    fn getSeed(_: *anyopaque) u64 {
        return 1;
    }
    fn getRegionInfo(_: *anyopaque, x: i32, z: i32) gen_interface.RegionInfo {
        return .{ .mood = .calm, .role = .transit, .focus = .none, .center_x = x, .center_z = z };
    }
    fn getColumnInfo(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        return getColumnInfoReduced(ptr, wx, wz, 0);
    }
    fn getColumnInfoReduced(ptr: *anyopaque, _: f32, _: f32, reduction: u8) ColumnInfo {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.block_next_sample.swap(false, .acq_rel)) {
            self.sample_started.store(true, .release);
            while (!self.release_sample.load(.acquire)) std.Options.debug_io.sleep(.fromNanoseconds(100_000), .boot) catch {};
        }
        self.sample_count += 1;
        self.last_reduction = reduction;
        return .{ .height = 64, .biome = .plains, .is_ocean = false, .temperature = 0.5, .humidity = 0.5, .continentalness = 0.5 };
    }
    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    const VTABLE = Generator.VTable{
        .generate = generate,
        .getSeed = getSeed,
        .getRegionInfo = getRegionInfo,
        .getColumnInfo = getColumnInfo,
        .getColumnInfoReduced = getColumnInfoReduced,
        .deinit = deinit,
    };

    fn generator(self: *@This()) Generator {
        return .{ .ptr = self, .vtable = &VTABLE, .info = .{ .name = "fake", .description = "fake", .version = 1 } };
    }
};

test "WorldMap coarse pass fills blocks with reduced samples" {
    var fake = FakeMapGenerator{};
    var map = try WorldMap.init(std.testing.allocator, 5, 3);
    defer map.deinit();

    const rendered = map.render(.{ .generator = fake.generator(), .center_x = 0, .center_z = 0, .scale = 4, .generation = 0, .overlay = null }, 2, 4);

    try std.testing.expect(rendered);
    try std.testing.expectEqual(@as(usize, 6), fake.sample_count);
    try std.testing.expectEqual(@as(u8, 4), fake.last_reduction);
    var alpha: usize = 3;
    while (alpha < map.worker_pixels.len) : (alpha += 4) try std.testing.expectEqual(@as(u8, 255), map.worker_pixels[alpha]);
}

test "WorldMap full pass samples every output pixel" {
    var fake = FakeMapGenerator{};
    var map = try WorldMap.init(std.testing.allocator, 5, 3);
    defer map.deinit();

    const rendered = map.render(.{ .generator = fake.generator(), .center_x = 0, .center_z = 0, .scale = 4, .generation = 0, .overlay = null }, 1, 2);

    try std.testing.expect(rendered);
    try std.testing.expectEqual(@as(usize, 15), fake.sample_count);
    try std.testing.expectEqual(@as(u8, 2), fake.last_reduction);
}

test "WorldMap terrain styling adds directional terrain contrast" {
    var fake = FakeMapGenerator{};
    var map = try WorldMap.init(std.testing.allocator, 3, 3);
    defer map.deinit();
    @memset(map.worker_pixels, 100);
    map.worker_heights[3] = 0;
    map.worker_heights[5] = 10;
    map.worker_heights[1] = 0;
    map.worker_heights[7] = 10;

    try std.testing.expect(map.applyTerrainStyling(.{ .generator = fake.generator(), .center_x = 0, .center_z = 0, .scale = 1, .generation = 0, .overlay = null }));

    try std.testing.expect(map.worker_pixels[(1 + 3) * 4] != 100);
}

test "WorldMap terrain styling outlines shorelines without shading water relief" {
    var fake = FakeMapGenerator{};
    var map = try WorldMap.init(std.testing.allocator, 3, 3);
    defer map.deinit();
    @memset(map.worker_pixels, 100);
    @memset(map.worker_heights, 64);
    @memset(map.worker_water, .none);
    map.worker_water[4] = .ocean;

    try std.testing.expect(map.applyTerrainStyling(.{ .generator = fake.generator(), .center_x = 0, .center_z = 0, .scale = 1, .generation = 0, .overlay = null }));

    try std.testing.expectEqual(@as(u8, 76), map.worker_pixels[4 * 4]);
}

test "WorldMap latest request supersedes an in-flight preview" {
    var fake = FakeMapGenerator{};
    fake.block_next_sample.store(true, .release);
    var map = try WorldMap.init(std.testing.allocator, 16, 16);
    defer map.deinit();
    defer fake.release_sample.store(true, .release);

    try map.requestUpdate(fake.generator(), 0, 0, 4, null);
    var started = false;
    for (0..10_000) |_| {
        if (fake.sample_started.load(.acquire)) {
            started = true;
            break;
        }
        std.Options.debug_io.sleep(.fromNanoseconds(100_000), .boot) catch {};
    }
    try std.testing.expect(started);

    try map.requestUpdate(fake.generator(), 256, -128, 8, null);
    fake.release_sample.store(true, .release);

    var latest: ?WorldMap.View = null;
    for (0..20_000) |_| {
        if (map.consumeCompleted()) |view| {
            latest = view;
            break;
        }
        std.Options.debug_io.sleep(.fromNanoseconds(100_000), .boot) catch {};
    }

    try std.testing.expect(latest != null);
    try std.testing.expectEqual(@as(u64, 2), latest.?.generation);
    try std.testing.expectEqual(@as(f32, 256), latest.?.center_x);
    try std.testing.expectEqual(@as(f32, -128), latest.?.center_z);
}

test "WorldMap loaded surface overrides procedural terrain with foliage" {
    var fake = FakeMapGenerator{};
    var map = try WorldMap.init(std.testing.allocator, 3, 3);
    defer map.deinit();
    const overlay = try map.createLoadedSurfaceOverlay();
    defer overlay.deinit();

    var heights = [_]i16{-1} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z);
    var blocks = [_]BlockType{.air} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z);
    heights[0] = 80;
    blocks[0] = .leaves;
    try overlay.ensureUnusedCapacity(1);
    overlay.appendAssumeCapacity(.{ .chunk_x = 0, .chunk_z = 0, .heights = heights, .blocks = blocks });
    overlay.finish();

    const request = WorldMap.Request{ .generator = fake.generator(), .center_x = 0, .center_z = 0, .scale = 1, .generation = 0, .overlay = overlay };
    try std.testing.expect(map.renderRows(request, 1, 2, 0, 1));

    const pixel = 2 + 2 * 3;
    const expected = WorldMap.colorForLiveBlock(.leaves);
    try std.testing.expectEqual(@as(i32, 80), map.worker_heights[pixel]);
    try std.testing.expectEqual(@as(u8, @intFromFloat(expected[0] * 255.0)), map.worker_pixels[pixel * 4]);
    try std.testing.expectEqual(@as(usize, 8), fake.sample_count);
}
