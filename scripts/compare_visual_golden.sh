#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'Usage: %s actual.png golden.png [diff.png]\n' "$0" >&2
    exit 2
fi

actual=$1
golden=$2
diff=${3:-visual-diff.png}
tolerance=${VISUAL_DIFF_RMSE_TOLERANCE:-0.015}

if [[ ! -s "$actual" ]]; then
    printf 'Actual screenshot missing: %s\n' "$actual" >&2
    exit 2
fi

if [[ ! -s "$golden" ]]; then
    printf 'Golden screenshot missing: %s\n' "$golden" >&2
    exit 2
fi

number='^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$'
if [[ ! "$tolerance" =~ $number ]] || ! awk -v t="$tolerance" 'BEGIN { exit !(t >= 0 && t <= 1) }'; then
    printf 'Invalid RMSE tolerance: %s\n' "$tolerance" >&2
    exit 2
fi

actual_size=$(magick identify -format '%wx%h' "$actual")
golden_size=$(magick identify -format '%wx%h' "$golden")
if [[ "$actual_size" != "$golden_size" ]]; then
    printf 'Image dimensions differ: %s vs %s\n' "$actual_size" "$golden_size" >&2
    exit 1
fi

require_non_black_image() {
    local image=$1
    local label=$2
    local mean
    mean=$(magick "$image" -colorspace RGB -format '%[fx:mean]' info:)
    if [[ ! "$mean" =~ $number ]] || ! awk -v value="$mean" 'BEGIN { exit !(value > 0.0001 && value <= 1) }'; then
        printf '%s is effectively black (mean %s); refusing an invalid visual comparison\n' "$label" "$mean" >&2
        exit 1
    fi
}

# A black baseline can make the test look healthy while proving nothing about
# menu composition. Validate both inputs before calculating their difference.
require_non_black_image "$golden" "Golden screenshot"
require_non_black_image "$actual" "Actual screenshot"

compare_status=0
metric_output=$(magick compare -metric RMSE "$golden" "$actual" "$diff" 2>&1) || compare_status=$?
# ImageMagick returns 1 for a valid comparison with differences, 2 for errors.
if (( compare_status > 1 )) || [[ ! "$metric_output" =~ \(([0-9.eE+-]+)\)$ ]]; then
    printf 'Image comparison failed (status %s): %s\n' "$compare_status" "$metric_output" >&2
    exit 2
fi
normalized=${BASH_REMATCH[1]}
if [[ ! "$normalized" =~ $number ]] || [[ ! -s "$diff" ]]; then
    printf 'Image comparison did not produce a valid metric and diff\n' >&2
    exit 2
fi

printf 'Visual RMSE: %s (tolerance %s)\n' "$normalized" "$tolerance"

if awk -v value="$normalized" -v tolerance="$tolerance" 'BEGIN { exit !(value > tolerance) }'; then
    printf 'Visual golden diff exceeds tolerance: %s > %s\n' "$normalized" "$tolerance" >&2
    exit 1
fi
