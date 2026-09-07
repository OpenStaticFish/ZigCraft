const std = @import("std");
const worldgen_api = @import("worldgen-api");

pub const biome = @import("biome.zig");
pub const biome_color_provider = @import("biome_color_provider.zig");
pub const biome_edge_detector = @import("biome_edge_detector.zig");
pub const biome_registry = @import("biome_registry.zig");
pub const biome_registry_tests = @import("biome_registry_tests.zig");
pub const biome_selector = @import("biome_selector.zig");
pub const biome_selector_tests = @import("biome_selector_tests.zig");
pub const biome_source = @import("biome_source.zig");
pub const caves = @import("caves.zig");
pub const caves_tests = @import("caves_tests.zig");
pub const climate_snapshot = @import("climate_snapshot.zig");
pub const coastal_generator = @import("coastal_generator.zig");
pub const coastal_generator_tests = @import("coastal_generator_tests.zig");
pub const biome_decorator = @import("biome_decorator.zig");
pub const decoration_provider = @import("decoration_provider.zig");
pub const decoration_registry = @import("decoration_registry.zig");
pub const decoration_types = @import("decoration_types.zig");
pub const gen_region = @import("gen_region.zig");
pub const height_sampler = @import("height_sampler.zig");
pub const height_sampler_tests = @import("height_sampler_tests.zig");
pub const noise_sampler = @import("noise_sampler.zig");
pub const lighting_computer = @import("worldgen-common").lighting_computer;
pub const lighting_interface = @import("worldgen-common").lighting_interface;
pub const mood = @import("mood.zig");
pub const noise = @import("noise.zig");
pub const overworld_generator = @import("overworld_generator.zig");
pub const region = @import("region.zig");
pub const schematics = @import("schematics.zig");
pub const surface_builder = @import("surface_builder.zig");
pub const terrain_shape_generator = @import("terrain_shape_generator.zig");
pub const terrain_shape_generator_tests = @import("terrain_shape_generator_tests.zig");
pub const terrain_modifier_tests = @import("terrain_modifier_tests.zig");
pub const terrain_report = @import("terrain_report.zig");
pub const tree_registry = @import("tree_registry.zig");
pub const world_class = @import("world_class.zig");
pub const world_map = @import("world_map.zig");

pub const OverworldGenerator = overworld_generator.OverworldGenerator;

const build_options = @import("worldgen_overworld_options");

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!worldgen_api.Generator {
    const gen = context.allocator.create(OverworldGenerator) catch return error.OutOfMemory;
    const restore_water = chunkDebugRestoreEnabled("water") or chunkDebugRestoreEnabled("watergen");
    const restore_caves = chunkDebugRestoreEnabled("caves");
    const restore_decorations = chunkDebugRestoreEnabled("decorations");
    gen.* = if (build_options.chunk_debug_mode)
        OverworldGenerator.initWithParams(context.seed, context.allocator, decoration_registry.StandardDecorationProvider.provider(), .{
            .terrain_shape = .{
                .sea_level = if (restore_water) 64 else -1,
                .ocean_threshold = if (restore_water) 0.37 else -1.0,
                .disable_caves = !restore_caves,
            },
            .basic_chunks_only = !restore_decorations,
        })
    else
        OverworldGenerator.init(context.seed, context.allocator, decoration_registry.StandardDecorationProvider.provider());
    return gen.generator();
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:overworld",
    .aliases = &.{ "normal", "overworld" },
    .info = OverworldGenerator.INFO,
    .create = create,
};

fn chunkDebugRestoreEnabled(name: []const u8) bool {
    if (!build_options.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_options.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}
