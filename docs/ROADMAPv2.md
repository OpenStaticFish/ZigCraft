
# Voxel Game Spec: Blocks + Worldgen + UI (Seeded)

This document specs the **basic building blocks** of a voxel sandbox game and a **seeded procedural world generator** with biomes, mountains, cliffs, oceans, rivers, oases, etc., plus a **home screen UI** with seed input and reproducibility.

---

## 1) Core Requirements

### 1.1 Goals
- Deterministic world generation: **same seed => same world** (across machines).
- Infinite or very large worlds via **chunked generation**.
- Multiple biomes and large-scale features:
  - oceans, beaches, rivers, lakes
  - plains/forests/deserts/snow biomes
  - mountain ranges, cliffs/plateaus
  - caves and ore distribution
  - oases in deserts (rare, seeded)

### 1.2 Non-goals (for v1)
- Complex climate simulation
- Realistic erosion simulation
- Full story/progression systems
These can be added later.

---

## 2) World Structure

### 2.1 Coordinate System
- World coordinates: integer (x, y, z)
- y is vertical, y=0 is sea level reference (can be offset).
- Use 32-bit int for block coords; 64-bit for derived hashes.

### 2.2 Chunking
- Chunk size: **16 x 16 x 256** (x,z,y) or configurable.
- Vertical sections recommended (e.g., 16x16x16 subchunks) for memory efficiency.
- Each chunk stores:
  - block IDs
  - lighting (optional v1)
  - metadata (optional)
- Generation happens in phases (heightmap first, then features).

### 2.3 World Layers
A clean approach is to treat generation as layered fields:
- **Continentalness** (land vs ocean)
- **Erosion/roughness** (cliffs vs smooth hills)
- **Temperature**
- **Humidity**
- **Height (base terrain)**
- **Local modifiers** (mountain mask, river carving, etc.)

---

## 3) Seed System

### 3.1 Seed Input
- Accept:
  - string seed (e.g. `"my cool world"`)
  - numeric seed (e.g. `123456789`)
- Convert string seed to 64-bit integer via stable hash (e.g., FNV-1a 64-bit).
- Use a stable PRNG for deterministic randomness (e.g., PCG32 / splitmix64).

### 3.2 Deterministic Noise
Use deterministic noise functions where:
- Input: (x, z) or (x, y, z) in world coords
- Output: float in [-1, 1] or [0, 1]
- Ensure floating-point determinism by:
  - using integer-based hashing noise where possible
  - or keeping same implementation + precision everywhere

---

## 4) Block System

### 4.1 Block Data Model
Each block has:
- `id` (uint16 or uint32)
- `name`
- `is_solid`
- `is_transparent`
- `emits_light` (optional)
- `light_absorption` (optional)
- `texture_index` per face (or material key)
- `break_time` (optional)
- `drops` (optional)
- `tags` (e.g., `ground`, `stone`, `wood`, `leaf`, `fluid`)

### 4.2 Basic Block Set (v1)
Minimum set for a complete world loop (terrain + resources + building):

#### Air / Fluids
- Air
- Water (source)
- Water (flowing) (optional v1; can fake as same block with level metadata)
- Lava (optional v1)
- Ice (cold biomes)
- Snow layer (thin overlay) (optional v1)

#### Terrain: Surface
- Grass
- Dirt
- Sand
- Red sand (optional)
- Gravel
- Clay (optional)

#### Terrain: Subsurface / Rock
- Stone
- Cobblestone (player-made, optional)
- Deepslate / Basalt (optional depth variation)
- Bedrock (bottom boundary)

#### Biome-specific
- Podzol / forest floor (optional)
- Mossy dirt / moss block (optional)
- Silt / mud (swamp-like, optional)
- Limestone / sandstone (optional for deserts)
- Snow block

#### Plants / Natural Blocks
- Short grass (decor)
- Tall grass (optional)
- Flowers (2–4 variants, optional)
- Cactus
- Dead bush (optional)
- Sugar cane / reeds (water edges)
- Logs (wood trunk)
- Leaves
- Sapling (optional)

#### Ores (basic progression)
- Coal ore
- Iron ore
- Copper ore (optional)
- Gold ore (optional)
- Diamond-like rare ore (optional)
- Redstone-like ore (optional)

#### Utility / Crafting (optional v1)
- Planks
- Crafting table
- Furnace
- Torch (light emitting)

### 4.3 Metadata (Optional v1)
If not doing full blockstate system, allow minimal metadata per block:
- water level (0..7)
- orientation (for logs)
- growth stage (for saplings, crops later)

---

## 5) Biome System

### 5.1 Biome Definition
A biome is defined by:
- `id`, `name`
- climate: temperature range, humidity range
- surface blocks:
  - top block (e.g., grass/sand/snow)
  - filler block (e.g., dirt/sand)
  - stone type overrides (optional)
- vegetation rules (density + types)
- terrain modifiers:
  - base height offset
  - hilliness
  - cliffiness bias
- water color / fog (optional)
- spawn rules (optional)

### 5.2 Biomes (v1 list)
- Ocean
- Beach
- Plains
- Forest
- Taiga (conifer + colder forest)
- Desert
- Savanna (optional)
- Tundra / Snow
- Mountains (high elevation biome)
- Badlands / Mesa (optional)
- Swamp (optional)

### 5.3 Climate Map
Compute 2D climate maps from noise:
- Temperature noise `T(x,z)` in [0..1]
- Humidity noise `H(x,z)` in [0..1]
Biome selection uses:
- altitude influence (high => colder)
- proximity to ocean influence (optional)

---

## 6) Terrain Generation Pipeline (Deterministic)

### 6.1 Overview
Worldgen runs in deterministic steps:

1. **Global maps (2D)**  
   Compute base fields per column (x,z):
   - continentalness C(x,z)
   - erosion E(x,z)
   - temperature T(x,z)
   - humidity H(x,z)
   - mountain mask M(x,z)
   - river mask R(x,z)
2. **Base height** from continentalness + mountain mask
3. **Cliffs** from slope + erosion
4. **Carving** rivers/coasts
5. **3D density field** for caves (optional v1)
6. **Material assignment** (stone/dirt/sand/snow)
7. **Features** (trees, cacti, ores, structures, oases)

### 6.2 Sea Level
- Define `SEA_LEVEL = 64` (config).
- Any column where surface height < SEA_LEVEL becomes ocean/lake fill.

### 6.3 Continentalness: Land vs Ocean
Use low-frequency noise to shape continents:
- `C(x,z)` in [0..1]
- thresholds:
  - `C < 0.35` => deep ocean
  - `0.35..0.45` => shallow ocean / coasts
  - `> 0.45` => land

This makes big oceans/continents instead of noisy puddles.

### 6.4 Base Height Function
Compute a base height:
- `base = SEA_LEVEL + landLift(C)`
- `landLift(C)`:
  - deep ocean => negative
  - coast => near SEA_LEVEL
  - inland => positive

Example conceptual mapping:
- `landLift = lerp(-40, +60, smoothstep(0.35, 0.75, C))`

### 6.5 Mountains (Ranges)
Use a mountain mask `M(x,z)`:
- low-frequency ridge noise or combined FBM
- threshold to form ranges:
  - `M > 0.6` => mountain region
Mountains add height:
- `mountAdd = pow(remap(M, 0.6..1.0), 2.0) * mountainAmplitude`
- amplitude: 60–140 blocks depending on desired scale

### 6.6 Hills / Local Variation
Use mid-frequency noise `Hn(x,z)`:
- adds small-to-medium variation (5–25 blocks)

### 6.7 Cliffs / Plateaus
Cliffs should appear where:
- slope is high OR erosion is low (meaning sharp terrain)
Compute slope using sampled heights:
- `slope = max(|h(x+1)-h(x)|, |h(z+1)-h(z)|)`
Cliffiness:
- `cliff = smoothstep(slopeLow, slopeHigh, slope) * (1 - E)`
Apply cliff shaping:
- Increase verticality by compressing heights into plateau steps or steep ramps.
Material rules:
- cliffs expose stone more (thin topsoil).

### 6.8 Oceans, Beaches, Shores
- If surface height < SEA_LEVEL:
  - fill with water up to SEA_LEVEL
  - seabed is sand/gravel/clay mix
- Beaches:
  - within N blocks of coastline AND height near SEA_LEVEL => sand

### 6.9 Rivers (Carving)
Use a river mask `R(x,z)`:
- generate a low-frequency "flow field" + noise threshold lines OR use “distance to river spline” style.
Simpler deterministic method:
- `R = abs(noise_river(x,z))`
- if `R < riverWidthThreshold`, this column is in a river corridor.
Carve height towards a river bed level:
- `riverDepth = remap(R, 0..threshold)` (deeper at center)
- `h = min(h, SEA_LEVEL - 2 - riverDepth)`
Fill with water where below SEA_LEVEL.

### 6.10 Lakes (Optional)
Lakes can be placed as rare features:
- pick candidate points by hashed grid
- if local basin exists, fill to lake level
Keep it deterministic by hashing region coords.

---

## 7) Material Assignment (Surface + Subsurface)

For each (x,z):
1. Determine final height `h`.
2. Determine biome based on (T, H, altitude, ocean distance).
3. Assign column materials:
   - y == h => top block (grass/sand/snow)
   - next `fillerDepth` (3–6) => filler (dirt/sand)
   - below => stone
4. Add bedrock at bottom:
   - y=0..4 => bedrock noise threshold

Biome-specific rules:
- Desert: top sand, filler sand/sandstone
- Snow: top snow block or snow layer + dirt
- Mountains: top stone/snow depending on temp/altitude

---

## 8) Caves & Ores (v1-friendly)

### 8.1 Caves
Option A (simple): 3D noise threshold carving.
- `density = noise3d(x,y,z)` + vertical bias
- if density > threshold => carve to air
Add cave rarity by using lower frequency + threshold tuning.

Option B (better later): worm/tunnel carving via random walk seeded per region.

### 8.2 Ores
Run ore passes after stone placement:
- For each ore type:
  - vertical range (minY..maxY)
  - vein size
  - vein count per chunk
- Deterministic placements using:
  - per-chunk PRNG seeded by (worldSeed, chunkX, chunkZ, oreType)

---

## 9) Features: Trees, Cacti, Vegetation, Oases

### 9.1 Feature Placement Strategy
For each chunk:
- Seed PRNG with `(worldSeed, chunkX, chunkZ, featurePassId)`.
- Decide a number of attempts based on biome.
- For each attempt:
  - pick (x,z) in chunk
  - find surface y
  - validate placement rules
  - place blocks

### 9.2 Trees
- Forest/taiga: more frequent
- Plains: rare lone trees
Tree shapes (v1):
- simple trunk height 4–7
- leaf blob radius 2–3
Use biome-specific block types (log/leaves).

### 9.3 Cacti
- Desert only
- height 2–5
- must be on sand

### 9.4 Oases (Desert Feature)
Goal: rare pockets of water + palms/trees in deserts.
Deterministic placement:
- Divide world into large regions (e.g., 256x256 blocks)
- For each region:
  - use hashed RNG to decide if an oasis exists (e.g., 5–10% chance)
  - if yes, pick a center point in the region
Placement rules:
- biome at center must be desert
- must be inland enough (not right on coast)
Build steps:
- carve a shallow basin
- fill with water (small lake)
- place sand around edges
- add reeds + a few trees + grass patches nearby

---

## 10) Home Screen UI Spec (Seed + World Creation)

### 10.1 Home Screen Layout
Required elements:
- Title: game name
- Primary actions:
  - `Singleplayer` (opens world create/load)
  - `Settings`
  - `Quit`
Optional:
- `Continue` (last played world)
- `Credits`

### 10.2 Singleplayer Screen
Two sections:
- **World List**
  - world name
  - last played date
  - seed (hidden behind “details”)
  - buttons: Play / Delete / Rename (delete requires confirm)
- **Create World**
  - World Name (text)
  - Seed (text input)
    - placeholder: “Leave blank for random”
  - Random seed button (generates a seed string or number)
  - World options (v1 minimal):
    - World Size: Infinite (default) / Limited (optional)
    - Starting biome bias: None (default) (optional)
  - Create button

### 10.3 Seed Behavior
- If seed input is empty:
  - generate a random 64-bit seed and display it after creation
- If seed input is provided:
  - store original string plus hashed numeric seed
Reproducibility:
- World folder stores:
  - `seed_string` (optional)
  - `seed_u64`
  - `worldgen_version`

### 10.4 Worldgen Versioning
Store a `worldgen_version` integer.
If you change generation later:
- new worlds get new version
- old worlds keep their version for deterministic chunk regen

---

## 11) Data Storage Spec

### 11.1 World Save Folder
Example structure:
- `worlds/<world_name>/`
  - `world.json` (metadata)
  - `region/` (chunk storage)
  - `player/` (player state)

### 11.2 `world.json`
Fields:
- `world_name`
- `seed_u64`
- `seed_string` (optional)
- `worldgen_version`
- `created_at`
- `last_played_at`
- `settings`:
  - `sea_level`
  - `chunk_size`
  - `enabled_features` (optional)

---

## 12) Implementation Roadmap (Suggested Order)

1. Seed system + deterministic PRNG
2. Chunk system + storage + basic meshing
3. Heightmap terrain: continentalness -> land/ocean
4. Biome selection via temp/humidity
5. Surface materials (grass/sand/snow)
6. Mountains + cliffs
7. Rivers + beaches
8. Caves (optional)
9. Ores
10. Vegetation (trees/cacti/reeds)
11. Oases
12. Home screen + world create/load with seed
13. Worldgen versioning + save format stabilization

---

## 13) Acceptance Criteria (v1)

- Creating a world with a seed reproduces the same terrain layout.
- Oceans/continents are large-scale and readable.
- At least 5 biomes appear in a typical exploration.
- Mountains and cliffs visibly exist (not just bumpy hills).
- Rivers exist and flow through land into oceans (even if simplified).
- Desert oases exist rarely and are deterministic.
- Home screen allows:
  - create world (name + seed)
  - load existing world
  - random seed generation

---
