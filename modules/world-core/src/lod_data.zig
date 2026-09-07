const std = @import("std");

const engine_core = @import("engine-core");
const world_core = @import("root.zig");

pub const LODLevel = engine_core.LODLevel;

pub const LODDataVersion = enum(u16) {
    simplified_v1 = 1,
    rich_v2 = 2,
};

pub const LODColumnProvenance = enum(u8) {
    worldgen = 0,
    chunk_derived = 1,
    edited = 2,

    pub fn canOverwrite(new: LODColumnProvenance, old: LODColumnProvenance) bool {
        return @intFromEnum(new) >= @intFromEnum(old);
    }
};

pub const MAX_LOD_VERTICAL_SPANS: usize = 4;

pub const LODMaterialLayers = struct {
    surface: world_core.BlockType,
    subsurface: world_core.BlockType,
    foundation: world_core.BlockType,

    pub fn default(surface: world_core.BlockType) LODMaterialLayers {
        return .{
            .surface = surface,
            .subsurface = surface,
            .foundation = surface,
        };
    }
};

pub const LODWaterState = struct {
    is_surface: bool,
    surface_height: f32,
    depth: f32,
    coverage: f32,

    pub const empty: LODWaterState = .{
        .is_surface = false,
        .surface_height = 0.0,
        .depth = 0.0,
        .coverage = 0.0,
    };
};

pub const LODLightingHint = struct {
    sky_light: u8,
    block_light: u8,
    ambient_occlusion: f32,

    pub const daylight: LODLightingHint = .{
        .sky_light = 15,
        .block_light = 0,
        .ambient_occlusion = 1.0,
    };
};

pub const LODVegetationHint = struct {
    tree_coverage: f32,
    avg_tree_height: f32,
    offset_x: f32,
    offset_z: f32,
    trunk: world_core.BlockType,
    leaves: world_core.BlockType,

    pub const empty: LODVegetationHint = .{
        .tree_coverage = 0.0,
        .avg_tree_height = 0.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .air,
        .leaves = .air,
    };
};

pub const LODVerticalSpan = struct {
    min_height: f32,
    max_height: f32,
    biome: world_core.BiomeId,
    material_layers: LODMaterialLayers,
    color: u32,
    water: LODWaterState,
    lighting: LODLightingHint,
    vegetation: LODVegetationHint,

    pub fn fromColumn(
        height: f32,
        biome: world_core.BiomeId,
        layers: LODMaterialLayers,
        color: u32,
        water_state: LODWaterState,
        lighting_hint: LODLightingHint,
        vegetation_hint: LODVegetationHint,
    ) LODVerticalSpan {
        return .{
            .min_height = height,
            .max_height = height,
            .biome = biome,
            .material_layers = layers,
            .color = color,
            .water = water_state,
            .lighting = lighting_hint,
            .vegetation = vegetation_hint,
        };
    }
};

pub fn regionSizeBlocks(lod_level: LODLevel) u32 {
    return lod_level.regionSizeBlocks(world_core.CHUNK_SIZE_X);
}

/// Simplified world data for distant LOD generation.
pub const LODSimplifiedData = struct {
    version: LODDataVersion,
    width: u32,
    heightmap: []f32,
    biomes: []world_core.BiomeId,
    top_blocks: []world_core.BlockType,
    colors: []u32,
    material_layers: []LODMaterialLayers,
    water: []LODWaterState,
    lighting: []LODLightingHint,
    vegetation: []LODVegetationHint,
    provenance: []LODColumnProvenance,
    vertical_span_counts: ?[]u8,
    vertical_spans: ?[]LODVerticalSpan,
    /// Owns the grid; its pointer must be allocated with this data's allocator.
    scene_grid: ?*@import("lod_scene.zig").SceneGrid = null,
    allocator: std.mem.Allocator,

    pub fn getGridSize(lod_level: LODLevel) u32 {
        return switch (lod_level) {
            // LOD4 is the fast horizon fallback; LOD3 retains the dense grid
            // and replaces it as refinement arrives.
            .lod0 => 33,
            .lod1 => 65,
            .lod2 => 65,
            .lod3 => 129,
            .lod4 => 65,
        };
    }

    pub fn getCellSizeBlocks(lod_level: LODLevel) u32 {
        const region_size = regionSizeBlocks(lod_level);
        const grid_size = getGridSize(lod_level);
        return region_size / @max(grid_size - 1, 1);
    }

    /// Returns a seam-friendly (power-of-two cells plus one edge sample) grid
    /// at a configurable density.  The edge samples are retained so adjacent
    /// regions still meet exactly after far-level decimation.
    pub fn getGridSizeForDensity(lod_level: LODLevel, density: f32) u32 {
        const base_cells = getGridSize(lod_level) - 1;
        const clamped = std.math.clamp(density, 0.0625, 1.0);
        const requested: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(base_cells)) * clamped))));
        var cells: u32 = 1;
        while (cells * 2 <= requested) : (cells *= 2) {}
        return cells + 1;
    }

    /// Valid source grids retain a power-of-two cell count that divides the
    /// region's block width. This makes every cell an integral world-space
    /// span, which is required by heightfield seams and compact index topology.
    pub fn isSupportedGridSize(lod_level: LODLevel, width: u32) bool {
        if (width < 2) return false;
        const cells = width - 1;
        if ((cells & (cells - 1)) != 0) return false;
        return regionSizeBlocks(lod_level) % cells == 0;
    }

    pub fn init(allocator: std.mem.Allocator, lod_level: LODLevel) !LODSimplifiedData {
        return initWithSampleDensity(allocator, lod_level, 1.0);
    }

    /// Allocates source storage using the requested LOD sample density. This
    /// changes worker sampling and mesh input cost, not just draw culling.
    pub fn initWithSampleDensity(allocator: std.mem.Allocator, lod_level: LODLevel, density: f32) !LODSimplifiedData {
        const grid_size = getGridSizeForDensity(lod_level, density);
        return initWithGridSize(allocator, lod_level, grid_size);
    }

    /// Allocates a validated, seam-compatible source grid. Cache loading uses
    /// this exact-width constructor so reduced-density payloads never get
    /// silently expanded into a different array topology.
    pub fn initWithGridSize(allocator: std.mem.Allocator, lod_level: LODLevel, grid_size: u32) !LODSimplifiedData {
        if (!isSupportedGridSize(lod_level, grid_size)) return error.InvalidGridSize;
        const count = grid_size * grid_size;

        const heightmap = try allocator.alloc(f32, count);
        errdefer allocator.free(heightmap);
        const biomes = try allocator.alloc(world_core.BiomeId, count);
        errdefer allocator.free(biomes);
        const top_blocks = try allocator.alloc(world_core.BlockType, count);
        errdefer allocator.free(top_blocks);
        const colors = try allocator.alloc(u32, count);
        errdefer allocator.free(colors);
        const material_layers = try allocator.alloc(LODMaterialLayers, count);
        errdefer allocator.free(material_layers);
        const water = try allocator.alloc(LODWaterState, count);
        errdefer allocator.free(water);
        const lighting = try allocator.alloc(LODLightingHint, count);
        errdefer allocator.free(lighting);
        const vegetation = try allocator.alloc(LODVegetationHint, count);
        errdefer allocator.free(vegetation);
        const provenance = try allocator.alloc(LODColumnProvenance, count);
        errdefer allocator.free(provenance);

        @memset(heightmap, 0.0);
        @memset(biomes, .plains);
        @memset(top_blocks, .air);
        @memset(colors, 0);
        @memset(material_layers, LODMaterialLayers.default(.air));
        @memset(water, LODWaterState.empty);
        @memset(lighting, LODLightingHint.daylight);
        @memset(vegetation, LODVegetationHint.empty);
        @memset(provenance, .worldgen);

        return .{
            .version = .rich_v2,
            .width = grid_size,
            .heightmap = heightmap,
            .biomes = biomes,
            .top_blocks = top_blocks,
            .colors = colors,
            .material_layers = material_layers,
            .water = water,
            .lighting = lighting,
            .vegetation = vegetation,
            .provenance = provenance,
            .vertical_span_counts = null,
            .vertical_spans = null,
            .allocator = allocator,
        };
    }

    pub fn initWithVerticalSpans(allocator: std.mem.Allocator, lod_level: LODLevel) !LODSimplifiedData {
        return initWithVerticalSpansSampleDensity(allocator, lod_level, 1.0);
    }

    pub fn initWithVerticalSpansSampleDensity(allocator: std.mem.Allocator, lod_level: LODLevel, density: f32) !LODSimplifiedData {
        var data = try initWithSampleDensity(allocator, lod_level, density);
        errdefer data.deinit();
        try data.enableVerticalSpans();
        return data;
    }

    pub fn initWithVerticalSpansGridSize(allocator: std.mem.Allocator, lod_level: LODLevel, grid_size: u32) !LODSimplifiedData {
        var data = try initWithGridSize(allocator, lod_level, grid_size);
        errdefer data.deinit();
        try data.enableVerticalSpans();
        return data;
    }

    pub fn deinit(self: *LODSimplifiedData) void {
        self.allocator.free(self.heightmap);
        self.allocator.free(self.biomes);
        self.allocator.free(self.top_blocks);
        self.allocator.free(self.colors);
        self.allocator.free(self.material_layers);
        self.allocator.free(self.water);
        self.allocator.free(self.lighting);
        self.allocator.free(self.vegetation);
        self.allocator.free(self.provenance);
        if (self.vertical_span_counts) |counts| self.allocator.free(counts);
        if (self.vertical_spans) |spans| self.allocator.free(spans);
        if (self.scene_grid) |grid| {
            grid.deinit();
            self.allocator.destroy(grid);
        }
        self.* = undefined;
    }

    pub fn enableVerticalSpans(self: *LODSimplifiedData) !void {
        if (self.vertical_spans != null) return;

        const count = self.width * self.width;
        const span_count = @as(usize, @intCast(count)) * MAX_LOD_VERTICAL_SPANS;
        const counts = try self.allocator.alloc(u8, count);
        errdefer self.allocator.free(counts);
        const spans = try self.allocator.alloc(LODVerticalSpan, span_count);
        errdefer self.allocator.free(spans);

        @memset(counts, 0);
        @memset(spans, LODVerticalSpan.fromColumn(0.0, .plains, LODMaterialLayers.default(.air), 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty));

        self.vertical_span_counts = counts;
        self.vertical_spans = spans;
    }

    pub fn hasVerticalSpans(self: *const LODSimplifiedData) bool {
        return self.vertical_span_counts != null and self.vertical_spans != null;
    }

    pub fn getHeight(self: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
        if (gx >= self.width or gz >= self.width) return 0;
        return self.heightmap[gz * self.width + gx];
    }

    pub fn setHeight(self: *LODSimplifiedData, gx: u32, gz: u32, height: f32) void {
        if (gx >= self.width or gz >= self.width) return;
        self.heightmap[gz * self.width + gx] = height;
    }

    pub fn setColumn(
        self: *LODSimplifiedData,
        gx: u32,
        gz: u32,
        height: f32,
        biome: world_core.BiomeId,
        layers: LODMaterialLayers,
        color: u32,
        water_state: LODWaterState,
        lighting_hint: LODLightingHint,
        vegetation_hint: LODVegetationHint,
    ) void {
        if (gx >= self.width or gz >= self.width) return;
        const idx = gz * self.width + gx;
        self.heightmap[idx] = height;
        self.biomes[idx] = biome;
        self.top_blocks[idx] = layers.surface;
        self.colors[idx] = color;
        self.material_layers[idx] = layers;
        self.water[idx] = water_state;
        self.lighting[idx] = lighting_hint;
        self.vegetation[idx] = vegetation_hint;
        if (self.hasVerticalSpans()) {
            _ = self.setVerticalSpan(gx, gz, 0, LODVerticalSpan.fromColumn(height, biome, layers, color, water_state, lighting_hint, vegetation_hint));
        }
    }

    pub fn setGeneratedColumn(
        self: *LODSimplifiedData,
        gx: u32,
        gz: u32,
        height: f32,
        biome: world_core.BiomeId,
        layers: LODMaterialLayers,
        color: u32,
        water_state: LODWaterState,
        lighting_hint: LODLightingHint,
        vegetation_hint: LODVegetationHint,
    ) void {
        // Provenance-aware: worldgen generation never overwrites a column held
        // by chunk_derived or edited data (issue #752 Phase 2.4). This makes
        // every generator's heightmap pass respect real chunk data, so a region
        // can regenerate its worldgen columns while preserving chunk-derived
        // columns without any special-casing at the call sites.
        if (!LODColumnProvenance.worldgen.canOverwrite(self.getColumnProvenance(gx, gz))) return;

        self.setColumn(gx, gz, height, biome, layers, color, water_state, lighting_hint, vegetation_hint);
        if (!self.hasVerticalSpans()) return;

        self.clearVerticalSpans(gx, gz);
        const terrain_layers = terrainLayersForGeneratedSpan(layers, water_state);
        const terrain_height = terrainHeightForGeneratedSpan(height, water_state);
        _ = self.setVerticalSpan(gx, gz, 0, .{
            .min_height = 0.0,
            .max_height = terrain_height,
            .biome = biome,
            .material_layers = terrain_layers,
            .color = color,
            .water = LODWaterState.empty,
            .lighting = lighting_hint,
            .vegetation = vegetation_hint,
        });

        var span_index: u8 = 1;

        if (water_state.is_surface and water_state.coverage > 0.0 and span_index < MAX_LOD_VERTICAL_SPANS) {
            _ = self.setVerticalSpan(gx, gz, span_index, .{
                .min_height = terrain_height,
                .max_height = @max(water_state.surface_height, terrain_height),
                .biome = biome,
                .material_layers = .{
                    .surface = .water,
                    .subsurface = .water,
                    .foundation = terrain_layers.foundation,
                },
                .color = color,
                .water = water_state,
                .lighting = lighting_hint,
                .vegetation = LODVegetationHint.empty,
            });
            span_index += 1;
        }

        if (vegetation_hint.tree_coverage > 0.0 and vegetation_hint.avg_tree_height >= 2.0 and span_index < MAX_LOD_VERTICAL_SPANS) {
            const canopy_top = height + vegetation_hint.avg_tree_height;
            const canopy_bottom = @max(height + 1.0, canopy_top - @max(vegetation_hint.avg_tree_height * 0.45, 2.0));
            const leaves = if (vegetation_hint.leaves == .air) world_core.BlockType.leaves else vegetation_hint.leaves;
            _ = self.setVerticalSpan(gx, gz, span_index, .{
                .min_height = canopy_bottom,
                .max_height = canopy_top,
                .biome = biome,
                .material_layers = .{
                    .surface = leaves,
                    .subsurface = leaves,
                    .foundation = terrain_layers.foundation,
                },
                .color = blockDefaultColor(leaves, color),
                .water = LODWaterState.empty,
                .lighting = lighting_hint,
                .vegetation = vegetation_hint,
            });
        }
    }

    fn blockDefaultColor(block: world_core.BlockType, fallback: u32) u32 {
        if (block == .air) return fallback;
        const color = world_core.block_registry.getBlockDefinition(block).default_color;
        const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
        const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
        const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
        return (r << 16) | (g << 8) | b;
    }

    fn terrainLayersForGeneratedSpan(layers: LODMaterialLayers, water_state: LODWaterState) LODMaterialLayers {
        if (!water_state.is_surface or layers.surface != .water) return layers;
        const floor_block = if (layers.subsurface == .air) layers.foundation else layers.subsurface;
        return .{
            .surface = floor_block,
            .subsurface = floor_block,
            .foundation = layers.foundation,
        };
    }

    fn terrainHeightForGeneratedSpan(height: f32, water_state: LODWaterState) f32 {
        if (!water_state.is_surface) return height;
        if (water_state.depth <= 0.0) return @min(height, water_state.surface_height);
        return @max(0.0, water_state.surface_height - water_state.depth);
    }

    pub fn setColumnProvenance(self: *LODSimplifiedData, gx: u32, gz: u32, provenance: LODColumnProvenance) void {
        if (gx >= self.width or gz >= self.width) return;
        self.provenance[gz * self.width + gx] = provenance;
    }

    pub fn getColumnProvenance(self: *const LODSimplifiedData, gx: u32, gz: u32) LODColumnProvenance {
        if (gx >= self.width or gz >= self.width) return .worldgen;
        return self.provenance[gz * self.width + gx];
    }

    /// Reset every worldgen-provenance column (height -> 0, spans cleared),
    /// leaving chunk_derived/edited columns untouched. Used on generator
    /// mismatch so a region can regenerate its worldgen columns from the new
    /// generator while preserving real chunk data (issue #752 Phase 2.4).
    /// Returns the number of columns that survived (chunk_derived or edited).
    pub fn purgeWorldgenColumns(self: *LODSimplifiedData) u32 {
        var survived: u32 = 0;
        const count = self.width * self.width;
        var idx: usize = 0;
        while (idx < count) : (idx += 1) {
            const p = self.provenance[idx];
            if (p == .worldgen) {
                self.heightmap[idx] = 0.0;
                if (self.hasVerticalSpans()) {
                    const gx: u32 = @intCast(idx % self.width);
                    const gz: u32 = @intCast(idx / self.width);
                    self.clearVerticalSpans(gx, gz);
                }
            } else {
                survived += 1;
            }
        }
        return survived;
    }

    /// True if any column is chunk_derived or edited (i.e. the region carries
    /// real chunk data worth preserving across a generator change).
    pub fn hasNonWorldgenColumns(self: *const LODSimplifiedData) bool {
        for (self.provenance) |p| {
            if (p != .worldgen) return true;
        }
        return false;
    }

    pub fn verticalSpanCount(self: *const LODSimplifiedData, gx: u32, gz: u32) u8 {
        if (gx >= self.width or gz >= self.width) return 0;
        const counts = self.vertical_span_counts orelse return 0;
        return counts[gz * self.width + gx];
    }

    pub fn getVerticalSpan(self: *const LODSimplifiedData, gx: u32, gz: u32, span_index: u8) ?LODVerticalSpan {
        if (gx >= self.width or gz >= self.width) return null;
        if (span_index >= self.verticalSpanCount(gx, gz)) return null;
        const spans = self.vertical_spans orelse return null;
        const column_idx = @as(usize, @intCast(gz * self.width + gx));
        const idx = column_idx * MAX_LOD_VERTICAL_SPANS + span_index;
        return spans[idx];
    }

    pub fn setVerticalSpan(self: *LODSimplifiedData, gx: u32, gz: u32, span_index: u8, span: LODVerticalSpan) bool {
        if (gx >= self.width or gz >= self.width) return false;
        if (@as(usize, span_index) >= MAX_LOD_VERTICAL_SPANS) return false;
        const counts = self.vertical_span_counts orelse return false;
        const spans = self.vertical_spans orelse return false;
        const column_idx = gz * self.width + gx;
        spans[@as(usize, @intCast(column_idx)) * MAX_LOD_VERTICAL_SPANS + span_index] = span;
        counts[column_idx] = @max(counts[column_idx], span_index + 1);
        return true;
    }

    pub fn clearVerticalSpans(self: *LODSimplifiedData, gx: u32, gz: u32) void {
        if (gx >= self.width or gz >= self.width) return;
        const counts = self.vertical_span_counts orelse return;
        counts[gz * self.width + gx] = 0;
    }

    pub fn totalMemoryBytes(self: *const LODSimplifiedData) usize {
        const count = self.width * self.width;
        const count_usize = @as(usize, @intCast(count));
        var total: usize = count_usize * (@sizeOf(f32) + @sizeOf(world_core.BiomeId) + @sizeOf(world_core.BlockType) + @sizeOf(u32) + @sizeOf(LODMaterialLayers) + @sizeOf(LODWaterState) + @sizeOf(LODLightingHint) + @sizeOf(LODVegetationHint) + @sizeOf(LODColumnProvenance));
        if (self.vertical_span_counts != null) total += count_usize * @sizeOf(u8);
        if (self.vertical_spans != null) total += @as(usize, @intCast(count)) * MAX_LOD_VERTICAL_SPANS * @sizeOf(LODVerticalSpan);
        if (self.scene_grid) |grid| total += grid.memoryBytes();
        return total;
    }

    /// Reuses exact coincident parent samples for one of its four child
    /// regions. Reuse is permitted only when both grids have the same
    /// world-space cell size (`parent.width == child.width * 2 - 1`); that
    /// restriction keeps shared edges byte-for-byte identical rather than
    /// blending unrelated coarse footprints. Returns copied sample count.
    pub fn reuseAlignedParentSamples(child: *LODSimplifiedData, parent: *const LODSimplifiedData, child_x: u1, child_z: u1) u32 {
        if (parent.width != child.width * 2 - 1) return 0;
        const offset_x = @as(u32, child_x) * (child.width - 1);
        const offset_z = @as(u32, child_z) * (child.width - 1);
        var copied: u32 = 0;
        var z: u32 = 0;
        while (z < child.width) : (z += 1) {
            var x: u32 = 0;
            while (x < child.width) : (x += 1) {
                if (child.getColumnProvenance(x, z) != .worldgen) continue;
                const dst = x + z * child.width;
                const src = (x + offset_x) + (z + offset_z) * parent.width;
                child.heightmap[dst] = parent.heightmap[src];
                child.biomes[dst] = parent.biomes[src];
                child.top_blocks[dst] = parent.top_blocks[src];
                child.colors[dst] = parent.colors[src];
                child.material_layers[dst] = parent.material_layers[src];
                child.water[dst] = parent.water[src];
                child.lighting[dst] = parent.lighting[src];
                child.vegetation[dst] = parent.vegetation[src];
                copied += 1;
            }
        }
        return copied;
    }
};

test "LODSimplifiedData initializes rich column defaults" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    try std.testing.expectEqual(@as(f32, 0.0), data.getHeight(0, 0));
    try std.testing.expectEqual(world_core.BlockType.air, data.top_blocks[0]);
    try std.testing.expectEqual(world_core.BlockType.air, data.material_layers[0].surface);
    try std.testing.expect(!data.water[0].is_surface);
    try std.testing.expectEqual(@as(u8, 15), data.lighting[0].sky_light);
    try std.testing.expectEqual(@as(f32, 0.0), data.vegetation[0].tree_coverage);
}

test "LODSimplifiedData far levels use configured detail grids" {
    try std.testing.expectEqual(@as(u32, 33), LODSimplifiedData.getGridSize(.lod0));
    try std.testing.expectEqual(@as(u32, 65), LODSimplifiedData.getGridSize(.lod1));
    try std.testing.expectEqual(@as(u32, 65), LODSimplifiedData.getGridSize(.lod2));
    try std.testing.expectEqual(@as(u32, 129), LODSimplifiedData.getGridSize(.lod3));
    try std.testing.expectEqual(@as(u32, 65), LODSimplifiedData.getGridSize(.lod4));
}

test "LODSimplifiedData density reduces far worker and mesh samples" {
    const allocator = std.testing.allocator;
    var lod3 = try LODSimplifiedData.initWithSampleDensity(allocator, .lod3, 0.5);
    defer lod3.deinit();
    var lod4 = try LODSimplifiedData.initWithSampleDensity(allocator, .lod4, 0.25);
    defer lod4.deinit();

    try std.testing.expectEqual(@as(u32, 65), lod3.width);
    try std.testing.expectEqual(@as(u32, 17), lod4.width);
    try std.testing.expect(lod3.heightmap.len < @as(usize, 129 * 129));
    try std.testing.expect(lod4.heightmap.len < @as(usize, 65 * 65));
}

test "LODSimplifiedData accepts every integral far density grid" {
    try std.testing.expect(LODSimplifiedData.isSupportedGridSize(.lod3, 17));
    try std.testing.expect(LODSimplifiedData.isSupportedGridSize(.lod3, 65));
    try std.testing.expect(LODSimplifiedData.isSupportedGridSize(.lod3, 129));
    try std.testing.expect(LODSimplifiedData.isSupportedGridSize(.lod4, 17));
    try std.testing.expect(LODSimplifiedData.isSupportedGridSize(.lod4, 65));
    try std.testing.expect(!LODSimplifiedData.isSupportedGridSize(.lod4, 18));
}

test "LODSimplifiedData reuses only aligned coarse parent samples" {
    const allocator = std.testing.allocator;
    var parent = try LODSimplifiedData.initWithSampleDensity(allocator, .lod4, 1.0);
    defer parent.deinit();
    var child = try LODSimplifiedData.initWithSampleDensity(allocator, .lod3, 0.5);
    defer child.deinit();
    parent.setHeight(64, 64, 91.0);
    try std.testing.expectEqual(@as(u32, 65 * 65), child.reuseAlignedParentSamples(&parent, 1, 1));
    try std.testing.expectEqual(@as(f32, 91.0), child.getHeight(0, 0));
}

test "LODColumnProvenance orders overwrite authority" {
    try std.testing.expect(LODColumnProvenance.chunk_derived.canOverwrite(.worldgen));
    try std.testing.expect(LODColumnProvenance.edited.canOverwrite(.chunk_derived));
    try std.testing.expect(!LODColumnProvenance.worldgen.canOverwrite(.chunk_derived));
    try std.testing.expect(!LODColumnProvenance.chunk_derived.canOverwrite(.edited));
}

test "LODSimplifiedData setColumn stores rich representative data" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    data.setColumn(1, 2, 63.0, .ocean, .{
        .surface = .water,
        .subsurface = .sand,
        .foundation = .stone,
    }, 0x3355AA, .{
        .is_surface = true,
        .surface_height = 63.0,
        .depth = 12.0,
        .coverage = 1.0,
    }, .{
        .sky_light = 15,
        .block_light = 0,
        .ambient_occlusion = 0.9,
    }, .{
        .tree_coverage = 0.5,
        .avg_tree_height = 7.0,
        .offset_x = 0.25,
        .offset_z = -0.25,
        .trunk = .wood,
        .leaves = .leaves,
    });

    const idx = 1 + 2 * data.width;
    try std.testing.expectEqual(@as(f32, 63.0), data.heightmap[idx]);
    try std.testing.expectEqual(world_core.BlockType.water, data.top_blocks[idx]);
    try std.testing.expectEqual(world_core.BlockType.sand, data.material_layers[idx].subsurface);
    try std.testing.expect(data.water[idx].is_surface);
    try std.testing.expectEqual(@as(f32, 12.0), data.water[idx].depth);
    try std.testing.expectEqual(@as(f32, 0.9), data.lighting[idx].ambient_occlusion);
    try std.testing.expectEqual(world_core.BlockType.leaves, data.vegetation[idx].leaves);
}

test "LODSimplifiedData tracks bounded vertical spans when enabled" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    try std.testing.expectEqual(LODDataVersion.rich_v2, data.version);
    try std.testing.expect(data.hasVerticalSpans());
    try std.testing.expectEqual(@as(u8, 0), data.verticalSpanCount(3, 4));

    try std.testing.expect(data.setVerticalSpan(3, 4, 0, .{
        .min_height = 72.0,
        .max_height = 76.0,
        .biome = .plains,
        .material_layers = .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone },
        .color = 0x66AA44,
        .water = LODWaterState.empty,
        .lighting = LODLightingHint.daylight,
        .vegetation = LODVegetationHint.empty,
    }));
    try std.testing.expect(data.setVerticalSpan(3, 4, 1, .{
        .min_height = 44.0,
        .max_height = 48.0,
        .biome = .plains,
        .material_layers = .{ .surface = .stone, .subsurface = .stone, .foundation = .stone },
        .color = 0x777777,
        .water = LODWaterState.empty,
        .lighting = .{ .sky_light = 8, .block_light = 0, .ambient_occlusion = 0.6 },
        .vegetation = LODVegetationHint.empty,
    }));

    try std.testing.expectEqual(@as(u8, 2), data.verticalSpanCount(3, 4));
    const lower = data.getVerticalSpan(3, 4, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 44.0), lower.min_height);
    try std.testing.expectEqual(world_core.BlockType.stone, lower.material_layers.surface);
    try std.testing.expect(!data.setVerticalSpan(3, 4, @intCast(MAX_LOD_VERTICAL_SPANS), lower));
}

test "LODSimplifiedData memory accounting includes optional vertical spans" {
    const allocator = std.testing.allocator;
    var baseline = try LODSimplifiedData.init(allocator, .lod1);
    defer baseline.deinit();
    var rich = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer rich.deinit();

    const count = @as(usize, @intCast(baseline.width * baseline.width));
    const span_bytes = count * (@sizeOf(u8) + MAX_LOD_VERTICAL_SPANS * @sizeOf(LODVerticalSpan));
    try std.testing.expectEqual(baseline.totalMemoryBytes() + span_bytes, rich.totalMemoryBytes());
}

test "LODSimplifiedData owns optional scene grid and accounts for its allocation" {
    const SceneGrid = @import("lod_scene.zig").SceneGrid;
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();
    try std.testing.expect(data.scene_grid == null);
    const baseline = data.totalMemoryBytes();
    const grid = try allocator.create(SceneGrid);
    grid.* = SceneGrid.init(allocator, 0, 0, 2, 1) catch |err| {
        allocator.destroy(grid);
        return err;
    };
    data.scene_grid = grid;
    try grid.appendColumn(-1, 1, &.{.{
        .min_y = 2,
        .max_y = 4,
        .block = .water,
        .biome = .ocean,
        .light = world_core.PackedLight.init(15, 0),
    }}, 4, 4, false);
    try std.testing.expectEqual(baseline + grid.memoryBytes(), data.totalMemoryBytes());
}

test "LODSimplifiedData setColumn seeds representative span when enabled" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer data.deinit();

    data.setColumn(2, 2, 80.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0x22AA44, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);

    try std.testing.expectEqual(@as(u8, 1), data.verticalSpanCount(2, 2));
    const span = data.getVerticalSpan(2, 2, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 80.0), span.max_height);
    try std.testing.expectEqual(world_core.BlockType.grass, span.material_layers.surface);
}

test "LODSimplifiedData generated columns emit surface and water spans" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer data.deinit();

    data.setGeneratedColumn(1, 1, 64.0, .ocean, .{
        .surface = .water,
        .subsurface = .sand,
        .foundation = .stone,
    }, 0x3355AA, .{
        .is_surface = true,
        .surface_height = 64.0,
        .depth = 10.0,
        .coverage = 1.0,
    }, LODLightingHint.daylight, LODVegetationHint.empty);

    try std.testing.expectEqual(@as(f32, 64.0), data.getHeight(1, 1));
    try std.testing.expectEqual(world_core.BlockType.water, data.top_blocks[1 + data.width]);
    try std.testing.expectEqual(@as(u8, 2), data.verticalSpanCount(1, 1));

    const surface = data.getVerticalSpan(1, 1, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0.0), surface.min_height);
    try std.testing.expectEqual(@as(f32, 54.0), surface.max_height);
    try std.testing.expectEqual(world_core.BlockType.sand, surface.material_layers.surface);
    try std.testing.expect(!surface.water.is_surface);

    const water = data.getVerticalSpan(1, 1, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 54.0), water.min_height);
    try std.testing.expectEqual(@as(f32, 64.0), water.max_height);
    try std.testing.expectEqual(world_core.BlockType.water, water.material_layers.surface);
    try std.testing.expect(water.water.is_surface);
}

test "LODSimplifiedData generated columns emit canopy spans" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer data.deinit();

    data.setGeneratedColumn(2, 2, 70.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0x2E7A32, LODWaterState.empty, LODLightingHint.daylight, .{
        .tree_coverage = 0.75,
        .avg_tree_height = 8.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    });

    try std.testing.expectEqual(@as(u8, 2), data.verticalSpanCount(2, 2));
    const canopy = data.getVerticalSpan(2, 2, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(world_core.BlockType.leaves, canopy.material_layers.surface);
    try std.testing.expect(canopy.min_height > 70.0);
    try std.testing.expectEqual(@as(f32, 78.0), canopy.max_height);
    try std.testing.expectEqual(@as(f32, 0.75), canopy.vegetation.tree_coverage);
}

test "setGeneratedColumn never overwrites chunk_derived or edited columns" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    // A chunk_derived column at height 70.
    data.setColumn(2, 2, 70.0, .forest, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    data.setColumnProvenance(2, 2, .chunk_derived);

    // Worldgen regen attempts to overwrite it with a different height.
    data.setGeneratedColumn(2, 2, 10.0, .desert, .{ .surface = .sand, .subsurface = .sand, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);

    try std.testing.expectEqual(@as(f32, 70.0), data.getHeight(2, 2));
    try std.testing.expectEqual(LODColumnProvenance.chunk_derived, data.getColumnProvenance(2, 2));

    // A neighboring worldgen column is still filled normally.
    data.setGeneratedColumn(3, 3, 40.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    try std.testing.expectEqual(@as(f32, 40.0), data.getHeight(3, 3));
}

test "purgeWorldgenColumns preserves chunk_derived and edited data" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    data.setGeneratedColumn(0, 0, 30.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    data.setColumn(1, 1, 80.0, .mountains, .{ .surface = .stone, .subsurface = .stone, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    data.setColumnProvenance(1, 1, .edited);

    const survived = data.purgeWorldgenColumns();
    try std.testing.expectEqual(@as(u32, 1), survived);
    try std.testing.expect(data.hasNonWorldgenColumns());

    // Worldgen column reset, edited column preserved.
    try std.testing.expectEqual(@as(f32, 0.0), data.getHeight(0, 0));
    try std.testing.expectEqual(@as(f32, 80.0), data.getHeight(1, 1));
    try std.testing.expectEqual(LODColumnProvenance.edited, data.getColumnProvenance(1, 1));
}
