#!/usr/bin/env bash
set -euo pipefail

baseline=${1:-docs/shaders/spirv-sizes.json}
threshold_percent=${SPIRV_SIZE_REGRESSION_THRESHOLD_PERCENT:-10}
update_baseline=${SPIRV_UPDATE_BASELINE:-0}

mkdir -p "$(dirname "$baseline")"
if [[ ! -f "$baseline" ]]; then
    printf '{\n  "threshold_percent": %s,\n  "shaders": {}\n}\n' "$threshold_percent" > "$baseline"
fi

tmp_dir=$(mktemp -d)
current=$(mktemp)
updated=$(mktemp)
trap 'rm -rf "$tmp_dir" "$current" "$updated"' EXIT

jq -n --argjson threshold "$threshold_percent" '{threshold_percent: $threshold, shaders: {}}' > "$current"

failed=0
updated_baseline=0

while IFS= read -r shader; do
    output="$tmp_dir/$(basename "$shader").spv"
    start_ns=$(date +%s%N)
    glslangValidator -V "$shader" -o "$output" >/dev/null
    end_ns=$(date +%s%N)
    size=$(stat -c '%s' "$output")
    compile_ms=$(( (end_ns - start_ns) / 1000000 ))

    printf 'SPIR-V size: %s %s bytes (%sms compile)\n' "$shader" "$size" "$compile_ms"
    jq --arg shader "$shader" --argjson size "$size" '.shaders[$shader] = $size' "$current" > "$updated"
    mv "$updated" "$current"

    baseline_size=$(jq -r --arg shader "$shader" '.shaders[$shader] // empty' "$baseline")
    # Explicit update mode records intentional changes to existing shaders too.
    # Normal verification below remains strict and never rewrites the baseline.
    if [[ "$update_baseline" == "1" ]]; then
        jq --arg shader "$shader" --argjson size "$size" '.shaders[$shader] = $size' "$baseline" > "$updated"
        mv "$updated" "$baseline"
        updated_baseline=1
        continue
    fi
    if [[ -z "$baseline_size" ]]; then
        printf 'SPIR-V baseline missing for new shader %s (%s bytes). Run scripts/update_spirv_baseline.sh and commit the updated baseline.\n' "$shader" "$size" >&2
        failed=1
        continue
    fi

    max_size=$(awk -v base="$baseline_size" -v threshold="$threshold_percent" 'BEGIN { printf "%d", int(base * (1 + threshold / 100.0) + 0.999999) }')
    if (( size > max_size )); then
        increase=$(awk -v base="$baseline_size" -v size="$size" 'BEGIN { printf "%.2f", ((size - base) / base) * 100.0 }')
        printf 'SPIR-V size regression: %s grew from %s to %s bytes (%s%% > %s%%)\n' "$shader" "$baseline_size" "$size" "$increase" "$threshold_percent" >&2
        failed=1
    fi
done < <(find assets/shaders/vulkan -maxdepth 1 \( -name '*.vert' -o -name '*.frag' -o -name '*.comp' \) | sort)

if [[ "$updated_baseline" -eq 1 ]]; then
    jq '.shaders |= (to_entries | sort_by(.key) | from_entries)' "$baseline" > "$updated"
    mv "$updated" "$baseline"
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
