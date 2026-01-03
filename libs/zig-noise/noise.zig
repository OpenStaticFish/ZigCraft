const std = @import("std");

// ============================================================================
// Luanti-style NoiseParams System (Issue #104)
// ============================================================================

/// 3D vector for anisotropic spread values
pub const Vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3f {
        return .{ .x = x, .y = y, .z = z };
    }

    /// Create uniform spread (same value for all axes)
    pub fn uniform(v: f32) Vec3f {
        return .{ .x = v, .y = v, .z = v };
    }
};

/// Noise generation flags (matches Luanti's NoiseFlags)
pub const NoiseFlags = packed struct {
    /// Use quintic (5th degree) interpolation for smoother results
    /// When false, uses linear interpolation (faster but more artifacts)
    eased: bool = true,
    /// Take absolute value of noise - creates ridged/billowy terrain
    /// Useful for mountain ridges, river channels
    absvalue: bool = false,
    _padding: u6 = 0,
};

/// Noise parameters following Luanti conventions
/// Key difference from raw frequency: uses 'spread' (feature size in blocks)
/// instead of frequency. spread=600 means features repeat every ~600 blocks.
pub const NoiseParams = struct {
    /// Value added to final noise output
    offset: f32 = 0,
    /// Amplitude multiplier for noise output
    scale: f32 = 1,
    /// Feature size in blocks for X, Y, Z axes
    /// Larger values = larger features, smaller frequency
    spread: Vec3f = Vec3f.uniform(600),
    /// Random seed for this noise layer
    seed: u64,
    /// Number of octaves for fractal noise (1-16 typical)
    octaves: u16 = 4,
    /// Persistence: amplitude multiplier per octave (0.5 typical)
    /// Lower = smoother, higher = more detail
    persist: f32 = 0.5,
    /// Lacunarity: frequency multiplier per octave (2.0 typical)
    lacunarity: f32 = 2.0,
    /// Noise generation flags
    flags: NoiseFlags = .{},

    /// Convert spread to 2D frequency (uses X component)
    pub fn getFrequency2D(self: NoiseParams) f32 {
        return 1.0 / self.spread.x;
    }

    /// Convert spread to 3D frequency vector (anisotropic)
    pub fn getFrequency3D(self: NoiseParams) Vec3f {
        return .{
            .x = 1.0 / self.spread.x,
            .y = 1.0 / self.spread.y,
            .z = 1.0 / self.spread.z,
        };
    }
};

/// Configured noise source that combines Noise + NoiseParams
/// Provides convenient get2D/get3D methods with all parameters baked in
pub const ConfiguredNoise = struct {
    noise: Noise,
    params: NoiseParams,

    pub fn init(params: NoiseParams) ConfiguredNoise {
        return .{
            .noise = Noise.init(params.seed),
            .params = params,
        };
    }

    /// Sample 2D noise at world coordinates
    /// Returns: offset + scale * fbm(x, z)
    pub fn get2D(self: *const ConfiguredNoise, x: f32, z: f32) f32 {
        const freq = self.params.getFrequency2D();
        var val = self.noise.fbm2D(
            x,
            z,
            self.params.octaves,
            self.params.lacunarity,
            self.params.persist,
            freq,
        );

        if (self.params.flags.absvalue) {
            val = @abs(val);
        }

        return val * self.params.scale + self.params.offset;
    }

    /// Sample 3D noise at world coordinates with anisotropic spread
    /// Returns: offset + scale * fbm3D(x, y, z)
    pub fn get3D(self: *const ConfiguredNoise, x: f32, y: f32, z: f32) f32 {
        const freq = self.params.getFrequency3D();

        // Manual FBM with anisotropic frequency
        var total: f32 = 0;
        var amplitude: f32 = 1;
        var max_val: f32 = 0;
        var curr_freq = freq;

        for (0..self.params.octaves) |_| {
            total += self.noise.perlin3D(
                x * curr_freq.x,
                y * curr_freq.y,
                z * curr_freq.z,
            ) * amplitude;
            max_val += amplitude;
            amplitude *= self.params.persist;
            curr_freq.x *= self.params.lacunarity;
            curr_freq.y *= self.params.lacunarity;
            curr_freq.z *= self.params.lacunarity;
        }

        var val = total / max_val;

        if (self.params.flags.absvalue) {
            val = @abs(val);
        }

        return val * self.params.scale + self.params.offset;
    }

    /// Sample 2D noise normalized to 0-1 range
    pub fn get2DNormalized(self: *const ConfiguredNoise, x: f32, z: f32) f32 {
        const freq = self.params.getFrequency2D();
        var val = self.noise.fbm2D(
            x,
            z,
            self.params.octaves,
            self.params.lacunarity,
            self.params.persist,
            freq,
        );

        if (self.params.flags.absvalue) {
            val = @abs(val);
            // absvalue range is 0 to ~1
            return clamp01(val * self.params.scale + self.params.offset);
        }

        // Normal range is -1 to 1, normalize to 0-1
        val = (val + 1.0) * 0.5;
        return clamp01(val * self.params.scale + self.params.offset);
    }

    /// Sample 2D ridged noise (built-in absvalue behavior)
    /// Useful for mountain ridges regardless of flags setting
    pub fn get2DRidged(self: *const ConfiguredNoise, x: f32, z: f32) f32 {
        const freq = self.params.getFrequency2D();
        const val = self.noise.ridged2D(
            x,
            z,
            self.params.octaves,
            self.params.lacunarity,
            self.params.persist,
            freq,
        );
        return val * self.params.scale + self.params.offset;
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

pub const Noise = struct {
    seed: u64,
    perm: [512]u8,

    pub fn init(seed: u64) Noise {
        var noise = Noise{
            .seed = seed,
            .perm = undefined,
        };

        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        for (0..256) |i| {
            noise.perm[i] = @intCast(i);
        }

        for (0..256) |i| {
            const j = random.intRangeAtMost(usize, 0, 255);
            const tmp = noise.perm[i];
            noise.perm[i] = noise.perm[j];
            noise.perm[j] = tmp;
        }

        for (0..256) |i| {
            noise.perm[256 + i] = noise.perm[i];
        }

        return noise;
    }

    pub fn perlin2D(self: *const Noise, x: f32, y: f32) f32 {
        const xi: i64 = @intFromFloat(@floor(x));
        const yi: i64 = @intFromFloat(@floor(y));

        const xf = x - @floor(x);
        const yf = y - @floor(y);

        const u = fade(xf);
        const v = fade(yf);

        const xi_idx = @as(usize, @intCast(@mod(xi, 256)));
        const yi_idx = @as(usize, @intCast(@mod(yi, 256)));
        const xi_idx1 = @as(usize, @intCast(@mod(xi + 1, 256)));
        const yi_idx1 = @as(usize, @intCast(@mod(yi + 1, 256)));

        const aa = self.perm[xi_idx + self.perm[yi_idx]];
        const ab = self.perm[xi_idx + self.perm[yi_idx1]];
        const ba = self.perm[xi_idx1 + self.perm[yi_idx]];
        const bb = self.perm[xi_idx1 + self.perm[yi_idx1]];

        const g1 = grad2D(aa, xf, yf);
        const g2 = grad2D(ba, xf - 1, yf);
        const g3 = grad2D(ab, xf, yf - 1);
        const g4 = grad2D(bb, xf - 1, yf - 1);

        const x1 = lerp(g1, g2, u);
        const x2 = lerp(g3, g4, u);

        return lerp(x1, x2, v);
    }

    pub fn perlin3D(self: *const Noise, x: f32, y: f32, z: f32) f32 {
        const xi: i64 = @intFromFloat(@floor(x));
        const yi: i64 = @intFromFloat(@floor(y));
        const zi: i64 = @intFromFloat(@floor(z));

        const xf = x - @floor(x);
        const yf = y - @floor(y);
        const zf = z - @floor(z);

        const u = fade(xf);
        const v = fade(yf);
        const w = fade(zf);

        const xi_idx = @as(usize, @intCast(@mod(xi, 256)));
        const yi_idx = @as(usize, @intCast(@mod(yi, 256)));
        const zi_idx = @as(usize, @intCast(@mod(zi, 256)));
        const xi_idx1 = @as(usize, @intCast(@mod(xi + 1, 256)));
        const yi_idx1 = @as(usize, @intCast(@mod(yi + 1, 256)));
        const zi_idx1 = @as(usize, @intCast(@mod(zi + 1, 256)));

        const a = self.perm[xi_idx] + yi_idx;
        const aa = self.perm[a] + zi_idx;
        const ab = self.perm[a] + zi_idx1;
        const b = self.perm[xi_idx1] + yi_idx;
        const ba = self.perm[b] + zi_idx;
        const bb = self.perm[b] + zi_idx1;

        const a1 = self.perm[xi_idx] + yi_idx1;
        const aa1 = self.perm[a1] + zi_idx;
        const ab1 = self.perm[a1] + zi_idx1;
        const b1 = self.perm[xi_idx1] + yi_idx1;
        const ba1 = self.perm[b1] + zi_idx;
        const bb1 = self.perm[b1] + zi_idx1;

        const g1 = grad3D(self.perm[aa], xf, yf, zf);
        const g2 = grad3D(self.perm[ba], xf - 1, yf, zf);
        const g3 = grad3D(self.perm[ab], xf, yf - 1, zf);
        const g4 = grad3D(self.perm[bb], xf - 1, yf - 1, zf);
        const g5 = grad3D(self.perm[aa1], xf, yf, zf - 1);
        const g6 = grad3D(self.perm[ba1], xf - 1, yf, zf - 1);
        const g7 = grad3D(self.perm[ab1], xf, yf - 1, zf - 1);
        const g8 = grad3D(self.perm[bb1], xf - 1, yf - 1, zf - 1);

        const x1 = lerp(g1, g2, u);
        const x2 = lerp(g3, g4, u);
        const y1 = lerp(x1, x2, v);

        const x3 = lerp(g5, g6, u);
        const x4 = lerp(g7, g8, u);
        const y2 = lerp(x3, x4, v);

        return lerp(y1, y2, w);
    }

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

    pub fn ridged2D(self: *const Noise, x: f32, y: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        var total: f32 = 0;
        var current_frequency: f32 = frequency;
        var amplitude: f32 = 1;
        var weight: f32 = 1;
        var max_value: f32 = 0;

        for (0..octaves) |_| {
            var signal = self.perlin2D(x * current_frequency, y * current_frequency);
            signal = 1.0 - @abs(signal);
            signal = signal * signal;

            signal *= weight;
            weight = std.math.clamp(signal * 2.0, 0.0, 1.0);

            total += signal * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            current_frequency *= lacunarity;
        }

        return total / max_value;
    }

    pub fn fbm2DNormalized(self: *const Noise, x: f32, y: f32, octaves: u32, lacunarity: f32, persistence: f32, frequency: f32) f32 {
        const val = self.fbm2D(x, y, octaves, lacunarity, persistence, frequency);
        const stretched = val * 1.4;
        const normalized = (stretched + 1.0) * 0.5;
        return @min(1.0, @max(0.0, normalized));
    }

    pub fn getHeight(self: *const Noise, x: f32, z: f32, scale: f32) f32 {
        const noise_val = self.fbm2D(x, z, 4, 2.0, 0.5, 1.0 / scale);
        return (noise_val + 1.0) * 0.5;
    }
};

pub const WarpOffset = struct {
    x: f32,
    z: f32,
};

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

pub fn hash3(x: f32, y: f32, z: f32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const zi: i32 = @intFromFloat(@floor(z));

    var h: u32 = @bitCast(xi *% 374761393 +% yi *% 668265263 +% zi *% 432432431);
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> 16);

    return @as(f32, @floatFromInt(h)) / 4294967295.0;
}

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}

fn grad2D(hash: u8, x: f32, y: f32) f32 {
    return switch (hash & 3) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        else => unreachable,
    };
}

fn grad3D(hash: u8, x: f32, y: f32, z: f32) f32 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    return (if ((h & 1) == 0) u else -u) + (if ((h & 2) == 0) v else -v);
}
