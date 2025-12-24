Below is a **clean, engine-ready cave system spec** you can hand to your agent.
It is designed to add **interesting caves without ruining the surface** and avoids the “too many holes” problem you hit earlier.

---

````md
# cave-system.md — Controlled, Natural Cave Generation (Voxel Engine)

This spec defines a **multi-style cave system** inspired by modern Minecraft + Minetest concepts, but simplified and controllable.

Goals:
- Large, readable cave networks
- Minimal surface perforation
- Deterministic, seeded generation
- No “swiss cheese” terrain
- Easy to tune density, rarity, and depth

---

## 1) Design Principles

1. **Caves are volumetric, not heightmap-based**
2. **Surface protection is mandatory**
3. **Caves appear in regions, not everywhere**
4. **Multiple cave types create variety**
5. **Rarity > density**

---

## 2) Cave Types (v1)

Implement **two cave systems**, layered:

### A) Worm / Tunnel Caves (Primary)
- Long, winding tunnels
- Large connected networks
- Main exploration caves

### B) Noise Cavities (Secondary)
- Small chambers
- Occasional bubbles / pockets
- Adds texture, not structure

(Do NOT start with ravines or mega-caverns yet.)

---

## 3) Global Cave Mask (Stops “Too Many Holes”)

Before carving ANY caves, compute a **2D cave region mask**.

### 3.1 Cave Region Noise (2D)
```text
C2D(x,z) = fbm2(seed+C2D, x*s, z*s, oct=3) → [0..1]
````

Suggested params:

* `s = 1/900 .. 1/1500`
* Region threshold:

  * `C2D < 0.55` → NO caves
  * `C2D >= 0.55` → caves allowed

This ensures:

* Entire regions with caves
* Entire regions with none

---

## 4) Surface Protection (Critical)

Never carve caves too close to the surface.

### Rule

```text
if (surfaceHeight(x,z) - y < minSurfaceDepth) → DO NOT carve
```

Suggested:

* `minSurfaceDepth = 8 .. 14`

This single rule removes:

* Holes everywhere
* Collapsing hills
* Ugly exposed cave ceilings

---

## 5) Worm / Tunnel Caves (Main System)

### 5.1 Seeded Cave Worms

For each chunk:

* Seed RNG with `(worldSeed, chunkX, chunkZ, CAVE_WORM)`
* Spawn `N` worms:

  * `N = 0..2` (biased low)

### 5.2 Worm Parameters

Each worm has:

* start position `(x,y,z)`
* direction vector `dir`
* radius `r`
* length `L`

Suggested ranges:

* `y`: 20..120
* `r`: 2..5
* `L`: 40..120 blocks

### 5.3 Worm Step Algorithm

For each step:

1. Carve a sphere at current position
2. Move forward
3. Slightly rotate direction using noise
4. Occasionally:

   * branch (rare)
   * change radius slightly

Pseudo:

```cpp
for i in 0..L:
  carveSphere(pos, r)
  dir += noiseVec3(pos) * turnStrength
  dir = normalize(dir)
  pos += dir * stepSize
```

### 5.4 Carve Rule

For each voxel in sphere:

* Only carve if:

  * cave mask allows
  * surface protection allows

---

## 6) Noise Cavities (Secondary System)

Used for:

* Small pockets
* Side chambers
* Irregular cave shapes

### 6.1 3D Density Noise

```text
D(x,y,z) = fbm3(seed+C3D, x*s, y*sY, z*s, oct=4)
```

Suggested:

* `s = 1/48 .. 1/70`
* `sY = same or slightly lower`
* `threshold = 0.65 .. 0.75`

### 6.2 Vertical Bias

Restrict cavities to depth bands:

```text
band = smoothstep(20, 50, y) * (1 - smoothstep(120, 160, y))
```

### 6.3 Final Carve Condition

```text
if C2D >= 0.55
and band > 0
and D > threshold
and surfaceDepth >= minSurfaceDepth
→ carve
```

---

## 7) Connectivity Rules (Important)

* Worm caves define the main network
* Noise cavities must:

  * either intersect a worm cave
  * or be extremely rare

This prevents:

* Isolated 1×1 holes
* Random floating cavities

---

## 8) Performance & Chunk Safety

### 8.1 Chunk Boundary Safety

* Worms may cross chunk borders
* Use world-space carving, not chunk-local
* Ensure neighbor chunks mark themselves dirty

### 8.2 Determinism

* All cave decisions must be:

  * seed-based
  * chunk-coordinate based
* No frame-based randomness

---

## 9) Debug Toggles (Highly Recommended)

* `show_cave_mask` (visualize regions)
* `disable_noise_caves`
* `disable_worm_caves`
* `draw_cave_bounds`

These dramatically speed tuning.

---

## 10) Tuning Guide (Quick Fixes)

If caves are too common:

* Increase `C2D threshold`
* Increase `minSurfaceDepth`
* Increase 3D noise threshold

If caves feel boring:

* Increase worm length
* Increase branch chance slightly
* Increase turn strength

If caves break the surface:

* Increase `minSurfaceDepth`
* Lower worm start Y max

---

## 11) Acceptance Criteria

* Large cave networks exist underground
* Surface terrain remains intact
* Not every mountain has holes
* Caves are discoverable but not everywhere
* Different seeds produce different cave regions

---

## 12) Future Extensions (Not v1)

* Ravines (vertical worms)
* Mega caverns
* Aquifers / flooded caves
* Biome-specific cave materials
* Stalactites / stalagmites

---

End of spec.

```

---

If you want next:
- **Ore distribution tied to cave proximity**
- **Lighting rules for caves**
- **Water/lava cave interactions**
- **Debug visualisation shaders**

Say which one.
```

