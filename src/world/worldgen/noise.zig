//! Simplex/Perlin noise implementation for terrain generation.
//! Includes fBm, ridged noise, domain warping utilities per worldgen-spec2.

const std = @import("std");

/// Smoothstep function for smooth interpolation between edges
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Clamp value to [0, 1] range
pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

pub const Noise = struct {
    seed: u64,

    // Permutation table
    perm: [512]u8,

    pub fn init(seed: u64) Noise {
        var noise = Noise{
            .seed = seed,
            .perm = undefined,
        };

        // Initialize permutation table
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        // Fill first 256 entries
        for (0..256) |i| {
            noise.perm[i] = @intCast(i);
        }

        // Shuffle
        for (0..256) |i| {
            const j = random.intRangeAtMost(usize, 0, 255);
            const tmp = noise.perm[i];
            noise.perm[i] = noise.perm[j];
            noise.perm[j] = tmp;
        }

        // Duplicate for overflow
        for (0..256) |i| {
            noise.perm[256 + i] = noise.perm[i];
        }

        return noise;
    }

    /// 2D Perlin noise, returns value in range [-1, 1]
    pub fn perlin2D(self: *const Noise, x: f32, y: f32) f32 {
        // Find unit grid cell
        const xi: i32 = @intFromFloat(@floor(x));
        const yi: i32 = @intFromFloat(@floor(y));

        // Get relative position in cell
        const xf = x - @floor(x);
        const yf = y - @floor(y);

        // Fade curves
        const u = fade(xf);
        const v = fade(yf);

        // Hash coordinates of corners
        const aa = self.perm[@intCast(@mod(xi, 256) + self.perm[@intCast(@mod(yi, 256))])];
        const ab = self.perm[@intCast(@mod(xi, 256) + self.perm[@intCast(@mod(yi + 1, 256))])];
        const ba = self.perm[@intCast(@mod(xi + 1, 256) + self.perm[@intCast(@mod(yi, 256))])];
        const bb = self.perm[@intCast(@mod(xi + 1, 256) + self.perm[@intCast(@mod(yi + 1, 256))])];

        // Gradient dot products
        const g1 = grad2D(aa, xf, yf);
        const g2 = grad2D(ba, xf - 1, yf);
        const g3 = grad2D(ab, xf, yf - 1);
        const g4 = grad2D(bb, xf - 1, yf - 1);

        // Interpolate
        const x1 = lerp(g1, g2, u);
        const x2 = lerp(g3, g4, u);

        return lerp(x1, x2, v);
    }

    /// 3D Perlin noise, returns value in range [-1, 1]
    pub fn perlin3D(self: *const Noise, x: f32, y: f32, z: f32) f32 {
        const xi: i32 = @intFromFloat(@floor(x));
        const yi: i32 = @intFromFloat(@floor(y));
        const zi: i32 = @intFromFloat(@floor(z));

        const xf = x - @floor(x);
        const yf = y - @floor(y);
        const zf = z - @floor(z);

        const u = fade(xf);
        const v = fade(yf);
        const w = fade(zf);

        const a = self.perm[@intCast(@mod(xi, 256))] + @as(usize, @intCast(@mod(yi, 256)));
        const aa = self.perm[@intCast(@mod(a, 256))] + @as(usize, @intCast(@mod(zi, 256)));
        const ab = self.perm[@intCast(@mod(a + 1, 256))] + @as(usize, @intCast(@mod(zi, 256)));
        const b = self.perm[@intCast(@mod(xi + 1, 256))] + @as(usize, @intCast(@mod(yi, 256)));
        const ba = self.perm[@intCast(@mod(b, 256))] + @as(usize, @intCast(@mod(zi, 256)));
        const bb = self.perm[@intCast(@mod(b + 1, 256))] + @as(usize, @intCast(@mod(zi, 256)));

        // Gradients
        const g1 = grad3D(self.perm[@intCast(@mod(aa, 256))], xf, yf, zf);
        const g2 = grad3D(self.perm[@intCast(@mod(ba, 256))], xf - 1, yf, zf);
        const g3 = grad3D(self.perm[@intCast(@mod(ab, 256))], xf, yf - 1, zf);
        const g4 = grad3D(self.perm[@intCast(@mod(bb, 256))], xf - 1, yf - 1, zf);
        const g5 = grad3D(self.perm[@intCast(@mod(aa + 1, 256))], xf, yf, zf - 1);
        const g6 = grad3D(self.perm[@intCast(@mod(ba + 1, 256))], xf - 1, yf, zf - 1);
        const g7 = grad3D(self.perm[@intCast(@mod(ab + 1, 256))], xf, yf - 1, zf - 1);
        const g8 = grad3D(self.perm[@intCast(@mod(bb + 1, 256))], xf - 1, yf - 1, zf - 1);

        const x1 = lerp(g1, g2, u);
        const x2 = lerp(g3, g4, u);
        const y1 = lerp(x1, x2, v);

        const x3 = lerp(g5, g6, u);
        const x4 = lerp(g7, g8, u);
        const y2 = lerp(x3, x4, v);

        return lerp(y1, y2, w);
    }

    /// Fractal Brownian Motion 2D - multiple octaves of noise
    /// Returns value normalized to approximately [-1, 1]
    pub fn fbm2D(self: *const Noise, x: f32, y: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        var total: f32 = 0;
        var current_frequency: f32 = frequency;
        var amplitude: f32 = 1;
        var max_value: f32 = 0;

        for (0..octaves) |_| {
            total += self.perlin2D(x * current_frequency, y * current_frequency) * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            current_frequency *= lacunarity;
        }

        return total / max_value;
    }

    /// Fractal Brownian Motion 3D - multiple octaves of 3D noise
    /// Returns value normalized to approximately [-1, 1]
    pub fn fbm3D(self: *const Noise, x: f32, y: f32, z: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        var total: f32 = 0;
        var current_frequency: f32 = frequency;
        var amplitude: f32 = 1;
        var max_value: f32 = 0;

        for (0..octaves) |_| {
            total += self.perlin3D(
                x * current_frequency,
                y * current_frequency,
                z * current_frequency,
            ) * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            current_frequency *= lacunarity;
        }

        return total / max_value;
    }

    /// Ridged noise 2D - creates ridge-like patterns (good for mountains, rivers)
    /// Returns value in [0, 1] range where valleys are near 0
    pub fn ridged2D(self: *const Noise, x: f32, y: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        var total: f32 = 0;
        var current_frequency: f32 = frequency;
        var amplitude: f32 = 1;
        var weight: f32 = 1;
        var max_value: f32 = 0;

        for (0..octaves) |_| {
            // Get absolute value of noise, invert it to create ridges
            var signal = self.perlin2D(x * current_frequency, y * current_frequency);
            signal = 1.0 - @abs(signal);
            signal = signal * signal; // Square for sharper ridges

            // Weight by previous octave
            signal *= weight;
            weight = std.math.clamp(signal * 2.0, 0.0, 1.0);

            total += signal * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            current_frequency *= lacunarity;
        }

        return total / max_value;
    }

    /// Sample 2D fBm and normalize to [0, 1] range
    pub fn fbm2DNormalized(self: *const Noise, x: f32, y: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        const val = self.fbm2D(x, y, octaves, lacunarity, persistence, frequency);
        return (val + 1.0) * 0.5;
    }

    /// Get height value normalized to 0-1 range (legacy compatibility)
    pub fn getHeight(self: *const Noise, x: f32, z: f32, scale: f32) f32 {
        const noise_val = self.fbm2D(x, z, 4, 2.0, 0.5, 1.0 / scale);
        return (noise_val + 1.0) * 0.5; // Convert from [-1,1] to [0,1]
    }
};

/// 2D domain warp offset
pub const WarpOffset = struct {
    x: f32,
    z: f32,
};

/// Compute domain warp offsets from low-frequency noise
/// Returns offsets to add to coordinates before sampling other noise fields
pub fn computeDomainWarp(
    warp_noise_x: *const Noise,
    warp_noise_z: *const Noise,
    x: f32,
    z: f32,
    warp_scale: f32,
    warp_amplitude: f32,
) WarpOffset {
    const offset_x = warp_noise_x.fbm2D(x, z, 3, 2.0, 0.5, warp_scale) * warp_amplitude;
    const offset_z = warp_noise_z.fbm2D(x, z, 3, 2.0, 0.5, warp_scale) * warp_amplitude;
    return .{
        .x = offset_x,
        .z = offset_z,
    };
}

fn fade(t: f32) f32 {
    // 6t^5 - 15t^4 + 10t^3
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}

fn grad2D(hash: u8, x: f32, y: f32) f32 {
    // Use lower 2 bits to select gradient direction
    return switch (hash & 3) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        else => unreachable,
    };
}

fn grad3D(hash: u8, x: f32, y: f32, z: f32) f32 {
    // Convert low 4 bits of hash code into 12 gradient directions
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
}
