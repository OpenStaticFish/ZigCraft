# Region Roles and Movement Paths Implementation

## Summary

This implementation adds two major systems to create intentional world composition and negative space:

1. **Region Role System** - Exact Feature Allow/Deny Tables
2. **Movement Path System** - Destination graph-based routing

---

## Part 1: Region Role System

### Core Principle
> Each region may have ONE primary feature. Everything else is background or suppressed.

### Region Types

#### Transit Region (50%)
- **Purpose**: Fast, boring, flat traversal
- **Height Multiplier**: 0.4 (very flat)
- **Vegetation Multiplier**: 0.25 (20-30% density)
- **Allowed Features**: Grass/plains surfaces, sparse vegetation
- **Suppressed**: Lakes, rivers, sub-biomes, dense forests, sand, cliffs

#### Destination Region (30%)
- **Purpose**: Make the player stop with one dominant feature
- **Feature Focus**: Lake, Forest, or Mountain (selected at region creation)
- **Multipliers**: Depends on focus
  - Lake: Height 0.3, Vegetation 0.5
  - Forest: Height 0.8, Vegetation 1.5
  - Mountain: Height 1.5, Vegetation 0.4
- **Rules**: Chosen feature exaggerated, all others suppressed

#### Boundary Region (20%)
- **Purpose**: Separate destinations with awkward terrain
- **Height Multiplier**: 1.0 (medium awkward)
- **Vegetation Multiplier**: 0.15 (very low)
- **Allowed**: Height noise, rock/rough terrain, sparse trees
- **Suppressed**: Large lakes, dense forests, landmarks, beaches

### Feature Allow/Deny Rules (Non-Negotiable)

| Feature        | Transit | Destination | Boundary |
|----------------|--------|-------------|----------|
| Large lakes    | ❌     | ✅ (if focus) | ❌       |
| Rivers         | ❌     | ✅ (contextual) | ❌    |
| Dense forest   | ❌     | ✅ (if focus) | ❌       |
| Sub-biomes     | ❌     | ❌           | ❌       |
| Height drama   | ❌     | ✅ (if focus) | ⚠️       |
| Vegetation     | low    | themed       | very low |

### Implementation

**File**: `src/world/worldgen/region.zig`

Key functions:
- `getRegion()` - Returns RegionInfo with role, mood, focus
- `allowLake()` - Only true if destination + lake focus
- `allowRiver()` - Only true for destinations
- `allowSubBiomes()` - Only true for destination + forest focus
- `allowHeightDrama()` - Only true for destination + mountain focus or boundary

---

## Part 2: Movement Path System

### Concept
Movement paths are:
- Implicit (not actual road blocks)
- Deterministic
- Visible from terrain alone
- Priority override for region suppression (narrow corridors only)

### Path Types

#### Valley Paths (Primary)
- **Used Between**: Destination ↔ Destination, Destination ↔ Transit
- **Width**: 32 blocks
- **Depth**: Up to 10 blocks lowered
- **Rules**:
  - Lower terrain slightly along path
  - Reduce slope by up to 60%
  - Suppress obstacles (lakes, rocks)
- **Probability**: 40-60% between compatible regions

#### Rivers (Secondary, Directional)
- **Only From**: Mountain/Wild Destination → Water (Ocean or Lake Destination)
- **Width**: 16 blocks
- **Depth**: Up to 15 blocks (deeper than valleys)
- **Rules**:
  - One river per source region max
  - Follows downhill-biased valley
  - Carves shallow channel
  - Overrides region suppression locally
- **Probability**: 50% from mountain to lake

#### Plains Corridors (Implicit Roads)
- **Used In**: Transit regions only
- **Width**: 12 blocks
- **Depth**: 2 blocks (very gentle)
- **Rules**:
  - Extra-flat strips
  - Reduced vegetation
  - No blocks added (terrain bias only)
- **Probability**: 50% in transit regions

### Path Graph

```
1. Identify all Destination regions
2. For each Destination:
   - Connect to 1-2 nearest Destinations (Valley paths)
   - Check if river source (mountain) with water target
3. Transit regions:
   - Connect to each other (Plains corridors)
4. Boundary regions:
   - No paths (keep them awkward)
```

### Implementation

**File**: `src/world/worldgen/region.zig`

Key functions:
- `shouldConnectRegions()` - Determines if and what path type connects two regions
- `getPathInfo()` - Returns path type, influence (0-1), and direction for a position
- `hasConnection()` - Deterministic connection check

### Path Constants

```zig
const VALLEY_WIDTH: f32 = 32.0;
const VALLEY_DEPTH: f32 = 10.0;
const RIVER_WIDTH: f32 = 16.0;
const PLAINS_CORRIDOR_WIDTH: f32 = 12.0;
```

---

## Integration with Terrain Generation

### Height Computation (`generator.zig`)

**Step 2 - Path System (Priority Override)**:
```zig
const path_info = region_pkg.getPathInfo(seed, x, z, region);
var path_depth: f32 = 0.0;
var slope_suppress: f32 = 0.0;

switch (path_info.path_type) {
    .valley => {
        path_depth = path_info.influence * VALLEY_DEPTH;
        slope_suppress = path_info.influence * 0.6;
    },
    .river => {
        path_depth = path_info.influence * RIVER_DEPTH;
        slope_suppress = path_info.influence * 0.8;
    },
    .plains_corridor => {
        path_depth = path_info.influence * 2.0;
        slope_suppress = path_info.influence * 0.9;
    },
    .none => {},
}
```

**Step 5 - Mountains (Region-Constrained)**:
```zig
if (region_pkg.allowHeightDrama(region) and c > p.continental_inland_low_max) {
    // Apply mountains only if allowed
}
```

**Step 8 - River Carving (Region-Constrained)**:
```zig
if (region_pkg.allowRiver(region) and river_mask > 0.001 and c > p.coast_max) {
    // Carve river only if allowed
}
```

### Feature Generation (`generator.zig`)

Vegetation multiplier applied per region:
```zig
const region = region_pkg.getRegion(seed, wx_center, wz_center);
const veg_mult = region_pkg.getVegetationMultiplier(region); // Transit=25%, Boundary=15%

// Sub-biome suppression
const allow_subbiomes = region_pkg.allowSubBiomes(region);

if (!allow_subbiomes) {
    // Skip variant-specific decorations (clearings, patches)
    if (s.variant_min != -1.0 or s.variant_max != 1.0) {
        continue;
    }
}
```

---

## Debug Visualization

### Region Role Colors
```zig
transit → [0.7, 0.7, 0.7]  // Gray/White
boundary → [0.3, 0.3, 0.3]  // Dark Gray
destination → [1.0, 0.8, 0.0]  // Gold
```

### Feature Focus Colors
```zig
none → [1.0, 1.0, 1.0]  // White
lake → [0.2, 0.4, 0.9]  // Blue
forest → [0.1, 0.6, 0.1]  // Green
mountain → [0.8, 0.2, 0.2]  // Red
```

### Path Type Colors
```zig
valley → [0.5, 0.3, 0.1]  // Brown
river → [0.0, 0.5, 1.0]  // Blue
plains_corridor → [0.9, 0.7, 0.5]  // Light tan
```

### In-Game Debug

**Updated `app.zig`**:
- Shows "ROLE:" label with color
- Displays role name (transit/destination/boundary)
- Can be extended to show focus and path overlay

---

## Acceptance Criteria

The system is correct when:

- ✅ You can point at a map and say "That's where I'd go next."
- ✅ Large boring areas exist and feel intentional (Transit regions)
- ✅ Interesting areas are rare and memorable (Destinations with single focus)
- ✅ Movement feels guided without signage (Valleys, corridors, rivers)
- ✅ No region has two "star" features
- ✅ Transit regions are fast and flat
- ✅ Destination regions are about ONE thing (lake, forest, or mountain)
- ✅ Boundary regions feel awkward and transitional

---

## Files Modified

1. **`src/world/worldgen/region.zig`** - Complete rewrite
   - Added `PathType` enum
   - Implemented exact feature allow/deny rules
   - Added destination graph-based path system
   - Added debug color functions

2. **`src/world/worldgen/generator.zig`**
   - Added path depth constants (`VALLEY_DEPTH`, `RIVER_DEPTH`)
   - Updated `computeHeight()` to use path system and region constraints
   - Updated `generateFeatures()` for sub-biome suppression
   - Updated `getRegionInfo()` and `getMood()` for new API
   - Fixed `getColumnInfo()` to use new region API

3. **`src/game/app.zig`**
   - Updated debug overlay to show Region Role instead of Mood
   - Changed imports from `mood.zig` to `region.zig`

---

## Testing

```bash
# Build
nix develop --command zig build

# Run tests
nix develop --command zig build test

# Run the game to see regions and paths in action
nix develop --command zig build run
```

### What to Look For

1. **Top-down view** (world map):
   - Large contiguous shapes ✅
   - Clear destination/boundary/transit regions
   - Visible path corridors between regions

2. **In-world view**:
   - Transit regions: Fast, flat, readable terrain
   - Destination regions: Single dominant feature (big lake OR forest OR mountains)
   - Boundary regions: Awkward, rocky terrain
   - Movement: Follow valleys/corridors naturally

3. **Game-feel**:
   - World "pulls" you through space (not surrounds you)
   - Clear "walk there", "follow that", "cross this" guidance
   - No more "this is interesting but not memorable"

---

## Next Steps

1. **Add map debug overlay** showing:
   - Region role colors (T/D/B)
   - Destination focus type
   - Path graph lines
   - Actual carved paths

2. **Fine-tune path probabilities** if needed:
   - Valley connectivity rate (currently 40-60%)
   - River generation rate (currently 50%)
   - Plains corridor density (currently 50%)

3. **Consider adding**:
   - Implicit roads (actual path blocks for transit corridors)
   - Handcrafted landmarks to validate feel
   - Path smoothing to reduce sharp corners

---

## References

This implementation follows the specification:
- "Region Roles + Movement Paths Specification (Production-Grade Composition Layer)"
- "worldgen-revamp.md" guidelines
- Issue #110 (Region Moods) enhancement

**Key Insight**: Worldgen is no longer procedural terrain — it's **procedural level design**.

> Regions give identity
> Paths give direction
> Absence gives meaning
