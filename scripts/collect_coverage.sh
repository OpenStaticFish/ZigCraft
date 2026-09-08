#!/usr/bin/env bash
set -euo pipefail

# Run inside the unit devenv shell. A private local cache prevents stale test
# executables (including old integration binaries) from entering this report.
root=$(git rev-parse --show-toplevel)
if [[ "$PWD" != "$root" ]]; then
    printf 'Run coverage from the repository root\n' >&2
    exit 2
fi
if (( $# > 1 )); then
    printf 'Usage: %s [new-report-directory]\n' "$0" >&2
    exit 2
fi
output=${1:-coverage/kcov}
if [[ -e "$output" || -L "$output" ]]; then
    printf 'Coverage output already exists: %s (no report is overwritten)\n' "$output" >&2
    exit 1
fi
jobs=${ZIGCRAFT_TEST_JOBS:-2}
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ZIGCRAFT_TEST_JOBS must be a positive integer\n' >&2
    exit 2
fi
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zigcraft-coverage.XXXXXX")
stage=build
status=0
trap 'status=$?; if (( status != 0 )); then printf "Coverage unavailable: %s exited with status %s. Evidence: %s\n" "$stage" "$status" "$work" >&2; fi' EXIT
printf 'Coverage evidence directory: %s\n' "$work"
mkdir -p "$work/cache" "$work/runs" "$work/bin"
# Zig 0.16's native Debug backend emits incomplete line mappings for kcov 43.
# Select LLVM only for these test executables, not for normal application builds.
zig build test -Doptimize=Debug -Dtest-llvm=true "-j$jobs" --cache-dir "$work/cache"
stage=discovery

# std.Build tests in this repository use either the default `test` name or
# explicit `<module>-tests` names. Enumerate both, not just the aggregate suite.
find "$work/cache/o" -type f \( -name test -o -name '*-tests' \) -perm -u+x -print0 | sort -z > "$work/test-executables"
mapfile -d '' binaries < "$work/test-executables"
if (( ${#binaries[@]} == 0 )); then
    printf 'No test executables found; coverage is unavailable\n' >&2
    exit 1
fi
index=0
for binary in "${binaries[@]}"; do
    index=$((index + 1))
    stage="test executable $index/${#binaries[@]} ($binary)"
    target="$work/bin/test-$index"
    cp "$binary" "$target"
    # kcov must trace the test ELF itself. Rewriting Zig's native ELF layout
    # with patchelf can abort, so use the library search path without editing it.
    # Equivalent glibc loaders can live at different Nix store paths. Let the
    # actual instrumented execution detect incompatibility, not path equality.
    printf 'Collecting test executable %d/%d: %s\n' "$index" "${#binaries[@]}" "$binary"
    LD_LIBRARY_PATH="${ZIGCRAFT_RUNTIME_LIBRARY_PATH:-${LD_LIBRARY_PATH:-}}" \
        ZIGCRAFT_LOG_LEVEL=fatal timeout --kill-after=10s 5m kcov \
        --include-path="$root/src,$root/modules,$root/libs/rmlui_bridge" \
        "$work/runs/$index" "$target"
done

stage=merge
mkdir -p "$(dirname "$output")"
if [[ -e "$output" || -L "$output" ]]; then
    printf 'Coverage output appeared during collection: %s (no report is overwritten)\n' "$output" >&2
    exit 1
fi
kcov --merge "$output" "$work"/runs/*
stage=validation
python3 scripts/validate_coverage.py "$output/kcov-merged/cobertura.xml"
printf 'Collected %d test executables. Temporary evidence retained at %s\n' "$index" "$work"
