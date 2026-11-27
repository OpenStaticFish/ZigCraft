#!/usr/bin/env bash
# Publish only the validated index on a fresh pinned checkout; execute no Zig.
set -euo pipefail

branch="feature/opencode-test-writer-$GITHUB_RUN_ID"
prior=$(gh api "repos/{owner}/{repo}/pulls?state=all&base=dev&head=OpenStaticFish:$branch" --jq '.[].number')
if [[ -n "$prior" ]]; then
    echo "This run already published a PR."
    exit 0
fi
gh api --silent 'repos/{owner}/{repo}/labels/automated-test'
bash scripts/configure_git_identity.sh "opencode[bot]" "opencode[bot]@users.noreply.github.com"
export GIT_INDEX_FILE="$RUNNER_TEMP/opencode-test-index"
# Deterministic commit identity lets a retry complete a PR after a successful
# push without replacing an existing branch (including a human's changes).
GIT_AUTHOR_DATE=$(git show -s --format=%cI HEAD)
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
git -c core.hooksPath=/dev/null commit -s -m "test: add regression tests for $MODULE"
gh auth setup-git
[[ "$(gh api 'repos/{owner}/{repo}/git/ref/heads/dev' --jq .object.sha)" == "$GITHUB_SHA" ]]
remote=$(git ls-remote --heads origin "refs/heads/$branch")
if [[ -z "$remote" ]]; then
    git -c core.hooksPath=/dev/null push --force-with-lease="refs/heads/$branch:" origin "HEAD:refs/heads/$branch"
elif [[ "${remote%%$'\t'*}" != "$(git rev-parse HEAD)" ]]; then
    echo 'Existing branch differs from the validated commit.' >&2
    exit 1
fi
[[ "$(gh api "repos/{owner}/{repo}/git/ref/heads/$branch" --jq .object.sha)" == "$(git rev-parse HEAD)" ]]
[[ "$(gh api 'repos/{owner}/{repo}/git/ref/heads/dev' --jq .object.sha)" == "$GITHUB_SHA" ]]
{
    printf '## Module\n%s (automated test coverage)\n\n## Tests added\n' "$MODULE"
    sed 's/^/- /' "$RUNNER_TEMP/test-names"
    cat <<EOF

## Verification
- Formatting, a focused test, and the full CPU unit suite passed against \`$GITHUB_SHA\`. All proposed tests were discovered.
- Only test files changed. Integration tests require a display and Vulkan driver and were not run in the CPU validation container.
- [Validation job]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)
EOF
} > "$RUNNER_TEMP/test-pr-body.md"
gh pr create --base dev --head "$branch" --label automated-test \
    --title "test: add regression tests for $MODULE" \
    --body-file "$RUNNER_TEMP/test-pr-body.md"
