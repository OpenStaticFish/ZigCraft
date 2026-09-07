#!/usr/bin/env bash
# Run from the repository root. Never uses an inherited save or a user world.
# Intact and summary-cache-loss reloads exercise canonical expanded meshes,
# NOT the existing Phase 5 saved-world compact qualification.
set -euo pipefail

canonical_target_line_ready() {
    local line=$1 token
    local -A fields=()
    for token in $line; do
        if [[ "$token" == *=* ]]; then
            [[ -n "${token%%=*}" && ! -v 'fields[${token%%=*}]' ]] || return 1
            fields[${token%%=*}]=${token#*=}
        fi
    done
    [[ ${fields[canonical_enabled]-} == true && ${fields[grid_complete]-} == true &&
       ${fields[grid_known_area]-} == 4096 && ${fields[grid_total_area]-} == 4096 &&
       ${fields[source_epoch]-} =~ ^[1-9][0-9]*$ &&
       ${fields[source_current]-} == true && ${fields[mesh_ready]-} == true &&
       ${fields[projected]-} == true && ${fields[drawn]-} == true &&
       ${fields[saved_features]-} == 9 ]]
}

if [[ ${1-} == --self-test && $# == 1 ]]; then
    # Counts from an evicted cache are deliberately skeptical: zero resident
    # observations do not invalidate a complete, current owned scene grid.
    valid='canonical_enabled=true cached_known=0 target_cached_known=0 grid_known_area=4096 grid_total_area=4096 grid_complete=true source_epoch=17 hierarchy_epoch=23 refresh_pending=true source_current=true mesh_ready=true projected=true drawn=true saved_features=9'
    canonical_target_line_ready "$valid"
    for bad in "${valid/grid_known_area=4096/grid_known_area=4095}" \
        "${valid/source_epoch=17/source_epoch=0}" "${valid/source_current=true/source_current=false}" \
        "${valid/saved_features=9/saved_features=8}" "${valid/drawn=true/drawn=false}" \
        "${valid/grid_complete=true/grid_complete=false}" "$valid saved_features=9" "$valid =bad" \
        "cached_known=200 target_cached_known=16"; do
        if canonical_target_line_ready "$bad"; then
            echo "Canonical saved parser accepted incomplete evidence: $bad" >&2
            exit 1
        fi
    done
    echo 'Canonical saved evidence parser: passed'
    python3 -B scripts/test_canonical_saved_capture.py
    exit 0
fi

mode=${1-both}
if [[ $# -gt 1 || ( "$mode" != both && "$mode" != intact && "$mode" != repair ) ]]; then
    echo 'Usage: bash scripts/run_canonical_saved_capture.sh [intact|repair|both|--self-test]' >&2
    exit 2
fi
test -f modules/game-core/src/session.zig
mkdir -p screenshots/canonical-saved
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir=$(mktemp -d "screenshots/canonical-saved/run-$run_id-XXXXXX")
save_dir="$run_dir/save"
mkdir "$save_dir"
stage=create
report_failure() {
    local status=$?
    if (( status != 0 )); then
        echo "CANONICAL_SAVED_FAILURE: run=$run_id stage=$stage status=$status evidence=$run_dir" | tee -a "$run_dir/metadata.log" >&2
    fi
}
trap report_failure EXIT
echo "CANONICAL_SAVED_RUN: run=$run_id mode=$mode save=$save_dir isolated=1 canonical=1 compact=off scope=saved_source qualified=0 seed=12345 auto_world=flat noon=0.5 reload_camera=160,106,160 detail_radius_chunks=6 horizon_blocks=384 origin_warmup=engine_only source_warmup_visit=0 preservation=all_original_chunk_blocks lighting_changes_allowed=1 new_chunks_allowed=1" | tee "$run_dir/metadata.log"

capture() {
    local scene=$1 label=$2 capture_id="$run_id-$2"
    env -u ZIGCRAFT_SMOKE_FRAMES -u ZIGCRAFT_CHUNK_DEBUG_MODE -u ZIGCRAFT_CHUNK_DEBUG_ENABLE \
        -u ZIGCRAFT_LOD_FIDELITY_HORIZON_CHUNKS -u ZIGCRAFT_LOD_FIDELITY_MEMORY_MB \
        ZIGCRAFT_SAVE_DIR="$save_dir" ZIGCRAFT_LOD_CANONICAL=1 ZIGCRAFT_LOD_NEAR_SOURCE=1 \
        ZIGCRAFT_LOD_FIDELITY_REFERENCE=0 ZIGCRAFT_LOD_COMPACT=off \
        ZIGCRAFT_LOD_PROFILE=1 ZIGCRAFT_LOD_DIAG=1 ZIGCRAFT_LOG_CONSOLE=1 \
        ZIGCRAFT_ENABLE_GPU_CULLING=0 ZIGCRAFT_LOD_GPU_CULLING=0 ZIGCRAFT_LOD_GPU_CULLING_VALIDATE=0 \
        ZIGCRAFT_PHASE5_SETTLE_FRAMES=180 \
        timeout --kill-after=10s 600s devenv shell --profile graphics -- \
        timeout --kill-after=10s 240s zig build run -Doptimize=ReleaseFast \
        -Dskip-present -Dauto-preset=low -Dauto-world=flat \
        -Dchunk-debug-mode=false -Dchunk-debug-enable= \
        -Dphase5-visual-scene="$scene" -Dphase5-visual-run-id="$capture_id" \
        -Dscreenshot-path="$run_dir/$label.png" -Dscreenshot-frame=900 \
        -Dscreenshot-delay-seconds=5 2>&1 | tee "$run_dir/$label.log"
    test -s "$run_dir/$label.png"
    if grep -Eq 'Vulkan validation error:|\[ERROR\]' "$run_dir/$label.log"; then
        echo "Runtime errors in $run_dir/$label.log" >&2
        return 1
    fi
    local accepted=0 line
    while IFS= read -r line; do
        if [[ "$line" == "LOD_CANONICAL_TARGET: run=$capture_id scene=$scene "* ]] && canonical_target_line_ready "$line"; then accepted=1; fi
    done < "$run_dir/$label.log"
    (( accepted == 1 ))
    if [[ "$scene" == canonical-save-reload ]]; then
        grep -Eq "^CANONICAL_SAVED_READINESS: run=$capture_id scene=$scene scope=saved_source qualified=0 ready=1 stable_frames=180 required_frames=180 target=0,0 target_lod=1 target_source_resident=0 required_nonresident=1 saved_features=9 canonical_enabled=true mesh_ready=true source_current=true projected=true drawn=true chunks_rendered=[1-9][0-9]* player=160\\.0,106\\.0,160\\.0 warmup_visit=0 compact_qualification=0$" "$run_dir/$label.log"
        grep -Fxq "CANONICAL_SAVED_READY: run=$capture_id scene=$scene scope=saved_source qualified=0 stable_frames=180 reload=1 target_source_resident=0 saved_features=9 compact_qualification=0" "$run_dir/$label.log"
    else
        grep -Eq "^CANONICAL_SAVED_READINESS: run=$capture_id scene=$scene scope=saved_source qualified=0 ready=1 stable_frames=180 required_frames=180 target=0,0 target_lod=1 target_source_resident=[0-9]+ required_nonresident=0 saved_features=9 canonical_enabled=true mesh_ready=true source_current=true projected=true drawn=true chunks_rendered=[1-9][0-9]* player=8\\.0,110\\.0,-32\\.0 warmup_visit=0 compact_qualification=0$" "$run_dir/$label.log"
        grep -Eq "^CANONICAL_SAVED_READY: run=$capture_id scene=$scene scope=saved_source qualified=0 stable_frames=180 reload=0 target_source_resident=[0-9]+ saved_features=9 compact_qualification=0$" "$run_dir/$label.log"
        grep -Eq "CANONICAL_SAVE_FLUSH: run=$capture_id scene=$scene saved=1 failures=0 committed_epoch=[1-9][0-9]* " "$run_dir/$label.log"
    fi
}

shopt -s nullglob
region_hashes() {
    local regions=("$save_dir"/regions/r.*.*.mca)
    (( ${#regions[@]} > 0 ))
    sha256sum -- "${regions[@]}"
}

snapshot_blocks() {
    local label=$1
    local regions=("$save_dir"/regions/r.*.*.mca)
    (( ${#regions[@]} > 0 ))
    mkdir "$run_dir/regions-$label"
    cp --reflink=auto -- "${regions[@]}" "$run_dir/regions-$label/"
    region_hashes > "$run_dir/regions-$label.sha256"
    python3 scripts/canonical_saved_blocks.py manifest "$run_dir/regions-$label" > "$run_dir/blocks-$label.json"
}

verify_blocks() {
    local label=$1
    python3 scripts/canonical_saved_blocks.py compare "$run_dir/blocks-before.json" "$run_dir/blocks-$label.json" | tee "$run_dir/blocks-$label-comparison.json"
}

capture canonical-save-create create
test -s "$save_dir/summaries/v1/r.0.0/c.0.0.zsum"
test -s "$save_dir/summaries/v1/r.0.0/c.1.0.zsum"
snapshot_blocks before
if [[ "$mode" != repair ]]; then
    stage=intact
    capture canonical-save-reload intact
    snapshot_blocks after-intact
    verify_blocks after-intact
    echo "CANONICAL_SAVED_BLOCKS: run=$run_id case=intact all_original_chunk_blocks_preserved=1" | tee -a "$run_dir/metadata.log"
fi
if [[ "$mode" != intact ]]; then
    stage=summary-cache-loss
    # Canonical manager bypasses legacy derived LOD stores. Fail on unexpected
    # stores rather than guessing filenames or deleting unknown artifacts.
    for unexpected in lod_cache lod_store near-source-v1; do
        test ! -e "$save_dir/$unexpected"
    done
    summaries=("$save_dir"/summaries/v1/r.*.*/c.*.*.zsum)
    (( ${#summaries[@]} >= 2 ))
    region_hashes > "$run_dir/regions-before-cache-loss.sha256"
    cp -a -- "$save_dir/summaries" "$run_dir/summaries-before-cache-loss"
    for artifact in "${summaries[@]}"; do
        # The only approved deletions are regular summary files produced by
        # this fresh run. Never recurse or remove region/level/user files.
        [[ -f "$artifact" && ! -L "$artifact" && "$artifact" == "$save_dir"/summaries/v1/r.*.*/c.*.*.zsum ]]
        rm -- "$artifact"
    done
    remaining=("$save_dir"/summaries/v1/r.*.*/c.*.*.zsum)
    (( ${#remaining[@]} == 0 ))
    region_hashes > "$run_dir/regions-after-cache-loss.sha256"
    cmp "$run_dir/regions-before-cache-loss.sha256" "$run_dir/regions-after-cache-loss.sha256"
    echo "CANONICAL_SUMMARY_CACHE_LOSS: run=$run_id summary_files=${#summaries[@]} remaining=0 derived_lod_cache=absent block_regions_unchanged_during_removal=1" | tee -a "$run_dir/metadata.log"
    stage=repair
    capture canonical-save-reload repair
    snapshot_blocks after-repair
    verify_blocks after-repair
    test -s "$save_dir/summaries/v1/r.0.0/c.0.0.zsum"
    test -s "$save_dir/summaries/v1/r.0.0/c.1.0.zsum"
    echo "CANONICAL_SAVED_BLOCKS: run=$run_id case=summary_cache_loss all_original_chunk_blocks_preserved=1 summaries_repaired=1 target_source_resident=0" | tee -a "$run_dir/metadata.log"
fi
echo "Canonical saved evidence: $run_dir (scope=saved_source; compact_qualification=0; qualified=0)"
