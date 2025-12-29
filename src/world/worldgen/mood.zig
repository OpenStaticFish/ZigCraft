//! Region Mood System (Pure Logic Layer)
//! Introduces intentional contrast and negative space by suppressing/exaggerating features.
//! Sits above biomes/terrain to direct "art direction" of large regions.

const std = @import("std");

pub const RegionMood = enum {
    calm, // Boring on purpose, travel stretches
    sparse, // Empty, lonely, minimal decoration
    lush, // Abundant vegetation, dense
    wild, // Chaos, height variance, sub-biomes

    /// Get mood for a world position (deterministic, large grid)
    pub fn get(seed: u64, world_x: i32, world_z: i32) RegionMood {
        const REGION_SIZE = 2048;

        // Grid coordinates
        const rx = @divFloor(world_x, REGION_SIZE);
        const rz = @divFloor(world_z, REGION_SIZE);

        // Hash region coordinates with seed
        var prng = std.Random.DefaultPrng.init(seed +%
            @as(u64, @bitCast(@as(i64, rx))) *% 0x9E3779B97F4A7C15 +%
            @as(u64, @bitCast(@as(i64, rz))) *% 0xC6A4A7935BD1E995);
        const rand = prng.random();

        // Weighted selection
        // Calm: 30%, Sparse: 30%, Lush: 25%, Wild: 15%
        const roll = rand.float(f32);
        if (roll < 0.30) return .calm;
        if (roll < 0.60) return .sparse;
        if (roll < 0.85) return .lush;
        return .wild;
    }

    /// Multiplier for vegetation density (trees, grass, etc.)
    pub fn getVegetationMultiplier(self: RegionMood) f32 {
        return switch (self) {
            .calm => 0.5,
            .sparse => 0.1, // Very low
            .lush => 1.5,
            .wild => 0.8, // Patchy
        };
    }

    /// Multiplier for height variance/noise amplitude
    pub fn getHeightMultiplier(self: RegionMood) f32 {
        return switch (self) {
            .calm => 0.6, // Flatten small hills
            .sparse => 0.3, // Very flat
            .lush => 0.9, // Slightly reduced for walkability
            .wild => 1.3, // Exaggerated
        };
    }

    /// Are rivers allowed?
    pub fn allowRivers(self: RegionMood) bool {
        return switch (self) {
            .calm => false,
            .sparse => false,
            .lush => true, // Rare (handled by caller logic usually, or probabilistic)
            .wild => true,
        };
    }

    /// Are sub-biomes (variants) allowed?
    pub fn allowSubBiomes(self: RegionMood) bool {
        return switch (self) {
            .calm => false, // Rare (bool check forces hard binary decision)
            .sparse => false,
            .lush => true,
            .wild => true,
        };
    }

    /// Debug color for visualization (RGB)
    pub fn getColor(self: RegionMood) [3]f32 {
        return switch (self) {
            .calm => .{ 0.2, 0.4, 0.8 }, // Blue
            .sparse => .{ 0.5, 0.5, 0.5 }, // Gray
            .lush => .{ 0.2, 0.8, 0.2 }, // Green
            .wild => .{ 0.8, 0.2, 0.2 }, // Red
        };
    }
};
