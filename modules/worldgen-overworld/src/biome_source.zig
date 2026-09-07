//! BiomeSource - Unified biome selection interface (Issue #147).
//! Orchestrates the registry, selector, edge detector, and color provider modules.

const registry = @import("biome_registry.zig");
const selector = @import("biome_selector.zig");
const edge_detector = @import("biome_edge_detector.zig");
const color_provider = @import("biome_color_provider.zig");

const BiomeId = registry.BiomeId;
const BiomeDefinition = registry.BiomeDefinition;
const ClimateParams = registry.ClimateParams;
const StructuralParams = registry.StructuralParams;
const BiomeEdgeInfo = edge_detector.BiomeEdgeInfo;

/// Result of biome selection with blending information
pub const BiomeResult = struct {
    primary: BiomeId,
    secondary: BiomeId, // For blending (may be same as primary)
    blend_factor: f32, // 0.0 = use primary, 1.0 = use secondary
};

/// Parameters for BiomeSource initialization
pub const BiomeSourceParams = struct {
    sea_level: i32 = 64,
    edge_detection_enabled: bool = true,
    ocean_threshold: f32 = 0.37,
};

/// Unified biome selection interface.
///
/// BiomeSource wraps all biome selection logic into a single, configurable
/// interface. This allows swapping biome selection behavior for different
/// dimensions (e.g., Overworld vs Nether) without modifying the generator.
///
/// Part of Issue #147: Modularize Terrain Generation Pipeline
pub const BiomeSource = struct {
    params: BiomeSourceParams,

    /// Initialize with default parameters
    pub fn init() BiomeSource {
        return initWithParams(.{});
    }

    /// Initialize with custom parameters
    pub fn initWithParams(params: BiomeSourceParams) BiomeSource {
        return .{ .params = params };
    }

    /// Primary biome selection interface.
    ///
    /// Selects a biome based on climate and structural parameters,
    /// with optional river override.
    ///
    /// Note: `self` is retained (rather than making this a namespace function)
    /// so that BiomeSource remains a consistent instance-based interface.
    /// Future dimension support (e.g., Nether) may use `self.params` here.
    pub fn selectBiome(
        self: *const BiomeSource,
        climate: ClimateParams,
        structural: StructuralParams,
        river_mask: f32,
    ) BiomeId {
        _ = self;
        return selector.selectBiomeWithConstraintsAndRiver(climate, structural, river_mask);
    }

    /// Select biome with edge detection and transition biome injection.
    ///
    /// This is the full biome selection that includes checking for
    /// biome boundaries and inserting appropriate transition biomes.
    pub fn selectBiomeWithEdge(
        self: *const BiomeSource,
        climate: ClimateParams,
        structural: StructuralParams,
        river_mask: f32,
        edge_info: BiomeEdgeInfo,
    ) BiomeResult {
        // First, get the base biome
        const base_biome = self.selectBiome(climate, structural, river_mask);

        // If edge detection is disabled or no edge detected, return base
        if (!self.params.edge_detection_enabled or edge_info.edge_band == .none) {
            return .{
                .primary = base_biome,
                .secondary = base_biome,
                .blend_factor = 0.0,
            };
        }

        // Check if transition is needed
        if (edge_info.neighbor_biome) |neighbor| {
            if (edge_detector.getTransitionBiome(base_biome, neighbor)) |transition| {
                // Set blend factor based on edge band
                const blend: f32 = switch (edge_info.edge_band) {
                    .inner => 0.3, // Closer to boundary: more original showing through
                    .middle => 0.2,
                    .outer => 0.1,
                    .none => 0.0,
                };
                return .{
                    .primary = transition,
                    .secondary = base_biome,
                    .blend_factor = blend,
                };
            }
        }

        // No transition needed
        return .{
            .primary = base_biome,
            .secondary = base_biome,
            .blend_factor = 0.0,
        };
    }

    /// Check if a position is ocean based on continentalness
    pub fn isOcean(self: *const BiomeSource, continentalness: f32) bool {
        return continentalness < self.params.ocean_threshold;
    }

    /// Get the biome definition for a biome ID
    pub fn getDefinition(_: *const BiomeSource, biome_id: BiomeId) BiomeDefinition {
        return registry.getBiomeDefinition(biome_id).*;
    }

    /// Get biome color for rendering
    pub fn getColor(_: *const BiomeSource, biome_id: BiomeId) u32 {
        return color_provider.getBiomeColor(biome_id);
    }

    /// Compute climate parameters from raw values
    pub fn computeClimate(
        self: *const BiomeSource,
        temperature: f32,
        humidity: f32,
        terrain_height: i32,
        continentalness: f32,
        erosion: f32,
        max_height: i32,
    ) ClimateParams {
        return selector.computeClimateParams(
            temperature,
            humidity,
            terrain_height,
            continentalness,
            erosion,
            self.params.sea_level,
            max_height,
        );
    }
};
