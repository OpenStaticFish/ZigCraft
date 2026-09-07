# Worldgen Biomes And Terrain

This document describes the current Overworld biome and terrain-shaping pipeline. Use it when tuning terrain, adding biomes, or reviewing worldgen changes.

## Key Files

- `modules/world-worldgen/src/terrain_shape_generator.zig`: per-column orchestration, chunk phase data, biome-aware terrain resampling, slopes, caves, surfaces, and decoration inputs.
- `modules/world-worldgen/src/noise_sampler.zig`: raw climate, terrain, continentalness, erosion, river, ridge, and detail noise sampling.
- `modules/world-worldgen/src/height_sampler.zig`: structure-first height calculation from sampled noise, region controls, path influence, and optional biome terrain modifiers.
- `modules/world-worldgen/src/biome_source.zig`: unified selector interface used by the terrain generator.
- `modules/world-worldgen/src/biome_selector.zig`: climate and structural biome selection, river overrides, blending helpers, and simplified LOD selection.
- `modules/world-worldgen/src/biome_registry.zig`: biome IDs, biome points, climate ranges, structural constraints, priority, surface blocks, vegetation, colors, and `TerrainModifier` data.
- `modules/world-worldgen/src/region.zig`: region roles, moods, feature focus, blended region controls, and movement path influence.
- `modules/world-worldgen/src/surface_builder.zig`: block placement for terrain surfaces, underwater surfaces, shorelines, and transitions.
- `modules/world-worldgen/src/decoration_provider.zig`, `biome_decorator.zig`, and `decoration_registry.zig`: biome and region constrained decorations.
- `modules/world-worldgen/src/terrain_report.zig` and `climate_snapshot.zig`: deterministic reporting and baselines for worldgen changes.

## Important Data Structures

- `TerrainShapeGenerator.Params`: top-level terrain knobs such as `sea_level`, `ocean_threshold`, ridge inland range, ridge sparsity, and cave disabling.
- `TerrainShapeGenerator.ColumnData`: sampled per-column terrain height, continentalness, erosion, river mask, climate, ridge mask, ocean flags, and cave region value.
- `TerrainShapeGenerator.ChunkPhaseData`: chunk-local arrays for heights, primary/secondary biome IDs, blend factors, slopes, river masks, ridge masks, temperatures, humidities, cave values, and coastal surface types.
- `HeightSampler.HeightParams`: continental zone thresholds, mountain/ridge amplitudes, highland detail range, and peak compression controls.
- `biome_registry.BiomeDefinition`: the authoritative biome definition: climate ranges, structural limits, priority, surface blocks, vegetation, terrain modifiers, and colors.
- `biome_registry.BiomePoint`: Voronoi-style center points used by compatibility and multi-parameter selection paths.
- `biome_registry.ClimateParams`: normalized temperature, humidity, elevation, continentalness, ruggedness, and ridge mask values.
- `biome_registry.StructuralParams`: absolute height, slope, continentalness, and ridge mask used as hard selection constraints.
- `region.RegionInfo`: region `role`, `mood`, feature `focus`, and region center.
- `region.RegionControls`: blended terrain controls: `height_mult`, `vegetation_mult`, `drama_mask`, `river_mask`, and `subbiome_mask`.

## Column Pipeline

`TerrainShapeGenerator.sampleColumnData` is the light-weight entry point for a world position. Chunk generation uses the same concepts through `prepareChunkPhaseData`.

The column pipeline is:

1. Sample raw noise through `NoiseSampler.sampleColumn`.
2. Apply coast jitter to continentalness so coastlines are not grid-straight.
3. Sample river mask, region, path information, and ridge mask.
4. Compute a base terrain height with `HeightSampler.computeHeightWithTerrainModifier` and no biome modifier.
5. Select a preliminary biome from that base column.
6. Recompute the height with the preliminary biome's `BiomeDefinition.terrain` modifier.
7. Apply altitude temperature lapse from the final height.
8. Return `ColumnData` for biome selection, surface building, decoration, reporting, and LOD consumers.

Chunk generation then computes neighbor slopes from the first pass of heights, reselects biomes with those slopes, applies wetland terrain modifiers, updates slopes again, and uses the final biome and terrain arrays for block placement and decorations.

## Height And Modifier Order

`HeightSampler.computeHeightWithTerrainModifier` is structure-first. The ordering matters because earlier stages establish broad land/ocean structure and later stages add local detail.

1. **Hard ocean decision**: if continentalness is below `HeightParams.ocean_threshold`, return ocean floor height immediately. Land, mountain, detail, biome, and river logic do not run for that column.
2. **Path system**: `region.PathInfo` produces path depth and slope suppression for valleys, rivers, and plains corridors.
3. **V7 terrain blend**: blend `terrain_base` and `terrain_alt` with `height_select`, scaled by `RegionControls.height_mult`.
4. **Continental land base**: add the continental base height from coast, inland low, inland high, or mountain core zones. Apply coastal ramp and path depth.
5. **Mountains and ridges**: only apply when `RegionControls.drama_mask` allows it and continentalness is inland enough.
6. **Fine detail**: add detail noise attenuated by erosion, land factor, coastal ramp, elevation, path slope suppression, and region height multiplier.
7. **Biome terrain modifier**: if provided, apply `TerrainModifier.applyHeight` before peak compression. The modifier applies `height_amplitude`, then `smoothing` toward sea level, then optional `clamp_to_sea_level`, then `height_offset`.
8. **Peak compression**: compress very high peaks through `compressPeakHeight`.
9. **River carving**: if region controls and river noise allow it, lerp down toward the river bed after biome shaping and peak compression.

Wetland biomes (`swamp`, `mangrove_swamp`, and `marsh`) also receive a chunk-phase adjustment in `TerrainShapeGenerator.applyWetlandTerrainModifiers`. Keep that second pass in mind when tuning low, flat biomes.

## Biome Selection

Runtime terrain uses `BiomeSource.selectBiome`, which delegates to `biome_selector.selectBiomeWithConstraintsAndRiver`.

Selection uses both climate and structure:

- `BiomeSource.computeClimate` normalizes temperature, humidity, elevation, continentalness, and ruggedness. Ruggedness is `1.0 - erosion`.
- `StructuralParams` adds absolute terrain height, local slope, continentalness, and ridge mask.
- `BiomeDefinition.meetsStructuralConstraints` is a hard filter for `min_height`, `max_height`, `max_slope`, `continentalness`, and ridge mask.
- `BiomeDefinition.scoreClimate` requires all climate ranges to contain the sampled values, then scores by average normalized distance from each range center.
- `BiomeDefinition.priority` is added as `priority * 0.01`, so priority is a tie-breaker or intentional override among otherwise valid candidates. Avoid using priority to force a biome across incompatible climate or structure; adjust ranges or structural constraints first.
- Ocean biomes are additionally guarded by ocean structure checks so land columns do not become ocean biomes only because the climate score is close.
- River override runs before normal selection when river masks are strong enough. Cold river columns become `frozen_river`; other active river columns become `river`.

There are also compatibility and utility selectors in `biome_selector.zig`:

- `selectBiomeVoronoiMultiParam` compares heat, humidity, elevation, continentalness, ruggedness, and ridge mask against `BIOME_POINTS` after height, slope, and continentalness filters.
- Blended selectors return primary/secondary biome IDs and a blend factor for transition-aware callers.

## Region Roles

Regions are large composition cells from `region.zig`. Role, mood, and feature focus shape the terrain before biome-specific surfaces and decorations are applied.

- `transit`: intentionally flatter and quieter. Height multiplier is low, vegetation is sparse, height drama is disabled, rivers/sub-biomes are disabled, and plains corridors may influence paths.
- `destination`: focused points of interest. Lake focus suppresses height and permits lakes, forest focus increases vegetation and permits sub-biomes, mountain focus permits height drama and emphasizes mountain terrain.
- `boundary`: separation space. Height drama is allowed at medium intensity, vegetation is very low, and rivers/sub-biomes are disabled.

`getBlendedControls` smooths role controls across neighboring region cells, so a column may inherit partial influence from nearby regions. Terrain, biome selection, and decorations should use the blended controls where available instead of assuming the nearest `RegionInfo` is absolute.

The region layer affects systems differently:

- Terrain height uses `height_mult`, `drama_mask`, `river_mask`, and movement paths in `HeightSampler`.
- Biome eligibility is still determined by climate and structural constraints, but region-shaped height, slope, rivers, and ridges feed those constraints.
- Decorations use vegetation/sub-biome controls so sparse regions stay sparse even when the biome normally supports dense vegetation.

## Adding Or Tuning A Biome Safely

Use the smallest data change that expresses the intended biome. Most new biomes should be registry changes plus targeted tests.

1. Add or confirm the `BiomeId` in `modules/world-core/src/block.zig` if the biome is new.
2. Add a `BiomeDefinition` in `modules/world-worldgen/src/biome_registry.zig` with tight temperature, humidity, elevation, continentalness, ruggedness, and ridge ranges.
3. Set structural constraints (`min_height`, `max_height`, `max_slope`, ridge limits) before increasing `priority`.
4. Add or tune a `BiomePoint` only if a Voronoi or compatibility path needs the biome to appear there.
5. Configure `surface` blocks and `vegetation` rules in the registry. Add decoration rules in `decoration_registry.zig` only when existing rules cannot express the biome.
6. Add a `TerrainModifier` only when the biome must shape height, such as wetlands or deliberately smoothed terrain. Prefer small amplitude, smoothing, or offset changes over broad priority overrides.
7. Check interactions with region roles. A destination forest can make vegetation denser, but transit and boundary roles may still intentionally suppress it.
8. Add or update focused tests in `biome_registry_tests.zig`, `biome_selector_tests.zig`, `height_sampler_tests.zig`, `terrain_modifier_tests.zig`, or `terrain_shape_generator_tests.zig` depending on what changed.
9. Regenerate or inspect deterministic baselines when distribution changes are intentional.

Avoid broad range overlaps unless the priority behavior is intentional and covered by a test. If a biome should only appear in narrow terrain, constrain structure first and climate second.

## Required Verification For Worldgen Changes

For documentation-only changes, no Zig formatting is required. For code or data changes, run formatting on changed Zig files and at least the unit suite:

```bash
devenv shell zig fmt <changed-zig-files>
devenv shell zig build test
```

For biome or terrain distribution changes, also compare deterministic reports and snapshots:

```bash
devenv shell zig build worldgen-report
devenv shell zig build worldgen-climate-snapshot
```

Use the output from `terrain_report.zig` to inspect representative seed biome counts, height ranges, ocean/land ratio, mountain coverage, and role effect profiles. Use the climate snapshot when climate-space selection boundaries or biome scoring changed. Include intentional baseline changes in the PR description so reviewers know whether distribution movement is expected.
