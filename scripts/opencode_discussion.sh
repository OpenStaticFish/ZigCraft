#!/usr/bin/env bash
# Shared by the issue-opened and issue-comment tasks. The caller uses set -euo pipefail.
repo="repos/$GITHUB_REPOSITORY"
event=$GITHUB_EVENT_PATH
number=$(jq -er '.issue.number' "$event")
[[ $number =~ ^[1-9][0-9]*$ && $GITHUB_SHA =~ ^[a-f0-9]{40}$ ]]
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

issue_snapshot() {
    gh api "$repo/issues/$number" | jq -ce --slurpfile event "$event" '
        select(.id == $event[0].issue.id and .state == "open")
        | {number,title,body,labels:[.labels[].name],author:.user.login,pr:has("pull_request")}'
}
current_dev() {
    [[ $(gh api "$repo/git/ref/heads/dev" --jq .object.sha) == "$GITHUB_SHA" ]]
}
already_commented() {
    # Propagate API errors even when this function is called in an if condition.
    gh api --paginate "$repo/issues/$number/comments?per_page=100" > "$tmp/comments" || exit 1
    local exists
    exists=$(jq -s --arg marker "${marker:?}" 'any(.[][]; .user.login == "github-actions[bot]"
        and ((.body // "") | startswith($marker + "\n")))' "$tmp/comments") || exit 1
    [[ $exists == true ]]
}
infer() {
    [[ $(wc -c < "$tmp/request") -le 98304 ]]
    opencode-ci < "$tmp/request" > "$tmp/response"
    [[ $(wc -c < "$tmp/response") -le 16000 ]]
    jq -Rse 'test("[^[:space:]]") and (test("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]") | not)' "$tmp/response" >/dev/null
    [[ $(cat "$tmp/response") != SKIP ]] || exit 0
}
prepare_reply() {
    {
        printf '%s\n\n' "$marker"
        python3 scripts/opencode_discussion_markdown.py "$GITHUB_REPOSITORY" "$tmp/response"
    } > "$tmp/reply"
    [[ $(wc -c < "$tmp/reply") -le 65536 ]]
}
post_reply() {
    gh api "$repo/issues/$number/comments" -F "body=@$tmp/reply" --silent
}
