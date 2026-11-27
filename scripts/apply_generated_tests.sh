#!/usr/bin/env bash
# Inspect the actual index delta, not filenames claimed by the patch. Never
# materialize proposed code in a checkout that runs trusted workflow scripts.
set -euo pipefail

patch="$RUNNER_TEMP/proposal/opencode-tests.patch"
[[ -f "$patch" && ! -L "$patch" && $(wc -c < "$patch") -le 131072 ]]
IFS= read -r header < "$patch"
[[ "$header" =~ ^Module:\ ([a-z0-9/-]+)$ ]]
module=${BASH_REMATCH[1]}
input=$(jq -r '.inputs.module // ""' "$GITHUB_EVENT_PATH")
[[ -z "$input" || "$module" == "$input" ]]
INPUT_MODULE="$module" GITHUB_OUTPUT="$RUNNER_TEMP/test-selection" bash scripts/select_test_writer_module.sh
read -ra roots <<< "$(sed -n 's/^scan_paths=//p' "$RUNNER_TEMP/test-selection")"

export GIT_INDEX_FILE="$RUNNER_TEMP/opencode-test-index"
git read-tree HEAD
git apply --cached --whitespace=error "$patch" 2>/dev/null
git diff --cached --no-renames --numstat > "$RUNNER_TEMP/test-stats"
while IFS=$'\t' read -r added deleted path; do
    [[ "$added" =~ ^[1-9][0-9]*$ && "$deleted" == 0 ]]
    [[ "$path" == src/tests.zig || "$path" =~ ^(src|modules)/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+_tests\.zig$ ]]
    [[ "$(git ls-files -s -- "$path")" == "100644 "* ]]
    if [[ "$path" == modules/* ]]; then
        package=${path%%/src/*}
        [[ " ${roots[*]} " == *" $package/src/"* ]]
    fi
done < "$RUNNER_TEMP/test-stats"

names="$RUNNER_TEMP/test-names"
git diff --cached --no-renames -U0 > "$RUNNER_TEMP/test-diff"
sed -nE 's/^\+test "([^"\\]+)" \{$/\1/p' "$RUNNER_TEMP/test-diff" > "$names"
count=$(wc -l < "$names")
[[ "$count" -ge 3 && "$count" -le 8 && "$(sort -u "$names" | wc -l)" -eq "$count" ]]
[[ "$(grep -cE '^\+[[:space:]]*test([[:space:]]|")' "$RUNNER_TEMP/test-diff")" -eq "$count" ]]
# The names will be used literally as a test filter and in the PR body.
if grep -qEv '^[a-zA-Z0-9][a-zA-Z0-9 ._():/-]{1,159}$' "$names"; then
    echo 'Use simple descriptive names for new tests.' >&2
    exit 1
fi
printf 'tree=%s\nmodule=%s\n' "$(git write-tree)" "$module" >> "$GITHUB_OUTPUT"
