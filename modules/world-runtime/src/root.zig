pub const chunk_queue_coordinator = @import("chunk_queue_coordinator.zig");

test {
    _ = @import("test_root.zig");
}
pub const gpu_acceleration_coordinator = @import("gpu_acceleration_coordinator.zig");
pub const gpu_mesher = @import("gpu_mesher.zig");
pub const lighting_engine = @import("lighting_engine.zig");
pub const world_mutation = @import("world_mutation.zig");
pub const world_diagnostics = @import("world_diagnostics.zig");
pub const world_diagnostics_tests = @import("world_diagnostics_tests.zig");
pub const world_renderer = @import("world_renderer.zig");
pub const world_streamer = @import("world_streamer.zig");
pub const world = @import("world.zig");
pub const world_facade_tests = @import("world_facade_tests.zig");

pub const ChunkQueueCoordinator = chunk_queue_coordinator.ChunkQueueCoordinator;
pub const GpuAccelerationCoordinator = gpu_acceleration_coordinator.GpuAccelerationCoordinator;
pub const GpuMesher = gpu_mesher.GpuMesher;
pub const GpuMesherStats = gpu_mesher.GpuMesherStats;
pub const WorldLightingEngine = lighting_engine.WorldLightingEngine;
pub const PlayerMovement = world_streamer.PlayerMovement;
pub const MAX_MDI_CHUNKS = world_renderer.MAX_MDI_CHUNKS;
pub const RenderLayer = world_renderer.RenderLayer;
pub const RenderStats = world_renderer.RenderStats;
pub const ShadowStats = world_renderer.ShadowStats;
pub const WorldMutationCoordinator = world_mutation.WorldMutationCoordinator;
pub const WorldRenderer = world_renderer.WorldRenderer;
pub const World = world.World;
pub const DebugLightInfo = world.DebugLightInfo;
pub const GpuMeshDispatch = world.GpuMeshDispatch;
pub const IWorld = world.IWorld;
pub const IWorldRenderView = world.IWorldRenderView;
pub const IWorldSimulation = world.IWorldSimulation;
pub const IWorldTelemetry = world.IWorldTelemetry;
pub const WorldStatsData = world.WorldStatsData;
pub const WorldStreamer = world_streamer.WorldStreamer;
