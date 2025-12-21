# atmosphere-lighting.md — Atmosphere, Sun/Moon, Day–Night Cycle, Dynamic Lighting (Voxel Engine)

This spec defines a complete “v1 atmosphere” system:
- Day/night cycle with sun + moon
- Sky rendering (simple → scalable)
- Dynamic lighting system for voxels (sunlight + block lights)
- Time/seed determinism and save format
- Practical performance strategy for 16×256×16 chunks

---

## 1) Goals

- Visually readable day/night cycle: dawn → day → dusk → night.
- Sun + moon directions affect:
  - sky color
  - ambient intensity
  - directional light (shadows optional later)
- World lighting:
  - **Sunlight** propagates from sky downward and into caves
  - **Block light** (torches, lava, etc.) propagates outward
- Lighting updates:
  - incremental, chunk-local, smooth streaming
  - no full-world recomputes
- Deterministic with seed + stored time.

Non-goals (v1):
- Real volumetric clouds
- Cascaded shadow maps
- Full physically-based scattering
- Global illumination

---

## 2) Time System

### 2.1 World Time Model
Store time as a continuous value:
- `timeOfDay` in `[0, 1)` where:
  - 0.00 = midnight
  - 0.25 = sunrise
  - 0.50 = noon
  - 0.75 = sunset

Or store `worldTicks`:
- `ticksPerDay = 24000` (Minecraft-like) (any consistent value ok)
- `timeOfDay = (worldTicks % ticksPerDay) / ticksPerDay`

### 2.2 Save Fields
In `world.json`:
- `world_time_ticks`
- `time_scale` (optional; 1.0 default)

### 2.3 Determinism
- World time is not derived from real clock; it advances by `deltaTime * timeScale`.
- When loaded, resume from saved ticks.

---

## 3) Sun & Moon

### 3.1 Directions
Compute a unit direction for the sun:
- `sunAngle = timeOfDay * 2π`
- Use a tilted orbit (more natural):
  - tilt around world X axis (e.g. 15–25 degrees)
- `sunDir` points from world towards sun (directional light direction is `-sunDir`)

Moon is opposite:
- `moonDir = -sunDir`

### 3.2 Colors/Intensity Curves
Define curves (can be simple lerps):
- `sunIntensity(timeOfDay)`:
  - 0 at night
  - ramp up at dawn
  - peak at noon
  - ramp down at dusk
- `moonIntensity(timeOfDay)`:
  - strongest at night
  - 0 at day

Recommended approach:
- Use smoothstep around sunrise/sunset:
  - dawn window: `0.22..0.28`
  - dusk window: `0.72..0.78`

### 3.3 Sun/Moon Rendering
Options:
- Billboard quad in sky dome
- Analytical disc in fragment shader (cheap)
- Textured sprites (later)

v1 requirement:
- Sun disc visible during day
- Moon disc visible at night

---

## 4) Sky Rendering

### 4.1 V1 Sky (Simple, Good Looking)
Use a fullscreen triangle/quad sky shader:
Inputs:
- camera direction
- `sunDir`, `moonDir`
- `sunIntensity`, `moonIntensity`
- color presets

Compute:
- sky gradient (horizon → zenith)
- sun glow near sunDir
- dusk/dawn tint near horizon

Stars:
- Render procedural starfield at night:
  - hash(viewDir) based stars
  - fade by `(1 - sunIntensity)`

Clouds (optional v1):
- 2D scrolling noise layer projected onto sky.

### 4.2 Fog (Strongly recommended)
Fog improves depth perception and hides chunk pop:
- Color matches sky/horizon
- Exponential fog:
  - `fogFactor = 1 - exp(-distance * fogDensity)`
- Increase fog at night slightly.

---

## 5) World Lighting Overview

You need two independent voxel light channels:

### 5.1 Light Types
- **Sunlight** (a.k.a. skylight)
  - Range: 0..15 (u4)
  - Source: sky exposure
  - Directional-ish: strongest downward, but spreads into caves
- **Block light**
  - Range: 0..15 (u4)
  - Source: emissive blocks (torch=14, lava=15, etc.)
  - Spreads in all directions

Store them separately:
- `skyLight` and `blockLight`
Final light at a voxel:
- `L = max(skyLight, blockLight)` for brightness
- (optional later) use both for color grading

---

## 6) Light Storage Layout

### 6.1 Per Block
Minimum:
- 4 bits skylight
- 4 bits blocklight
Pack into one byte:
- `uint8 light = (sky << 4) | block`

### 6.2 Per Subchunk
Because you already mesh in 16×16×16:
- store light arrays per subchunk too (cache-friendly)

---

## 7) Skylight Computation

### 7.1 Initial Skylight for a Column
For each (x,z) column:
- Start from `y=255` downwards
- Keep a “sunlight value” initially 15
- For each y:
  - if block is fully opaque: sunlight becomes 0 below
  - else set `skyLight(x,y,z)=currentSun`

This produces:
- outdoor light = 15
- caves under overhangs become dark

### 7.2 Skylight Flood Fill (Spread into caves)
After vertical pass, propagate skylight sideways/down into openings:
- BFS flood from all voxels with skylight > 0
- Spread to neighbors with decay:
  - `next = cur - 1` (or no decay for vertical-down in some engines, but decay is simpler)
- Only propagate through non-opaque blocks.

Performance:
- Do this per chunk (and across chunk borders using neighbor queues)

### 7.3 Incremental Updates
When blocks change:
- If removing an opaque block:
  - skylight can increase below → “light add” BFS
- If placing an opaque block:
  - skylight can decrease → “light remove” BFS + re-add from other sources

(Use the standard “remove then add” algorithm used by voxel engines.)

---

## 8) Block Light Propagation

### 8.1 Emissive Blocks
Define emissive levels:
- Torch: 14
- Lava: 15
- Glowstone (if any): 15
- Lantern: 13, etc.

### 8.2 Flood Fill
For each source voxel with `blockLight = N`:
- BFS outward:
  - neighbor gets `max(existing, N-1)` if transparent
- stops at 0

### 8.3 Incremental Updates
On block changes:
- If a light source removed:
  - run “remove light” BFS (tracking old levels)
  - then re-add from remaining sources
- If added:
  - add BFS only

---

## 9) Cross-Chunk Lighting

### 9.1 Border Exchanges
Lighting must be consistent across chunk edges.

Rules:
- When a chunk loads or updates lighting, it must:
  - push border light changes to neighbors
  - or request neighbor border values during BFS

Implementation options:
- Option A: keep a 1-block “light padding” border cache per chunk
- Option B: BFS queries neighbor chunk live via accessor

V1 recommendation:
- Query neighbors live and queue work if neighbor missing.

### 9.2 When Neighbor Missing
Treat missing neighbor as:
- “opaque” for propagation? (prevents light leaking)
- OR “air” for propagation? (causes popping)
Recommended:
- Treat missing as opaque for lighting to avoid fake leaks.
- When neighbor arrives, recompute border propagation for both.

---

## 10) Rendering the Lighting

### 10.1 V1 Lighting Model
In chunk mesh vertex data, include a packed light value per vertex:
- simplest: per-face/per-vertex light = sample from the adjacent voxel
- For each quad vertex, sample light from the block “in front” of the face.

Shader:
- `brightness = light / 15.0`
- `color = textureColor * (ambient + brightness * directionalFactor)`

### 10.2 Day/Night Integration
Do NOT recompute skylight values each timeOfDay.
Instead:
- Skylight values represent “full sun” exposure (0..15).
- Apply time-of-day as a global multiplier:
  - `skyFactor = sunIntensity(timeOfDay)`
  - final brightness uses:
    - `skyLight * skyFactor` (scaled)
    - blockLight unaffected (or slightly affected by exposure)
This gives:
- Day: bright outdoors
- Night: outdoors dim, but torches still bright

### 10.3 Ambient Light
At night, avoid fully black outdoors:
- `ambient = lerp(nightAmbient, dayAmbient, sunIntensity)`
Example:
- nightAmbient: 0.05..0.12
- dayAmbient: 0.20..0.35

---

## 11) Smooth Lighting (Optional v1, Recommended)

“Minecraft-style” smooth lighting uses neighbor samples to create gradients across faces.

Simpler approach:
- Per-vertex brightness = average of 4 nearby voxels adjacent to that vertex.
- Works well with greedy meshing.

If you do this, merging faces must ensure the corner samples remain valid.

---

## 12) Moonlight (Optional v1)

Two approaches:

### 12.1 Simple
- Moon only affects sky color
- World lighting at night is ambient + block lights
(v1 acceptable)

### 12.2 Better
- Add `moonFactor` as part of `skyFactor` at night:
  - `skyFactor = max(sunIntensity, moonIntensity * moonScale)`
- `moonScale` small (e.g. 0.10..0.25)

---

## 13) Required Debug Tools

- Toggle: show skylight as colors
- Toggle: show block light as colors
- Show current `timeOfDay`, `sunIntensity`, `moonIntensity`
- Force time presets: midnight/noon/sunrise/sunset
- Visualize light BFS queue sizes (optional)

---

## 14) Implementation Order

1. World time + sun/moon direction + sky shader
2. Fog matching time-of-day
3. Light storage per voxel (packed)
4. Skylight vertical pass per chunk
5. Block light BFS (add only)
6. Incremental light updates (remove+add)
7. Cross-chunk lighting propagation
8. Per-vertex light sampling and shader application
9. Optional smooth lighting

---

## 15) Acceptance Criteria

- Sun rises/sets; moon visible at night.
- Sky colors and fog shift naturally through the day.
- Outdoor areas brighten/dim with time-of-day without re-lighting the world.
- Caves are dark unless opened to the surface or lit by torches.
- Placing a torch lights nearby blocks smoothly.
- Lighting does not “leak” through solid terrain across chunk borders.
- Lighting updates are incremental (no full world rebuild).

---

