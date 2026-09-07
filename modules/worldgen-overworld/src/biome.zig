//! Biome system facade — re-exports from specialized sub-modules.
//!
//! This file exists solely to preserve the existing import path
//! `@import("biome.zig")` used by 17+ files across the codebase.
//! All logic lives in the sub-modules:
//!   - biome_registry.zig       — Data definitions, types, BIOME_REGISTRY
//!   - biome_selector.zig       — Selection algorithms (Voronoi, score-based, blended)
//!   - biome_edge_detector.zig  — Edge detection, transition rules
//!   - biome_color_provider.zig — Color lookup for maps
//!   - biome_source.zig         — BiomeSource unified interface

// ============================================================================
// Sub-module imports
// ============================================================================

const biome_registry = @import("biome_registry.zig");
const biome_selector = @import("biome_selector.zig");
const biome_edge_detector = @import("biome_edge_detector.zig");
const biome_color_provider = @import("biome_color_provider.zig");
const biome_source_mod = @import("biome_source.zig");

// ============================================================================
// Types from biome_registry.zig
// ============================================================================

pub const Range = biome_registry.Range;
pub const ColorTints = biome_registry.ColorTints;
pub const VegetationProfile = biome_registry.VegetationProfile;
pub const TerrainModifier = biome_registry.TerrainModifier;
pub const SurfaceBlocks = biome_registry.SurfaceBlocks;
pub const BiomeDefinition = biome_registry.BiomeDefinition;
pub const ClimateParams = biome_registry.ClimateParams;
pub const BiomeId = biome_registry.BiomeId;
pub const BiomePoint = biome_registry.BiomePoint;
pub const StructuralParams = biome_registry.StructuralParams;
pub const TreeType = biome_registry.TreeType;

// ============================================================================
// Constants from biome_registry.zig
// ============================================================================

pub const BLEND_EPSILON = biome_registry.BLEND_EPSILON;
pub const BIOME_POINTS = biome_registry.BIOME_POINTS;
pub const BIOME_REGISTRY = biome_registry.BIOME_REGISTRY;

// ============================================================================
// Functions from biome_registry.zig
// ============================================================================

pub const getBiomeDefinition = biome_registry.getBiomeDefinition;
pub const isMountainFamilyTerrainBiome = biome_registry.isMountainFamilyTerrainBiome;

// ============================================================================
// Types from biome_edge_detector.zig
// ============================================================================

pub const EdgeBand = biome_edge_detector.EdgeBand;
pub const BiomeEdgeInfo = biome_edge_detector.BiomeEdgeInfo;
pub const TransitionRule = biome_edge_detector.TransitionRule;

// ============================================================================
// Constants from biome_edge_detector.zig
// ============================================================================

pub const EDGE_STEP = biome_edge_detector.EDGE_STEP;
pub const EDGE_CHECK_RADII = biome_edge_detector.EDGE_CHECK_RADII;
pub const EDGE_WIDTH = biome_edge_detector.EDGE_WIDTH;
pub const TRANSITION_RULES = biome_edge_detector.TRANSITION_RULES;

// ============================================================================
// Functions from biome_edge_detector.zig
// ============================================================================

pub const needsTransition = biome_edge_detector.needsTransition;
pub const getTransitionBiome = biome_edge_detector.getTransitionBiome;

// ============================================================================
// Functions from biome_selector.zig
// ============================================================================

pub const selectBiomeVoronoi = biome_selector.selectBiomeVoronoi;
pub const selectBiomeVoronoiMultiParam = biome_selector.selectBiomeVoronoiMultiParam;
pub const selectBiomeVoronoiWithRiver = biome_selector.selectBiomeVoronoiWithRiver;
pub const selectBiome = biome_selector.selectBiome;
pub const selectBiomeMultiParam = biome_selector.selectBiomeMultiParam;
pub const selectBiomeWithRiver = biome_selector.selectBiomeWithRiver;
pub const computeClimateParams = biome_selector.computeClimateParams;
pub const BiomeSelection = biome_selector.BiomeSelection;
pub const selectBiomeBlended = biome_selector.selectBiomeBlended;
pub const selectBiomeWithRiverBlended = biome_selector.selectBiomeWithRiverBlended;
pub const selectBiomeWithConstraints = biome_selector.selectBiomeWithConstraints;
pub const selectBiomeWithConstraintsAndRiver = biome_selector.selectBiomeWithConstraintsAndRiver;

// ============================================================================
// Functions from biome_color_provider.zig
// ============================================================================

pub const getBiomeColor = biome_color_provider.getBiomeColor;

// ============================================================================
// Types from biome_source.zig
// ============================================================================

pub const BiomeResult = biome_source_mod.BiomeResult;
pub const BiomeSourceParams = biome_source_mod.BiomeSourceParams;
pub const BiomeSource = biome_source_mod.BiomeSource;
