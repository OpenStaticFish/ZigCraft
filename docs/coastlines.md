````md
# coastlines.md — Natural Beaches, Shores, and Coastal Transitions (Voxel Engine)

This spec fixes “too much sand between sea and trees” and improves coastline quality to feel closer to Minecraft/Minetest.

Key idea:
- **Beaches are not a biome paint.**
- Beaches are a **conditional shoreline rule** based on:
  - sea level proximity
  - slope
  - ocean exposure (ocean vs lake/river)
  - local coastal width variation
- Forests need a **coastal transition band** (reduced trees) so you don’t get “forest meets sand”.

---

## 1) Goals

- Narrow, believable beaches (typical 2–5 blocks).
- Wider beaches only in exposed areas (rare).
- Steep coasts become cliffs (little/no sand).
- Forests do not touch sand directly; include a transition band.
- Rivers/lakes do not create massive beaches.
- Data-driven/tunable; works with future biomes.

Non-goals (v1):
- Real dune simulation
- Wave erosion
- Tidal effects

---

## 2) Definitions & Inputs

World constants:
- `seaLevel` (e.g. 64)
- `waterBlockId`
- `airBlockId`

Per-column values (computed for each XZ):
- `h = surfaceHeight(x,z)` (top solid block height)
- `depth = h - seaLevel`
- `slope = maxAbsNeighborDelta(h, x,z)`  (see §3)
- `continentalness C(x,z)` (0..1)
- `isOcean(x,z)` derived from continentalness (see §4)

Optional but recommended:
- `shoreDistOcean(x,z)` distance (blocks) from column to nearest **ocean water** (see §5)

---

## 3) Slope Metric (Cheap and Effective)

Compute a simple 2D gradient from neighbor heights:

### 3.1 4-neighbor slope
```text
slope4 = max(
  abs(h - h(x+1,z)),
  abs(h - h(x-1,z)),
  abs(h - h(x,z+1)),
  abs(h - h(x,z-1))
)
````

Optional 8-neighbor (stronger):

* include diagonals as well

Recommended:

* use 4-neighbor for speed
* optionally clamp to a reasonable range

Why:

* Beaches form on gentle slopes.
* Steep slopes should become cliffs/rock.

---

## 4) Ocean vs Lake/River (Critical)

The main reason you have too much sand is usually:

* treating ANY nearby water as “coast”.

We must distinguish **ocean shoreline** from inland water.

### 4.1 Ocean classification using continentalness

Example thresholds (tune to your generator):

* `C < 0.35` => deep ocean
* `0.35..0.45` => ocean
* `0.45..0.52` => coast band
* `> 0.52` => inland

Define:

```text
isOceanWater(x,z) = (column is water) AND (C(x,z) < oceanThreshold)
```

Define:

```text
isOceanLand(x,z) = (column is land) AND (C(x,z) < inlandCutoff)
```

Where:

* `oceanThreshold ~ 0.45`
* `inlandCutoff ~ 0.55`

This prevents:

* huge “beaches” around lakes
* sand banding around rivers

---

## 5) Shore Distance to Ocean (Two Options)

Beaches need a distance-from-shore measurement.

### Option A (v1, simple): Local radius search (fast, approximate)

For a land column, search within radius R (e.g. 12) for any `isOceanWater`.

Return:

* `shoreDistOcean = min manhattan/chebyshev distance to found ocean water`
* If none found: `shoreDistOcean = INF`

This is easy and good enough for v1.

### Option B (v2, best): BFS distance field (accurate)

For a region (e.g. chunk + padding), BFS from all `isOceanWater` cells to compute distance for all land cells.

Store per chunk:

* `shoreDistOcean` array (16×16)

Recommended later when you want perfect coast control.

---

## 6) Beach Width Field (No More Uniform Bands)

Beaches should vary width based on “exposure”.

Compute an exposure noise:

```text
exposure = fbm2(seed+EXPOSE, x*sE, z*sE, oct=2..3) -> [0..1]
```

Suggested:

* `sE = 1/1500 .. 1/2500`

Then:

```text
baseBeachWidth = lerp(2, 7, exposure)
```

Now incorporate slope:

```text
slopeFactor = 1 - smoothstep(slopeMin, slopeMax, slope)
beachWidth = baseBeachWidth * slopeFactor
```

Suggested:

* `slopeMin = 1`
* `slopeMax = 4`

Interpretation:

* gentle coast (slope ~0..1): width stays near base width
* steep coast (slope >= 4): width collapses toward 0

Finally clamp:

```text
beachWidth = clamp(beachWidth, 0, 10)
```

---

## 7) Beach Eligibility Rules (When to Place Sand)

A land column becomes “beach sand” only if:

### 7.1 Near sea level

Beaches are near sea level, not up on mountains.

```text
depthOK = (depth >= 0) AND (depth <= beachMaxDepth)
```

Suggested:

* `beachMaxDepth = 6`  (0..6 blocks above sea level)

### 7.2 Ocean shoreline only

```text
oceanOK = (shoreDistOcean != INF)
```

### 7.3 Within computed beach width

```text
widthOK = (shoreDistOcean <= beachWidth)
```

### 7.4 Gentle slope only

```text
slopeOK = (slope <= beachSlopeMax)
```

Suggested:

* `beachSlopeMax = 2` (tune 1..3)

### 7.5 Final condition

```text
isBeach = depthOK && oceanOK && widthOK && slopeOK
```

Result:

* Typical beaches: 2–5 blocks
* Wide beaches: rare and only exposed shores
* Cliff shores: almost no sand

---

## 8) Cliff Shores (Rock meets sea)

When slope is steep near sea level, we want rock/cliff not sand.

Define:

```text
isCliffCoast = depthOK && oceanOK && (slope >= cliffSlopeMin)
```

Suggested:

* `cliffSlopeMin = 4`

If `isCliffCoast`:

* top block becomes stone/rock (or biome rock)
* optionally place gravel at waterline

---

## 9) Coastal Transition Band (Fix “trees touch beach”)

Even with good beaches, forests shouldn’t start immediately behind sand.

Define a coastal vegetation suppression band:

```text
noTreeDist = lerp(noTreeMin, noTreeMax, exposure)
```

Suggested:

* `noTreeMin = 6`
* `noTreeMax = 18`

Rule:

```text
if shoreDistOcean <= noTreeDist:
  suppress trees (tree density = 0 or near 0)
  allow shrubs/grass
```

This creates:

* beach → grassy/shrubby band → forest

---

## 10) Coastal Micro-Biomes (Optional, High Impact)

Instead of abrupt biome adjacency, introduce a “CoastalPlains” transition for forests:

Rule:

```text
if biome == Forest && shoreDistOcean <= coastalBand && !isBeach:
  biome = CoastalPlains
```

Suggested:

* `coastalBand = 12..24`

CoastalPlains characteristics:

* same climate as forest, but:

  * tree density reduced (e.g. 20–40% of forest)
  * more grass and shrubs
  * occasional sand patches near beach edge

This is how you get Minecraft-like “soft” coasts.

---

## 11) Sand Placement Scope (Important)

Sand should be applied as a *surface override* only:

* do not change underlying height
* do not force large dunes everywhere in non-desert biomes

Surface layering rule:

* If `isBeach`: top = sand, filler = sand/sandstone (few layers)
* Else: biome decides top block normally

For deserts:

* desert biome still uses sand inland
* but coastline rules still control shore realism

---

## 12) Implementation Order

1. Compute `slope(x,z)` from neighbor heights.
2. Implement `isOceanWater/isOceanLand` using continentalness thresholds.
3. Implement `shoreDistOcean` (Option A radius search first).
4. Implement exposure noise and `beachWidth`.
5. Implement `isBeach` and `isCliffCoast` surface overrides.
6. Add `noTreeDist` suppression band for vegetation placement.
7. Add optional `CoastalPlains` micro-biome rule.
8. Add debug visualizers.

---

## 13) Debug Visualizers (Required)

* Color by `shoreDistOcean` (gradient)
* Show `beachWidth` map
* Highlight `isBeach` cells
* Highlight `isCliffCoast` cells
* Show vegetation suppression band

These are critical for tuning.

---

## 14) Tuning Targets (What “good” looks like)

* Typical beach width: 2–5 blocks
* Wide beaches: 6–10 blocks only in exposed areas
* Cliff shores: 0–2 blocks of sand (or none)
* Trees start: 8–20 blocks inland (varies by exposure/biome)

---

## 15) Acceptance Criteria

* No massive uniform sand bands around oceans.
* Forests do not touch sand immediately; transition band exists.
* Steep mountain coasts become cliffs rather than beaches.
* Lakes and rivers do not generate huge beaches.
* Coastline varies naturally (bays, coves, exposed shores).

---

End of spec.

```
```

