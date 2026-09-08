#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
    printf 'Usage: %s log...\n' "$0" >&2
    exit 2
fi
for log in "$@"; do
    if [[ ! -s "$log" ]]; then
        printf 'Missing or empty graphics log: %s\n' "$log" >&2
        exit 1
    fi
done
status=0
rg -n -i 'vuid-|validation.*(error|failed)|(error|failed).*validation|skipping integration test' "$@" || status=$?
if (( status != 1 )); then
    printf 'Graphics log rejection: validation error, initialization skip, or unreadable log\n' >&2
    exit 1
fi
