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

// Worldgen modules
const Noise = @import("zig-noise").Noise;

// ============================================================================
// Vec3 Tests
// ============================================================================

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
// Chunk Meshing Tests
// ============================================================================

test "single block generates 6 faces" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();
    try mesh.buildWithNeighbors(&chunk, .empty);

    var total_verts: u32 = 0;
    for (mesh.pending_solid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
    for (mesh.pending_fluid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
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
    for (mesh.pending_solid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
    for (mesh.pending_fluid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
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
    for (mesh.pending_solid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
    for (mesh.pending_fluid) |p| {
        if (p) |v| total_verts += @intCast(v.len);
    }
    try testing.expect(total_verts < 72);
}
