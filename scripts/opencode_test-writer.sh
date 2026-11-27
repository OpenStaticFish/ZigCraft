#!/usr/bin/env bash
set -euo pipefail

bash scripts/authorize_source_task.sh
work=$(mktemp -d "$RUNNER_TEMP/test-writer.XXXXXXXX")
BASE_BRANCH=dev GITHUB_OUTPUT="$work/existing" bash scripts/check_existing_test_prs.sh
if grep -qx 'skip=true' "$work/existing"; then exit 0; fi
input=$(jq -r '.inputs.module // ""' "$GITHUB_EVENT_PATH")
INPUT_MODULE="$input" GITHUB_OUTPUT="$work/selection" bash scripts/select_test_writer_module.sh
module=$(sed -n 's/^module=//p' "$work/selection")
paths=$(sed -n 's/^scan_paths=//p' "$work/selection")
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" && -z "$(git status --porcelain)" ]]
{
    cat .agents/skills/test-writer/SKILL.md
    sed "s|\\\$MODULE|$module|g; s|\\\$DEFAULT_BRANCH|dev|g; s|\\\$SCAN_PATHS|$paths|g" .github/prompts/test-writer.md
    cat <<'EOF'

Workflow mechanics for this run: use native read/search/edit tools on this checkout.
Leave your edits uncommitted. The workflow handles all shell commands, formatting checks,
focused test discovery, the full unit suite, sign-off, push, and PR creation.
Use named tests in test-only files (*_tests.zig or src/tests.zig). For new files,
register them in src/tests.zig without changing production files, module roots or build.zig.
Only add lines. Give each of the 3–8 tests a unique plain-text name on one line.
If there are fewer than three worthwhile tests, leave no changes.
EOF
} | env -u GH_TOKEN opencode-ci > "$work/summary"
{
    printf '## Test writer: %s\n\n' "$module"
    head -c 16384 "$work/summary" | sed -e 's/@/＠/g' -e 's/^/    /'
} >> "$GITHUB_STEP_SUMMARY"

# Include newly authored tests as well as edits. The validation and publication
# jobs independently apply the patch to fresh trusted indexes and check paths.
git add --intent-to-add -- src modules
if git diff --quiet HEAD && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    echo 'No tests proposed.'
    exit 0
fi
[[ -z "$(git ls-files --others --exclude-standard)" ]]
if ! git diff --quiet HEAD -- . ':(exclude)src/tests.zig' ':(exclude,glob)src/**/*_tests.zig' ':(exclude,glob)modules/**/*_tests.zig'; then
    echo 'Test writer modified a non-test file.' >&2
    exit 1
fi
{
    printf 'Module: %s\n\n' "$module"
    git diff --no-ext-diff --no-renames HEAD
} > "$RUNNER_TEMP/opencode-tests.patch"
