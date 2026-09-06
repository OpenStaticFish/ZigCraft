#!/usr/bin/env bash
# M1 local visual reference only, not full-horizon/performance qualification.
# Run from the repository root. Compare off/on at the same camera and seed.
set -euo pipefail

if [[ $# != 1 || ( "$1" != off && "$1" != on ) ]]; then
    echo "Usage: bash scripts/run_lod_fidelity_capture.sh <off|on>" >&2
    exit 2
fi

near_source=$1
# The engine's boolean environment parser accepts "0", not "off", as false.
near_source_flag=0
near_source_enabled=false
if [[ "$near_source" == on ]]; then
    near_source_flag=1
    near_source_enabled=true
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="screenshots/lod-fidelity/run-$run_id-$near_source"
mkdir -p "$run_dir"
output="$run_dir/lod-forest.png"
capture_log="$run_dir/lod-forest.log"

echo "LOD fidelity: run=$run_id scene=lod-forest near_source=$near_source near_source_flag=$near_source_flag compact=off preset=low auto_world=normal seed=12345 initial=896,84,-1152 final=1024,106,-1024 retreat_frames=180 target_lod1=14,-18 local_reference=1 capture_horizon=384 radii_chunks=6,16,24,24,24 density=1,1,0.25 detail_radius_chunks=6 active_lod_count=3 memory_budget_mb=1024 qualified=0" | tee "$capture_log"
# Preserve HOME and the caller's display/driver environment. Disable inherited
# persistence so this is natural generation, never a modified saved world.
# The outer budget includes devenv setup; the inner budget bounds build/run.
env -u ZIGCRAFT_SAVE_DIR -u ZIGCRAFT_SMOKE_FRAMES -u ZIGCRAFT_CHUNK_DEBUG_MODE -u ZIGCRAFT_CHUNK_DEBUG_ENABLE \
    ZIGCRAFT_LOD_NEAR_SOURCE="$near_source_flag" \
    ZIGCRAFT_LOD_COMPACT=off \
    ZIGCRAFT_LOD_PROFILE=1 \
    ZIGCRAFT_LOD_DIAG=1 \
    ZIGCRAFT_LOG_CONSOLE=1 \
    ZIGCRAFT_LOD_GPU_CULLING=0 \
    ZIGCRAFT_LOD_GPU_CULLING_VALIDATE=0 \
    ZIGCRAFT_PHASE5_SETTLE_FRAMES=180 \
    timeout --kill-after=10s 600s devenv shell --profile graphics -- \
    timeout --kill-after=10s 240s zig build run \
    -Doptimize=ReleaseFast \
    -Dskip-present \
    -Dauto-preset=low \
    -Dauto-world=normal \
    -Dchunk-debug-mode=false \
    -Dchunk-debug-enable= \
    -Dphase5-visual-scene=lod-forest \
    -Dphase5-visual-run-id="$run_id" \
    -Dscreenshot-path="$output" \
    -Dscreenshot-frame=900 \
    -Dscreenshot-delay-seconds=5 2>&1 | tee -a "$capture_log"

test -s "$output"
if grep -Eq 'Vulkan validation error:|\[ERROR\]' "$capture_log"; then
    echo "Capture contains runtime errors; inspect $capture_log" >&2
    exit 1
fi
grep -Eq "LOD_FIDELITY_CONFIG: run=$run_id scene=lod-forest local_reference=1 qualified=0 capture_horizon=384 " "$capture_log"
grep -Eq "LOD_FIDELITY_WARMUP: run=$run_id scene=lod-forest .* completed=1 " "$capture_log"
grep -Eq "LOD_FIDELITY_MOTION: run=$run_id scene=lod-forest .* frame=180 target_frames=180 completed=1 " "$capture_log"
grep -Eq "LOD_FIDELITY_READINESS: run=$run_id scene=lod-forest .* ready=1 .* near_enabled=$near_source_enabled " "$capture_log"
grep -Eq "LOD_FIDELITY_READY: run=$run_id scene=lod-forest .* leaves=[1-9][0-9]* " "$capture_log"
echo "Capture evidence: $output (M1 local reference only, not full-horizon/performance qualification; inspect natural foliage and near-LOD fidelity)"
