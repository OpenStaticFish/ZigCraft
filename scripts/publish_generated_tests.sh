#!/usr/bin/env bash
# The publisher reconstructs the single allowed file from the original
# immutable response on a fresh pinned checkout. It executes no proposed Zig.
set -euo pipefail

branch="feature/opencode-test-writer-$GITHUB_RUN_ID"
prior=$(gh api "repos/{owner}/{repo}/pulls?state=all&base=dev&head=OpenStaticFish:$branch" --jq '.[].number')
if [[ -n "$prior" ]]; then
    echo "This run already published a PR."
    exit 0
fi
gh api --silent 'repos/{owner}/{repo}/labels/automated-test'
bash scripts/configure_git_identity.sh "opencode[bot]" "opencode[bot]@users.noreply.github.com"
git add -- src/tests.zig
[[ "$(git diff --cached --name-only)" == src/tests.zig ]]
# Deterministic commit identity lets a retry complete a PR after a successful
# push without replacing an existing branch (including a human's changes).
GIT_AUTHOR_DATE=$(git show -s --format=%cI HEAD)
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
git -c core.hooksPath=/dev/null commit -s -m "test: add $MODULE regression coverage"
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
gh pr create --base dev --head "$branch" --label automated-test \
    --title "test: add $MODULE regression coverage" \
    --body "Tests proposed for \`$MODULE\` against \`$GITHUB_SHA\`. Formatting, a named focused test and the full CPU unit suite passed in the isolated validation job: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID. Please review the coverage and ordinary CI."
