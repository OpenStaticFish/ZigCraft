const std = @import("std");
const fs = @import("fs");

const Player = @import("player.zig").Player;
const Vec3 = @import("engine-math").Vec3;
const GpuTimingResults = @import("engine-rhi").GpuTimingResults;
const WorldStats = @import("engine-ui").WorldStats;

pub const BENCHMARK_WORLD_SEED: u64 = 12345;
pub const BENCHMARK_SCHEMA_VERSION: u32 = 4;

pub const Scenario = enum {
    stationary,
    traversal,
    rapid_turn,
    teleport_eviction,

    pub fn parse(value: []const u8) !Scenario {
        if (std.mem.eql(u8, value, "stationary")) return .stationary;
        if (std.mem.eql(u8, value, "traversal")) return .traversal;
        if (std.mem.eql(u8, value, "rapid-turn")) return .rapid_turn;
        if (std.mem.eql(u8, value, "teleport-eviction")) return .teleport_eviction;
        return error.InvalidBenchmarkScenario;
    }

    pub fn name(self: Scenario) []const u8 {
        return switch (self) {
            .stationary => "stationary",
            .traversal => "traversal",
            .rapid_turn => "rapid-turn",
            .teleport_eviction => "teleport-eviction",
        };
    }
};

const Waypoint = struct {
    pos: Vec3,
    look: Vec3,
    duration: f32,
};

const STATIONARY_PATH = [_]Waypoint{.{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, -0.1, 0), .duration = 60.0 }};
const TRAVERSAL_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, 0, 0), .duration = 5.0 },
    .{ .pos = Vec3.init(200, 150, 200), .look = Vec3.init(0, -0.3, 1), .duration = 10.0 },
    .{ .pos = Vec3.init(-500, 80, 300), .look = Vec3.init(1, 0, -1), .duration = 10.0 },
    .{ .pos = Vec3.init(-900, 120, -200), .look = Vec3.init(0.2, -0.7, 0.1), .duration = 10.0 },
    .{ .pos = Vec3.init(300, 90, -800), .look = Vec3.init(-1, 0.25, 0.2), .duration = 10.0 },
    .{ .pos = Vec3.init(900, 160, 700), .look = Vec3.init(0.3, -0.9, -0.1), .duration = 15.0 },
};
const RAPID_TURN_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, 0, 0), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(0.2, -0.2, 1), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(-1, 0.1, 0), .duration = 1.0 },
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(-0.2, 0.2, -1), .duration = 1.0 },
};
const TELEPORT_EVICTION_PATH = [_]Waypoint{
    .{ .pos = Vec3.init(8, 100, 8), .look = Vec3.init(1, -0.1, 0), .duration = 4.0 },
    .{ .pos = Vec3.init(1_536, 140, 512), .look = Vec3.init(-1, -0.2, 0), .duration = 4.0 },
    .{ .pos = Vec3.init(-1_536, 120, 1_024), .look = Vec3.init(0, -0.1, -1), .duration = 4.0 },
    .{ .pos = Vec3.init(-1_024, 160, -1_536), .look = Vec3.init(1, -0.3, 0.2), .duration = 4.0 },
    .{ .pos = Vec3.init(1_024, 110, -1_024), .look = Vec3.init(0.1, -0.1, 1), .duration = 4.0 },
};

pub const Summary = struct {
    min: f64,
    avg: f64,
    max: f64,
    p1: f64,
    p5: f64,
    p50: f64,
    p95: f64,
    p99: f64,
};

pub const GpuSummary = struct {
    shadow_avg: f64,
    opaque_avg: f64,
    total_avg: f64,
    total: Summary,
};

pub const WorstFrame = struct {
    frame_index: u32,
    frame_ms: f64,
    gpu_total_ms: f64,
    dominant_gpu_pass: []const u8,
    dominant_gpu_pass_ms: f64,
};

pub const BuildMetadata = struct {
    mode: []const u8,
    world: []const u8,
    headless: bool = true,
    resolution: [2]u32 = .{ 1920, 1080 },
};

pub const BenchmarkProvenance = struct {
    gpu_adapter: []const u8 = "unknown",
    gpu_driver: []const u8 = "unknown",
    runner: []const u8 = "unknown",
    zig_toolchain: []const u8 = "unknown",
};

pub const BenchmarkCompletionEvidence = struct {
    scenario_completed: bool = false,
    sampled_duration_s: f64 = 0,
    requested_duration_s: f64 = 0,
    sampled_frame_count: u32 = 0,
    warmup_ready: bool = false,
    warmup_timed_out: bool = false,
    evidence_mode: bool = false,
};

pub const BenchmarkResults = struct {
    schema_version: u32 = BENCHMARK_SCHEMA_VERSION,
    artifact_type: []const u8 = "benchmark-result",
    preset: []const u8,
    scenario: []const u8,
    world_seed: u64,
    build: BuildMetadata,
    provenance: BenchmarkProvenance,
    render_distance: i32,
    gpu_memory_mb_avg: f64,
    gpu_memory_mb_max: f64,
    frames: u32,
    duration_s: f32,
    fps: Summary,
    frame_ms: Summary,
    max_frame_ms: f64,
    cpu_ms_avg: f64,
    gpu_ms: GpuSummary,
    draw_calls_avg: f64,
    vertices_avg: f64,
    chunks_rendered_avg: f64,
    worst_frame: WorstFrame,
    completion: BenchmarkCompletionEvidence,
};

const FrameSample = struct {
    cpu_ms: f32,
    fps: f32,
    gpu_shadow_ms: f32,
    gpu_opaque_ms: f32,
    gpu_total_ms: f32,
    draw_calls: u32,
    vertices: u64,
    chunks_rendered: u32,
    gpu_memory_mb: f32,
};

pub const SloThresholds = struct {
    fps_p1_min: f64,
    max_frame_ms: f64,
    draw_calls_max: f64,
    vertices_max: f64,
    gpu_memory_mb_max: f64,
};

pub const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    preset: []const u8,
    scenario: Scenario,
    render_distance: i32,
    duration_s: f32,
    world_seed: u64,
    build: BuildMetadata,
    provenance: BenchmarkProvenance,
    output_path: []const u8,
    start_ms: i64,
    elapsed_s: f32 = 0,
    sampled_s: f32 = 0,
    warmup_s: f32 = 1.0,
    settled_warmup_s: f32 = 0,
    warmup_ready: bool = false,
    warmup_timed_out: bool = false,
    evidence_mode: bool = false,
    scenario_elapsed_s: f32 = 0,
    samples: std.ArrayListUnmanaged(FrameSample) = .empty,

    pub fn init(allocator: std.mem.Allocator, preset: []const u8, scenario_name: []const u8, render_distance: i32, duration_s: f32, world_seed: u64, build_mode: []const u8, benchmark_world: []const u8, output_path: []const u8) !BenchmarkRunner {
        var runner = BenchmarkRunner{
            .allocator = allocator,
            .preset = preset,
            .scenario = try Scenario.parse(scenario_name),
            .render_distance = render_distance,
            .duration_s = duration_s,
            .world_seed = world_seed,
            .build = .{ .mode = build_mode, .world = benchmark_world },
            .provenance = provenanceFromEnvironment(),
            .output_path = output_path,
            .start_ms = nowMs(),
            .evidence_mode = environmentFlag("ZIGCRAFT_BENCHMARK_EVIDENCE"),
        };
        try runner.samples.ensureTotalCapacity(allocator, @max(@as(usize, 64), @as(usize, @intFromFloat(@ceil(duration_s * 120.0)))));
        return runner;
    }

    pub fn deinit(self: *BenchmarkRunner) void {
        self.samples.deinit(self.allocator);
    }

    pub fn applyPose(self: *const BenchmarkRunner, player: *Player) void {
        const pose = poseAtTime(self.scenario, self.scenario_elapsed_s);
        player.fly_mode = true;
        player.can_fly = true;
        player.noclip = true;
        player.velocity = Vec3.zero;
        player.is_grounded = false;
        player.position = pose.pos.sub(Vec3.init(0, Player.EYE_HEIGHT, 0));
        player.camera.position = pose.pos;
        player.camera.setYawPitch(yawFromLook(pose.look), pitchFromLook(pose.look));
        player.target_block = null;
    }

    pub fn recordFrame(self: *BenchmarkRunner, dt: f32, fps: f32, gpu: GpuTimingResults, world_stats: ?WorldStats, draw_calls: u32, gpu_memory_mb: f32) !void {
        if (!std.math.isFinite(dt) or dt <= 0.0) return error.InvalidBenchmarkSample;
        self.elapsed_s += dt;
        if (!self.warmup_ready) {
            const geometry_ready = if (world_stats) |stats| stats.chunks_rendered > 0 and stats.vertices_rendered > 0 else false;
            const queues_settled = if (world_stats) |stats| stats.gen_queue == 0 and stats.mesh_queue == 0 and stats.upload_queue == 0 else false;
            self.settled_warmup_s = if (geometry_ready and queues_settled) self.settled_warmup_s + dt else 0;
            if (self.elapsed_s >= self.warmup_s and self.settled_warmup_s >= 1.0) self.warmup_ready = true;
            if (wallElapsedSeconds(self) > 90.0) self.warmup_timed_out = true;
            return;
        }
        const shadow_ms = averageArray(&gpu.shadow_pass_ms);
        try self.samples.append(self.allocator, .{
            .cpu_ms = dt * 1000.0,
            .fps = if (dt > 0.000001) 1.0 / dt else fps,
            .gpu_shadow_ms = shadow_ms,
            .gpu_opaque_ms = gpu.opaque_pass_ms,
            .gpu_total_ms = gpu.total_gpu_ms,
            .draw_calls = draw_calls,
            .vertices = if (world_stats) |stats| stats.vertices_rendered else 0,
            .chunks_rendered = if (world_stats) |stats| stats.chunks_rendered else 0,
            .gpu_memory_mb = gpu_memory_mb,
        });
        self.sampled_s += dt;
        self.scenario_elapsed_s += dt;
    }

    pub fn isComplete(self: *const BenchmarkRunner) bool {
        return self.sampled_s >= self.duration_s or self.warmup_timed_out or wallElapsedSeconds(self) >= self.duration_s + self.warmup_s + 90.0;
    }

    pub fn writeResults(self: *const BenchmarkRunner) !void {
        const results = try self.makeResults();
        try validateResults(results);
        const json = try results_json(results, self.allocator);
        defer self.allocator.free(json);
        if (fs.path.dirname(self.output_path)) |dir| try fs.cwd().makePath(dir);
        var file = try fs.cwd().createFile(self.output_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }

    pub fn makeResults(self: *const BenchmarkRunner) !BenchmarkResults {
        const fps = try self.collect(fpsField);
        defer self.allocator.free(fps);
        const frame_ms = try self.collect(frameMsField);
        defer self.allocator.free(frame_ms);
        const gpu_total = try self.collect(gpuTotalField);
        defer self.allocator.free(gpu_total);

        var cpu_sum: f64 = 0;
        var shadow_sum: f64 = 0;
        var opaque_sum: f64 = 0;
        var gpu_sum: f64 = 0;
        var draw_sum: f64 = 0;
        var vertices_sum: f64 = 0;
        var chunks_sum: f64 = 0;
        var memory_sum: f64 = 0;
        var memory_max: f64 = 0;
        var worst = WorstFrame{ .frame_index = 0, .frame_ms = 0, .gpu_total_ms = 0, .dominant_gpu_pass = "none", .dominant_gpu_pass_ms = 0 };
        for (self.samples.items, 0..) |sample, index| {
            cpu_sum += sample.cpu_ms;
            shadow_sum += sample.gpu_shadow_ms;
            opaque_sum += sample.gpu_opaque_ms;
            gpu_sum += sample.gpu_total_ms;
            draw_sum += @floatFromInt(sample.draw_calls);
            vertices_sum += @floatFromInt(sample.vertices);
            chunks_sum += @floatFromInt(sample.chunks_rendered);
            memory_sum += sample.gpu_memory_mb;
            memory_max = @max(memory_max, sample.gpu_memory_mb);
            if (sample.cpu_ms > worst.frame_ms) {
                const opaque_is_dominant = sample.gpu_opaque_ms >= sample.gpu_shadow_ms;
                worst = .{ .frame_index = @intCast(index), .frame_ms = sample.cpu_ms, .gpu_total_ms = sample.gpu_total_ms, .dominant_gpu_pass = if (opaque_is_dominant) "opaque" else "shadow", .dominant_gpu_pass_ms = if (opaque_is_dominant) sample.gpu_opaque_ms else sample.gpu_shadow_ms };
            }
        }
        const count = @as(f64, @floatFromInt(@max(self.samples.items.len, 1)));
        var fps_summary = try summarizeSeries(self.allocator, fps);
        if (cpu_sum > 0) fps_summary.avg = @as(f64, @floatFromInt(self.samples.items.len)) / (cpu_sum / 1000.0);
        return .{
            .preset = self.preset,
            .scenario = self.scenario.name(),
            .world_seed = self.world_seed,
            .build = self.build,
            .provenance = self.provenance,
            .render_distance = self.render_distance,
            .gpu_memory_mb_avg = memory_sum / count,
            .gpu_memory_mb_max = memory_max,
            .frames = @intCast(self.samples.items.len),
            .duration_s = self.duration_s,
            .fps = fps_summary,
            .frame_ms = try summarizeSeries(self.allocator, frame_ms),
            .max_frame_ms = worst.frame_ms,
            .cpu_ms_avg = cpu_sum / count,
            .gpu_ms = .{ .shadow_avg = shadow_sum / count, .opaque_avg = opaque_sum / count, .total_avg = gpu_sum / count, .total = try summarizeSeries(self.allocator, gpu_total) },
            .draw_calls_avg = draw_sum / count,
            .vertices_avg = vertices_sum / count,
            .chunks_rendered_avg = chunks_sum / count,
            .worst_frame = worst,
            .completion = .{ .scenario_completed = self.sampled_s >= self.duration_s and !self.warmup_timed_out, .sampled_duration_s = self.sampled_s, .requested_duration_s = self.duration_s, .sampled_frame_count = @intCast(self.samples.items.len), .warmup_ready = self.warmup_ready, .warmup_timed_out = self.warmup_timed_out, .evidence_mode = self.evidence_mode },
        };
    }

    fn collect(self: *const BenchmarkRunner, comptime getter: fn (FrameSample) f32) ![]f32 {
        var values = try self.allocator.alloc(f32, self.samples.items.len);
        for (self.samples.items, 0..) |sample, index| values[index] = getter(sample);
        return values;
    }
};

pub fn thresholdsForPreset(preset: []const u8) SloThresholds {
    if (std.ascii.eqlIgnoreCase(preset, "low")) return .{ .fps_p1_min = 12, .max_frame_ms = 260, .draw_calls_max = 700, .vertices_max = 3_500_000, .gpu_memory_mb_max = 2200 };
    if (std.ascii.eqlIgnoreCase(preset, "medium")) return .{ .fps_p1_min = 8, .max_frame_ms = 260, .draw_calls_max = 2600, .vertices_max = 6_000_000, .gpu_memory_mb_max = 2400 };
    if (std.ascii.eqlIgnoreCase(preset, "high")) return .{ .fps_p1_min = 6, .max_frame_ms = 260, .draw_calls_max = 3600, .vertices_max = 8_500_000, .gpu_memory_mb_max = 2800 };
    if (std.ascii.eqlIgnoreCase(preset, "ultra")) return .{ .fps_p1_min = 4, .max_frame_ms = 260, .draw_calls_max = 4500, .vertices_max = 12_000_000, .gpu_memory_mb_max = 3400 };
    return .{ .fps_p1_min = 3, .max_frame_ms = 260, .draw_calls_max = 5500, .vertices_max = 16_000_000, .gpu_memory_mb_max = 4096 };
}

pub fn validateResults(results: BenchmarkResults) !void {
    const completion = results.completion;
    if (!completion.scenario_completed or !completion.warmup_ready or completion.warmup_timed_out or completion.sampled_frame_count == 0 or completion.sampled_duration_s < completion.requested_duration_s) return error.IncompleteBenchmarkScenario;
    if (results.frames != completion.sampled_frame_count or !std.math.isFinite(results.duration_s) or results.duration_s <= 0.0) return error.IncompleteBenchmarkScenario;
    inline for (.{ results.fps.min, results.fps.avg, results.fps.max, results.fps.p1, results.fps.p5, results.fps.p50, results.fps.p95, results.fps.p99, results.frame_ms.min, results.frame_ms.avg, results.frame_ms.max, results.frame_ms.p1, results.frame_ms.p5, results.frame_ms.p50, results.frame_ms.p95, results.frame_ms.p99, results.max_frame_ms, results.cpu_ms_avg, results.gpu_ms.shadow_avg, results.gpu_ms.opaque_avg, results.gpu_ms.total_avg, results.gpu_ms.total.min, results.gpu_ms.total.avg, results.gpu_ms.total.max, results.draw_calls_avg, results.vertices_avg, results.chunks_rendered_avg, results.gpu_memory_mb_avg, results.gpu_memory_mb_max }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteBenchmarkResult;
    }
    if (completion.evidence_mode and !validProvenance(results.provenance)) return error.MissingBenchmarkProvenance;
    const thresholds = thresholdsForResults(results);
    const breached = results.fps.p1 < thresholds.fps_p1_min or
        results.max_frame_ms > thresholds.max_frame_ms or
        results.draw_calls_avg > thresholds.draw_calls_max or
        results.vertices_avg > thresholds.vertices_max or
        results.gpu_memory_mb_max > thresholds.gpu_memory_mb_max;
    if (breached) {
        std.log.err("benchmark SLO breach for {s}: p1 FPS {d:.2}/{d:.2}, max frame {d:.2}/{d:.2}ms, draw calls {d:.2}/{d:.2}, vertices {d:.2}/{d:.2}, GPU memory {d:.2}/{d:.2}MiB", .{
            results.preset,
            results.fps.p1,
            thresholds.fps_p1_min,
            results.max_frame_ms,
            thresholds.max_frame_ms,
            results.draw_calls_avg,
            thresholds.draw_calls_max,
            results.vertices_avg,
            thresholds.vertices_max,
            results.gpu_memory_mb_max,
            thresholds.gpu_memory_mb_max,
        });
        return error.BenchmarkSloBreach;
    }
}

fn baselineRenderDistanceForPreset(preset: []const u8) i32 {
    if (std.ascii.eqlIgnoreCase(preset, "low")) return 6;
    if (std.ascii.eqlIgnoreCase(preset, "medium")) return 10;
    if (std.ascii.eqlIgnoreCase(preset, "high")) return 12;
    if (std.ascii.eqlIgnoreCase(preset, "ultra")) return 14;
    return 16;
}

fn thresholdsForResults(results: BenchmarkResults) SloThresholds {
    var thresholds = thresholdsForPreset(results.preset);
    const baseline = baselineRenderDistanceForPreset(results.preset);
    if (results.render_distance > baseline) {
        const extra_chunks: f64 = @floatFromInt(results.render_distance - baseline);
        thresholds.draw_calls_max *= 1.0 + extra_chunks * 0.05;
    }
    return thresholds;
}

fn results_json(results: BenchmarkResults, allocator: std.mem.Allocator) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, results, .{ .whitespace = .indent_2 });
}

fn summarizeSeries(allocator: std.mem.Allocator, values: []const f32) !Summary {
    if (values.len == 0) return .{ .min = 0, .avg = 0, .max = 0, .p1 = 0, .p5 = 0, .p50 = 0, .p95 = 0, .p99 = 0 };
    const sorted = try allocator.dupe(f32, values);
    defer allocator.free(sorted);
    std.sort.block(f32, sorted, {}, comptime std.sort.asc(f32));
    var sum: f64 = 0;
    for (sorted) |value| sum += value;
    return .{ .min = sorted[0], .avg = sum / @as(f64, @floatFromInt(sorted.len)), .max = sorted[sorted.len - 1], .p1 = percentile(sorted, 0.01), .p5 = percentile(sorted, 0.05), .p50 = percentile(sorted, 0.50), .p95 = percentile(sorted, 0.95), .p99 = percentile(sorted, 0.99) };
}

fn percentile(sorted: []const f32, fraction: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const position = std.math.clamp(fraction, 0.0, 1.0) * @as(f64, @floatFromInt(sorted.len - 1));
    const lower: usize = @intFromFloat(@floor(position));
    const upper = @min(lower + 1, sorted.len - 1);
    const blend = position - @as(f64, @floatFromInt(lower));
    return @as(f64, sorted[lower]) * (1.0 - blend) + @as(f64, sorted[upper]) * blend;
}

fn averageArray(values: []const f32) f32 {
    var sum: f32 = 0;
    for (values) |value| sum += value;
    return sum / @as(f32, @floatFromInt(values.len));
}

fn fpsField(sample: FrameSample) f32 {
    return sample.fps;
}
fn frameMsField(sample: FrameSample) f32 {
    return sample.cpu_ms;
}
fn gpuTotalField(sample: FrameSample) f32 {
    return sample.gpu_total_ms;
}

const Pose = struct { pos: Vec3, look: Vec3 };

fn poseAtTime(scenario: Scenario, elapsed_s: f32) Pose {
    const path = switch (scenario) {
        .stationary => &STATIONARY_PATH,
        .traversal => &TRAVERSAL_PATH,
        .rapid_turn => &RAPID_TURN_PATH,
        .teleport_eviction => &TELEPORT_EVICTION_PATH,
    };
    const interpolate = scenario != .teleport_eviction;
    var remaining = elapsed_s;
    const total = pathDuration(path);
    while (remaining >= total) remaining -= total;
    for (path, 0..) |waypoint, index| {
        const next = path[(index + 1) % path.len];
        const in_segment = if (interpolate) remaining <= waypoint.duration else remaining < waypoint.duration;
        if (in_segment or index == path.len - 1) {
            if (!interpolate) return .{ .pos = waypoint.pos, .look = waypoint.look.normalize() };
            const progress = std.math.clamp(remaining / @max(waypoint.duration, 0.0001), 0.0, 1.0);
            const smooth = progress * progress * (3.0 - 2.0 * progress);
            return .{ .pos = lerpVec3(waypoint.pos, next.pos, smooth), .look = lerpVec3(waypoint.look, next.look, smooth).normalize() };
        }
        remaining -= waypoint.duration;
    }
    unreachable;
}

fn pathDuration(path: []const Waypoint) f32 {
    var total: f32 = 0;
    for (path) |waypoint| total += waypoint.duration;
    return total;
}

fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a.add(b.sub(a).scale(t));
}

fn nowMs() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

fn wallElapsedSeconds(self: *const BenchmarkRunner) f32 {
    return @as(f32, @floatFromInt(@max(@as(i64, 0), nowMs() - self.start_ms))) / 1000.0;
}

fn environmentLabel(name: [:0]const u8) []const u8 {
    const raw = std.c.getenv(name) orelse return "unknown";
    const value = std.mem.span(raw);
    return if (value.len == 0) "unknown" else value;
}

fn environmentFlag(name: [:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    const value = std.mem.span(raw);
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.ascii.eqlIgnoreCase(value, "false") and !std.ascii.eqlIgnoreCase(value, "off");
}

fn provenanceFromEnvironment() BenchmarkProvenance {
    return .{ .gpu_adapter = environmentLabel("ZIGCRAFT_BENCHMARK_GPU_ADAPTER"), .gpu_driver = environmentLabel("ZIGCRAFT_BENCHMARK_GPU_DRIVER"), .runner = environmentLabel("ZIGCRAFT_BENCHMARK_RUNNER"), .zig_toolchain = environmentLabel("ZIGCRAFT_BENCHMARK_ZIG_TOOLCHAIN") };
}

fn validProvenance(provenance: BenchmarkProvenance) bool {
    inline for (.{ provenance.gpu_adapter, provenance.gpu_driver, provenance.runner, provenance.zig_toolchain }) |value| {
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "unknown")) return false;
    }
    return true;
}

fn yawFromLook(look: Vec3) f32 {
    return std.math.atan2(look.z, look.x);
}
fn pitchFromLook(look: Vec3) f32 {
    return std.math.atan2(look.y, @sqrt(look.x * look.x + look.z * look.z));
}

test "benchmark scenarios loop with smooth traversal and discontinuous teleports" {
    try std.testing.expectEqual(Scenario.traversal, try Scenario.parse("traversal"));
    try std.testing.expectError(error.InvalidBenchmarkScenario, Scenario.parse("unbounded"));
    const traversal_start = poseAtTime(.traversal, 0);
    const traversal_mid = poseAtTime(.traversal, 2.5);
    try std.testing.expect(traversal_mid.pos.x > traversal_start.pos.x);
    try std.testing.expectApproxEqAbs(traversal_start.pos.x, poseAtTime(.traversal, pathDuration(&TRAVERSAL_PATH)).pos.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), poseAtTime(.teleport_eviction, 3.9).pos.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1_536), poseAtTime(.teleport_eviction, 4.0).pos.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), poseAtTime(.teleport_eviction, pathDuration(&TELEPORT_EVICTION_PATH)).pos.x, 0.001);
}

test "benchmark percentiles interpolate between adjacent samples" {
    const samples = [_]f32{ 10, 20 };
    try std.testing.expectApproxEqAbs(@as(f64, 15), percentile(&samples, 0.5), 0.001);
}
