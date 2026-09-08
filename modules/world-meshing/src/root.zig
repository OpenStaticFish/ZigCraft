pub const chunk_mesh = @import("chunk_mesh.zig");

test {
    _ = @import("test_root.zig");
}
pub const chunk_allocator = @import("chunk_allocator.zig");
pub const chunk_storage = @import("chunk_storage.zig");
pub const chunk_mesh_tests = @import("chunk_mesh_tests.zig");
pub const chunk_storage_extended_tests = @import("chunk_storage_extended_tests.zig");
pub const chunk_storage_interface_tests = @import("chunk_storage_interface_tests.zig");
pub const chunk_storage_tests = @import("chunk_storage_tests.zig");
pub const gpu_block_buffer = @import("gpu_block_buffer.zig");
pub const gpu_block_buffer_tests = @import("gpu_block_buffer_tests.zig");
pub const world_interface_vtable_tests = @import("world_interface_vtable_tests.zig");
pub const world_tests = @import("world_tests.zig");
pub const meshing = struct {
    pub const ao_calculator = @import("meshing/ao_calculator.zig");
    pub const biome_color_sampler = @import("meshing/biome_color_sampler.zig");
    pub const boundary = @import("meshing/boundary.zig");
    pub const boundary_cross_tests = @import("meshing/boundary_cross_tests.zig");
    pub const boundary_tests = @import("meshing/boundary_tests.zig");
    pub const cross_mesher = @import("meshing/cross_mesher.zig");
    pub const custom_mesh_mesher = @import("meshing/custom_mesh_mesher.zig");
    pub const greedy_mesher = @import("meshing/greedy_mesher.zig");
    pub const lighting_sampler = @import("meshing/lighting_sampler.zig");
    pub const wall_attached_mesher = @import("meshing/wall_attached_mesher.zig");
};

pub const ChunkMesh = chunk_mesh.ChunkMesh;
pub const ChunkData = chunk_storage.ChunkData;
pub const ChunkStorage = chunk_storage.ChunkStorage;
pub const GlobalVertexAllocator = chunk_allocator.GlobalVertexAllocator;
pub const GpuBlockBuffer = gpu_block_buffer.GpuBlockBuffer;
pub const IChunkStorage = chunk_storage.IChunkStorage;
pub const NeighborChunks = chunk_mesh.NeighborChunks;
pub const NUM_SUBCHUNKS = chunk_mesh.NUM_SUBCHUNKS;
pub const Pass = chunk_mesh.Pass;
pub const SUBCHUNK_SIZE = chunk_mesh.SUBCHUNK_SIZE;
pub const VertexAllocation = chunk_allocator.VertexAllocation;
