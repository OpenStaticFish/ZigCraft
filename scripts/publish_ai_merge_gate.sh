#!/usr/bin/env bash

set -euo pipefail

# Retain the entrypoint so stale callers fail visibly, not with merge authority.
printf 'AI merge authorization is retired. Static review is advisory; require human approval and build/test checks. See docs/ci-review-security.md.\n' >&2
exit 2
