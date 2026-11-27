# OpenCode CI

The workflows use the [original Markdown prompts](../.github/prompts) with the
pinned OpenCode CLI. The [CI provider config](../.github/opencode/provider.json)
routes `zigcraft/gpt-6.2-sol` to the private OpenAI Responses endpoint with
medium reasoning effort. It does not change developers' local providers.

## Proxy setup

Only [the shared workflow](../.github/workflows/opencode-v2-infer.yml) joins
Tailscale. Keep the `opencode-proxy` GitHub environment restricted to `dev`.

| Environment setting | Value |
| --- | --- |
| Variables `TS_OIDC_CLIENT_ID`, `TS_OIDC_AUDIENCE` | The existing Tailscale GitHub federated identity |
| Secret `OPENCODE_PROXY_BASE_URL` | `https://<peer>.<tailnet>.ts.net[:port]/v1` |
| Secret `OPENCODE_PROXY_KEY` | A dedicated proxy credential |

The identity uses `tag:ci` and is bound to `repository_id=1100057461`,
`ref=refs/heads/dev`, and
`job_workflow_ref=OpenStaticFish/ZigCraft/.github/workflows/opencode-v2-infer.yml@refs/heads/dev`.
Limit the tag's network access to the proxy's TLS port. To check the connection
after merging a change, dispatch **OpenCode proxy smoke** on `dev`; it requires
the expected text from the configured model.

## Jobs

PR review reads the current PR diff from GitHub and posts its review and merge
gate on the reviewed SHA. The model runs from the trusted `dev` checkout. PR
code, including labeled visual captures, never runs on the proxy runner.

Optional jobs use the existing repository variables (literal `true` to enable):

| Variable | Job |
| --- | --- |
| `OPENCODE_V2_TRIAGE_ENABLED` | Triage newly opened issues |
| `OPENCODE_V2_SLASH_ENABLED` | Respond to maintainer `/oc` and `/opencode` commands in issue or PR conversations |
| `OPENCODE_AUDIT_ENABLED` | Audit a module on dispatch or Mondays at 06:00 UTC |
| `OPENCODE_TEST_WRITER_ENABLED` | Propose tests on dispatch or Tuesdays at 04:00 UTC |
| `OPENCODE_VISUAL_ENABLED` | Inspect the captured image or diagnose failure on dispatch or daily at 04:43 UTC |

Generated tests are built off the tailnet. The repository's `OPENCODE_PAT` is
used to publish test and slash-command edit PRs so those PRs trigger ordinary CI; the model does not
receive it.
