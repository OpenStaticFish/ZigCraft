#!/usr/bin/env bash
# Read the task prompt from stdin. Only the final answer goes to the caller;
# intermediate tool output and provider diagnostics do not go to Actions logs.
set -euo pipefail
agent=inspect
if [[ "$TASK" == test-writer ]]; then agent=test-writer; fi
export OPENCODE_CONFIG="$GITHUB_WORKSPACE/.github/opencode/provider.json"
unset GH_TOKEN GITHUB_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_RUNTIME_TOKEN
opencode --standalone run --title "ZigCraft CI: $TASK" --agent "$agent" --format json "$@" |
    jq -ner '
      reduce inputs as $e ({text:"", done:false};
        if $e.type == "error" then error("OpenCode request failed")
        elif $e.type == "step_start" then {text:"", done:false}
        elif $e.type == "text" then .text += $e.part.text
        elif $e.type == "step_finish" then .done = ($e.part.reason == "stop")
        else . end)
      | if .done and (.text | length > 0) then .text else error("No complete OpenCode answer") end'
