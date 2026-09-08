# Restored Discovery Audit

Restoring module test discovery exposed nine failing test blocks: 182/191
passed before these corrections. None of the corrections retunes terrain,
climate noise, biome ranges, priorities, surfaces, or the Voronoi algorithm.
The sole production change is a separate water-coverage reporting metric.
All original tests remain; the coastal transition fixture now exercises edge
injection rather than expecting an edge-only biome from natural selection.

## Failure Causes

1. **Low ridge mask:** `50728aec` (#679) deliberately changed ordinary mountains'
   minimum ridge mask from `0.1` to `0.0`. Test rejection on `jagged_peaks`, which
   still requires a ridge, immediately below and exactly at its minimum. Also
   protect ridge-free ordinary mountains with an accepted zero-mask sample.
2. **Baseline wet biome:** `a408e2d3` (#671) changed constrained selection from
   heat/humidity Voronoi points to the authoritative biome definitions. The old
   swamp point accepted continentalness `0.45`; the current definition requires
   at least `0.48`. Move the wet fixture inland to `0.6`, retaining expected
   `swamp`. The same test also contained an unreachable `coastal_plains` natural
   selection expectation: that definition is explicitly edge-injection-only.
   Preserve its original inputs in the transition test and call
   `BiomeSource.selectBiomeWithEdge`, checking both edge and no-edge behavior.
3. **Structural swamp edge:** The same invalid `0.45` fixture meant even the
   supposed positive control was structurally ineligible. Use `0.6`, accept the
   maximum allowed slope, reject one block steeper, and retain `0.45` as a
   negative control for the inland constraint.
4. **Coast boundary:** #679 moved the ocean boundary from `0.35` to `0.37`;
   `3fc9502b` (#681) narrowed beaches to continentalness `0.37..0.41` and height
   at most `68`. Exercise the current named bounds, including ocean immediately
   below the beach, both beach endpoints, inland immediately beyond it, and
   slope/height exclusion. Inland water remains a non-beach control.
5. **Migrated Voronoi point:** `85d4f517` (#674) defines elevation centers at
   explicit sites or structural height limits, not necessarily range midpoints.
   The fixture sampled snowy mountains at height `184`, although its site is
   at `112`. Convert each point's actual elevation center back to block height,
   check eligibility, and require every point to select its own biome.
6. **Inland-high zone:** #679 moved the exclusive upper bound from `0.75` to
   `0.72`. Exercise the current lower/upper bounds and their immediate outside
   values instead of treating `0.72` as inland-high. The exact upper bound must
   enter `mountain_core`.
7. **Coastal filler:** #681 deliberately reduced the minimum coastal layer from
   six blocks to three, including the surface, and limited structural beaches
   to three blocks above sea level. The old fixture forced a beach at height
   `70` and expected sand five blocks below it. Obtain a real beach classification
   at height `67`; check all layers for filler depths `1`, `3`, and `5`, the first
   stone beneath them, and preservation of air, water, bedrock, and non-beach dirt.
8. **Shallow ocean floor:** #681 narrowed sand from water depth `<=12` to `<=5`;
   the old depth-nine fixture is medium-depth clay by design. Check sand at
   depths one and five, its filler extent, clay at six and thirty, and gravel
   at thirty-one. No surface rule changes are needed.
9. **Representative spawn regions:** #681 deliberately lowered the broad
   continental lowland base to `sea + 2.5` and introduced blended terrain
   modifiers. The test conflated dry sea-level ground with water and demanded
   climate-scale diversity from five origin-centered `256x256` windows. In the
   original fixture, seed 42 has `0.305557` at-or-below-sea-level coverage; all
   five windows contain zero dry-biome and mountain samples. That locality is
   smaller than the configured 900-block continental and 1400-block macro-climate
   spreads. Seeded Perlin fields also share zero noise at the origin, so changing
   seeds does not make this small origin sample a broad climate survey.

## Report Semantics

`sea_level_coverage` retains its existing meaning: integer surface height at or
below sea level. New `water_coverage` counts surface heights strictly below sea
level, where surface placement has room for water above the terrain. A surface
at sea level is solid, dry ground, including sea-level-clamped wetlands.

The new regression compares both report metrics to real `SurfaceBuilder`
placement over the original seed-42 region, requires wet and dry sea-level
columns to be present, and verifies the formatted report distinguishes them.

The representative-seed test retains all five seeds and all numerical limits:

- Local `256x256` origin regions: ocean `<=0.30`, water `<=0.30`, mountain `<=0.12`.
- Diversity survey: ocean `>=0.03`, forest `>=0.08`, wetlands `>=0.005`, dry biomes
  `>=0.003`, mountains `>=0.002` across the same 327,680 survey samples.

The diversity fixture samples a fixed `2048x2048` square from `(-1024,-1024)` at
eight-block intervals with reduction zero. It uses the existing climate capture
for full-detail columns, then reselects through `BiomeSource` using actual
one-block neighbor slopes. It does not use the snapshot's flat-slope assumption
or differences between distant survey points. No seed-specific coordinate search,
adaptive retries, expectation snapshots, or reduced thresholds are used.

These are deterministic column/report tests, not a rendered-world or complete
chunk-decoration verification.
