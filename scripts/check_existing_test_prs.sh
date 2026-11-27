#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

base_branch="${BASE_BRANCH:?BASE_BRANCH is required}"
existing=$(gh api --paginate "repos/{owner}/{repo}/pulls?state=open&base=$base_branch&per_page=100" \
    --jq '.[] | select((.head.ref | startswith("opencode/schedule-") or startswith("feature/opencode-test-writer-")) or any(.labels[]; .name == "automated-test")) | .number')

if [[ -n "$existing" ]]; then
    write_output skip true
    printf 'Existing automated test PR(s): %s\n' "$existing"
else
    write_output skip false
fi
