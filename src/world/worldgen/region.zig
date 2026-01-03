//! Region Composition System (Pure Logic Layer)
//! Defines Region Roles (Transit, Destination, Boundary) and Movement Paths
//! to create intentional world composition and negative space.

const std = @import("std");
const Vec3f = @import("noise.zig").Vec3f;

pub const RegionMood = enum {
    calm, // Boring on purpose
    sparse, // Empty, lonely
    lush, // Abundant vegetation
    wild, // Chaos, landmarks
};

pub const RegionRole = enum {
    transit, // Fast, boring, flat
    destination, // One star feature (focus)
    boundary, // Awkward, separation
};

pub const FeatureFocus = enum {
    none,
    lake,
    forest,
    mountain,
};

pub const PathType = enum {
    none,
    valley, // Primary: between destinations
    river, // Secondary: from mountains to water
    plains_corridor, // Implicit roads in transit regions
};

/// Complete region information with role, mood, and feature focus
pub const RegionInfo = struct {
    mood: RegionMood,
    role: RegionRole,
    focus: FeatureFocus,
    center_x: i32,
    center_z: i32,
};

// ============================================================================
// FEATURE ALLOW/DENY TABLES (Exact Per Spec)
// ============================================================================

/// Multiplier for height variance based on Role + Focus
/// Transit = flat, Destination depends on focus, Boundary = medium awkward
pub fn getHeightMultiplier(info: RegionInfo) f32 {
    return switch (info.role) {
        .transit => 0.4,
        .destination => switch (info.focus) {
            .mountain => 1.5,
            .lake => 0.3,
            .forest => 0.8,
            .none => 1.0,
        },
        .boundary => 1.0,
    };
}

/// Multiplier for vegetation density
/// Transit = 20-30%, Destination = themed, Boundary = very low (10-20%)
pub fn getVegetationMultiplier(info: RegionInfo) f32 {
    return switch (info.role) {
        .transit => 0.25,
        .destination => switch (info.focus) {
            .forest => 1.5,
            .lake => 0.5,
            .mountain => 0.4,
            .none => 1.0,
        },
        .boundary => 0.15,
    };
}

/// === HARD FEATURE ALLOW/DENY RULES (Non-Negotiable) ===
/// Large lakes: ONLY in Destination with lake focus
/// Suppressed in Transit, Boundary, and other Destinations
pub fn allowLake(info: RegionInfo) bool {
    return info.role == .destination and info.focus == .lake;
}

/// Rivers:
/// - Transit: NO
/// - Boundary: NO
/// - Destination: YES (if contextual: feeding lake or from mountain)
pub fn allowRiver(info: RegionInfo) bool {
    return info.role == .destination;
}

/// Sub-biomes:
/// - Transit: NO
/// - Boundary: NO
/// - Destination: ONLY if forest focus
pub fn allowSubBiomes(info: RegionInfo) bool {
    return info.role == .destination and info.focus == .forest;
}

/// Height drama (mountains, cliffs):
/// - Transit: NO
/// - Destination: ONLY if mountain focus
/// - Boundary: Medium awkward noise allowed
pub fn allowHeightDrama(info: RegionInfo) bool {
    return switch (info.role) {
        .transit => false,
        .destination => info.focus == .mountain,
        .boundary => true, // Awkward terrain
    };
}

// ============================================================================
// MOVEMENT PATH SYSTEM
// ============================================================================

const REGION_SIZE = 1024;

/// Path configuration constants
const VALLEY_WIDTH: f32 = 32.0;
const VALLEY_DEPTH: f32 = 10.0;
const RIVER_WIDTH: f32 = 16.0;
const PLAINS_CORRIDOR_WIDTH: f32 = 12.0;

/// Movement path information for a position
pub const PathInfo = struct {
    path_type: PathType,
    influence: f32, // 0.0 = none, 1.0 = center of path
    direction: [2]f32, // Flow direction (dx, dz), normalized
};

/// Get region info for a world position
pub fn getRegion(seed: u64, world_x: i32, world_z: i32) RegionInfo {
    const rx = @divFloor(world_x, REGION_SIZE);
    const rz = @divFloor(world_z, REGION_SIZE);
    const center_x = rx * REGION_SIZE + REGION_SIZE / 2;
    const center_z = rz * REGION_SIZE + REGION_SIZE / 2;

    var prng = std.Random.DefaultPrng.init(seed +%
        @as(u64, @bitCast(@as(i64, rx))) *% 0x9E3779B97F4A7C15 +%
        @as(u64, @bitCast(@as(i64, rz))) *% 0xC6A4A7935BD1E995);
    const rand = prng.random();

    // 1. Assign Role (50% Transit, 30% Destination, 20% Boundary)
    const roll_role = rand.float(f32);
    const role: RegionRole = if (roll_role < 0.50)
        .transit
    else if (roll_role < 0.80)
        .destination
    else
        .boundary;

    // 2. Assign Mood (Orthogonal to role)
    const roll_mood = rand.float(f32);
    const mood: RegionMood = if (roll_mood < 0.30)
        .calm
    else if (roll_mood < 0.60)
        .sparse
    else if (roll_mood < 0.85)
        .lush
    else
        .wild;

    // 3. Assign Feature Focus (Only for Destination)
    const focus: FeatureFocus = if (role == .destination) blk: {
        const roll_focus = rand.float(f32);
        break :blk if (roll_focus < 0.33)
            .lake
        else if (roll_focus < 0.66)
            .forest
        else
            .mountain;
    } else .none;

    return .{
        .mood = mood,
        .role = role,
        .focus = focus,
        .center_x = center_x,
        .center_z = center_z,
    };
}

/// Check if position is on a movement path
/// Returns path influence (0.0 = none, 1.0 = center of path)
pub fn getPathInfluence(seed: u64, x: i32, z: i32) f32 {
    const current = getRegion(seed, x, z);
    const path_info = getPathInfo(seed, x, z, current);
    return path_info.influence;
}

/// Get complete path information for a position
pub fn getPathInfo(seed: u64, x: i32, z: i32, current: RegionInfo) PathInfo {
    const rx = @divFloor(x, REGION_SIZE);
    const rz = @divFloor(z, REGION_SIZE);

    var max_influence: f32 = 0.0;
    var best_path_type: PathType = .none;
    var direction = [2]f32{ 0.0, 0.0 };

    const px: f32 = @floatFromInt(x);
    const pz: f32 = @floatFromInt(z);
    const c1x: f32 = @floatFromInt(current.center_x);
    const c1z: f32 = @floatFromInt(current.center_z);

    // Check all 8 neighbors for path connections
    const neighbors = [_][2]i32{
        .{ 1, 0 }, .{ -1, 0 },  .{ 0, 1 },  .{ 0, -1 },
        .{ 1, 1 }, .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 },
    };

    for (neighbors) |offset| {
        const nx = rx + offset[0];
        const nz = rz + offset[1];

        const neighbor_info = getRegion(seed, nx * REGION_SIZE, nz * REGION_SIZE);
        const connection_type = shouldConnectRegions(current, neighbor_info);

        if (connection_type != .none) {
            const c2x: f32 = @floatFromInt(neighbor_info.center_x);
            const c2z: f32 = @floatFromInt(neighbor_info.center_z);

            const dist = distToSegment(px, pz, c1x, c1z, c2x, c2z);
            const path_width = switch (connection_type) {
                .valley => VALLEY_WIDTH,
                .river => RIVER_WIDTH,
                .plains_corridor => PLAINS_CORRIDOR_WIDTH,
                .none => 0.0,
            };

            if (dist < path_width) {
                const influence = 1.0 - (dist / path_width);
                if (influence > max_influence) {
                    max_influence = influence;
                    best_path_type = connection_type;
                    // Calculate direction (from c1 to c2)
                    const dx = c2x - c1x;
                    const dz = c2z - c1z;
                    const len = @sqrt(dx * dx + dz * dz);
                    if (len > 0.001) {
                        direction = [2]f32{ dx / len, dz / len };
                    }
                }
            }
        }
    }

    return .{
        .path_type = best_path_type,
        .influence = max_influence,
        .direction = direction,
    };
}

/// Determine if two regions should be connected by a path, and what type
/// Destination graph: Connect Destinations to each other (1-2 connections)
/// Plains corridors: Only in Transit regions
fn shouldConnectRegions(a: RegionInfo, b: RegionInfo) PathType {
    // === VALLEY PATHS (Primary) ===
    // Connect: Destination ↔ Destination, Destination ↔ Transit
    if (a.role == .destination and b.role == .destination) {
        // 40% chance of valley connection between destinations
        if (hasConnection(a.center_x, a.center_z, b.center_x, b.center_z, 0.40)) {
            return .valley;
        }
    }

    if (a.role == .destination and b.role == .transit) {
        // 60% chance of valley from destination to transit
        if (hasConnection(a.center_x, a.center_z, b.center_x, b.center_z, 0.60)) {
            return .valley;
        }
    }

    if (a.role == .transit and b.role == .destination) {
        if (hasConnection(a.center_x, a.center_z, b.center_x, b.center_z, 0.60)) {
            return .valley;
        }
    }

    // === RIVERS (Secondary, Directional) ===
    // Only from: Mountain/Wild Destination → Water (Ocean or Lake Destination)
    if (a.role == .destination and a.focus == .mountain) {
        if (b.role == .destination and b.focus == .lake) {
            // 50% chance of river from mountain to lake
            if (hasConnection(a.center_x, a.center_z, b.center_x, b.center_z, 0.50)) {
                return .river;
            }
        }
        // Rivers to ocean are determined by continentalness (in generator)
    }

    // === PLAINS CORRIDORS (Implicit Roads) ===
    // Only within Transit regions (connect transit to transit)
    if (a.role == .transit and b.role == .transit) {
        // 50% chance of corridor in transit regions
        if (hasConnection(a.center_x, a.center_z, b.center_x, b.center_z, 0.50)) {
            return .plains_corridor;
        }
    }

    return .none;
}

/// Deterministic connection check between two region centers
fn hasConnection(x1: i32, z1: i32, x2: i32, z2: i32, probability: f32) bool {
    // Hash the pair to get deterministic connection decision
    const min_x = @min(x1, x2);
    const max_x = @max(x1, x2);
    const min_z = @min(z1, z2);
    const max_z = @max(z1, z2);

    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(@as(i64, min_x))) *%
        0x9E3779B97F4A7C15 +%
        @as(u64, @bitCast(@as(i64, min_z))) *% 0xC6A4A7935BD1E995 +%
        @as(u64, @bitCast(@as(i64, max_x))) *% 0xBB67AE8584CAA73B +%
        @as(u64, @bitCast(@as(i64, max_z))) *% 0x85EBCA77B2A2A9B5);

    return prng.random().float(f32) < probability;
}

/// Distance from point P to segment AB
fn distToSegment(px: f32, pz: f32, ax: f32, az: f32, bx: f32, bz: f32) f32 {
    const l2 = (bx - ax) * (bx - ax) + (bz - az) * (bz - az);
    if (l2 == 0) return @sqrt((px - ax) * (px - ax) + (pz - az) * (pz - az));
    var t = ((px - ax) * (bx - ax) + (pz - az) * (bz - az)) / l2;
    t = std.math.clamp(t, 0.0, 1.0);
    const proj_x = ax + t * (bx - ax);
    const proj_z = az + t * (bz - az);
    return @sqrt((px - proj_x) * (px - proj_x) + (pz - proj_z) * (pz - proj_z));
}

// ============================================================================
// DEBUG VISUALIZATION
// ============================================================================

/// Get debug color for region (Role-based)
pub fn getRoleColor(role: RegionRole) [3]f32 {
    return switch (role) {
        .transit => .{ 0.7, 0.7, 0.7 },
        .boundary => .{ 0.3, 0.3, 0.3 },
        .destination => .{ 1.0, 0.8, 0.0 },
    };
}

/// Get debug color for destination focus
pub fn getFocusColor(focus: FeatureFocus) [3]f32 {
    return switch (focus) {
        .none => .{ 1.0, 1.0, 1.0 },
        .lake => .{ 0.2, 0.4, 0.9 },
        .forest => .{ 0.1, 0.6, 0.1 },
        .mountain => .{ 0.8, 0.2, 0.2 },
    };
}

/// Get debug color for path type
pub fn getPathColor(path_type: PathType) [3]f32 {
    return switch (path_type) {
        .none => .{
            0.0,
            0.0,
            0.0,
        },
        .valley => .{ 0.5, 0.3, 0.1 },
        .river => .{ 0.0, 0.5, 1.0 },
        .plains_corridor => .{ 0.9, 0.7, 0.5 },
    };
}
