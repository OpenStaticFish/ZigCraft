const std = @import("std");

/// Halton sequence generator for TAA jitter
pub const JitterGenerator = struct {
    /// Generate Halton sequence sample for TAA jitter
    /// index: sample index (e.g. frame index % period)
    /// base: prime number (usually 2 for X, 3 for Y)
    pub fn halton(index: u32, base: u32) f32 {
        var f: f32 = 1.0;
        var r: f32 = 0.0;
        var i = index;

        const inv_base = 1.0 / @as(f32, @floatFromInt(base));

        while (i > 0) {
            f *= inv_base;
            r += f * @as(f32, @floatFromInt(i % base));
            i /= base;
        }

        return r;
    }
};
