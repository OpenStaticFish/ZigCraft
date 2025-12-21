# worldgen-luanti-style.md — Revamp Worldgen to “Luanti/Minetest-like” Pipeline

Objective:
Rebuild your worldgen pipeline so it behaves like Luanti’s mapgen approach: coherent large-scale terrain, clean surface layering, predictable chunk boundaries, and a clear separation between terrain shape, biomes, surface rules, caves, and decorations.

This is specifically designed to fix your current problems:
- Artificial/predictable patterns
- Hard biome blobs and disconnected regions
- Too-wide, uniform sand bands around coasts
- Height discontinuities (sand higher than forest)
- Over-dramatic cliffs/walls and chaotic high terrain
- Features (trees) popping in unnatural patches

---

## 1) Match Luanti’s Core Strategy: “Generate Bigger Than You Store”

Luanti generates in a larger working volume (mapchunk) to keep features consistent across boundaries, then “commits” a subset.

### Your equivalent (recommended)
Keep your existing storage chunk size:
- **Chunk storage**: 16 × 256 × 16 (X,Y,Z)

But generate using a larger “gen region”:
- **GenRegion**: 80 × 256 × 80 (X,Z) = 5×5 chunks horizontally
- That’s the direct equivalent of Luanti’s 80×80×80 (but you’re full height, so 80×256×80)

Why:
- Mountains, coastlines, caves, and biome transitions need neighborhood context.
- If you compute everything per chunk in isolation, you get seams, blobs, and “painted” transitions.

### Implementation rule
When a chunk is needed:
- Determine its GenRegion origin (aligned to 5×5 chunk grid).
- Generate the entire GenRegion in one pass.
- Fill/cache the 25 chunks from that result.

---

## 2) Luanti-Style Generation Pipeline (Phases)

You must implement these phases in order, and keep them cleanly separated.

### Phase A: Terrain Shape (Stone + Water Only)
Output:
- a solid/empty decision for every voxel (stone vs air)
- water filling under sea level
- **no dirt, no sand, no grass, no trees**

Inputs:
- seed
- continuous fields (noise)

Recommended approach:
- Use 2D fields for “macro shape”:
  - continentalness (ocean/land)
  - peaks / mountain mask
  - erosion (ruggedness limiter)
- Optional 3D density for overhangs:
  - density(x,y,z) threshold => stone/air

Hard rule:
- Terrain shape is **biome-agnostic**.

Deliverable:
- `stoneMask[x][y][z]`
- `heightmap[x][z]` (top solid y)
- `oceanMask[x][z]` (ocean vs inland classification)
- `slope[x][z]` (computed from heightmap)

### Phase B: Biome Calculation (Climate Space)
Output:
- biome ownership per (x,z) column
- BUT as weights (top2/top3) not a single hard biome

Inputs (computed in Phase A and from climate noise):
- temperature T(x,z)
- humidity H(x,z)
- continentalness C(x,z)
- elevation normalized E01(x,z) from heightmap
- ruggedness/erosion R(x,z)

Rule:
- Determine `biomeA`, `biomeB`, blend `t` per column.

Deliverable:
- `biomeAId[x][z]`
- `biomeBId[x][z]`
- `blendT[x][z]`

### Phase C: Surface “Dusting” (Top/Filler Replacement)
Output:
- replace the top layers of stone with biome-appropriate layers:
  - top node (1 block)
  - filler (3–5 blocks)
  - optional biome stone variants (sandstone, etc.)

Inputs:
- heightmap + slope
- biome blend (A/B/t)
- sea level + ocean shoreline distance

Hard rules:
- Surface rules **never change terrain height**.
- Beaches are not “biome = sand”; beaches are a shoreline rule (see §4).

Deliverable:
- final terrain surface blocks (stone/dirt/grass/sand/etc.)
- still no trees/ores yet

### Phase D: Caves / Caverns / Dungeons (Carving + Structures)
Output:
- carve stone into air using controlled cave logic
- optionally place dungeon rooms/halls later

Inputs:
- stoneMask (pre-surface or post-surface depending on your approach)
- cave region mask
- 3D noise / worm tunnels
- surface protection depth

Rule:
- Apply cave carving BEFORE final surface painting if you want correct cave mouths and dirt ceilings, OR carve after and then fix up ceilings—pick one and keep it consistent.

Recommendation:
- Carve after Phase A, then recompute heightmap, then do Phase C dusting.

Deliverable:
- carved volume
- updated heightmap

### Phase E: Decorations and Ores (Deterministic Feature Placement)
Output:
- trees, plants, shrubs, boulders, ores

Inputs:
- biome blend (A/B/t)
- slope and elevation constraints
- coastline buffers

Hard rule:
- Feature placement must be deterministic per region and must obey spacing rules.
- Features should not define terrain shape.

Deliverable:
- final blocks (including trees and ores)

---

## 3) Data Structures and Caching (Required to Feel “Coherent”)

### 3.1 Region cache
Maintain an LRU cache keyed by GenRegion coords:
- `GenRegionKey = (regionX, regionZ)`
- store:
  - heightmap 80×80
  - slope 80×80
  - climate fields 80×80 (T/H/C/R/P/etc.)
  - biome blend 80×80 (A/B/t)
  - optionally stoneMask if memory allows (or regenerate in steps)

### 3.2 Deterministic random
For features, never use global RNG state. Use:
- `hash(seed, worldX, worldZ, featureSalt)` as randomness source

This prevents tree blobs that change depending on generation order.

---

## 4) Coastlines (Stop the Sand Bands Permanently)

Beaches must be handled in Phase C (surface rules) and must be conditional.

Required rules:
- Beaches apply only:
  - near sea level (0..6 blocks above sea)
  - gentle slope only (<=2)
  - ocean shore only (not lakes/rivers)
  - variable width based on “exposure”
- Tree placement suppressed within a coastal band (6–18 blocks inland, varying by exposure)

You already have `coastlines.md`. Integrate it strictly as:
- Phase C (surface)
- Phase E (tree suppression)

If sand still forms huge bands, it means:
- you’re using “any water” instead of “ocean water”
- or you’re applying sand beyond the near-sea band
- or you’re letting deserts override shoreline logic globally

---

## 5) Fix “Disconnected Pieces” (Height Discontinuities + Biome Blobs)

These are always caused by mixing responsibilities.

### 5.1 Height discontinuities (sand above forest)
Cause:
- biome or surface is altering height
Fix:
- Height is Phase A only.
- Biome terrain modifiers (if any) are tiny and blended, never hard-switched.

### 5.2 Predictable blobs (big forest blob, big mountain blob)
Cause:
- single-noise classification
- no domain warp
- no multi-field selection
Fix:
- use climate space (T/H/C/E/R)
- return top2 + blend
- optional domain warp for the *inputs* (not for final biome id)

### 5.3 Mountains as giant walls
Cause:
- ridged noise driving height directly
- missing erosion limiter
Fix:
- mountain mask (inland * peaks * (1-erosion))
- capped mountain lift
- optional slope limiter on heightmap

---

## 6) Concrete Implementation Plan (What to build next)

### Step 1 — Add GenRegion generation (80×256×80)
- Align regions to 5×5 chunks.
- Generate and cache 25 chunks per region.

### Step 2 — Refactor into Phase functions
Create strict functions:
- `phaseA_generateTerrainStoneWater(region)`
- `phaseB_computeBiomeBlend(region)`
- `phaseC_applySurfaceRules(region)`
- `phaseD_carveCaves(region)`
- `phaseE_placeFeatures(region)`

### Step 3 — Recompute heightmap after carving
If caves can open to surface:
- carve first
- recompute heightmap
- then apply surface dusting

### Step 4 — Add debugging overlays (mandatory)
You cannot tune without these:
- height grayscale
- slope heatmap
- ocean classification
- shoreline distance
- biome A/B/t visualization
- mountain mask visualization

---

## 7) Success Criteria (“Now it feels like Luanti/Minecraft”)

- No visible seams or discontinuities at chunk borders.
- Mountains form coherent ranges with foothills and calmer peaks.
- Forests taper naturally; no hard blobs.
- Beaches are narrow and varied; forests don’t touch sand.
- Sand is never “floating above” dirt/forest due to disconnected height rules.
- Different seeds produce strongly distinct worlds without obvious repetition.

---

## 8) Notes on Matching Luanti Behavior in Your Constraints

Luanti’s default generation unit is large (80³), and that is a major reason its worlds feel coherent.
Your vertical axis is fixed at 256, so your best equivalent is:
- **80×256×80 generation regions** with strict phase separation.

This alone will remove a huge amount of “artificial / painted” look because your algorithms stop fighting chunk boundaries and stop fighting each other.

---

End of spec.

