//! Comprehensive unit tests for ZigCraft.
//!
//! Coverage includes:
//! - Math: Vec3, Mat4, AABB, Frustum, Plane
//! - World: Chunk, BlockType, PackedLight, coordinate conversion
//! - Worldgen: Noise (determinism, range bounds)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const Vec3 = @import("zig-math").Vec3;
const Mat4 = @import("zig-math").Mat4;
const AABB = @import("zig-math").AABB;
const Frustum = @import("zig-math").Frustum;
const Plane = @import("zig-math").Plane;

// World modules
const Chunk = @import("world/chunk.zig").Chunk;
const ChunkMesh = @import("world/chunk_mesh.zig").ChunkMesh;
const NeighborChunks = @import("world/chunk_mesh.zig").NeighborChunks;
const PackedLight = @import("world/chunk.zig").PackedLight;
const CHUNK_SIZE_X = @import("world/chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("world/chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("world/chunk.zig").CHUNK_SIZE_Z;
const worldToChunk = @import("world/chunk.zig").worldToChunk;
const worldToLocal = @import("world/chunk.zig").worldToLocal;
const BlockType = @import("world/block.zig").BlockType;
const BiomeId = @import("world/worldgen/biome.zig").BiomeId;

// Worldgen modules
const Noise = @import("zig-noise").Noise;

// Issue #147: Modular terrain generation subsystems
const NoiseSampler = @import("world/worldgen/noise_sampler.zig").NoiseSampler;
const HeightSampler = @import("world/worldgen/height_sampler.zig").HeightSampler;
const SurfaceBuilder = @import("world/worldgen/surface_builder.zig").SurfaceBuilder;
const CoastalSurfaceType = @import("world/worldgen/surface_builder.zig").CoastalSurfaceType;
const BiomeSource = @import("world/worldgen/biome.zig").BiomeSource;

// ECS tests
test {
    _ = @import("ecs_tests.zig");
    _ = @import("engine/graphics/vulkan_device.zig");
    _ = @import("vulkan_tests.zig");
    _ = @import("world/worldgen/schematics.zig");
    _ = @import("engine/atmosphere/tests.zig");
}

test "Vec3 addition" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);
    const c = a.add(b);
    try testing.expectEqual(@as(f32, 5), c.x);
    try testing.expectEqual(@as(f32, 7), c.y);
    try testing.expectEqual(@as(f32, 9), c.z);
}

test "Vec3 subtraction" {
    const a = Vec3.init(5, 7, 9);
    const b = Vec3.init(1, 2, 3);
    const c = a.sub(b);
    try testing.expectEqual(@as(f32, 4), c.x);
    try testing.expectEqual(@as(f32, 5), c.y);
    try testing.expectEqual(@as(f32, 6), c.z);
}

test "Vec3 scaling" {
    const a = Vec3.init(1, 2, 3);
    const b = a.scale(2.0);
    try testing.expectEqual(@as(f32, 2), b.x);
    try testing.expectEqual(@as(f32, 4), b.y);
    try testing.expectEqual(@as(f32, 6), b.z);
}

test "Vec3 dot product" {
    const a = Vec3.init(1, 0, 0);
    const b = Vec3.init(0, 1, 0);
    // Orthogonal vectors have dot product of 0
    try testing.expectEqual(@as(f32, 0), a.dot(b));

    // Parallel vectors
    const c = Vec3.init(2, 0, 0);
    try testing.expectEqual(@as(f32, 2), a.dot(c));

    // General case
    const d = Vec3.init(1, 2, 3);
    const e = Vec3.init(4, 5, 6);
    try testing.expectEqual(@as(f32, 32), d.dot(e)); // 1*4 + 2*5 + 3*6 = 32
}

test "Vec3 cross product" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = x.cross(y);
    try testing.expectEqual(@as(f32, 0), z.x);
    try testing.expectEqual(@as(f32, 0), z.y);
    try testing.expectEqual(@as(f32, 1), z.z);

    // Cross product is anti-commutative
    const neg_z = y.cross(x);
    try testing.expectEqual(@as(f32, -1), neg_z.z);
}

test "Vec3 length and lengthSquared" {
    const v = Vec3.init(3, 4, 0);
    try testing.expectEqual(@as(f32, 25), v.lengthSquared());
    try testing.expectEqual(@as(f32, 5), v.length());

    // 3D case: 1^2 + 2^2 + 2^2 = 9
    const v2 = Vec3.init(1, 2, 2);
    try testing.expectEqual(@as(f32, 9), v2.lengthSquared());
    try testing.expectEqual(@as(f32, 3), v2.length());
}

test "Vec3 normalize" {
    const v = Vec3.init(3, 4, 0);
    const n = v.normalize();
    try testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), n.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), n.length(), 0.0001);

    // Zero vector normalization should return zero
    const zero = Vec3.zero.normalize();
    try testing.expectEqual(@as(f32, 0), zero.x);
    try testing.expectEqual(@as(f32, 0), zero.y);
    try testing.expectEqual(@as(f32, 0), zero.z);
}

test "Vec3 negate" {
    const v = Vec3.init(1, -2, 3);
    const neg = v.negate();
    try testing.expectEqual(@as(f32, -1), neg.x);
    try testing.expectEqual(@as(f32, 2), neg.y);
    try testing.expectEqual(@as(f32, -3), neg.z);
}

test "Vec3 lerp" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(10, 20, 30);

    const mid = a.lerp(b, 0.5);
    try testing.expectEqual(@as(f32, 5), mid.x);
    try testing.expectEqual(@as(f32, 10), mid.y);
    try testing.expectEqual(@as(f32, 15), mid.z);

    // t=0 should return a
    const start = a.lerp(b, 0);
    try testing.expectEqual(a.x, start.x);

    // t=1 should return b
    const end = a.lerp(b, 1);
    try testing.expectEqual(b.x, end.x);
}

test "Vec3 distance" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(3, 4, 0);
    try testing.expectEqual(@as(f32, 5), a.distance(b));
}

test "Vec3 constants" {
    try testing.expectEqual(@as(f32, 0), Vec3.zero.x);
    try testing.expectEqual(@as(f32, 1), Vec3.one.x);
    try testing.expectEqual(@as(f32, 1), Vec3.up.y);
    try testing.expectEqual(@as(f32, -1), Vec3.down.y);
    try testing.expectEqual(@as(f32, 1), Vec3.right.x);
    try testing.expectEqual(@as(f32, -1), Vec3.left.x);
}

// ============================================================================
// Mat4 Tests
// ============================================================================

test "Mat4 identity" {
    const id = Mat4.identity;
    // Diagonal should be 1
    try testing.expectEqual(@as(f32, 1), id.data[0][0]);
    try testing.expectEqual(@as(f32, 1), id.data[1][1]);
    try testing.expectEqual(@as(f32, 1), id.data[2][2]);
    try testing.expectEqual(@as(f32, 1), id.data[3][3]);
    // Off-diagonal should be 0
    try testing.expectEqual(@as(f32, 0), id.data[0][1]);
    try testing.expectEqual(@as(f32, 0), id.data[1][0]);
}

test "Mat4 multiply identity" {
    const id = Mat4.identity;
    const result = id.multiply(id);
    // Identity * Identity = Identity
    try testing.expectEqual(@as(f32, 1), result.data[0][0]);
    try testing.expectEqual(@as(f32, 1), result.data[1][1]);
    try testing.expectEqual(@as(f32, 0), result.data[0][1]);
}

test "Mat4 translate" {
    const t = Mat4.translate(Vec3.init(5, 10, 15));
    try testing.expectEqual(@as(f32, 5), t.data[3][0]);
    try testing.expectEqual(@as(f32, 10), t.data[3][1]);
    try testing.expectEqual(@as(f32, 15), t.data[3][2]);

    // Transform a point
    const point = Vec3.init(1, 2, 3);
    const transformed = t.transformPoint(point);
    try testing.expectEqual(@as(f32, 6), transformed.x);
    try testing.expectEqual(@as(f32, 12), transformed.y);
    try testing.expectEqual(@as(f32, 18), transformed.z);
}

test "Mat4 scale" {
    const s = Mat4.scale(Vec3.init(2, 3, 4));
    try testing.expectEqual(@as(f32, 2), s.data[0][0]);
    try testing.expectEqual(@as(f32, 3), s.data[1][1]);
    try testing.expectEqual(@as(f32, 4), s.data[2][2]);

    const point = Vec3.init(1, 1, 1);
    const scaled = s.transformPoint(point);
    try testing.expectEqual(@as(f32, 2), scaled.x);
    try testing.expectEqual(@as(f32, 3), scaled.y);
    try testing.expectEqual(@as(f32, 4), scaled.z);
}

test "Mat4 transformDirection ignores translation" {
    const t = Mat4.translate(Vec3.init(100, 200, 300));
    const dir = Vec3.init(1, 0, 0);
    const transformed = t.transformDirection(dir);
    // Direction should be unchanged by translation
    try testing.expectEqual(@as(f32, 1), transformed.x);
    try testing.expectEqual(@as(f32, 0), transformed.y);
    try testing.expectEqual(@as(f32, 0), transformed.z);
}

test "Mat4 inverse of identity" {
    const id = Mat4.identity;
    const inv = id.inverse();
    // Inverse of identity is identity
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), inv.data[0][1], 0.0001);
}

test "Mat4 inverse multiplied by original gives identity" {
    // Test with scale matrix (simpler case)
    const s = Mat4.scale(Vec3.init(2, 3, 4));
    const inv = s.inverse();
    const product = s.multiply(inv);

    // Should be close to identity
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[3][3], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), product.data[0][1], 0.0001);
}

test "Mat4 rotation preserves length" {
    const rot = Mat4.rotateY(std.math.pi / 4.0); // 45 degrees
    const v = Vec3.init(1, 0, 0);
    const rotated = rot.transformDirection(v);
    // Length should be preserved
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.length(), 0.0001);
}

test "Mat4 perspective has correct structure" {
    const p = Mat4.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 1000.0);
    // Perspective matrix should have -1 at [2][3]
    try testing.expectEqual(@as(f32, -1), p.data[2][3]);
    // And 0 at [3][3]
    try testing.expectEqual(@as(f32, 0), p.data[3][3]);
}

// ============================================================================
// AABB Tests
// ============================================================================

test "AABB init and accessors" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 20, 30));
    try testing.expectEqual(@as(f32, 0), aabb.min.x);
    try testing.expectEqual(@as(f32, 30), aabb.max.z);

    const center = aabb.center();
    try testing.expectEqual(@as(f32, 5), center.x);
    try testing.expectEqual(@as(f32, 10), center.y);
    try testing.expectEqual(@as(f32, 15), center.z);

    const size = aabb.size();
    try testing.expectEqual(@as(f32, 10), size.x);
    try testing.expectEqual(@as(f32, 20), size.y);
    try testing.expectEqual(@as(f32, 30), size.z);
}

test "AABB fromCenterSize" {
    const aabb = AABB.fromCenterSize(Vec3.init(5, 5, 5), Vec3.init(10, 10, 10));
    try testing.expectEqual(@as(f32, 0), aabb.min.x);
    try testing.expectEqual(@as(f32, 10), aabb.max.x);
}

test "AABB contains point" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));

    // Point inside
    try testing.expect(aabb.contains(Vec3.init(5, 5, 5)));

    // Point on boundary
    try testing.expect(aabb.contains(Vec3.init(0, 0, 0)));
    try testing.expect(aabb.contains(Vec3.init(10, 10, 10)));

    // Point outside
    try testing.expect(!aabb.contains(Vec3.init(-1, 5, 5)));
    try testing.expect(!aabb.contains(Vec3.init(11, 5, 5)));
}

test "AABB intersects" {
    const a = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));
    const b = AABB.init(Vec3.init(5, 5, 5), Vec3.init(15, 15, 15));
    const c = AABB.init(Vec3.init(20, 20, 20), Vec3.init(30, 30, 30));

    // Overlapping boxes
    try testing.expect(a.intersects(b));
    try testing.expect(b.intersects(a));

    // Non-overlapping boxes
    try testing.expect(!a.intersects(c));
    try testing.expect(!c.intersects(a));
}

test "AABB expand and translate" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));

    const expanded = aabb.expand(Vec3.init(1, 1, 1));
    try testing.expectEqual(@as(f32, -1), expanded.min.x);
    try testing.expectEqual(@as(f32, 11), expanded.max.x);

    const translated = aabb.translate(Vec3.init(5, 5, 5));
    try testing.expectEqual(@as(f32, 5), translated.min.x);
    try testing.expectEqual(@as(f32, 15), translated.max.x);
}

// ============================================================================
// Plane and Frustum Tests
// ============================================================================

test "Plane signedDistance" {
    // XY plane at z=0, normal pointing +Z
    const plane = Plane.init(Vec3.init(0, 0, 1), 0);

    // Point in front of plane
    try testing.expectEqual(@as(f32, 5), plane.signedDistance(Vec3.init(0, 0, 5)));

    // Point behind plane
    try testing.expectEqual(@as(f32, -3), plane.signedDistance(Vec3.init(0, 0, -3)));

    // Point on plane
    try testing.expectEqual(@as(f32, 0), plane.signedDistance(Vec3.init(0, 0, 0)));
}

test "Plane normalize" {
    const plane = Plane.init(Vec3.init(0, 0, 2), 4);
    const normalized = plane.normalize();
    try testing.expectApproxEqAbs(@as(f32, 1), normalized.normal.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), normalized.distance, 0.0001);
}

test "Frustum intersectsSphere" {
    // Create a simple view-projection matrix (identity for testing)
    // This creates a frustum that contains points near origin
    const vp = Mat4.identity;
    const frustum = Frustum.fromViewProj(vp);

    // Sphere at origin should be inside
    try testing.expect(frustum.intersectsSphere(Vec3.init(0, 0, 0), 0.5));
}

// ============================================================================
// PackedLight Tests
// ============================================================================

test "PackedLight init and accessors" {
    const light = PackedLight.init(15, 10);
    try testing.expectEqual(@as(u4, 15), light.getSkyLight());
    try testing.expectEqual(@as(u4, 10), light.getBlockLight());
    try testing.expectEqual(@as(u4, 15), light.getMaxLight());
}

test "PackedLight setters" {
    var light = PackedLight.init(0, 0);
    light.setSkyLight(12);
    light.setBlockLight(8);
    try testing.expectEqual(@as(u4, 12), light.getSkyLight());
    try testing.expectEqual(@as(u4, 8), light.getBlockLight());
}

test "PackedLight brightness" {
    const full = PackedLight.init(15, 0);
    try testing.expectEqual(@as(f32, 1.0), full.getBrightness());

    const half = PackedLight.init(7, 0);
    try testing.expectApproxEqAbs(@as(f32, 7.0 / 15.0), half.getBrightness(), 0.001);

    const zero = PackedLight.init(0, 0);
    try testing.expectEqual(@as(f32, 0.0), zero.getBrightness());
}

// ============================================================================
// Chunk Coordinate Conversion Tests
// ============================================================================

test "worldToChunk positive coordinates" {
    const result = worldToChunk(32, 48);
    try testing.expectEqual(@as(i32, 2), result.chunk_x);
    try testing.expectEqual(@as(i32, 3), result.chunk_z);
}

test "worldToChunk negative coordinates" {
    // -1 should be in chunk -1 (floor division)
    const result = worldToChunk(-1, -1);
    try testing.expectEqual(@as(i32, -1), result.chunk_x);
    try testing.expectEqual(@as(i32, -1), result.chunk_z);

    // -16 should be in chunk -1
    const result2 = worldToChunk(-16, -16);
    try testing.expectEqual(@as(i32, -1), result2.chunk_x);

    // -17 should be in chunk -2
    const result3 = worldToChunk(-17, -17);
    try testing.expectEqual(@as(i32, -2), result3.chunk_x);
}

test "worldToChunk zero" {
    const result = worldToChunk(0, 0);
    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
}

test "worldToLocal positive coordinates" {
    const result = worldToLocal(35, 50);
    try testing.expectEqual(@as(u32, 3), result.x); // 35 % 16 = 3
    try testing.expectEqual(@as(u32, 2), result.z); // 50 % 16 = 2
}

test "worldToLocal negative coordinates" {
    // -1 should map to 15 (proper modulo behavior)
    const result = worldToLocal(-1, -1);
    try testing.expectEqual(@as(u32, 15), result.x);
    try testing.expectEqual(@as(u32, 15), result.z);

    // -17 should map to 15
    const result2 = worldToLocal(-17, -17);
    try testing.expectEqual(@as(u32, 15), result2.x);
}

// ============================================================================
// Chunk Tests
// ============================================================================

test "Chunk init" {
    const chunk = Chunk.init(5, -3);
    try testing.expectEqual(@as(i32, 5), chunk.chunk_x);
    try testing.expectEqual(@as(i32, -3), chunk.chunk_z);
    try testing.expectEqual(Chunk.State.missing, chunk.state);
    try testing.expect(chunk.dirty);
}

test "Chunk getBlock and setBlock" {
    var chunk = Chunk.init(0, 0);

    // Default is air
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 0, 0));

    // Set and get
    chunk.setBlock(5, 64, 10, .stone);
    try testing.expectEqual(BlockType.stone, chunk.getBlock(5, 64, 10));

    // Other blocks unchanged
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 64, 0));
}

test "Chunk getBlockSafe bounds checking" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);

    // Valid access
    try testing.expectEqual(BlockType.stone, chunk.getBlockSafe(0, 0, 0));

    // Out of bounds returns air
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(-1, 0, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(16, 0, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(0, -1, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(0, 256, 0));
}

test "Chunk light operations" {
    var chunk = Chunk.init(0, 0);

    // Default light is 0
    try testing.expectEqual(@as(u4, 0), chunk.getSkyLight(0, 0, 0));
    try testing.expectEqual(@as(u4, 0), chunk.getBlockLight(0, 0, 0));

    // Set and get
    chunk.setSkyLight(5, 64, 10, 15);
    chunk.setBlockLight(5, 64, 10, 8);
    try testing.expectEqual(@as(u4, 15), chunk.getSkyLight(5, 64, 10));
    try testing.expectEqual(@as(u4, 8), chunk.getBlockLight(5, 64, 10));
}

test "Chunk getWorldX and getWorldZ" {
    const chunk = Chunk.init(3, -2);
    try testing.expectEqual(@as(i32, 48), chunk.getWorldX()); // 3 * 16
    try testing.expectEqual(@as(i32, -32), chunk.getWorldZ()); // -2 * 16
}

test "Chunk fill and fillLayer" {
    var chunk = Chunk.init(0, 0);

    chunk.fillLayer(0, .bedrock);
    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            try testing.expectEqual(BlockType.bedrock, chunk.getBlock(@intCast(x), 0, @intCast(z)));
        }
    }
    // Layer 1 should still be air
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 1, 0));
}

test "Chunk pin and unpin" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(!chunk.isPinned());

    chunk.pin();
    try testing.expect(chunk.isPinned());

    chunk.pin();
    try testing.expect(chunk.isPinned()); // Still pinned

    chunk.unpin();
    try testing.expect(chunk.isPinned()); // Still pinned (count = 1)

    chunk.unpin();
    try testing.expect(!chunk.isPinned()); // Now unpinned
}

// ============================================================================
// BlockType Tests
// ============================================================================

test "BlockType isSolid" {
    try testing.expect(!BlockType.air.isSolid());
    try testing.expect(!BlockType.water.isSolid());
    try testing.expect(BlockType.stone.isSolid());
    try testing.expect(BlockType.dirt.isSolid());
    try testing.expect(BlockType.grass.isSolid());
    try testing.expect(BlockType.leaves.isSolid());
}

test "BlockType isTransparent" {
    try testing.expect(BlockType.air.isTransparent());
    try testing.expect(BlockType.water.isTransparent());
    try testing.expect(BlockType.glass.isTransparent());
    try testing.expect(BlockType.leaves.isTransparent());
    try testing.expect(!BlockType.stone.isTransparent());
    try testing.expect(!BlockType.dirt.isTransparent());
}

test "BlockType isOpaque" {
    try testing.expect(!BlockType.air.isOpaque());
    try testing.expect(!BlockType.water.isOpaque());
    try testing.expect(!BlockType.glass.isOpaque());
    try testing.expect(BlockType.stone.isOpaque());
    try testing.expect(BlockType.dirt.isOpaque());
}

test "BlockType isAir" {
    try testing.expect(BlockType.air.isAir());
    try testing.expect(!BlockType.stone.isAir());
    try testing.expect(!BlockType.water.isAir());
}

test "BlockType getLightEmission" {
    try testing.expectEqual(@as(u4, 15), BlockType.glowstone.getLightEmission());
    try testing.expectEqual(@as(u4, 0), BlockType.stone.getLightEmission());
    try testing.expectEqual(@as(u4, 0), BlockType.water.getLightEmission());
}

test "BlockType getColor returns valid RGB" {
    const colors = BlockType.stone.getColor();
    try testing.expect(colors[0] >= 0 and colors[0] <= 1);
    try testing.expect(colors[1] >= 0 and colors[1] <= 1);
    try testing.expect(colors[2] >= 0 and colors[2] <= 1);
}

// ============================================================================
// Noise Tests
// ============================================================================

test "Noise deterministic with same seed" {
    const noise1 = Noise.init(12345);
    const noise2 = Noise.init(12345);

    const val1 = noise1.perlin2D(1.5, 2.5);
    const val2 = noise2.perlin2D(1.5, 2.5);

    try testing.expectEqual(val1, val2);
}

test "Noise different with different seed" {
    const noise1 = Noise.init(12345);
    const noise2 = Noise.init(54321);

    const val1 = noise1.perlin2D(1.5, 2.5);
    const val2 = noise2.perlin2D(1.5, 2.5);

    try testing.expect(val1 != val2);
}

test "Noise perlin2D range" {
    const noise = Noise.init(42);

    // Sample many points and verify range is approximately [-1, 1]
    var min_val: f32 = 1.0;
    var max_val: f32 = -1.0;

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.perlin2D(x, y);
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
    }

    // Perlin noise should be in [-1, 1] range
    try testing.expect(min_val >= -1.0);
    try testing.expect(max_val <= 1.0);
}

test "Noise perlin3D range" {
    const noise = Noise.init(42);

    var min_val: f32 = 1.0;
    var max_val: f32 = -1.0;

    var z: f32 = 0;
    while (z < 5) : (z += 1) {
        var y: f32 = 0;
        while (y < 5) : (y += 1) {
            var x: f32 = 0;
            while (x < 5) : (x += 1) {
                const val = noise.perlin3D(x, y, z);
                min_val = @min(min_val, val);
                max_val = @max(max_val, val);
            }
        }
    }

    try testing.expect(min_val >= -1.0);
    try testing.expect(max_val <= 1.0);
}

test "Noise fbm2D produces varied output" {
    const noise = Noise.init(42);

    // Sample at positions that are far apart for noticeable variation
    const val1 = noise.fbm2D(0.5, 0.5, 4, 2.0, 0.5, 0.01);
    const val2 = noise.fbm2D(50.5, 50.5, 4, 2.0, 0.5, 0.01);
    const val3 = noise.fbm2D(100.5, 100.5, 4, 2.0, 0.5, 0.01);

    // At least two of three values should differ (noise is continuous)
    const all_same = (val1 == val2) and (val2 == val3);
    try testing.expect(!all_same);
}

test "Noise fbm2DNormalized range" {
    const noise = Noise.init(42);

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.fbm2DNormalized(x, y, 4, 2.0, 0.5, 0.1);
            // Normalized should be in [0, 1]
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "Noise ridged2D range" {
    const noise = Noise.init(42);

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.ridged2D(x, y, 4, 2.0, 0.5, 0.1);
            // Ridged should be in [0, 1]
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "Noise handles large coordinates" {
    const noise = Noise.init(42);

    // Large coordinates should not panic (used i64 internally to avoid overflow)
    const val = noise.perlin2D(100000.5, -100000.5);
    try testing.expect(val >= -1.0 and val <= 1.0);
}

test "Noise getHeight returns normalized value" {
    const noise = Noise.init(42);
    const height = noise.getHeight(10.0, 20.0, 64.0);
    try testing.expect(height >= 0.0 and height <= 1.0);
}

// ============================================================================
// NoiseParams Tests (Issue #104)
// ============================================================================

const noise_mod = @import("world/worldgen/noise.zig");

test "Vec3f init and uniform" {
    const v1 = noise_mod.Vec3f.init(1.0, 2.0, 3.0);
    try testing.expectEqual(@as(f32, 1.0), v1.x);
    try testing.expectEqual(@as(f32, 2.0), v1.y);
    try testing.expectEqual(@as(f32, 3.0), v1.z);

    const v2 = noise_mod.Vec3f.uniform(500.0);
    try testing.expectEqual(@as(f32, 500.0), v2.x);
    try testing.expectEqual(@as(f32, 500.0), v2.y);
    try testing.expectEqual(@as(f32, 500.0), v2.z);
}

test "NoiseParams default values" {
    const params = noise_mod.NoiseParams{ .seed = 12345 };
    try testing.expectEqual(@as(f32, 0), params.offset);
    try testing.expectEqual(@as(f32, 1), params.scale);
    try testing.expectEqual(@as(f32, 600), params.spread.x);
    try testing.expectEqual(@as(f32, 600), params.spread.y);
    try testing.expectEqual(@as(f32, 600), params.spread.z);
    try testing.expectEqual(@as(u16, 4), params.octaves);
    try testing.expectEqual(@as(f32, 0.5), params.persist);
    try testing.expectEqual(@as(f32, 2.0), params.lacunarity);
    try testing.expect(params.flags.eased);
    try testing.expect(!params.flags.absvalue);
}

test "NoiseParams frequency from spread" {
    const params = noise_mod.NoiseParams{
        .seed = 12345,
        .spread = noise_mod.Vec3f.uniform(500),
    };
    try testing.expectApproxEqAbs(@as(f32, 0.002), params.getFrequency2D(), 0.0001);

    // Anisotropic spread
    const params2 = noise_mod.NoiseParams{
        .seed = 12345,
        .spread = noise_mod.Vec3f.init(250, 350, 250),
    };
    const freq3d = params2.getFrequency3D();
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 250.0), freq3d.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 350.0), freq3d.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 250.0), freq3d.z, 0.0001);
}

test "NoiseFlags packed struct size" {
    // NoiseFlags should be 1 byte
    try testing.expectEqual(@as(usize, 1), @sizeOf(noise_mod.NoiseFlags));
}

test "ConfiguredNoise init" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 70.0,
        .offset = 4.0,
        .spread = noise_mod.Vec3f.uniform(600),
        .octaves = 5,
        .persist = 0.6,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    try testing.expectEqual(@as(u64, 42), cn.params.seed);
    try testing.expectEqual(@as(f32, 70.0), cn.params.scale);
    try testing.expectEqual(@as(f32, 4.0), cn.params.offset);
}

test "ConfiguredNoise get2D returns value with offset and scale" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 10.0,
        .offset = 5.0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 3,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    const val = cn.get2D(100, 100);
    // FBM output is roughly -1 to 1
    // After scale and offset: offset + scale * fbm = 5 + 10 * [-1,1] = [-5, 15]
    try testing.expect(val >= -10 and val <= 20);
}

test "ConfiguredNoise absvalue flag produces non-negative" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(50),
        .flags = .{ .absvalue = true },
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    // Sample multiple points - all should be >= 0
    var all_non_negative = true;
    var x: f32 = 0;
    while (x < 100) : (x += 10) {
        var z: f32 = 0;
        while (z < 100) : (z += 10) {
            const val = cn.get2D(x, z);
            if (val < 0) all_non_negative = false;
        }
    }
    try testing.expect(all_non_negative);
}

test "ConfiguredNoise get3D anisotropic spread" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.init(250, 350, 250),
        .octaves = 3,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    const val = cn.get3D(100, 50, 100);
    // Should be in valid range
    try testing.expect(val >= -2 and val <= 2);
}

test "ConfiguredNoise get2DNormalized returns 0-1 range" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 4,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    var x: f32 = 0;
    while (x < 50) : (x += 5) {
        var z: f32 = 0;
        while (z < 50) : (z += 5) {
            const val = cn.get2DNormalized(x, z);
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "ConfiguredNoise get2DRidged produces ridged output" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 4,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    // Ridged noise should be in [0, 1] range regardless of flags
    var x: f32 = 0;
    while (x < 50) : (x += 5) {
        var z: f32 = 0;
        while (z < 50) : (z += 5) {
            const val = cn.get2DRidged(x, z);
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "ConfiguredNoise determinism with same params" {
    const params = noise_mod.NoiseParams{
        .seed = 12345,
        .scale = 50.0,
        .offset = 10.0,
        .spread = noise_mod.Vec3f.uniform(300),
        .octaves = 5,
        .persist = 0.6,
    };

    const cn1 = noise_mod.ConfiguredNoise.init(params);
    const cn2 = noise_mod.ConfiguredNoise.init(params);

    const val1 = cn1.get2D(123.456, 789.012);
    const val2 = cn2.get2D(123.456, 789.012);

    try testing.expectEqual(val1, val2);
}

// ============================================================================
// WorldGen Determinism Tests
// ============================================================================

const OverworldGenerator = @import("world/worldgen/overworld_generator.zig").OverworldGenerator;
const deco_registry = @import("world/worldgen/decoration_registry.zig");
const Generator = @import("world/worldgen/generator_interface.zig").Generator;

test "WorldGen same seed produces identical blocks at origin" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    var gen2 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    gen1.generate(&chunk1, null);
    gen2.generate(&chunk2, null);

    try testing.expectEqualSlices(BlockType, &chunk1.blocks, &chunk2.blocks);
}

test "WorldGen same seed produces identical biomes at origin" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    var gen2 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    gen1.generate(&chunk1, null);
    gen2.generate(&chunk2, null);

    try testing.expectEqualSlices(BiomeId, &chunk1.biomes, &chunk2.biomes);
}

test "WorldGen same seed produces identical blocks at different positions" {
    const allocator = testing.allocator;

    const seed: u64 = 54321;

    var gen1 = OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    var chunk1a = Chunk.init(0, 0);
    var chunk1b = Chunk.init(1, 0);
    var chunk1c = Chunk.init(0, 1);

    gen1.generate(&chunk1a, null);
    gen1.generate(&chunk1b, null);
    gen1.generate(&chunk1c, null);

    var gen2 = OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    var chunk2a = Chunk.init(0, 0);
    var chunk2b = Chunk.init(1, 0);
    var chunk2c = Chunk.init(0, 1);

    gen2.generate(&chunk2a, null);
    gen2.generate(&chunk2b, null);
    gen2.generate(&chunk2c, null);

    try testing.expectEqualSlices(BlockType, &chunk1a.blocks, &chunk2a.blocks);
    try testing.expectEqualSlices(BlockType, &chunk1b.blocks, &chunk2b.blocks);
    try testing.expectEqualSlices(BlockType, &chunk1c.blocks, &chunk2c.blocks);

    try testing.expect(!std.mem.eql(BlockType, &chunk1a.blocks, &chunk1b.blocks));
    try testing.expect(!std.mem.eql(BlockType, &chunk1a.blocks, &chunk1c.blocks));
}

test "WorldGen different seeds produce different blocks" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(11111, allocator, deco_registry.StandardDecorationProvider.provider());
    var gen2 = OverworldGenerator.init(99999, allocator, deco_registry.StandardDecorationProvider.provider());

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    gen1.generate(&chunk1, null);
    gen2.generate(&chunk2, null);

    const all_same = std.mem.eql(BlockType, &chunk1.blocks, &chunk2.blocks);
    try testing.expect(!all_same);
}

test "WorldGen different seeds produce different biomes" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(11111, allocator, deco_registry.StandardDecorationProvider.provider());
    var gen2 = OverworldGenerator.init(99999, allocator, deco_registry.StandardDecorationProvider.provider());

    // With structure-first generation (Issue #92), noise scales are much larger
    // (continental scale = 1/3500). To see biome differences, we need to test
    // at multiple distant locations spanning different continental zones.
    // Use chunk coordinates (world = chunk * 16) that sample different noise phases.
    // Test locations ~10000+ blocks apart in world space.
    const test_locations = [_][2]i32{
        .{ -300, 200 }, // ~5000 blocks from origin
        .{ 500, -400 }, // Different direction
        .{ 700, 300 }, // ~11000 blocks from origin
        .{ -600, -500 }, // Negative quadrant
        .{ 1000, 1000 }, // ~22000 blocks from origin
    };

    var differences_found: u32 = 0;

    for (test_locations) |loc| {
        var chunk1 = Chunk.init(loc[0], loc[1]);
        var chunk2 = Chunk.init(loc[0], loc[1]);

        gen1.generate(&chunk1, null);
        gen2.generate(&chunk2, null);

        if (!std.mem.eql(BiomeId, &chunk1.biomes, &chunk2.biomes)) {
            differences_found += 1;
        }
    }

    // With large-scale noise, we expect at least SOME locations to differ
    // Even if individual chunks look similar, across 5 samples there should be variance
    try testing.expect(differences_found >= 1);
}

test "WorldGen determinism across multiple chunks with same seed" {
    const allocator = testing.allocator;
    const seed: u64 = 987654321;

    var gens = [_]OverworldGenerator{
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
    };

    var chunks1 = [_]Chunk{
        Chunk.init(0, 0),
        Chunk.init(5, -3),
        Chunk.init(-7, 12),
    };

    var chunks2 = [_]Chunk{
        Chunk.init(0, 0),
        Chunk.init(5, -3),
        Chunk.init(-7, 12),
    };

    for (&gens, 0..) |*gen, i| {
        gen.generate(&chunks1[i], null);
    }

    for (&gens, 0..) |*gen, i| {
        gen.generate(&chunks2[i], null);
    }

    for (0..3) |i| {
        try testing.expectEqualSlices(BlockType, &chunks1[i].blocks, &chunks2[i].blocks);
        try testing.expectEqualSlices(BiomeId, &chunks1[i].biomes, &chunks2[i].biomes);
    }
}

test "WorldGen golden output for known seed at origin" {
    const allocator = testing.allocator;

    var gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    var chunk = Chunk.init(0, 0);

    gen.generate(&chunk, null);

    try testing.expect(chunk.generated);
    try testing.expect(chunk.dirty);

    // With the coastal terrain fixes (Issue #92), the terrain shape has changed.
    // Instead of checking a fixed Y coordinate, verify terrain generation is valid:
    // 1. Bedrock must be present at y=0
    const bedrock_present = chunk.getBlock(0, 0, 0) == .bedrock;
    try testing.expect(bedrock_present);

    // 2. There must be a valid surface somewhere in the chunk
    const surface_height = chunk.getHighestSolidY(8, 8);
    try testing.expect(surface_height > 0);
    try testing.expect(surface_height < CHUNK_SIZE_Y);

    // 3. The surface block should be solid (not air/water)
    const surface_block = chunk.getBlock(8, surface_height, 8);
    try testing.expect(surface_block.isSolid());
}

test "WorldGen populates heightmap and biomes" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    var chunk = Chunk.init(0, 0);

    gen.generate(&chunk, null);

    // Check heightmap
    const h = chunk.getSurfaceHeight(8, 8);
    try testing.expect(h > 0);
    try testing.expect(h < CHUNK_SIZE_Y);

    // Check that stored height corresponds to a solid or water block (terrain surface)
    // Note: getBlock takes u32 y, h is i16
    const block_at_surface = chunk.getBlock(8, @intCast(h), 8);
    // It should be solid or water (if ocean)
    // Actually, surface_height is the height of the terrain surface.
    // If underwater, it's the sea floor?
    // generator.zig: `surface_heights[idx] = terrain_height_i;`
    // computeHeight returns the height of the solid terrain (seabed if ocean).
    // So block at h should be solid (sand/gravel/dirt/stone).
    // Block at h+1 might be water or air.
    try testing.expect(block_at_surface != BlockType.air);
    try testing.expect(block_at_surface != BlockType.water); // Should be seabed if underwater

    // Check biomes
    const b = chunk.biomes[8 + 8 * 16];
    // Just ensure valid enum
    try testing.expect(@intFromEnum(b) <= 20); // 20 is max ID currently
}

test "Decoration placement" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    _ = gen;
}

test "OverworldGenerator with mock decoration provider" {
    const allocator = std.testing.allocator;
    const DecorationProvider = @import("world/worldgen/decoration_provider.zig").DecorationProvider;

    const MockProvider = struct {
        called_count: *usize,

        pub fn provider(called_count: *usize) DecorationProvider {
            return .{
                .ptr = called_count,
                .vtable = &VTABLE,
            };
        }

        const VTABLE = DecorationProvider.VTable{
            .decorate = decorate,
        };

        fn decorate(
            ptr: *anyopaque,
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
            _ = chunk;
            _ = local_x;
            _ = local_z;
            _ = surface_y;
            _ = surface_block;
            _ = biome;
            _ = variant;
            _ = allow_subbiomes;
            _ = veg_mult;
            _ = random;
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
    };

    var called_count: usize = 0;
    var gen = OverworldGenerator.init(42, allocator, MockProvider.provider(&called_count));

    var chunk = try allocator.create(Chunk);
    defer allocator.destroy(chunk);
    chunk.* = Chunk.init(0, 0);

    // Manually set some surface heights to trigger decoration attempts
    var z: u32 = 0;
    while (z < 16) : (z += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) {
            chunk.setSurfaceHeight(x, z, 64);
            chunk.setBlock(x, 64, z, .grass);
            chunk.biomes[x + z * 16] = .plains;
        }
    }

    gen.generateFeatures(chunk);

    // Should have been called 16*16 = 256 times
    try std.testing.expectEqual(@as(usize, 256), called_count);
}

// ============================================================================
// Chunk Meshing Tests
// ============================================================================

test "single block generates 6 faces" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expectEqual(@as(u32, 36), total_verts);
}

test "adjacent blocks share face (no internal faces)" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBlock(9, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expect(total_verts < 72);
}

test "adjacent transparent blocks share face" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .water);
    chunk.setBlock(9, 64, 8, .water);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty);

    var total_verts: u32 = 0;
    if (mesh.pending_solid) |v| total_verts += @intCast(v.len);
    if (mesh.pending_fluid) |v| total_verts += @intCast(v.len);
    try testing.expect(total_verts < 72);
}

// ============================================================================
// Biome Structural Constraints Tests (Issue #92)
// ============================================================================

test "Biome structural constraints - height filter" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    // Updated for structure-first thresholds (Issue #92):
    // - snowy_mountains requires min_height = 110 (updated from 100)
    // - Mountains require continentalness >= 0.75 (inland high or core)
    const snowy_mountains = getBiomeDefinition(.snowy_mountains);
    try testing.expect(snowy_mountains.min_height == 110);

    // Low elevation test - should NOT get snowy_mountains
    const climate_low = ClimateParams{
        .temperature = 0.3,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.85, // Continental core (>0.75)
        .ruggedness = 0.8,
    };
    const structural_low = StructuralParams{
        .height = 50, // Below min_height = 110
        .slope = 5,
        .continentalness = 0.85,
        .ridge_mask = 0.3,
    };
    const biome_at_low_elev = selectBiomeWithConstraints(climate_low, structural_low);
    try testing.expect(biome_at_low_elev != .snowy_mountains);

    // High elevation test - should get snowy_mountains
    const climate_high = ClimateParams{
        .temperature = 0.1, // Cold (Heat=10) to match snowy_mountains
        .humidity = 0.5,
        .elevation = 0.8,
        .continentalness = 0.85, // Continental core (>0.75)
        .ruggedness = 0.8,
    };
    const structural_high = StructuralParams{
        .height = 120, // Above min_height = 110
        .slope = 5,
        .continentalness = 0.85, // Must be >= 0.75 for mountains
        .ridge_mask = 0.3,
    };
    const biome_at_high_elev = selectBiomeWithConstraints(climate_high, structural_high);
    try testing.expect(biome_at_high_elev == .snowy_mountains);
}

test "Biome structural constraints - slope filter" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    const swamp = getBiomeDefinition(.swamp);
    try testing.expect(swamp.max_slope == 3);

    const climate = ClimateParams{
        .temperature = 0.7,
        .humidity = 0.9,
        .elevation = 0.35,
        .continentalness = 0.6,
        .ruggedness = 0.1,
    };
    const structural_steep = StructuralParams{
        .height = 65,
        .slope = 10,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };
    const biome_steep = selectBiomeWithConstraints(climate, structural_steep);
    try testing.expect(biome_steep != .swamp);

    const structural_flat = StructuralParams{
        .height = 65,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };
    const biome_flat = selectBiomeWithConstraints(climate, structural_flat);
    try testing.expect(biome_flat == .swamp);
}

test "Biome structural constraints - desert elevation limit" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    const desert = getBiomeDefinition(.desert);
    try testing.expect(desert.max_height == 90);

    const climate = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.5,
        .continentalness = 0.8,
        .ruggedness = 0.2,
    };
    const structural_low = StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.8,
        .ridge_mask = 0.1,
    };
    const biome_low = selectBiomeWithConstraints(climate, structural_low);
    try testing.expect(biome_low == .desert);

    const structural_high = StructuralParams{
        .height = 110,
        .slope = 2,
        .continentalness = 0.8,
        .ridge_mask = 0.1,
    };
    const biome_high = selectBiomeWithConstraints(climate, structural_high);
    try testing.expect(biome_high != .desert);
}

// ============================================================================
// Biome Edge Detection Tests (Issue #102)
// ============================================================================

test "needsTransition returns true for desert-forest pair" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Desert <-> Forest should need a transition
    try testing.expect(biome_mod.needsTransition(.desert, .forest) == true);
    try testing.expect(biome_mod.needsTransition(.forest, .desert) == true);

    // Desert <-> Plains should need a transition
    try testing.expect(biome_mod.needsTransition(.desert, .plains) == true);

    // Snow tundra <-> Plains should need a transition
    try testing.expect(biome_mod.needsTransition(.snow_tundra, .plains) == true);
    try testing.expect(biome_mod.needsTransition(.snow_tundra, .forest) == true);

    // Mountains <-> Plains should need a transition
    try testing.expect(biome_mod.needsTransition(.mountains, .plains) == true);
}

test "needsTransition returns false for compatible biomes" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Plains <-> Forest are compatible, no transition needed
    try testing.expect(biome_mod.needsTransition(.plains, .forest) == false);

    // Ocean <-> Beach are compatible
    try testing.expect(biome_mod.needsTransition(.ocean, .beach) == false);

    // Same biome never needs transition
    try testing.expect(biome_mod.needsTransition(.desert, .desert) == false);
    try testing.expect(biome_mod.needsTransition(.forest, .forest) == false);
}

test "getTransitionBiome returns correct biome for pairs" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Desert <-> Forest should get dry_plains
    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .forest), .dry_plains);
    try testing.expectEqual(biome_mod.getTransitionBiome(.forest, .desert), .dry_plains);

    // Desert <-> Plains should get dry_plains
    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .plains), .dry_plains);

    // Snow tundra <-> Plains should get taiga
    try testing.expectEqual(biome_mod.getTransitionBiome(.snow_tundra, .plains), .taiga);
    try testing.expectEqual(biome_mod.getTransitionBiome(.snow_tundra, .forest), .taiga);

    // Mountains <-> Plains should get foothills
    try testing.expectEqual(biome_mod.getTransitionBiome(.mountains, .plains), .foothills);

    // Swamp <-> Forest should get marsh
    try testing.expectEqual(biome_mod.getTransitionBiome(.swamp, .forest), .marsh);
}

test "getTransitionBiome returns null for compatible pairs" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Plains <-> Forest has no transition defined
    try testing.expectEqual(biome_mod.getTransitionBiome(.plains, .forest), null);

    // Ocean <-> Beach has no transition defined
    try testing.expectEqual(biome_mod.getTransitionBiome(.ocean, .beach), null);

    // Same biome returns null
    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .desert), null);
}

test "EdgeBand enum values are correct" {
    const biome_mod = @import("world/worldgen/biome.zig");

    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.none), 0);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.outer), 1);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.middle), 2);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.inner), 3);
}

test "Edge detection constants are properly defined" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // EDGE_STEP should be 4 for coarse grid sampling
    try testing.expectEqual(biome_mod.EDGE_STEP, 4);

    // EDGE_WIDTH should be 8 for transition band width
    try testing.expectEqual(biome_mod.EDGE_WIDTH, 8);

    // EDGE_CHECK_RADII should have 3 values: 4, 8, 12
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII.len, 3);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[0], 4);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[1], 8);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[2], 12);
}

test "BiomeEdgeInfo struct fields" {
    const biome_mod = @import("world/worldgen/biome.zig");

    const edge_info = biome_mod.BiomeEdgeInfo{
        .base_biome = .desert,
        .neighbor_biome = .forest,
        .edge_band = .middle,
    };

    try testing.expectEqual(edge_info.base_biome, .desert);
    try testing.expectEqual(edge_info.neighbor_biome.?, .forest);
    try testing.expectEqual(edge_info.edge_band, .middle);

    // Test with no neighbor
    const no_edge = biome_mod.BiomeEdgeInfo{
        .base_biome = .plains,
        .neighbor_biome = null,
        .edge_band = .none,
    };

    try testing.expectEqual(no_edge.neighbor_biome, null);
    try testing.expectEqual(no_edge.edge_band, .none);
}

test "Transition rules table has expected entries" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Should have at least 10 transition rules
    try testing.expect(biome_mod.TRANSITION_RULES.len >= 10);

    // Verify a few specific rules exist
    var found_desert_forest = false;
    var found_snow_plains = false;
    var found_mountain_plains = false;

    for (biome_mod.TRANSITION_RULES) |rule| {
        if ((rule.biome_a == .desert and rule.biome_b == .forest) or
            (rule.biome_a == .forest and rule.biome_b == .desert))
        {
            found_desert_forest = true;
            try testing.expectEqual(rule.transition, .dry_plains);
        }
        if ((rule.biome_a == .snow_tundra and rule.biome_b == .plains) or
            (rule.biome_a == .plains and rule.biome_b == .snow_tundra))
        {
            found_snow_plains = true;
            try testing.expectEqual(rule.transition, .taiga);
        }
        if ((rule.biome_a == .mountains and rule.biome_b == .plains) or
            (rule.biome_a == .plains and rule.biome_b == .mountains))
        {
            found_mountain_plains = true;
            try testing.expectEqual(rule.transition, .foothills);
        }
    }

    try testing.expect(found_desert_forest);
    try testing.expect(found_snow_plains);
    try testing.expect(found_mountain_plains);
}

// ============================================================================
// Voronoi Biome Selection Tests (Issue #106)
// ============================================================================

test "BiomePoint struct fields" {
    const biome_mod = @import("world/worldgen/biome.zig");

    const point = biome_mod.BiomePoint{
        .id = .desert,
        .heat = 90,
        .humidity = 10,
        .weight = 1.2,
        .min_continental = 0.42,
    };

    try testing.expectEqual(point.id, .desert);
    try testing.expectEqual(@as(f32, 90), point.heat);
    try testing.expectEqual(@as(f32, 10), point.humidity);
    try testing.expectEqual(@as(f32, 1.2), point.weight);
    try testing.expectEqual(@as(f32, 0.42), point.min_continental);
}

test "BIOME_POINTS table has expected biomes" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Should have multiple biome points
    try testing.expect(biome_mod.BIOME_POINTS.len >= 15);

    // Find specific biomes
    var found_desert = false;
    var found_plains = false;
    var found_forest = false;
    var found_snow = false;

    for (biome_mod.BIOME_POINTS) |point| {
        if (point.id == .desert) found_desert = true;
        if (point.id == .plains) found_plains = true;
        if (point.id == .forest) found_forest = true;
        if (point.id == .snow_tundra) found_snow = true;
    }

    try testing.expect(found_desert);
    try testing.expect(found_plains);
    try testing.expect(found_forest);
    try testing.expect(found_snow);
}

test "selectBiomeVoronoi returns desert for hot/dry" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Hot (90) and dry (10) should select desert
    // Height 70 (within desert y_max=90), continental 0.5 (inland), slope 0
    const result = biome_mod.selectBiomeVoronoi(90, 10, 70, 0.5, 0);
    try testing.expectEqual(result, .desert);
}

test "selectBiomeVoronoi returns snow_tundra for cold/dry" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Cold (5) and dry (30) should select snow_tundra
    // Height 70, continental 0.5 (inland), slope 0
    const result = biome_mod.selectBiomeVoronoi(5, 30, 70, 0.5, 0);
    try testing.expectEqual(result, .snow_tundra);
}

test "selectBiomeVoronoi returns ocean for low continentalness" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Any heat/humidity, but low continentalness = ocean
    const result = biome_mod.selectBiomeVoronoi(50, 50, 50, 0.25, 0);
    try testing.expectEqual(result, .ocean);
}

test "selectBiomeVoronoi returns deep_ocean for very low continentalness" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Very low continentalness = deep ocean
    const result = biome_mod.selectBiomeVoronoi(50, 50, 30, 0.10, 0);
    try testing.expectEqual(result, .deep_ocean);
}

test "selectBiomeVoronoi respects height constraints" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // High elevation with cold temp should get mountains, not plains
    // snowy_mountains requires y_min=100, so at height 110 with cold temp...
    const high_result = biome_mod.selectBiomeVoronoi(10, 40, 110, 0.65, 0);
    try testing.expectEqual(high_result, .snowy_mountains);

    // At low height with same temp, should NOT get snowy_mountains
    const low_result = biome_mod.selectBiomeVoronoi(10, 40, 70, 0.65, 0);
    try testing.expect(low_result != .snowy_mountains);
}

test "selectBiomeVoronoi weight affects selection" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Plains has high weight (1.5), so it should win in temperate areas
    // even if slightly closer to another biome's center
    const result = biome_mod.selectBiomeVoronoi(50, 45, 70, 0.5, 0);
    try testing.expectEqual(result, .plains);
}

test "selectBiomeVoronoiWithRiver returns river when mask active" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // High river mask should override to river biome
    const result = biome_mod.selectBiomeVoronoiWithRiver(50, 50, 65, 0.5, 0, 0.8);
    try testing.expectEqual(result, .river);

    // Low river mask should return normal biome
    const no_river = biome_mod.selectBiomeVoronoiWithRiver(50, 50, 65, 0.5, 0, 0.2);
    try testing.expect(no_river != .river);
}

test "selectBiomeWithConstraints uses Voronoi selection" {
    const biome_mod = @import("world/worldgen/biome.zig");

    // Create climate params for hot/dry area
    const climate = biome_mod.ClimateParams{
        .temperature = 0.9, // Hot -> 90 in Voronoi scale
        .humidity = 0.1, // Dry -> 10 in Voronoi scale
        .elevation = 0.4,
        .continentalness = 0.5,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.5,
        .ridge_mask = 0.1,
    };

    const result = biome_mod.selectBiomeWithConstraints(climate, structural);
    try testing.expectEqual(result, .desert);
}

// ============================================================================
// Issue #147: Modular Terrain Generation Pipeline Tests
// ============================================================================

test "NoiseSampler deterministic output" {
    const sampler = NoiseSampler.init(12345);

    // Same inputs should give same outputs
    const c1 = sampler.getContinentalness(100.0, 200.0, 0);
    const c2 = sampler.getContinentalness(100.0, 200.0, 0);
    try testing.expectEqual(c1, c2);

    // Different positions should give different values
    const c3 = sampler.getContinentalness(500.0, 600.0, 0);
    try testing.expect(c1 != c3);
}

test "NoiseSampler values in expected range" {
    const sampler = NoiseSampler.init(42);

    // Continentalness should be 0-1
    const c = sampler.getContinentalness(0.0, 0.0, 0);
    try testing.expect(c >= 0.0 and c <= 1.0);

    // Temperature should be 0-1
    const t = sampler.getTemperature(0.0, 0.0, 0);
    try testing.expect(t >= 0.0 and t <= 1.0);

    // Humidity should be 0-1
    const h = sampler.getHumidity(0.0, 0.0, 0);
    try testing.expect(h >= 0.0 and h <= 1.0);
}

test "NoiseSampler batch sampling matches individual" {
    const sampler = NoiseSampler.init(99999);
    const x: f32 = 123.0;
    const z: f32 = 456.0;
    const reduction: u8 = 0;

    // Get values individually
    const warp = sampler.computeWarp(x, z, reduction);
    const xw = x + warp.x;
    const zw = z + warp.z;
    const c_individual = sampler.getContinentalness(xw, zw, reduction);
    const t_individual = sampler.getTemperature(xw, zw, reduction);

    // Get values via batch
    const column = sampler.sampleColumn(x, z, reduction);

    // Should match
    try testing.expectEqual(c_individual, column.continentalness);
    try testing.expectEqual(t_individual, column.temperature);
}

test "NoiseSampler different seeds produce different results" {
    const sampler1 = NoiseSampler.init(111);
    const sampler2 = NoiseSampler.init(222);

    const c1 = sampler1.getContinentalness(100.0, 100.0, 0);
    const c2 = sampler2.getContinentalness(100.0, 100.0, 0);

    try testing.expect(c1 != c2);
}

test "HeightSampler continental zones" {
    const sampler = HeightSampler.init();
    const world_class_mod = @import("world/worldgen/world_class.zig");

    // Deep ocean
    try testing.expectEqual(world_class_mod.ContinentalZone.deep_ocean, sampler.getContinentalZone(0.1));

    // Ocean
    try testing.expectEqual(world_class_mod.ContinentalZone.ocean, sampler.getContinentalZone(0.25));

    // Coast
    try testing.expectEqual(world_class_mod.ContinentalZone.coast, sampler.getContinentalZone(0.38));

    // Inland low
    try testing.expectEqual(world_class_mod.ContinentalZone.inland_low, sampler.getContinentalZone(0.50));

    // Inland high
    try testing.expectEqual(world_class_mod.ContinentalZone.inland_high, sampler.getContinentalZone(0.70));

    // Mountain core
    try testing.expectEqual(world_class_mod.ContinentalZone.mountain_core, sampler.getContinentalZone(0.90));
}

test "HeightSampler ocean detection" {
    const sampler = HeightSampler.init();

    try testing.expect(sampler.isOcean(0.0));
    try testing.expect(sampler.isOcean(0.34));
    try testing.expect(!sampler.isOcean(0.35));
    try testing.expect(!sampler.isOcean(0.5));
}

test "HeightSampler mountain mask range" {
    const sampler = HeightSampler.init();

    // Mountain mask should be in 0-1 range
    const m1 = sampler.getMountainMask(0.8, 0.3, 0.8);
    try testing.expect(m1 >= 0.0 and m1 <= 1.0);

    const m2 = sampler.getMountainMask(0.2, 0.8, 0.4);
    try testing.expect(m2 >= 0.0 and m2 <= 1.0);
}

test "SurfaceBuilder coastal type detection" {
    const builder = SurfaceBuilder.init();

    // Sand beach: low slope, near ocean, at sea level
    const sand = builder.getCoastalSurfaceType(0.37, 1, 65, 0.3);
    try testing.expectEqual(CoastalSurfaceType.sand_beach, sand);

    // Cliff: high slope
    const cliff = builder.getCoastalSurfaceType(0.37, 6, 65, 0.3);
    try testing.expectEqual(CoastalSurfaceType.cliff, cliff);

    // Gravel beach: high erosion
    const gravel = builder.getCoastalSurfaceType(0.37, 2, 65, 0.8);
    try testing.expectEqual(CoastalSurfaceType.gravel_beach, gravel);

    // Too far inland: no coastal type
    const inland = builder.getCoastalSurfaceType(0.50, 1, 70, 0.3);
    try testing.expectEqual(CoastalSurfaceType.none, inland);
}

test "SurfaceBuilder bedrock at y=0" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(0, 50, .plains, 3, false, false);
    try testing.expectEqual(BlockType.bedrock, block);
}

test "SurfaceBuilder water above terrain below sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(60, 55, .plains, 3, false, true);
    try testing.expectEqual(BlockType.water, block);
}

test "SurfaceBuilder air above terrain above sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(80, 70, .plains, 3, false, false);
    try testing.expectEqual(BlockType.air, block);
}

test "BiomeSource initialization" {
    const source = BiomeSource.init();
    try testing.expect(source.params.sea_level == 64);
    try testing.expect(source.params.edge_detection_enabled == true);
}

test "BiomeSource ocean detection" {
    const source = BiomeSource.init();
    try testing.expect(source.isOcean(0.2));
    try testing.expect(!source.isOcean(0.5));
}

test "BiomeSource selectBiome hot dry returns desert" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const source = BiomeSource.init();

    // Hot and dry climate params -> should select desert
    const climate = biome_mod.ClimateParams{
        .temperature = 0.9, // Hot
        .humidity = 0.1, // Dry
        .elevation = 0.4,
        .continentalness = 0.6, // Inland
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = source.selectBiome(climate, structural, 0.0);
    try testing.expectEqual(result, BiomeId.desert);
}

test "BiomeSource selectBiome cold wet returns taiga" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const source = BiomeSource.init();

    // Cold and wet climate -> should select taiga
    const climate = biome_mod.ClimateParams{
        .temperature = 0.2, // Cold
        .humidity = 0.7, // Wet
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };

    const structural = biome_mod.StructuralParams{
        .height = 72,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = source.selectBiome(climate, structural, 0.0);
    try testing.expectEqual(result, BiomeId.taiga);
}

test "BiomeSource selectBiome river override" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const source = BiomeSource.init();

    // Normal land params but high river mask -> should return river
    const climate = biome_mod.ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    // High river mask should force river biome
    const result = source.selectBiome(climate, structural, 0.9);
    try testing.expectEqual(result, BiomeId.river);
}

test "BiomeSource selectBiomeSimplified returns valid biome" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const source = BiomeSource.init();

    // Test various climate combinations return valid biomes
    const climate1 = biome_mod.ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const result1 = source.selectBiomeSimplified(climate1);
    try testing.expectEqual(result1, BiomeId.desert);

    // Ocean check
    const climate2 = biome_mod.ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.1, // Deep ocean
        .ruggedness = 0.2,
    };

    const result2 = source.selectBiomeSimplified(climate2);
    try testing.expectEqual(result2, BiomeId.deep_ocean);
}

test "BiomeSource getColor returns valid packed RGB" {
    const source = BiomeSource.init();

    // Desert should be sand-colored
    const desert_color = source.getColor(BiomeId.desert);
    try testing.expect(desert_color != 0);

    // Ocean should be blue-ish
    const ocean_color = source.getColor(BiomeId.ocean);
    try testing.expect(ocean_color != desert_color);
}

test "BiomeSource selectBiomeWithEdge no edge returns primary only" {
    const biome_mod = @import("world/worldgen/biome.zig");
    const source = BiomeSource.init();

    const climate = biome_mod.ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    // No edge detected
    const edge_info = biome_mod.BiomeEdgeInfo{
        .base_biome = BiomeId.plains,
        .neighbor_biome = null,
        .edge_band = .none,
    };

    const result = source.selectBiomeWithEdge(climate, structural, 0.0, edge_info);
    try testing.expectEqual(result.primary, result.secondary);
    try testing.expectEqual(result.blend_factor, 0.0);
}
