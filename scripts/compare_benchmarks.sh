#!/usr/bin/env bash
set -euo pipefail

warn_threshold=5
fail_threshold=10
preset=""
scenario=""

if [[ $# -lt 2 ]]; then
    printf 'Usage: %s baseline.json new.json\n' "$0" >&2
    exit 2
fi

baseline="$1"
new="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            preset="$2"
            shift 2
            ;;
        --scenario)
            scenario="$2"
            shift 2
            ;;
        --warn)
            warn_threshold="$2"
            shift 2
            ;;
        --fail)
            fail_threshold="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

read_json() {
    jq -r "$1" "$2"
}

[[ -n "$preset" && -n "$scenario" ]] || { printf 'Schema-v4 comparison requires --preset and --scenario.\n' >&2; exit 2; }
python3 scripts/benchmark_baseline.py validate "$baseline"
bash scripts/validate_benchmark_artifact.sh --result "$new"
python3 scripts/benchmark_baseline.py compatibility "$baseline" "$new" --preset "$preset" --scenario "$scenario"
baseline_source="$baseline"

if [[ -n "$preset" ]]; then
    baseline_source=$(mktemp)
    jq -c --arg preset "$preset" --arg scenario "$scenario" '.results[$preset][$scenario]' "$baseline" > "$baseline_source"
    if [[ "$(read_json 'type' "$baseline_source")" == "null" ]]; then
        printf 'Baseline preset not found: %s\n' "$preset" >&2
        exit 2
    fi
fi

cleanup() {
    if [[ -n "${baseline_source:-}" && "$baseline_source" == /tmp/* && -f "$baseline_source" ]]; then
        rm -f "$baseline_source"
    fi
}

trap cleanup EXIT

pct_change() {
    awk -v old="$1" -v new="$2" 'BEGIN {
        if (old == 0 && new == 0) { print 0; exit }
        if (old == 0) { print 100; exit }
        printf "%.2f", ((new - old) / old) * 100.0
    }'
}

baseline_fps_avg=$(read_json '.fps.avg' "$baseline_source")
new_fps_avg=$(read_json '.fps.avg' "$new")
baseline_fps_p1=$(read_json '.fps.p1' "$baseline_source")
new_fps_p1=$(read_json '.fps.p1' "$new")
baseline_gpu=$(read_json '.gpu_ms.total.avg' "$baseline_source")
new_gpu=$(read_json '.gpu_ms.total.avg' "$new")
baseline_draws=$(read_json '.draw_calls_avg' "$baseline_source")
new_draws=$(read_json '.draw_calls_avg' "$new")

fps_avg_change=$(pct_change "$baseline_fps_avg" "$new_fps_avg")
fps_p1_change=$(pct_change "$baseline_fps_p1" "$new_fps_p1")
gpu_change=$(pct_change "$baseline_gpu" "$new_gpu")
draw_change=$(pct_change "$baseline_draws" "$new_draws")

printf 'FPS avg: %s -> %s (%s%%)\n' "$baseline_fps_avg" "$new_fps_avg" "$fps_avg_change"
printf 'FPS p1: %s -> %s (%s%%)\n' "$baseline_fps_p1" "$new_fps_p1" "$fps_p1_change"
printf 'GPU total avg: %s -> %s (%s%%)\n' "$baseline_gpu" "$new_gpu" "$gpu_change"
printf 'Draw calls avg: %s -> %s (%s%%)\n' "$baseline_draws" "$new_draws" "$draw_change"

fps_p1_drop=$(awk -v change="$fps_p1_change" 'BEGIN { if (change < 0) printf "%.2f", -change; else print 0 }')
gpu_increase=$(awk -v change="$gpu_change" 'BEGIN { if (change > 0) printf "%.2f", change; else print 0 }')
draw_increase=$(awk -v change="$draw_change" 'BEGIN { if (change > 0) printf "%.2f", change; else print 0 }')

regressed=0

check_metric() {
    local name=$1
    local regression=$2

    if awk -v value="$regression" -v warn="$warn_threshold" 'BEGIN { exit !(value >= warn) }'; then
        printf 'Warning: %s regressed by %s%%\n' "$name" "$regression"
    fi

    if awk -v value="$regression" -v fail="$fail_threshold" 'BEGIN { exit !(value >= fail) }'; then
        printf 'Regression exceeds failure threshold for %s (%s%% >= %s%%)\n' "$name" "$regression" "$fail_threshold" >&2
        regressed=1
    fi
}

check_metric "FPS p1" "$fps_p1_drop"
check_metric "GPU total avg" "$gpu_increase"
check_metric "draw calls avg" "$draw_increase"

if [[ "$regressed" -ne 0 ]]; then
    exit 1
fi
