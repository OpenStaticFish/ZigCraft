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
    # kcov execs the ELF, bypassing the build runner's explicit Nix loader.
    # Patch only this private LLVM-built copy, never the cached original.
    stage="ELF inspection $index/${#binaries[@]} ($binary)"
    readelf --wide --program-headers --dynamic "$target" > "$work/bin/test-$index.original.elf.txt"
    interpreter=$(LC_ALL=C readelf --wide --program-headers "$target" |
        sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    printf 'Original test ELF interpreter: %s\n' "${interpreter:-<static>}"
    if [[ -n "${ZIGCRAFT_DYNAMIC_LINKER:-}" && -n "$interpreter" &&
          "$interpreter" != "$ZIGCRAFT_DYNAMIC_LINKER" ]]; then
        stage="ELF interpreter patch $index/${#binaries[@]} ($binary)"
        patchelf --set-interpreter "$ZIGCRAFT_DYNAMIC_LINKER" "$target"
        if [[ "$(patchelf --print-interpreter "$target")" != "$ZIGCRAFT_DYNAMIC_LINKER" ]]; then
            printf 'Coverage ELF interpreter patch did not apply\n' >&2
            exit 1
        fi
    fi
    readelf --wide --program-headers --dynamic "$target" > "$work/bin/test-$index.elf.txt"
    stage="test executable $index/${#binaries[@]} ($binary)"
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
