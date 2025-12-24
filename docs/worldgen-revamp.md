````md
# worldgen-revamp.md — Minecraft/Minetest-Quality Worldgen Revamp Spec

This spec is a full revamp plan to move from “procedural paint / artificial blobs” to a layered, stable, believable worldgen pipeline closer to Minecraft (1.18+) / Minetest quality.

It targets the current issues:
- Coastlines: too much sand, uniform bands, forests touching beaches
- Terrain: abrupt height jumps, “walls”, overly dramatic slopes
- Biomes: hard blobs, sharp boundaries, predictable patterns
- Consistency: sand sometimes above forest, mismatched height/surface rules
- Overall feel: disconnected systems that don’t blend

---

## 0) Design Principle: Separate the Layers (Hard Rule)

We enforce a strict pipeline separation:

1) **Terrain (world shape)**
   - continents/oceans, mountains, valleys, base height, cliffs, caves density
   - NO biome block painting
   - NO vegetation

2) **Climate + Biome selection**
   - temperature/humidity/etc. => biome weights (not single biome)
   - biome selection does NOT define terrain height; only small *blended* modifiers

3) **Surface rules**
   - decide top/filler blocks using (biome weights + slope + sea proximity + masks)
   - beaches and cliff shores belong here

4) **Features**
   - trees, plants, boulders, ores, structures
   - placed deterministically after surface is set
   - obey coast buffers and transition bands

If any layer does another layer’s job, you get exactly the artifacts you’re seeing.

---

## 1) Target Output Qualities (Acceptance Targets)

### 1.1 Coastline targets
- Typical beach width: 2–5 blocks
- Wide beaches: 6–10 blocks only in exposed zones
- Steep coasts: 0–2 blocks of sand (cliff/rock meets sea)
- Forest tree line begins: 8–20 blocks inland (biome dependent)

### 1.2 Terrain targets
- No long near-vertical walls unless explicitly a “cliff biome” / special feature
- High elevation silhouettes are calm/broad; micro-noise reduced at peaks
- Height transitions between regions are continuous (no plateaus “pasted on”)

### 1.3 Biome targets
- Biomes form large readable regions, but borders are blended
- Transition zones exist (forest→plains→beach, desert→savanna→plains)
- Vegetation density ramps; no instant 0→100% jumps

---

## 2) Proposed New Architecture

### 2.1 Data produced per (x,z) column
Compute these once and reuse:
- `continentalness C` (0..1) : ocean→inland
- `peaks P` (0..1) : mountain-likelihood mask (ridged recommended)
- `erosion E` (0..1) : ruggedness limiter
- `weirdness W` (0..1) : variation / ridge-vs-valley signal
- `temperature T` (0..1)
- `humidity H` (0..1)

Optional:
- `exposure X` (0..1) : coastline beach width variation
- `riverMask Rm` later

### 2.2 Data produced per (x,y,z)
- `density(x,y,z)` for caves/overhangs (v2; keep separate)

---

## 3) Terrain Generator Revamp (World Shape Only)

### 3.1 Base height from continentalness
Use continentalness to drive a smooth ocean→land curve:
- deep ocean basin
- continental shelf
- coastal rise
- inland plateau

Example conceptual mapping (tune):
- `C < 0.35` => deep ocean
- `0.35..0.45` => shallow ocean
- `0.45..0.55` => coast band
- `> 0.55` => inland

Height should be continuous through these bands.

### 3.2 Mountain system = mask + capped lift (fixes “walls”)
Do NOT do “ridgedNoise * hugeAmp directly into height”.

Instead:
1) Compute mountain mask:
```text
inland = smoothstep(0.48, 0.70, C)
peakMask = smoothstep(0.60, 0.90, P)
ruggedMask = 1.0 - smoothstep(0.45, 0.85, E)
mountMask = inland * peakMask * ruggedMask
````

2. Compute mountain lift (use smooth noise, then cap):

```text
liftNoise = fbm2(seed+LIFT, x*sL, z*sL) -> [0..1]
mountLiftRaw = mountMask * liftNoise * mountAmp
mountLift = mountLiftRaw / (1 + mountLiftRaw / mountCap)
```

This prevents runaway cliffs and creates ranges, not walls.

### 3.3 Elevation-dependent detail attenuation (fixes “busy peaks”)

Detail noise must fade with elevation:

```text
elev01 = clamp01((height - seaLevel) / highlandRange)
detailAtten = 1 - smoothstep(0.3, 0.85, elev01)
height += detailNoise * detailAmp * detailAtten
```

### 3.4 Slope limiter (optional but very effective)

After generating a local heightmap (chunk + border), run 3–6 relaxation passes:

* enforce `maxDelta` between neighbors (suggest 2)
  This kills giant vertical sheets while preserving mountains.

---

## 4) Climate → Biomes (Fixes blobs, predictability)

### 4.1 Biome selection returns weights, not a single biome

For each (x,z), compute scores for all biomes in climate space:

* temperature
* humidity
* continentalness
* erosion/ruggedness
* elevation band

Pick top 2 (optionally 3):

* `biomeA`, `biomeB`
* `blend t = scoreA / (scoreA + scoreB)`

### 4.2 Blend everything using `t`

This is non-negotiable:

* surface blocks
* vegetation density
* color tints
* *small* terrain modifiers (never large plateaus)

This is how you avoid “big blobs” and hard borders.

### 4.3 Add transition micro-biomes

For harsh pairs, define explicit transitions:

* Desert ↔ Forest => Savanna / Dry Plains
* Forest ↔ Swamp => Marsh
* Plains ↔ Mountains => Foothills
  Use these only near 50/50 blends.

---

## 5) Surface Rules (Fixes sand bands + sand above trees)

Surface rules are a separate step that takes:

* final terrain height `h`
* slope `slope(x,z)`
* sea proximity
* biome weights

### 5.1 Compute slope for surface rules

Use max neighbor delta of heightmap.

### 5.2 Coastlines: beaches are conditional (ocean-only + gentle slope)

Use the `coastlines.md` approach:

* distinguish ocean water via continentalness
* compute `shoreDistOcean`
* compute `beachWidth` from exposure + slope
* only place sand where:

  * near sea level (0..6 above sea)
  * gentle slope (<=2)
  * within beach width
  * ocean-only (not lakes)

### 5.3 Coastal transition band (prevents forest touching sand)

In vegetation pass:

* suppress trees for 6–18 blocks inland (varies by exposure)
  Optionally replace forest with CoastalPlains micro-biome for that band.

### 5.4 Prevent “sand above trees”

Rule: beach sand must never be applied outside the near-sea band.

* sand inland is controlled by desert biome, not “near water”.

Additionally:

* surface rules must not alter height.
  If you have any “raise/lower for biome” logic, remove or blend and keep amplitude small.

---

## 6) Features (Trees, Plants) (Fixes tree blobs and harsh edges)

### 6.1 Use density fields, not binary placement

For each column compute:

* `treeDensity = lerp(densityB, densityA, t)`
  Then place trees using probability based on density.

This creates natural tapering.

### 6.2 Add spacing rules

Use a deterministic hash + spacing radius:

* avoid trees every 1–2 blocks
* enforce minimum distance between trunks

### 6.3 Biome-aware coastal suppression

If `shoreDistOcean <= noTreeDist`:

* set `treeDensity = 0`
* allow shrubs/grass

---

## 7) Debugging: Add the “Minecraft tools” you’re missing

You cannot tune worldgen without visibility.

Required debug views:

* show height as grayscale
* show slope heatmap
* show continentalness
* show mountain mask
* show temperature/humidity
* show biome weights (A/B with blend value)
* show shoreline distance + beach eligibility

Also:

* print under cursor:

  * h, slope, C, P, E, biomeA/B, t, shoreDistOcean, beachWidth

These debug tools are a major reason Minecraft-like pipelines converge fast.

---

## 8) Implementation Plan (Incremental, No Rewrite Cliff)

### Phase 1 — Stabilize terrain

1. Refactor: isolate “terrain height function” (no blocks/biomes inside).
2. Implement mountain mask + capped lift.
3. Add elevation-dependent detail attenuation.
4. Add optional slope limiter.

Exit criteria:

* no vertical sheets/walls
* highlands feel calmer

### Phase 2 — Fix biomes (no blobs)

1. Implement biome weights (top2 + blend t).
2. Blend surface blocks (probabilistic).
3. Blend vegetation density.

Exit criteria:

* no hard circular islands
* transitions feel gradual

### Phase 3 — Fix coastlines (sand problem)

1. Implement ocean-only shoreline distance.
2. Implement slope+sea-level constrained beaches.
3. Add coastal no-tree band.

Exit criteria:

* beaches 2–5 blocks typical
* forests no longer touch sand

### Phase 4 — Polish

1. Add transition micro-biomes (savanna, foothills, marsh).
2. Improve vegetation spacing and variety.
3. Tune constants using debug views.

Exit criteria:

* “looks believable at distance”
* “looks cohesive on the ground”

---

## 9) Known Failure Modes & Direct Fixes

### Massive sand bands

Cause:

* beach rule uses any water; no slope/sea constraints
  Fix:
* ocean-only + slope + sea band + variable width

### Sand above trees / height discontinuities

Cause:

* biome is modifying height or surface logic is inconsistent
  Fix:
* terrain height independent; biome modifiers blended and small; surface rules don’t change height

### Big blobs of forest / big blobs of mountain

Cause:

* single-noise biome classification; no blending; mountain mask too broad
  Fix:
* climate-space selection + blend; mountain mask inland+peaks+erosion

### Artificial predictability

Cause:

* too few independent fields; same noise scale reused everywhere
  Fix:
* separate scales for C/P/E/T/H/exposure; add domain warp sparingly

---

## 10) Acceptance Criteria (Final)

* Coastlines look natural; beaches narrow and variable.
* Forests transition through a coastal band; no “forest meets sand”.
* Mountains appear as ranges, not walls; peaks are calmer.
* Biomes blend and taper; no hard blobs.
* Terrain, biomes, surface, and features feel cohesive and connected.
* New biomes can be added by data/config, not code rewrites.

---

End of spec.

```
::contentReference[oaicite:0]{index=0}
```

