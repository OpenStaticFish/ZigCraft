comptime {
    _ = @import("biome_colors.zig");
    _ = @import("chunk_allocator.zig");
    _ = @import("chunk_mesh.zig");
    _ = @import("chunk_mesh_tests.zig");
    _ = @import("chunk_storage.zig");
    _ = @import("chunk_storage_extended_tests.zig");
    _ = @import("chunk_storage_interface_tests.zig");
    _ = @import("chunk_storage_tests.zig");
    _ = @import("gpu_block_buffer.zig");
    _ = @import("gpu_block_buffer_tests.zig");
    _ = @import("world_interface_vtable_tests.zig");
    _ = @import("world_tests.zig");
    _ = @import("meshing/ao_calculator.zig");
    _ = @import("meshing/biome_color_sampler.zig");
    _ = @import("meshing/boundary.zig");
    _ = @import("meshing/boundary_cross_tests.zig");
    _ = @import("meshing/boundary_tests.zig");
    _ = @import("meshing/cross_mesher.zig");
    _ = @import("meshing/custom_mesh_mesher.zig");
    _ = @import("meshing/flat_quad_mesher.zig");
    _ = @import("meshing/greedy_mesher.zig");
    _ = @import("meshing/lighting_sampler.zig");
    _ = @import("meshing/tall_cross_mesher.zig");
    _ = @import("meshing/wall_attached_mesher.zig");
}
