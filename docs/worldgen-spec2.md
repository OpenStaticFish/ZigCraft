This spec replaces the earlier heightmap-only approach with a **layered noise stack** closer in spirit to modern Minecraft-style generation: multiple large-scale fields (continentalness, erosion, peaks/valleys) plus climate-driven biome placement, separate ocean shaping, and controlled 3D carving to avoid “too many holes”.

It does **not** claim Mojang’s exact implementation (that changes over versions and is complex), but it **does** mirror the key ideas Minecraft exposes via its multi-noise biome parameters and noise settings pipeline. :contentReference[oaicite:0]{index=0}

---

## 0) The real problem you’re seeing (and the fixes)

### Symptoms
- “Worlds look samey” → too few distinct low-frequency controls; no domain warping; biome transitions too uniform.
- “Oceans too flat / fake” → using one height function for everything; seabed not varied; coastlines too smooth.
- “Too many holes” → 3D density threshold carving without constraints; caves breaking the surface too often; no cave masking near surface.

### Fixes (high level)
1. Use **separate fields** for continents vs mountains vs erosion (not just one fBm height).
2. Use **domain warping** so patterns aren’t obviously “noise bands”.
3. Give oceans their own treatment: **coastline shaping + seabed noise**, not “sea level clamp”.
4. Make caves controlled: **cave mask** + **surface protection** + **rarity**.

---

## 1) Determinism & Seeds

- Accept `seed_string` or `seed_u64`.
- Convert string → u64 using stable hash (FNV-1a 64-bit is fine).
- Use deterministic PRNG (SplitMix64/PCG32).
- All noise samplers are seeded from `(seed_u64, salt)`.

---

## 2) Chunk Inputs/Outputs

- Terrain is defined per (x,z) column + 3D density for caves.
- Chunk generation outputs:
  - block IDs
  - biome ID (per column, or per 4×4 cell like MC-style)
  - optional: heightmap cache

---

## 3) Noise types to implement

### 3.1 Primary noise (recommended)
- **OpenSimplex2** (2D + 3D) or classic Perlin/Simplex.
- Build **fBm** (octaves), **ridged** variant, and **domain warp** utility.

### 3.2 Why this matches Minecraft/Minetest style
- Modern Minecraft uses multiple “multi-noise” parameters for biome decisions (temperature, humidity, continentalness, erosion, weirdness, etc.). :contentReference[oaicite:1]{index=1}
- Noise settings are configurable in datapacks; these parameters primarily drive biome placement and tie into terrain/aquifer logic in that pipeline. :contentReference[oaicite:2]{index=2}
- Minetest mapgen v7 uses a combination of 2D and 3D Perlin noise and is notable for large rivers and cave differences (useful inspiration for “less flat” water + controlled caves). :contentReference[oaicite:3]{index=3}

---

## 4) Core 2D Fields (computed per column)

All fields are sampled in **world-space** with domain warping applied first.

### 4.1 Domain warping (anti-samey)
Compute a warp offset from low-frequency noise:
- `warp = vec2( noise2(seed+W0, x*sW, z*sW), noise2(seed+W1, x*sW, z*sW) ) * warpAmp`
- Use warped coords for subsequent sampling:
- `Xw = x + warp.x`, `Zw = z + warp.y`

Suggested:
- `sW = 1/900` to `1/1400`
- `warpAmp = 30` to `80` blocks

### 4.2 Continentalness C (landmass)
Purpose: big continents + ocean basins.
- `C = fbm2(seed+C0, Xw*sC, Zw*sC, oct=4)`
- Normalize to [0..1].

Suggested:
- `sC = 1/2200` to `1/3200`
- thresholds:
  - `C < 0.35` deep ocean
  - `0.35..0.46` coast / shelf
  - `> 0.46` land

### 4.3 Erosion E (cliffs vs rolling)
Purpose: places where terrain should be “sharper” vs “soft”.
- `E = fbm2(seed+E0, Xw*sE, Zw*sE, oct=4)` → [0..1]

Suggested:
- `sE = 1/900` to `1/1400`

Interpretation:
- low E → sharp, rugged, cliff-prone
- high E → smooth hills/plains

### 4.4 Peaks & Valleys / Weirdness P (mountain rhythm)
Purpose: repeated large-scale mountain range rhythm but warped.
- Use ridged noise:
  - `P = ridged2(seed+P0, Xw*sP, Zw*sP, oct=5)` → [0..1]

Suggested:
- `sP = 1/700` to `1/1100`

### 4.5 Climate: Temperature T and Humidity H
Purpose: biome variety independent of elevation bands.
- `T = fbm2(seed+T0, Xw*sT, Zw*sT, oct=3)` → [0..1]
- `H = fbm2(seed+H0, Xw*sH, Zw*sH, oct=3)` → [0..1]

Suggested:
- `sT = 1/4000` to `1/6000`
- `sH = 1/3000` to `1/5000`

Altitude adjustment:
- `T_adj = clamp01(T - (height / 512.0)*tempLapse)`
- `tempLapse = 0.20..0.35`

---

## 5) Height Function (less flat, more structure)

Let:
- `SEA = 64`

### 5.1 Base land height from continentalness
Map C to a base elevation:
- `land = smoothstep(0.35, 0.75, C)`
- `baseHeight = lerp(SEA - 55, SEA + 70, land)`

This creates:
- deep oceans
- broad continental plates
- varied inland elevation

### 5.2 Mountains from Peaks/Valleys + low erosion
Mountains should occur where:
- peaks are high (P) AND erosion is low (rugged zones)

Define mountain mask:
- `mMask = smoothstep(0.55, 0.85, P) * (1.0 - smoothstep(0.45, 0.80, E))`

Mountain lift:
- `mount = pow(mMask, 1.7) * mountAmp`
- `mountAmp = 60..170`

### 5.3 Hills / local detail
Add smaller variation:
- `detail = fbm2(seed+D0, Xw*sD, Zw*sD, oct=5) * detailAmp`
- `sD = 1/180..1/260`
- `detailAmp = 6..18`

### 5.4 Final surface height (pre carving)
- `h0 = baseHeight + mount + detail`

### 5.5 Cliff shaping (reduces “rounded noise blobs”)
Compute slope from sampled heights (or gradient of a noise field):
- `slope = max(|h0(x+1)-h0(x)|, |h0(z+1)-h0(z)|)`
Cliff factor:
- `cliff = smoothstep(3, 10, slope) * (1.0 - E)`
Apply:
- reduce topsoil thickness when `cliff` high
- optionally snap/terrace heights slightly in cliff regions:
  - `h = mix(h0, round(h0 / step) * step, cliff * terraceStrength)`
  - `step=3..6`, `terraceStrength=0.2..0.5`

---

## 6) Oceans that don’t look fake

### 6.1 Coastline roughness (prevents perfect curves)
Use a dedicated coastal noise:
- `coastJitter = fbm2(seed+OJ0, Xw*sOJ, Zw*sOJ, oct=3) * 0.05`
- Apply to the “ocean threshold”:
  - effectively shift `C` by jitter near coasts
This makes shorelines irregular.

Suggested:
- `sOJ = 1/500..1/800`

### 6.2 Seabed / ocean floor variation
If column is ocean (final height below SEA):
- seabed height:
  - `seabed = SEA - 18 - deepFactor(C)*35 + fbm2(seed+OF0, Xw*sOF, Zw*sOF, oct=5)*seabedAmp`
  - `sOF=1/220..1/360`, `seabedAmp=3..10`
Where `deepFactor(C)` increases as C decreases (deep ocean basins).

### 6.3 Waves are NOT geometry
Do not try to add “wave noise” to water surface blocks.
Keep water plane flat at SEA; make the seabed interesting.

---

## 7) Rivers and Lakes (fewer “random holes”, more readable water)

### 7.1 River mask (2D)
Use a ridged or “valley” field:
- `R = ridged2(seed+R0, Xw*sR, Zw*sR, oct=4)` → [0..1]
Rivers occur where ridges are LOW (valley lines). Convert:
- `river = 1.0 - R`
- `riverMask = smoothstep(riverMin, riverMax, river)`
Suggested:
- `sR=1/900..1/1500`
- `riverMin=0.72`, `riverMax=0.86`

### 7.2 Carve rivers into terrain
Let `riverDepth = riverMask * riverDepthMax`
- `riverDepthMax = 6..18`
Carve:
- `h = min(h, h0 - riverDepth)`
Fill with water if `h < SEA-1`.

---

## 8) Biomes (Minecraft-like multi-noise selection concept)

Use (T_adj, H, C, E, P, altitude) to choose biome.
Minecraft exposes these types of parameters to place biomes in a “multi-noise” space. :contentReference[oaicite:4]{index=4}

### 8.1 Biome set (v1)
- Deep Ocean, Ocean, Beach
- Plains, Forest
- Taiga (cold forest)
- Desert
- Snow/Tundra
- Mountains (high elevation + rugged)

### 8.2 Simple decision approach (works well)
1. If `C < 0.35` → Deep Ocean
2. Else if `C < 0.46` and `abs(h-SEA) < 4` → Beach
3. Else land:
   - if `altitude > SEA+95` or `mMask > 0.6` → Mountains (snow if cold)
   - else pick by T/H:
     - hot + dry → Desert
     - temperate + humid → Forest
     - temperate + dry → Plains
     - cold → Taiga / Snow

---

## 9) Materials & Surface Layers

### 9.1 Top/filler logic
- Determine `topBlock` by biome.
- `fillerDepth` varies by erosion and detail:
  - `fillerDepth = 3 + floor(fbm2(seed+FD0, Xw*sFD, Zw*sFD, oct=2) * 2)`
- On cliffs (`cliff > 0.6`) reduce filler to 0–1 and expose stone.

### 9.2 Ocean floor materials
- Shallow: sand + gravel patches
- Deep: gravel + clay/silt (if you have it)

---

## 10) Caves without “too many holes”

If your current caves are “too holey”, it’s usually because:
- density threshold is too permissive
- caves are allowed near the surface
- cave noise frequency is too high
- no rarity gating

### 10.1 Cave mask (rare + deeper)
Make a 2D cave “probability mask”:
- `Cave2 = fbm2(seed+CV2, Xw*sCV2, Zw*sCV2, oct=3)` → [0..1]
- `caveAllowed = smoothstep(0.58, 0.80, Cave2)`  
This makes caves appear in regions, not everywhere.

Suggested:
- `sCV2=1/900..1/1500`

### 10.2 3D density field (carving)
Compute density:
- `n = fbm3(seed+CV3, x*sCV3, y*sY, z*sCV3, oct=4)`
- Add vertical bias so caves prefer certain bands:
  - `band = smoothstep(12, 60, y) * (1.0 - smoothstep(120, 180, y))`
- Final carve condition:
  - if `caveAllowed > 0` AND `band > 0` AN

