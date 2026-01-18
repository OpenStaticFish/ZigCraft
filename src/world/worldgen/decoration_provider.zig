const std = @import("std");
const Chunk = @import("../chunk.zig").Chunk;
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;

/// Abstraction for decoration placement logic.
/// Allows OverworldGenerator to be decoupled from specific decoration implementations.
///
/// Note: Decorations are typically placed once per column. Providers should
/// break after the first valid decoration to prevent overlap and unintended density.
pub const DecorationProvider = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        decorate: *const fn (
            ptr: ?*anyopaque,
            chunk: *Chunk,
            local_x: u32,
            local_z: u32,
            surface_y: i32,
            surface_block: BlockType,
            biome: BiomeId,
            variant: f32,
            allow_subbiomes: bool,
            veg_mult: f32,
            random: std.Random,
        ) void,
    };

    pub fn decorate(
        self: DecorationProvider,
        chunk: *Chunk,
        local_x: u32,
        local_z: u32,
        surface_y: i32,
        surface_block: BlockType,
        biome: BiomeId,
        variant: f32,
        allow_subbiomes: bool,
        veg_mult: f32,
        random: std.Random,
    ) void {
        self.vtable.decorate(
            self.ptr,
            chunk,
            local_x,
            local_z,
            surface_y,
            surface_block,
            biome,
            variant,
            allow_subbiomes,
            veg_mult,
            random,
        );
    }
};
