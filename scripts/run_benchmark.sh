#!/usr/bin/env bash
set -euo pipefail

duration=60
presets="low,medium,high"
scenarios="stationary,traversal,rapid-turn,teleport-eviction"
benchmark_world="overworld"
output_dir="docs/benchmarks/results"
per_preset_timeout=600
overwrite=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            duration="$2"
            shift 2
            ;;
        --presets)
            presets="$2"
            shift 2
            ;;
        --scenarios) scenarios="$2"; shift 2 ;;
        --benchmark-world) benchmark_world="$2"; shift 2 ;;
        --benchmark-fixture) printf '%s\n' '--benchmark-fixture was removed; benchmark fixtures are unsupported.' >&2; exit 2 ;;
        --overwrite) overwrite=true; shift ;;
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --per-preset-timeout)
            per_preset_timeout="$2"
            shift 2
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$output_dir"

IFS=',' read -r -a preset_list <<< "$presets"
IFS=',' read -r -a scenario_list <<< "$scenarios"

for preset in "${preset_list[@]}"; do
    for scenario in "${scenario_list[@]}"; do
    output_file="$output_dir/$preset/$scenario.json"
    [[ ! -e "$output_file" || "$overwrite" == true ]] || { printf 'Refusing to overwrite %s\n' "$output_file" >&2; exit 1; }
    mkdir -p "$(dirname "$output_file")"
    printf 'Running benchmark preset %s -> %s\n' "$preset" "$output_file"
    benchmark_cmd=(zig build benchmark -Doptimize=ReleaseFast -Dbenchmark-preset="$preset" -Dbenchmark-scenario="$scenario" -Dbenchmark-world="$benchmark_world" -Dbenchmark-duration="$duration" -Dbenchmark-output="$output_file")
    if [[ -n "${IN_NIX_SHELL:-}" ]]; then
        timeout --preserve-status "${per_preset_timeout}s" "${benchmark_cmd[@]}"
    else
        timeout --preserve-status "${per_preset_timeout}s" devenv shell --profile graphics -- "${benchmark_cmd[@]}"
    fi
    bash "$(dirname "$0")/validate_benchmark_artifact.sh" --result "$output_file"
    done
done
