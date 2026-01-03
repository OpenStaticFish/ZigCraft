//! Noise generation utilities
//! Re-exports from zig-noise library plus Luanti-style NoiseParams system

const zig_noise = @import("zig-noise");

// Core noise types
pub const Noise = zig_noise.Noise;

// Utility functions
pub const smoothstep = zig_noise.smoothstep;
pub const clamp01 = zig_noise.clamp01;
pub const computeDomainWarp = zig_noise.computeDomainWarp;

// Luanti-style NoiseParams system (Issue #104)
pub const Vec3f = zig_noise.Vec3f;
pub const NoiseFlags = zig_noise.NoiseFlags;
pub const NoiseParams = zig_noise.NoiseParams;
pub const ConfiguredNoise = zig_noise.ConfiguredNoise;
