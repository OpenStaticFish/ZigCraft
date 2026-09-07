#!/usr/bin/env bash
# Scoped local reference or full-horizon service evidence, always qualified=0.
# Run from the repository root. Compare off/on at the same camera and seed.
# ZIGCRAFT_LOD_FIDELITY_HORIZON_CHUNKS: 64..512 selects service; absent/invalid
# (including out of range) uses the unchanged local 24-chunk profile.
# ZIGCRAFT_LOD_FIDELITY_MEMORY_MB: absent defaults to local=1024/service=256 MiB.
# Explicit values retain the runtime parser: clamp 64..4096, invalid uses 1024.
# ZIGCRAFT_LOD_FIDELITY_REFERENCE=1 selects full detail at the same final camera,
# radius 12, local horizon 384 blocks. It is NOT the LOD acceptance bar.
set -euo pipefail

if [[ $# != 1 || ( "$1" != off && "$1" != on ) ]]; then
    echo "Usage: bash scripts/run_lod_fidelity_capture.sh <off|on>" >&2
    exit 2
fi

near_source=$1
reference=${ZIGCRAFT_LOD_FIDELITY_REFERENCE-0}
[[ "$reference" == 1 ]] || reference=0
requested_horizon_chunks=${ZIGCRAFT_LOD_FIDELITY_HORIZON_CHUNKS-unset}
caller_horizon_chunks=$requested_horizon_chunks
requested_memory_mb=${ZIGCRAFT_LOD_FIDELITY_MEMORY_MB-unset}

# Match std.fmt.parseInt(u32, ..., 10), without shell arithmetic overflow or
# interpreting a leading zero as octal. Underscores and leading + are accepted.
parse_u32_decimal() {
    local digits=$1 negative=0
    [[ "$digits" =~ ^[+-]?[0-9]([0-9_]*[0-9])?$ ]] || return 1
    [[ "$digits" != -* ]] || negative=1
    digits=${digits#[+-]}
    digits=${digits//_/}
    digits=${digits#"${digits%%[!0]*}"}
    digits=${digits:-0}
    (( ${#digits} <= 10 )) || return 1
    parsed_u32=$((10#$digits))
    (( parsed_u32 <= 4294967295 && (negative == 0 || parsed_u32 == 0) ))
}

requested_scope=local
[[ ${ZIGCRAFT_LOD_FIDELITY_HORIZON_CHUNKS+x} ]] && requested_scope=service
scope=local
horizon_chunks=24
active_lod_count=3
local_reference=1
radii_chunks=6,16,24,24,24
source_density=1.00,1.00,0.25,0.50,0.50
expected_memory_mb=1024
detail_radius_chunks=6
if parse_u32_decimal "$requested_horizon_chunks" && (( parsed_u32 >= 64 && parsed_u32 <= 512 )); then
    scope=service
    horizon_chunks=$parsed_u32
    active_lod_count=5
    local_reference=0
    radii_chunks="6,16,64,$((horizon_chunks < 128 ? horizon_chunks : 128)),$horizon_chunks"
    source_density=1.00,1.00,0.25,0.25,0.50
    expected_memory_mb=256
fi
if [[ "$reference" == 1 ]]; then
    scope=full_reference
    requested_scope=full_reference
    requested_horizon_chunks=unset
    horizon_chunks=24
    active_lod_count=3
    local_reference=1
    detail_radius_chunks=12
    radii_chunks=12,16,24,24,24
    source_density=1.00,1.00,0.25,0.50,0.50
    expected_memory_mb=1024
fi
if [[ ${ZIGCRAFT_LOD_FIDELITY_MEMORY_MB+x} ]]; then
    expected_memory_mb=1024
    if parse_u32_decimal "$requested_memory_mb"; then
        expected_memory_mb=$((parsed_u32 < 64 ? 64 : parsed_u32 > 4096 ? 4096 : parsed_u32))
    fi
fi
capture_horizon=$((horizon_chunks * 16))
# The engine's boolean environment parser accepts "0", not "off", as false.
near_source_flag=0
canonical_enabled=false
if [[ "$near_source" == on ]]; then
    near_source_flag=1
    canonical_enabled=true
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="screenshots/lod-fidelity/run-$run_id-$near_source-$scope"
mkdir -p "$run_dir"
output="$run_dir/lod-forest.png"
capture_log="$run_dir/lod-forest.log"

echo "LOD fidelity: run=$run_id scene=lod-forest canonical=$near_source_flag reference=$reference near_source=$near_source near_source_flag=$near_source_flag compact=off preset=low auto_world=normal seed=12345 noon=0.5 initial=896,84,-1152 final=1024,106,-1024 retreat_frames=180 target_lod1=14,-18 requested_scope=$requested_scope scope=$scope local_reference=$local_reference caller_horizon_chunks=$caller_horizon_chunks requested_horizon_chunks=$requested_horizon_chunks horizon_chunks=$horizon_chunks capture_horizon=$capture_horizon radii_chunks=$radii_chunks source_density=$source_density detail_radius_chunks=$detail_radius_chunks active_lod_count=$active_lod_count requested_memory_budget_mb=$requested_memory_mb expected_memory_budget_mb=$expected_memory_mb qualified=0" | tee "$capture_log"
# Preserve HOME and the caller's display/driver environment. Disable inherited
# persistence so this is natural generation, never a modified saved world.
# The outer budget includes devenv setup; the inner budget bounds build/run.
env -u ZIGCRAFT_SAVE_DIR -u ZIGCRAFT_SMOKE_FRAMES -u ZIGCRAFT_CHUNK_DEBUG_MODE -u ZIGCRAFT_CHUNK_DEBUG_ENABLE \
    ZIGCRAFT_LOD_CANONICAL="$near_source_flag" \
    ZIGCRAFT_LOD_FIDELITY_REFERENCE="$reference" \
    ZIGCRAFT_LOD_NEAR_SOURCE="$near_source_flag" \
    ZIGCRAFT_ENABLE_GPU_CULLING=0 \
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
runtime_config=$(grep -Em1 "LOD_FIDELITY_CONFIG: run=$run_id scene=lod-forest " "$capture_log")
for field in "scope=$scope" "requested_scope=$requested_scope" "local_reference=$local_reference" "qualified=0" \
    "requested_horizon_chunks=$requested_horizon_chunks" "horizon_policy=64..512_else24" \
    "capture_horizon=$capture_horizon" "horizon_chunks=$horizon_chunks" "detail_radius_chunks=$detail_radius_chunks" \
    "source_density=$source_density" "active_lod_count=$active_lod_count" \
    "requested_memory_budget_mb=$requested_memory_mb" "seed=12345" "auto_world=normal" "reference=$reference" "canonical=$near_source_flag"; do
    [[ "$runtime_config" == *" $field "* ]] || { echo "Runtime config mismatch: $field" >&2; exit 1; }
done
[[ "$runtime_config" == *" near_source=$near_source_flag" ]]
[[ "${runtime_config// /}" == *"radii_chunks={$radii_chunks}"* ]]
[[ "$runtime_config" =~ \ memory_budget_mb=([0-9]+)\  ]]
actual_memory_mb=${BASH_REMATCH[1]}
(( actual_memory_mb == expected_memory_mb ))
grep -Eq "LOD_FIDELITY_RESIDENCY: run=$run_id scene=lod-forest scope=$scope .* memory_budget_mb=$actual_memory_mb " "$capture_log"
grep -Eq "LOD_FIDELITY_WARMUP: run=$run_id scene=lod-forest .* completed=1 " "$capture_log"
grep -Eq "LOD_FIDELITY_MOTION: run=$run_id scene=lod-forest .* frame=180 target_frames=180 completed=1 " "$capture_log"
# Canonical manager disables the duplicate legacy branch even when its input
# flag matches on. Off explicitly disables both sources.
grep -Eq "LOD_FIDELITY_READINESS: run=$run_id scene=lod-forest scope=$scope .* ready=1 .* near_enabled=false " "$capture_log"
grep -Eq "LOD_CANONICAL_TARGET: run=$run_id scene=lod-forest canonical_enabled=$canonical_enabled " "$capture_log"
if [[ "$reference" == 1 ]]; then
    grep -Eq "LOD_FIDELITY_REFERENCE: run=$run_id scope=full_reference qualified=0 ready=1 target_ready=16 target_visible=16 required_chunks=16 .* chunks_rendered=[1-9][0-9]* vertices_rendered=[1-9][0-9]* projection_current=true canonical_enabled=$canonical_enabled lod_target_draw_required=0" "$capture_log"
    grep -Eq "LOD_FIDELITY_READY: run=$run_id scene=lod-forest scope=full_reference .* stable_frames=180 player=1024.0,106.0,-1024.0 .* lod_target_draw_required=0" "$capture_log"
else
    grep -Eq "LOD_FIDELITY_READY: run=$run_id scene=lod-forest scope=$scope .* qualified=0 .* stable_frames=180 player=1024.0,106.0,-1024.0 .* target_lod=1 target=14,-18 drawn=1 leaves=[1-9][0-9]* .* lod_target_draw_required=1" "$capture_log"
    if [[ "$near_source" == on ]]; then
        grep -Eq "LOD_CANONICAL_TARGET: run=$run_id scene=lod-forest canonical_enabled=true .* grid_complete=true source_epoch=[1-9][0-9]* .* source_current=true mesh_ready=true projected=true drawn=true " "$capture_log"
    fi
fi
if [[ "$scope" == service ]]; then
    grep -Eq "LOD_FIDELITY_SERVICE: run=$run_id scene=lod-forest scope=service qualified=0 .* overlap_seen=1 .* backlog_scope=resident_maps scheduling_evidence=bounded_opportunities ms_guarantee=0" "$capture_log"
    grep -Eq "LOD_FIDELITY_TARGET_DRAW: run=$run_id scene=lod-forest scope=service qualified=0 target_lod=1 target=14,-18 first_current_draw_tick=[0-9]+ " "$capture_log"
    grep -Eq "LOD_FIDELITY_READY: run=$run_id scene=lod-forest scope=service overlap_seen=1 " "$capture_log"
fi
echo "LOD fidelity effective: requested_scope=$requested_scope scope=$scope requested_horizon_chunks=$requested_horizon_chunks actual_horizon_chunks=$horizon_chunks requested_memory_budget_mb=$requested_memory_mb actual_memory_budget_mb=$actual_memory_mb qualified=0" | tee -a "$capture_log"
echo "Capture evidence: $output (scope=$scope; reference=$reference; full_reference is not LOD-qualified; no full-horizon or millisecond/performance qualification)"
