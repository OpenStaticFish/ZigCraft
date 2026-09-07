//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const ChunkKey = world_core.ChunkKey;
const worldToChunk = world_core.worldToChunk;
const worldToLocal = world_core.worldToLocal;
const world_meshing = @import("world-meshing");
const NeighborChunks = world_meshing.NeighborChunks;
const ChunkStorage = world_meshing.ChunkStorage;
const ChunkData = world_meshing.ChunkData;
const gen_interface = @import("world-worldgen");
const Generator = gen_interface.Generator;
const WorldMap = gen_interface.WorldMap;
const registry = @import("world-worldgen").registry;
const rhi_mod = @import("engine-rhi").rhi;
const RHI = rhi_mod.RHI;

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const IShadowScene = @import("engine-rhi").IShadowScene;
const ShadowConfig = @import("engine-rhi").ShadowConfig;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const MAX_MDI_CHUNKS = @import("world_renderer.zig").MAX_MDI_CHUNKS;
const RenderStats = @import("world_renderer.zig").RenderStats;
const RenderLayer = @import("world_renderer.zig").RenderLayer;
const ShadowStats = @import("world_renderer.zig").ShadowStats;
const ChunkStateCounts = world_core.ChunkStateCounts;
const VoxelCollisionWorld = @import("engine-physics").VoxelCollisionWorld;
const GraphicsWorldRenderView = @import("engine-rhi").IWorldRenderView;
const ILPVWorld = @import("engine-rhi").ILPVWorld;
const block_registry = @import("world-core").block_registry;
const LpvGridBuilder = @import("lpv_grid_builder.zig").LpvGridBuilder;

pub const DebugLightInfo = struct {
    sky: u4,
    block: u4,
};
const WorldStateData = world_core.WorldStateData;
pub const GpuMeshDispatch = struct {
    dispatch_fn: ?*const fn (ctx: *anyopaque) void,
    dispatch_ctx: ?*anyopaque,
};

pub const WorldOrchestration = struct {
    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(renderer: anytype, streamer: anytype, world: anytype, player_pos: Vec3, dt: f32) !void {
        renderer.beginFrame();
        try streamer.updateFrame(player_pos, dt);
        world.checkAutoSave();
    }

    /// Renders the full-detail chunk stream for the current camera.
    pub fn render(renderer: anytype, streamer: anytype, view_proj: Mat4, camera_pos: Vec3, layer: anytype) void {
        renderer.render(view_proj, camera_pos, streamer.getActiveRenderDistance(), layer);
    }
};
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const WorkerPool = engine_core.WorkerPool;
const Job = engine_core.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const log = engine_core.log;
const runtime_env = engine_core.runtime_env;

const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const SaveManager = @import("world-persistence").SaveManager;
const LoadResult = @import("world-persistence").LoadResult;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

/// Named statistics struct for World (extracted from anonymous return type for interface use).
pub const WorldStatsData = struct {
    chunks_loaded: usize,
    total_vertices: u64,
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};

pub const IWorld = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void,
        render: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        renderOpaque: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        renderFluid: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        deinit: *const fn (ptr: *anyopaque) void,
        getRenderStats: *const fn (ptr: *anyopaque) RenderStats,
        getStats: *const fn (ptr: *anyopaque) WorldStatsData,
        shadowScene: *const fn (ptr: *anyopaque) IShadowScene,
        enableSaveManager: *const fn (ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void,
        takeSaveFailureWarningCount: *const fn (ptr: *anyopaque) usize,
        pauseGeneration: *const fn (ptr: *anyopaque) void,
        isPaused: *const fn (ptr: *anyopaque) bool,
        collisionWorld: *const fn (ptr: *anyopaque) VoxelCollisionWorld,
        getBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType,
        setBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void,
        getColumnInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo,
        getDebugLightInfo: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo,
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo,
        getGenerator: *const fn (ptr: *anyopaque) Generator,
        getGeneratorName: *const fn (ptr: *anyopaque) []const u8,
        getRenderDistance: *const fn (ptr: *anyopaque) i32,
        setRenderDistance: *const fn (ptr: *anyopaque, distance: i32) void,
        getChunkStateCounts: *const fn (ptr: *anyopaque) ChunkStateCounts,
        isStartupBusy: *const fn (ptr: *anyopaque) bool,
        getWorldStateData: *const fn (ptr: *anyopaque) WorldStateData,
        lpvWorld: *const fn (ptr: *anyopaque) ILPVWorld,
        graphicsRenderView: *const fn (ptr: *anyopaque) GraphicsWorldRenderView,
        getGpuMeshDispatch: *const fn (ptr: *anyopaque) GpuMeshDispatch,
        isGpuCullingEnabled: *const fn (ptr: *anyopaque) bool,
    };

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: IWorld, player_pos: Vec3, dt: f32) !void {
        try self.vtable.update(self.ptr, player_pos, dt);
    }

    /// Renders all enabled world layers for the current camera.
    pub fn render(self: IWorld, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.render(self.ptr, view_proj, camera_pos);
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: IWorld, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.renderOpaque(self.ptr, view_proj, camera_pos);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: IWorld, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.renderFluid(self.ptr, view_proj, camera_pos);
    }

    /// Stops world jobs and releases streaming, meshing, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: IWorld) void {
        self.vtable.deinit(self.ptr);
    }

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: IWorld) RenderStats {
        return self.vtable.getRenderStats(self.ptr);
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: IWorld) WorldStatsData {
        return self.vtable.getStats(self.ptr);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: IWorld) IShadowScene {
        return self.vtable.shadowScene(self.ptr);
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: IWorld, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.vtable.enableSaveManager(self.ptr, save_dir_path, world_name);
    }

    /// Returns and clears the accumulated save-failure warning count.
    /// Use to surface persistence warnings without repeating already-consumed failures.
    pub fn takeSaveFailureWarningCount(self: IWorld) usize {
        return self.vtable.takeSaveFailureWarningCount(self.ptr);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: IWorld) void {
        self.vtable.pauseGeneration(self.ptr);
    }

    /// Reports whether chunk generation is currently paused.
    /// Rendering and loaded-chunk queries may still continue while paused.
    pub fn isPaused(self: IWorld) bool {
        return self.vtable.isPaused(self.ptr);
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: IWorld) VoxelCollisionWorld {
        return self.vtable.collisionWorld(self.ptr);
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.vtable.getBlock(self.ptr, world_x, world_y, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.vtable.setBlock(self.ptr, world_x, world_y, world_z, block);
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.vtable.getColumnInfo(self.ptr, world_x, world_z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: IWorld, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.vtable.getDebugLightInfo(self.ptr, world_x, world_y, world_z);
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.vtable.getRegionInfo(self.ptr, world_x, world_z);
    }

    /// Returns the active world generator interface.
    /// The generator is owned by the world runtime.
    pub fn getGenerator(self: IWorld) Generator {
        return self.vtable.getGenerator(self.ptr);
    }

    /// Returns the display name of the active world generator.
    /// The slice is owned by the generator metadata.
    pub fn getGeneratorName(self: IWorld) []const u8 {
        return self.vtable.getGeneratorName(self.ptr);
    }

    /// Returns the active chunk render distance in chunks.
    /// Used by streaming, renderer masks, and settings UI.
    pub fn getRenderDistance(self: IWorld) i32 {
        return self.vtable.getRenderDistance(self.ptr);
    }

    /// Changes the active chunk render distance.
    /// The streamer reconciles loaded chunks on subsequent updates.
    pub fn setRenderDistance(self: IWorld, distance: i32) void {
        self.vtable.setRenderDistance(self.ptr, distance);
    }

    /// Returns counts of chunks in each streaming/meshing state.
    /// Used for diagnostics and startup-busy checks.
    pub fn getChunkStateCounts(self: IWorld) ChunkStateCounts {
        return self.vtable.getChunkStateCounts(self.ptr);
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: IWorld) bool {
        return self.vtable.isStartupBusy(self.ptr);
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: IWorld) WorldStateData {
        return self.vtable.getWorldStateData(self.ptr);
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: IWorld) ILPVWorld {
        return self.vtable.lpvWorld(self.ptr);
    }

    /// Returns the graphics-facing world render view.
    /// Use for renderer systems that need chunk buffers without full world mutation access.
    pub fn graphicsRenderView(self: IWorld) GraphicsWorldRenderView {
        return self.vtable.graphicsRenderView(self.ptr);
    }

    /// Returns the optional GPU meshing dispatch hook.
    /// The hook is null when GPU meshing is unavailable.
    pub fn getGpuMeshDispatch(self: IWorld) GpuMeshDispatch {
        return self.vtable.getGpuMeshDispatch(self.ptr);
    }

    /// Returns true when chunk visibility is currently produced by GPU culling.
    pub fn isGpuCullingEnabled(self: IWorld) bool {
        return self.vtable.isGpuCullingEnabled(self.ptr);
    }

    /// Narrows the world facade to simulation and mutation operations.
    /// Use to avoid giving consumers render or telemetry access.
    pub fn simulation(self: IWorld) IWorldSimulation {
        return .{ .world = self };
    }

    /// Narrows the world facade to render-facing operations.
    /// Use by graphics systems that should not mutate simulation state.
    pub fn renderView(self: IWorld) IWorldRenderView {
        return .{ .world = self };
    }

    /// Narrows the world facade to diagnostics and settings operations.
    /// Use by UI/debug systems that only need world state snapshots.
    pub fn telemetry(self: IWorld) IWorldTelemetry {
        return .{ .world = self };
    }
};

pub const IWorldSimulation = struct {
    world: IWorld,

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: IWorldSimulation, player_pos: Vec3, dt: f32) !void {
        try self.world.update(player_pos, dt);
    }

    /// Stops world jobs and releases streaming, meshing, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: IWorldSimulation) void {
        self.world.deinit();
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: IWorldSimulation, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.world.enableSaveManager(save_dir_path, world_name);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: IWorldSimulation) void {
        self.world.pauseGeneration();
    }

    /// Reports whether chunk generation is currently paused.
    /// Rendering and loaded-chunk queries may still continue while paused.
    pub fn isPaused(self: IWorldSimulation) bool {
        return self.world.isPaused();
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: IWorldSimulation) VoxelCollisionWorld {
        return self.world.collisionWorld();
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.world.setBlock(world_x, world_y, world_z, block);
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: IWorldSimulation, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.world.getColumnInfo(world_x, world_z);
    }
};

pub const IWorldRenderView = struct {
    world: IWorld,

    /// Renders all enabled world layers for the current camera.
    pub fn render(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.world.render(view_proj, camera_pos);
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.world.renderOpaque(view_proj, camera_pos);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.world.renderFluid(view_proj, camera_pos);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: IWorldRenderView) IShadowScene {
        return self.world.shadowScene();
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: IWorldRenderView) ILPVWorld {
        return self.world.lpvWorld();
    }

    /// Returns the graphics-facing world render view.
    /// Use for renderer systems that need chunk buffers without full world mutation access.
    pub fn graphicsRenderView(self: IWorldRenderView) GraphicsWorldRenderView {
        return self.world.graphicsRenderView();
    }

    /// Returns the optional GPU meshing dispatch hook.
    /// The hook is null when GPU meshing is unavailable.
    pub fn getGpuMeshDispatch(self: IWorldRenderView) GpuMeshDispatch {
        return self.world.getGpuMeshDispatch();
    }
};

pub const IWorldTelemetry = struct {
    world: IWorld,

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: IWorldTelemetry) RenderStats {
        return self.world.getRenderStats();
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: IWorldTelemetry) WorldStatsData {
        return self.world.getStats();
    }

    /// Returns the active chunk render distance in chunks.
    /// Used by streaming, renderer masks, and settings UI.
    pub fn getRenderDistance(self: IWorldTelemetry) i32 {
        return self.world.getRenderDistance();
    }

    /// Changes the active chunk render distance.
    /// The streamer reconciles loaded chunks on subsequent updates.
    pub fn setRenderDistance(self: IWorldTelemetry, distance: i32) void {
        self.world.setRenderDistance(distance);
    }

    /// Returns counts of chunks in each streaming/meshing state.
    /// Used for diagnostics and startup-busy checks.
    pub fn getChunkStateCounts(self: IWorldTelemetry) ChunkStateCounts {
        return self.world.getChunkStateCounts();
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: IWorldTelemetry) bool {
        return self.world.isStartupBusy();
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: IWorldTelemetry) WorldStateData {
        return self.world.getWorldStateData();
    }

    /// Returns the display name of the active world generator.
    /// The slice is owned by the generator metadata.
    pub fn getGeneratorName(self: IWorldTelemetry) []const u8 {
        return self.world.getGeneratorName();
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.world.getDebugLightInfo(world_x, world_y, world_z);
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: IWorldTelemetry, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.world.getRegionInfo(world_x, world_z);
    }

    /// Returns the active world generator interface.
    /// The generator is owned by the world runtime.
    pub fn getGenerator(self: IWorldTelemetry) Generator {
        return self.world.getGenerator();
    }
};

pub const ChunkPos = struct { x: i32, z: i32 };

pub const World = struct {
    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        render_distance: i32,
        seed: u64,
        rhi: RHI,
        atlas: *const TextureAtlas,
        generator_index: usize = 0,
    };

    storage: ChunkStorage,
    streamer: *WorldStreamer,
    renderer: *WorldRenderer,
    allocator: std.mem.Allocator,
    generator: Generator,
    render_distance: i32,
    rhi: RHI,
    paused: bool = false,
    safe_mode: bool,
    safe_render_distance: i32,
    map_mutation_revision: std.atomic.Value(u64) = .init(0),

    // Save system (Issue #380)
    save_manager: ?*SaveManager,

    // GPU Block Buffer (Batch 5 - Issue #389)
    gpu_block_buffer: ?*GpuBlockBuffer,

    // Mutation coordinator (Issue #550)
    mutation: WorldMutationCoordinator,

    // LPV lighting grid builder (Issue #789)
    lpv_grid_builder: LpvGridBuilder,

    /// Creates a world runtime with full-detail chunk streaming, meshing, rendering, and persistence.
    /// The allocator, generator, and RHI-backed resources must remain valid for the world lifetime. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn init(options: InitOptions) !*World {
        const allocator = options.allocator;
        const world = try allocator.create(World);
        errdefer allocator.destroy(world);

        const storage = ChunkStorage.init(allocator);
        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const safe_render_distance: i32 = @max(options.render_distance, 2);
        const streamer_render_distance = safe_render_distance;
        const max_uploads: usize = if (strict_safe_mode)
            @as(usize, 4)
        else if (safe_mode)
            @as(usize, 8)
        else
            @as(usize, 32);
        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: limiting uploads to {} per frame", .{max_uploads});
        }

        world.* = .{
            .storage = storage,
            .streamer = undefined,
            .renderer = undefined,
            .allocator = allocator,
            .render_distance = safe_render_distance,
            .generator = try registry.createGenerator(options.generator_index, options.seed, allocator),
            .rhi = options.rhi,
            .paused = false,
            .safe_mode = safe_mode,
            .safe_render_distance = safe_render_distance,
            .map_mutation_revision = .init(0),
            .save_manager = null,
            .gpu_block_buffer = null,
            .mutation = undefined,
            .lpv_grid_builder = undefined,
        };
        errdefer world.generator.deinit(allocator);

        world.lpv_grid_builder = LpvGridBuilder.init(&world.storage);

        log.log.info("World.init: initializing WorldRenderer", .{});
        const culling_size = options.rhi.query().getRenderResolution();
        var culling_system = if (!safe_mode) blk: {
            break :blk options.rhi.cullingFactory().createCullingSystem(allocator, MAX_MDI_CHUNKS) catch |err| {
                log.log.warn("GPU culling init failed ({}), falling back to CPU culling", .{err});
                break :blk null;
            };
        } else null;
        errdefer if (culling_system) |system| system.deinit();

        world.renderer = try WorldRenderer.init(allocator, options.rhi.resourceManager(), options.rhi.renderContext(), options.rhi.query(), &world.storage, options.atlas, options.rhi, &culling_system, culling_size, safe_mode);
        errdefer world.renderer.deinit();

        world.gpu_block_buffer = world.renderer.getGpuBlockBuffer();

        world.mutation = WorldMutationCoordinator.init(
            &world.storage,
            allocator,
            world.gpu_block_buffer,
            world.renderer.getGpuMesher() != null,
        );

        log.log.info("World.init: initializing WorldStreamer (render_distance={}, requested={})", .{ streamer_render_distance, safe_render_distance });
        world.streamer = try WorldStreamer.init(allocator, &world.storage, world.generator, options.atlas, streamer_render_distance, world.renderer.vertex_allocator, max_uploads, world.gpu_block_buffer, world.renderer.getGpuMesher());
        errdefer world.streamer.deinit();

        return world;
    }

    /// Stops world jobs and releases streaming, meshing, rendering, and persistence resources.
    /// No borrowed world sub-interfaces may be used after this returns.
    pub fn deinit(self: *World) void {
        self.pauseGeneration();

        self.rhi.query().waitIdle();

        if (self.save_manager) |sm| {
            self.saveAllModifiedChunks();
            sm.deinit();
        }

        self.streamer.deinit();

        // Storage must be deinitialized before renderer because it uses the renderer's vertex_allocator
        // to free mesh buffers.
        // On shutdown we can skip per-chunk GPU frees since the allocator is destroyed next.
        self.storage.deinitWithoutRHI();
        self.renderer.deinit();

        self.generator.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Pauses background chunk generation and streaming work.
    /// Already loaded chunks remain accessible and renderable.
    pub fn pauseGeneration(self: *World) void {
        self.paused = true;
        self.streamer.setPaused(true);
    }

    /// Resumes background chunk generation after a pause.
    /// Queued work may continue on subsequent `update` calls.
    pub fn resumeGeneration(self: *World) void {
        self.paused = false;
        self.streamer.setPaused(false);
    }

    /// Attaches persistence to the world using a save directory and world name.
    /// May load metadata or create save structures; call before relying on autosave. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn enableSaveManager(self: *World, save_dir_path: []const u8, world_name: []const u8) !void {
        const seed = self.generator.getSeed();
        const gen_name = self.generator.info.name;
        self.save_manager = try SaveManager.init(self.allocator, save_dir_path, world_name, seed, gen_name);
        self.streamer.setSaveManager(self.save_manager);
    }

    /// Returns and clears the accumulated save-failure warning count.
    /// Use to surface persistence warnings without repeating already-consumed failures.
    pub fn takeSaveFailureWarningCount(self: *World) usize {
        const sm = self.save_manager orelse return 0;
        return sm.takePersistedFailedSaveCount();
    }

    fn enqueueModifiedChunks(self: *World, sm: *SaveManager) std.ArrayListUnmanaged(ChunkKey) {
        var dirty_keys = std.ArrayListUnmanaged(ChunkKey).empty;

        self.storage.chunks_mutex.lock();
        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.modified and chunk.generated) {
                dirty_keys.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.log.err("Failed to track dirty chunk ({}, {}) for save: {}", .{ entry.key_ptr.*.x, entry.key_ptr.*.z, err });
                    continue;
                };

                chunk.pin();
                sm.enqueueSave(chunk);
                chunk.modified = false;
                chunk.unpin();
            }
        }
        self.storage.chunks_mutex.unlock();

        return dirty_keys;
    }

    fn remarkFailedSaves(self: *World, failed: []ChunkKey) void {
        self.storage.chunks_mutex.lock();
        for (failed) |key| {
            if (self.storage.chunks.get(key)) |data| {
                data.chunk.modified = true;
            }
        }
        self.storage.chunks_mutex.unlock();
    }

    /// Synchronously saves chunks marked dirty by mutations or streaming.
    /// Returns errors from persistence and leaves unsaved chunks dirty for later retry.
    pub fn saveAllModifiedChunks(self: *World) void {
        const sm = self.save_manager orelse return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred while saving modified chunks", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// Runs autosave bookkeeping and persists dirty chunks when the save interval has elapsed.
    /// No work occurs when persistence is disabled.
    pub fn checkAutoSave(self: *World) void {
        const sm = self.save_manager orelse return;
        if (!sm.shouldAutoSave()) return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        sm.markAutoSaved();
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred during auto-save", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// Attempts to load a chunk from persistent storage.
    /// Returns `null` when no saved data exists for the requested chunk.
    pub fn loadChunkFromSave(self: *World, cx: i32, cz: i32, out_chunk: *Chunk) LoadResult {
        const sm = self.save_manager orelse return .not_found;
        return sm.loadChunk(cx, cz, out_chunk);
    }

    /// Set render distance and trigger chunk loading/unloading update
    pub fn setRenderDistance(self: *World, distance: i32) void {
        const requested = @max(distance, 2);
        const target = if (self.safe_mode) @min(requested, self.safe_render_distance) else requested;

        if (self.render_distance != target) {
            if (self.safe_mode and target != requested) {
                log.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance {} -> {}", .{ distance, target });
            }
            log.log.info("Render distance changed: {} -> {}", .{ self.render_distance, target });
            self.render_distance = target;
            self.applyRenderDistance();
        }
    }

    fn applyRenderDistance(self: *World) void {
        self.streamer.setRenderDistance(self.render_distance);
    }

    /// Returns a resident chunk or creates storage for it.
    /// May allocate chunk data and enqueue follow-up generation or meshing work. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        return self.storage.getOrCreate(chunk_x, chunk_z);
    }

    /// Returns the block type at world-space coordinates.
    /// Returns air or generated fallback behavior when the target chunk is unavailable.
    pub fn getBlock(self: *World, world_x: i32, world_y: i32, world_z: i32) BlockType {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    /// Returns packed light debug data for a world-space voxel when available.
    /// Returns `null` when the target chunk or light sample is unavailable.
    pub fn getDebugLightInfo(self: *World, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return null;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return null;
        const local = worldToLocal(world_x, world_z);
        const light = data.chunk.getLight(local.x, @intCast(world_y), local.z);
        return .{
            .sky = light.getSkyLight(),
            .block = light.getBlockLight(),
        };
    }

    /// Returns generator column metadata for a world X/Z column.
    /// Does not require the chunk to be resident.
    pub fn getColumnInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.generator.getColumnInfo(@floatFromInt(world_x), @floatFromInt(world_z));
    }

    /// Returns generator region metadata for a world X/Z location.
    /// Used by debug UI and terrain diagnostics.
    pub fn getRegionInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.generator.getRegionInfo(world_x, world_z);
    }

    /// Applies a block mutation at world-space coordinates.
    /// Updates chunk data and schedules affected mesh/render state refreshes. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        const result = (try self.mutation.applyBlockMutation(world_x, world_y, world_z, block)) orelse return;
        self.storage.markMapSurfaceChanged();
        _ = self.map_mutation_revision.fetchAdd(1, .release);
        self.streamer.enqueueMutationLighting(&self.mutation, result) catch |err| {
            log.log.warn("Failed to enqueue block lighting update, applying synchronously: {}", .{err});
            try self.mutation.updateLighting(result);
            self.streamer.requestDirtyRemesh(result.chunk_x, result.chunk_z);
        };
    }

    pub fn getMapSurfaceRevision(self: *const World) u64 {
        return self.map_mutation_revision.load(.acquire);
    }

    pub fn getMapResidencyRevision(self: *const World) u64 {
        return self.storage.getMapSurfaceRevision();
    }

    /// Copies actual loaded top surfaces for a map viewport. The map worker
    /// receives only immutable values, never live chunk pointers.
    pub fn captureLoadedMapSurface(
        self: *World,
        overlay: *WorldMap.LoadedSurfaceOverlay,
        center_x: f32,
        center_z: f32,
        scale: f32,
        width: u32,
        height: u32,
    ) !void {
        const half_width = @as(f32, @floatFromInt(width)) * scale * 0.5;
        const half_height = @as(f32, @floatFromInt(height)) * scale * 0.5;
        const min_world_x: i32 = @intFromFloat(@floor(center_x - half_width));
        const max_world_x: i32 = @intFromFloat(@ceil(center_x + half_width));
        const min_world_z: i32 = @intFromFloat(@floor(center_z - half_height));
        const max_world_z: i32 = @intFromFloat(@ceil(center_z + half_height));
        const min_chunk = worldToChunk(min_world_x, min_world_z);
        const max_chunk = worldToChunk(max_world_x, max_world_z);

        try overlay.ensureUnusedCapacity(self.storage.count());

        // Match mutation/lighting lock order. Generated chunks are immutable
        // for this short copy except for mutations, which lighting_mutex blocks.
        self.storage.lighting_mutex.lock();
        self.storage.chunks_mutex.lockShared();

        var iterator = self.storage.iteratorUnsafe();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.x < min_chunk.chunk_x or key.x > max_chunk.chunk_x or key.z < min_chunk.chunk_z or key.z > max_chunk.chunk_z) continue;
            const chunk = &entry.value_ptr.*.chunk;
            // Generation rebuilds the cached surface before publishing the
            // chunk as generated. Skip chunks still owned by a worker so this
            // shared-lock copy never races that unlocked rebuild.
            if (!chunk.generated or chunk.state != .generated) continue;
            if (!chunk.mapSurfaceIsCurrent()) _ = chunk.rebuildMapSurface();
            overlay.appendAssumeCapacity(.{
                .chunk_x = key.x,
                .chunk_z = key.z,
                .heights = chunk.map_surface_heights,
                .blocks = chunk.map_surface_blocks,
            });
        }
        self.storage.chunks_mutex.unlockShared();
        self.storage.lighting_mutex.unlock();
        overlay.finish();
    }

    /// Get chunk data at chunk coordinates.
    /// WARNING: Returned pointer is only guaranteed valid if called from the main thread
    /// and used before the next call to World.update (which may unload chunks).
    /// If accessing from a background thread, the chunk must be pinned first.
    pub fn getChunk(self: *World, cx: i32, cz: i32) ?*ChunkData {
        return self.storage.get(cx, cz);
    }

    /// Advances world streaming, generation, meshing, autosave, and runtime queues for one frame.
    /// `player_pos` drives chunk residency; `dt` is frame time in seconds. Propagates errors from streaming, persistence, meshing, or mutation subsystems.
    pub fn update(self: *World, player_pos: Vec3, dt: f32) !void {
        try WorldOrchestration.update(self.renderer, self.streamer, self, player_pos, dt);
    }

    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3) void {
        WorldOrchestration.render(self.renderer, self.streamer, view_proj, camera_pos, .all);
    }

    /// Renders opaque terrain and world geometry for the current camera.
    /// Fluid and transparent passes are intentionally excluded.
    pub fn renderOpaque(self: *World, view_proj: Mat4, camera_pos: Vec3) void {
        WorldOrchestration.render(self.renderer, self.streamer, view_proj, camera_pos, .terrain);
    }

    /// Renders fluid surfaces for the current camera.
    /// Opaque depth and reflection resources should already be prepared by the renderer.
    pub fn renderFluid(self: *World, view_proj: Mat4, camera_pos: Vec3) void {
        WorldOrchestration.render(self.renderer, self.streamer, view_proj, camera_pos, .fluid);
    }

    /// Renders world geometry into the active shadow pass.
    /// The shadow renderer provides receiver-volume-derived caster bounds.
    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
        _ = shadow_config; // Bounds already encode the configured caster reach.
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, caster_min, caster_max);
    }

    /// Returns the world shadow-scene interface used by the shadow renderer.
    /// The returned interface borrows the world and must not outlive it.
    pub fn shadowScene(self: *World) IShadowScene {
        return .{
            .ptr = self,
            .vtable = &.{
                .renderShadowPass = renderShadowPassWrapper,
            },
        };
    }

    fn renderShadowPassWrapper(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderShadowPass(light_space_matrix, camera_pos, caster_min, caster_max, shadow_config);
    }

    /// Returns renderer counters for the latest world render work.
    /// Used by HUDs and diagnostics; values are snapshots, not live references.
    pub fn getRenderStats(self: *const World) RenderStats {
        return self.renderer.last_render_stats;
    }

    /// Returns the voxel collision query interface for loaded world data.
    /// The interface borrows world storage and follows world lifetime.
    pub fn collisionWorld(self: *World) VoxelCollisionWorld {
        return .{ .ptr = self, .vtable = &COLLISION_VTABLE };
    }

    /// Returns the world data interface used by LPV lighting injection.
    /// The returned interface borrows the world and must not outlive it.
    pub fn lpvWorld(self: *World) ILPVWorld {
        return self.lpv_grid_builder.interface();
    }

    /// Shadow stats reset in `beginFrame()` and accumulate across all shadow passes until the next frame.
    /// Call `resetShadowStats()` manually if you need per-cascade stats.
    pub fn getShadowStats(self: *const World) ShadowStats {
        return self.renderer.last_shadow_stats;
    }

    /// Clears accumulated shadow rendering counters.
    /// Use before measuring a fresh shadow pass or diagnostic interval.
    pub fn resetShadowStats(self: *World) void {
        self.renderer.resetShadowStats();
    }

    /// Counts chunks by state for the debug inspector overlay.
    /// Note: Holds a shared mutex lock while iterating all chunks.
    /// May cause minor contention with world streamer threads under heavy load.
    pub fn getChunkStateCounts(self: *World) ChunkStateCounts {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var counts: ChunkStateCounts = .{};
        counts.total = @intCast(self.storage.chunks.count());

        var iter = self.storage.chunks.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr.*.chunk.state;
            switch (state) {
                .missing => counts.missing += 1,
                .generating => counts.generating += 1,
                .meshing => counts.meshing += 1,
                .renderable => counts.renderable += 1,
                else => counts.other_states += 1,
            }
            if (entry.value_ptr.*.chunk.dirty) counts.dirty += 1;
        }
        return counts;
    }

    /// Returns chunk, vertex, and queue counts for world runtime diagnostics.
    /// The values reflect the current world manager state.
    pub fn getStats(self: *World) WorldStatsData {
        const streamer_stats = self.streamer.getStats();

        return .{
            .chunks_loaded = self.storage.count(),
            // Runtime callers only need queue and chunk counts here. Recomputing the
            // full loaded-vertex sum every frame walks every chunk mesh under lock and
            // can stall the main thread while the world is streaming.
            .total_vertices = self.renderer.last_render_stats.vertices_rendered,
            .gen_queue = streamer_stats.gen_queue,
            .mesh_queue = streamer_stats.mesh_queue,
            .upload_queue = streamer_stats.upload_queue,
        };
    }

    /// Reports whether startup generation or streaming still has visible work pending.
    /// Used by smoke tests and startup diagnostics.
    pub fn isStartupBusy(self: *World) bool {
        return self.streamer.isStartupBusy(self.render_distance);
    }

    /// Returns compact world state telemetry for UI and diagnostics.
    /// The returned struct is a snapshot of runtime state.
    pub fn getWorldStateData(self: *World) WorldStateData {
        const stats = self.getStats();
        return .{
            .generator_name = self.generator.info.name,
            .seed = self.generator.getSeed(),
            .gen_queue = @as(u32, @intCast(stats.gen_queue)),
            .mesh_queue = @as(u32, @intCast(stats.mesh_queue)),
            .upload_queue = @as(u32, @intCast(stats.upload_queue)),
        };
    }

    /// Returns the full `IWorld` facade for this world instance.
    /// The facade borrows the world and must not outlive it.
    pub fn interface(self: *World) IWorld {
        return .{ .ptr = self, .vtable = &IWORLD_VTABLE };
    }

    /// Narrows the world facade to render-facing operations.
    /// Use by graphics systems that should not mutate simulation state.
    pub fn renderView(self: *World) GraphicsWorldRenderView {
        return .{ .ptr = self, .vtable = &WORLD_RENDER_VIEW_VTABLE };
    }

    const IWORLD_VTABLE = IWorld.VTable{
        .update = iupdate,
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
        .deinit = ideinit,
        .getRenderStats = igetRenderStats,
        .getStats = igetStats,
        .shadowScene = ishadowScene,
        .enableSaveManager = ienableSaveManager,
        .takeSaveFailureWarningCount = itakeSaveFailureWarningCount,
        .pauseGeneration = ipauseGeneration,
        .isPaused = iisPaused,
        .collisionWorld = icollisionWorld,
        .getBlock = igetBlock,
        .setBlock = isetBlock,
        .getColumnInfo = igetColumnInfo,
        .getDebugLightInfo = igetDebugLightInfo,
        .getRegionInfo = igetRegionInfo,
        .getGenerator = igetGenerator,
        .getGeneratorName = igetGeneratorName,
        .getRenderDistance = igetRenderDistance,
        .setRenderDistance = isetRenderDistance,
        .getChunkStateCounts = igetChunkStateCounts,
        .isStartupBusy = iisStartupBusy,
        .getWorldStateData = igetWorldStateData,
        .lpvWorld = ilpvWorld,
        .graphicsRenderView = igraphicsRenderView,
        .getGpuMeshDispatch = igetGpuMeshDispatch,
        .isGpuCullingEnabled = iisGpuCullingEnabled,
    };

    const WORLD_RENDER_VIEW_VTABLE = GraphicsWorldRenderView.VTable{
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
    };

    fn iupdate(ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.update(player_pos, dt);
    }

    fn irender(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.render(view_proj, camera_pos);
    }

    fn irenderOpaque(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderOpaque(view_proj, camera_pos);
    }

    fn irenderFluid(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderFluid(view_proj, camera_pos);
    }

    fn ideinit(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn igetRenderStats(ptr: *anyopaque) RenderStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRenderStats();
    }

    fn igetStats(ptr: *anyopaque) WorldStatsData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getStats();
    }

    fn ishadowScene(ptr: *anyopaque) IShadowScene {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.shadowScene();
    }

    fn ienableSaveManager(ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.enableSaveManager(save_dir_path, world_name);
    }

    fn itakeSaveFailureWarningCount(ptr: *anyopaque) usize {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.takeSaveFailureWarningCount();
    }

    fn ipauseGeneration(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.pauseGeneration();
    }

    fn iisPaused(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.paused;
    }

    fn icollisionWorld(ptr: *anyopaque) VoxelCollisionWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.collisionWorld();
    }

    fn igetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getBlock(world_x, world_y, world_z);
    }

    fn isetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.setBlock(world_x, world_y, world_z, block);
    }

    fn igetColumnInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(world_x, world_z);
    }

    fn igetDebugLightInfo(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getDebugLightInfo(world_x, world_y, world_z);
    }

    fn igetRegionInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn igetGenerator(ptr: *anyopaque) Generator {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator;
    }

    fn igetGeneratorName(ptr: *anyopaque) []const u8 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator.info.name;
    }

    fn igetRenderDistance(ptr: *anyopaque) i32 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.render_distance;
    }

    fn isetRenderDistance(ptr: *anyopaque, distance: i32) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.setRenderDistance(distance);
    }

    fn igetChunkStateCounts(ptr: *anyopaque) ChunkStateCounts {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getChunkStateCounts();
    }

    fn iisStartupBusy(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isStartupBusy();
    }

    fn igetWorldStateData(ptr: *anyopaque) WorldStateData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getWorldStateData();
    }

    fn ilpvWorld(ptr: *anyopaque) ILPVWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.lpvWorld();
    }

    fn igraphicsRenderView(ptr: *anyopaque) GraphicsWorldRenderView {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.renderView();
    }

    fn igetGpuMeshDispatch(ptr: *anyopaque) GpuMeshDispatch {
        const self: *World = @ptrCast(@alignCast(ptr));
        return if (self.renderer.getGpuMesher() != null)
            .{ .dispatch_fn = WorldRenderer.processGpuMeshing, .dispatch_ctx = @ptrCast(self.renderer) }
        else
            .{ .dispatch_fn = null, .dispatch_ctx = null };
    }

    fn iisGpuCullingEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.renderer.isGpuCullingEnabled();
    }

    const COLLISION_VTABLE = VoxelCollisionWorld.VTable{
        .isSolidAt = collisionIsSolidAt,
    };

    fn collisionIsSolidAt(ptr: *anyopaque, x: i32, y: i32, z: i32) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        const block = self.getBlock(x, y, z);
        return block_registry.getBlockDefinition(block).is_solid;
    }
};
