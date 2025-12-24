````md
# biomes.md — Extensible Biome System & Variety Expansion (Voxel Engine)

This spec defines a **biome system** that:
- Produces **much more variety** (deserts, swamps, forests, etc.)
- Avoids “everything looks the same”
- Is **data-driven and extensible**
- Allows adding new biomes later without rewriting worldgen
- Integrates cleanly with existing terrain, caves, lighting, and rendering

This is intentionally aligned with **Minecraft-style multi-parameter biome selection**, but simplified and engine-friendly.

---

## 1) Goals

- Large-scale biome regions (readable from high altitude)
- Smooth biome transitions (no hard borders)
- Biomes affect:
  - surface blocks
  - vegetation
  - terrain shape bias
  - colors (grass/water tint)
- Easy to add new biomes later
- Deterministic per seed

Non-goals (v1):
- Full climate simulation
- Seasonal biome shifts
- Weather systems (rain/snow handled later)

---

## 2) Core Concept: Biomes Are Chosen in “Climate Space”

Biomes are **not chosen by a single noise**.

Each biome is selected by evaluating **multiple continuous parameters**:

Primary biome axes:
- **Temperature** (cold → hot)
- **Humidity** (dry → wet)
- **Elevation** (low → high)
- **Continentalness** (ocean → inland)
- **Ruggedness** (smooth → mountainous)

This prevents repetition and allows meaningful combinations.

---

## 3) Global Biome Parameter Fields

These are computed **per (x,z)** column and reused everywhere.

### 3.1 Temperature (T)
Controls cold vs hot biomes.

```text
T = fbm2(seed+TEMP, X*sT, Z*sT, oct=3) → [0..1]
````

Adjust for altitude:

```text
T_adj = clamp01(T - altitude * lapseRate)
```

Suggested:

* `sT = 1/4000 .. 1/6000`
* `lapseRate = 0.25 .. 0.35`

---

### 3.2 Humidity (H)

Controls dry vs wet biomes.

```text
H = fbm2(seed+HUM, X*sH, Z*sH, oct=3) → [0..1]
```

Suggested:

* `sH = 1/3000 .. 1/5000`

---

### 3.3 Continentalness (C)

Already used in terrain:

* ocean vs coast vs inland

Reuse existing field:

* deep ocean
* shallow ocean
* coast
* land
* deep inland

---

### 3.4 Elevation (E)

Normalized surface height:

```text
E = clamp01((height - seaLevel) / elevationRange)
```

Used to separate:

* beaches
* plains
* hills
* mountains
* alpine zones

---

### 3.5 Ruggedness / Erosion (R)

Already computed for cliffs/mountains.

Reuse:

* low R → smooth (plains, deserts)
* high R → rough (mountains, badlands)

---

## 4) Biome Definition (Data-Driven)

Each biome is defined by **constraints + weights**, not hard rules.

### 4.1 Biome Struct

```text
Biome {
  id
  name

  temperatureRange   [min,max]
  humidityRange      [min,max]
  elevationRange     [min,max]
  continentalRange   [min,max]
  ruggednessRange    [min,max]

  priority           (int)
  blendWeight        (float)

  surfaceBlocks {
    top
    filler
    depthRange
  }

  vegetationProfile
  terrainModifiers
  colorTints
}
```

---

## 5) Biome Selection Algorithm

For each (x,z):

1. Compute climate parameters:

   * T_adj, H, C, E, R
2. Evaluate **all biomes**:

   * If parameters fall outside biome ranges → score = 0
   * Otherwise compute normalized score based on distance to ideal center
3. Pick:

   * Highest score biome (v1)
   * Or top 2 biomes for blending (optional v2)

This makes biomes:

* Predictable
* Tunable
* Expandable

---

## 6) Core Biomes (v1)

### 6.1 Ocean Biomes

* Deep Ocean
* Ocean
* Shallow Ocean
* Beach

Ocean biomes depend mostly on:

* continentalness
* elevation

---

### 6.2 Plains

* Temp: temperate
* Humidity: low–medium
* Elevation: low
* Ruggedness: low

Surface:

* grass
* dirt filler
  Vegetation:
* sparse trees
* grass

---

### 6.3 Forest

* Temp: temperate
* Humidity: medium–high
* Elevation: low–medium
* Ruggedness: low–medium

Vegetation:

* dense trees
* bushes
* tall grass

---

### 6.4 Desert

* Temp: high
* Humidity: very low
* Elevation: low–medium
* Ruggedness: low

Surface:

* sand
* sandstone filler
  Vegetation:
* cactus
* dead bushes

Terrain:

* flatter, smoother
* fewer hills

---

### 6.5 Swamp

* Temp: warm
* Humidity: very high
* Elevation: near sea level
* Continentalness: inland

Surface:

* grass/mud
* shallow water pools
  Vegetation:
* swamp trees
* reeds

Special:

* waterlogged terrain
* darker grass/water tint

---

### 6.6 Mountains

* Elevation: high
* Ruggedness: high

Sub-variants by temperature:

* Cold mountains → snow
* Warm mountains → bare stone

Surface:

* stone
* thin soil
  Vegetation:
* sparse or none

---

### 6.7 Snow / Tundra

* Temp: very low
* Elevation: low–medium

Surface:

* snow
* frozen water
  Vegetation:
* minimal

---

## 7) Biome Influence on Terrain Shape

Biomes should not only change blocks, but also **bias terrain**.

Examples:

* Desert:

  * reduce hill amplitude
  * smooth noise
* Swamp:

  * clamp elevation near sea level
  * add micro-depressions
* Mountains:

  * amplify peaks
  * increase cliff chance
* Plains:

  * reduce ruggedness

Apply these as **local modifiers** on top of base terrain.

---

## 8) Vegetation System (Biome-Driven)

Each biome has a vegetation profile:

```text
VegetationProfile {
  treeTypes
  treeDensity
  bushDensity
  grassDensity
  specialFeatures
}
```

Placement rules:

* Deterministic per chunk
* Biome controls density and type
* Terrain slope limits placement

This keeps forests dense and deserts sparse automatically.

---

## 9) Biome Blending (v1 Simple, v2 Advanced)

### v1 (Simple)

* Single biome per column
* Hard switch at boundaries
* Acceptable initially

### v2 (Recommended)

* Pick top 2 biome scores
* Blend:

  * surface blocks (probabilistic)
  * colors
  * vegetation density
* Produces smooth transitions:

  * forest → plains
  * desert → savanna
  * swamp → forest

---

## 10) Visual Biome Identity

Each biome defines:

* grass tint
* foliage tint
* water tint
* fog color bias (optional)

These are applied in shaders via biome ID or biome color lookup.

---

## 11) Adding New Biomes Later (Key Requirement)

To add a new biome later:

1. Define parameter ranges
2. Define surface blocks
3. Define vegetation profile
4. Register biome

NO changes needed to:

* core terrain generator
* cave system
* lighting
* chunk system

Examples of easy future biomes:

* Savanna
* Badlands
* Jungle
* Mangrove swamp
* Volcanic
* Mushroom fields

---

## 12) Debug & Tooling (Strongly Recommended)

* Biome visualization mode (color by biome)
* Climate visualization:

  * temperature map
  * humidity map
* Show biome scores under cursor
* Toggle biome blending on/off

These are essential for tuning.

---

## 13) Acceptance Criteria

* World contains clearly distinct regions:

  * deserts
  * forests
  * swamps
  * mountains
* Biomes are large-scale and readable from above
* No checkerboard or noisy biome distribution
* Terrain shape changes with biome
* Adding a new biome requires only data changes
* Different seeds produce dramatically different biome layouts

---

## 14) Implementation Order

1. Implement temperature + humidity maps
2. Convert biomes to data-driven definitions
3. Single-biome selection
4. Surface + vegetation per biome
5. Terrain shape modifiers per biome
6. Visual tints
7. Debug visualizers
8. Optional biome blending

---

End of spec.

```

If you want next:
- **Biome blending implementation details**
- **Vegetation placement rules**
- **Biome-aware caves & ores**
- **Biome-specific ambient sounds**

Say the word.
```

