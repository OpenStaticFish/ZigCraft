#!/usr/bin/env bash
set -euo pipefail

[[ "$GITHUB_EVENT_NAME" == workflow_dispatch &&
   "$GITHUB_REPOSITORY" == OpenStaticFish/ZigCraft && "$GITHUB_REF" == refs/heads/dev ]]
[[ "$(gh api 'repos/{owner}/{repo}' --jq .default_branch)" == dev ]]
[[ "$(gh api 'repos/{owner}/{repo}/git/ref/heads/dev' --jq .object.sha)" == "$GITHUB_SHA" ]]
for actor in "$GITHUB_ACTOR" "$GITHUB_TRIGGERING_ACTOR"; do
    permission=$(gh api "repos/{owner}/{repo}/collaborators/$actor/permission" --jq .permission)
    case "$permission" in
        admin|maintain|write) ;;
        *) echo "Dispatch requires current write access." >&2; exit 1 ;;
    esac
done
