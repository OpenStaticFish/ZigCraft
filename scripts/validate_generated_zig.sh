#!/usr/bin/env bash
# Called *inside* the pinned unit devenv on a disposable Ubuntu runner. Expose
# only the toolchain and a disposable copy of the tracked tree to proposed Zig.
set -euo pipefail

source_tree=$(mktemp -d "$RUNNER_TEMP/test-source.XXXXXXXX")
git archive HEAD | tar -x -C "$source_tree"
cp src/tests.zig "$source_tree/src/tests.zig"
# No image download. Supply only Ubuntu's merged-/usr symlinks; executables
# come from the read-only hosted OS and the same devenv store as normal CI.
layout=$(mktemp -d "$RUNNER_TEMP/test-layout.XXXXXXXX")
for directory in bin lib lib64; do ln -s "usr/$directory" "$layout/$directory"; done
image=$(tar -C "$layout" -cf - . | docker import -)
trap 'docker image rm "$image" >/dev/null' EXIT

# devenv may name its profile via a workspace symlink. Resolve it before
# entering the mount namespace (which deliberately doesn't contain that path).
store_path_list() {
    local entry resolved
    local -a entries directories=()
    IFS=: read -ra entries <<< "$1"
    for entry in "${entries[@]}"; do
        [[ -d "$entry" ]] || continue
        resolved=$(realpath "$entry")
        if [[ "$resolved" == /nix/store/* ]]; then
            directories+=("$resolved")
        fi
    done
    (IFS=:; echo "${directories[*]}")
}

run_isolated() {
    local work=$1
    shift
    docker run --rm --user "$(id -u):$(id -g)" --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
        --mount type=bind,src=/nix/store,dst=/nix/store,readonly \
        --mount type=bind,src=/usr,dst=/usr,readonly \
        --tmpfs /tmp:rw,nosuid,nodev -v "$work:/project" -w /project \
        -e HOME=/project/.home -e "PATH=$(store_path_list "$PATH"):/usr/bin:/bin" \
        -e "PKG_CONFIG_PATH=$(store_path_list "${PKG_CONFIG_PATH:-}")" \
        -e NIX_CFLAGS_COMPILE -e NIX_CFLAGS_LINK -e NIX_LDFLAGS \
        -e ZIGCRAFT_DYNAMIC_LINKER -e ZIGCRAFT_RUNTIME_LIBRARY_PATH \
        -e ZIG_GLOBAL_CACHE_DIR=/project/.cache/zig "$image" "$@"
}

# Neither check may change the other's source/build scripts or seed its cache.
# Don't forward compiler/test output (including potential runner commands).
focused=$(mktemp -d "$RUNNER_TEMP/test-focus.XXXXXXXX")
cp -a "$source_tree/." "$focused"
run_isolated "$focused" zig fmt --check src/tests.zig >/dev/null 2>&1 || {
    echo 'Generated test formatting failed.' >&2; exit 1
}
if ! run_isolated "$focused" zig build test -j2 "-Dtest-filter=$FOCUSED_TEST" 2>&1 |
    awk -v test="test.$FOCUSED_TEST...OK" 'index($0, test) {found=1} END {exit !found}'; then
    echo 'Focused test failed or was not discovered by the runner.' >&2
    exit 1
fi
rm -rf -- "$focused"
run_isolated "$source_tree" zig build test -j2 >/dev/null 2>&1 || {
    echo 'Full unit suite failed.' >&2; exit 1
}
