# OpenCode CI: private proxy rollout

Every OpenCode CI caller, including the required PR gate, requests `gpt-6.2-sol` with `reasoning.effort: medium` through CLIProxyAPI. The `default`, `review`, and `vision` profiles distinguish the workload and whether to attach an image; none can select another model or upstream provider.

The reviewer revisits earlier findings and explains fixes in the report. Each `ai-merge-gate` decision uses the current pinned review: matching head and base, zero unresolved critical, high or medium findings, confidence of at least 80, and a `MERGE` recommendation. Previous reviews provide context; their decisions do not carry forward to another commit.

The 96 KiB request limit includes the review instructions, revision identifiers, and the **complete UTF-8 diff**. With the full report prompt, budget **89 KiB for the diff** (down from roughly 94 KiB with the verdict-only prompt). The exact ceiling is 98,304 bytes minus the mandatory prompt and framing for that PR. Larger diffs are accepted when they still fit; optional history and metadata use only the remaining space. A diff that cannot fit is rejected before inference rather than reviewed in part.

The required status is published from the validated response artifact. The former workflow that parsed bot comments for its verdict is retired; the fenced verdict in the GitHub comment is a report, not an input to the required status.

Only `opencode-v2-infer.yml` may join the tailnet. It runs on disposable GitHub-hosted Ubuntu. Preparation, comment/PR publication, Zig checks, visual capture, profiling and benchmarks run elsewhere. The proxy and tailnet need an operator; they do not need a self-hosted Actions runner.

## Provision before enabling a caller

| Owner | Configuration |
| --- | --- |
| Tailnet admin | Use the existing `tag:ci` for inference runners. Configure the [GitHub OIDC federated identity](https://tailscale.com/docs/features/workload-identity-federation) with **auth_keys:write** for only that tag. Bind it to the claims below. Permit the tag to reach only the proxy node on its TLS TCP port. Check effective access, including other grants; test that an unrelated peer and a different port are denied. |
| Proxy admin | Serve authenticated OpenAI **Responses** at `https://<peer>.<tailnet>.ts.net[:port]/v1`, with a valid certificate, reachable over the peer’s Tailscale IPv4 address. Issue a ZigCraft-only key with an independent budget and concurrency limit. Allow and route the exact `gpt-6.2-sol` ID with medium reasoning and image input; do not substitute another model on failure. Review upstream routing, retention, rotation and budget alerts privately. |
| Repo maintainer | Restrict the **`opencode-proxy`** environment to the protected `dev` branch (no tags). Set environment **variables** `TS_OIDC_CLIENT_ID` and `TS_OIDC_AUDIENCE` to the values from Tailscale, and environment **secrets** `OPENCODE_PROXY_BASE_URL` and `OPENCODE_PROXY_KEY`. Only the inference job and the jobs calling it need `id-token: write` for this integration. |
| Edit publisher owner | Create a second `dev`-only environment **`opencode-test-publish`** with a required reviewer. Install an App on **this repo only** with Contents and Pull requests write, Metadata read, no workflow write or ruleset bypass. Store `OPENCODE_APP_ID` (variable) and `OPENCODE_APP_PRIVATE_KEY` (secret) only there. Inspect the prepared diff before approving. App-created PRs must trigger the ordinary CI and review rules. |

The initial ZigCraft key is dedicated and independently revocable. Its server-side model allowlist and quota are pending: CI requests only the configured model, but the key itself is not limited to it.

Use issuer `https://token.actions.githubusercontent.com` and the exact GitHub environment subject for this repository (normally `repo:OpenStaticFish/ZigCraft:environment:opencode-proxy`; use the actual subject if immutable IDs or customization are enabled). Set exact custom claims `repository_id=1100057461`, `ref=refs/heads/dev` and `job_workflow_ref=OpenStaticFish/ZigCraft/.github/workflows/opencode-v2-infer.yml@refs/heads/dev`. The audience comes from Tailscale when it creates the identity.

Restrict who can change `dev`, workflows, local actions, prompts and publisher helpers. Record the on-call contacts for the above roles, the rotation date and quota privately. Do not put an address, key, internal logs or upstream account details in an issue.

## Pilot in order

1. Dispatch **OpenCode V2 proxy smoke** on `dev`. There are no prompt, endpoint or model inputs. Success requires the pinned CLI's actual response to match the fixed challenge. Check the run summary, ephemeral-node removal, and a separate cancelled run. Record the run URLs. Exercise missing key, invalid key, unavailable proxy and denied model/quota with disposable credentials before live use.
2. Set repo variable `OPENCODE_V2_PR_SHADOW_ENABLED=true`. Dispatch **OpenCode V2 PR pilot** on `dev` for one small open, same-repo, non-draft PR, supplying its number and exact base/head SHAs. Compare the summary with that diff. Shadow never posts a comment, updates statuses or enables auto-merge.
3. Enable issue triage before advisory PR publication. Set each repo Actions variable below to the literal `true` only for a caller being exercised. Unset/`false` stops new work; cancel outstanding runs to stop in-flight work.

| Repo variable | Entry point and acceptance |
| --- | --- |
| `OPENCODE_V2_TRIAGE_ENABLED` | Open an eligible issue; expect one bounded triage comment or an intentional spam/no-response skip. Re-run and verify deduplication. |
| `OPENCODE_V2_PR_ADVISORY_ENABLED` | **Cutover interlock:** `opencode-pr.yml` already uses the gateway and publishes the required `ai-merge-gate`. To switch to advisory-only publication, agree the ruleset replacement with maintainers, coordinate [#981](https://github.com/OpenStaticFish/ZigCraft/pull/981), and verify ordinary mergeability. Disable and drain the gate workflow before enabling the advisory publisher. A shadow or advisory review cannot satisfy the gate. |
| `OPENCODE_V2_SLASH_ENABLED` | Use `/oc <question>` on an issue or PR conversation. `/oc edit <path> <instruction>` proposes a one-file replacement; inspect the `slash-edit-preview` artifact. Inline review comments are not trusted entry points. Try a user without current write access, then a same-repo maintainer edit. Verify the reviewed branch targets `dev` and a normal CI run starts. |
| `OPENCODE_AUDIT_ENABLED` | Dispatch `opencode-audit.yml`; omit `module` to use rotation. Expect a validated finding referencing a supplied file/line or no issue. Repeat the same finding to check deduplication. |
| `OPENCODE_TEST_WRITER_ENABLED` | Dispatch `opencode-test-writer.yml` with the repo's `automated-test` label in place. A reviewed, validated addition to `src/tests.zig` can create a DCO-signed PR; existing-PR and empty/invalid-change paths must not push. Inspect the `validated-tests` diff and verify downstream CI. |
| `OPENCODE_VISUAL_ENABLED` | Dispatch `visual-test.yml` on `dev`. A successful comparison supplies a normalized image; failure supplies only bounded diagnostic signals. Missing capture stays a failed deterministic check. The label preflight was removed from capture; provision the `visual-test` issue label for publication. See [#978](https://github.com/OpenStaticFish/ZigCraft/issues/978) for capture history. Scheduled and labeled PR captures remain deterministic-only. |

Audit and test-writer schedules are paused. Restore each weekly inference trigger by reviewed workflow change only after recording a hosted result for that caller. Record **both** visual paths (the black golden may need separate review), one edit PR with ordinary CI, and one fixture or run per caller in [#991](https://github.com/OpenStaticFish/ZigCraft/issues/991).

## Operations and rollback

- Input artifacts contain bounded data from this repo/run, not credentials. Only the short `response.txt` crosses from inference to validation. No shared OpenCode auth, session or cache directories. The proxy environment is never passed to callers or publishers.
- Check the run’s profile, duration and stage results first: preparation, CLI install, join, peer/TLS, provider access/quota, response validation, publication. Compare run counts, stage failures and latency with proxy-side usage for the ZigCraft key. Keep raw CLI transcripts, prompts, session databases and Tailscale status out of diagnostics.
- Change the model or reasoning effort once in [the shared model configuration](../.github/actions/opencode-v2/model.json), update the wire test, and re-run smoke. There is no model-catalog job rewriting workflow YAML and no direct-provider fallback.
- To roll back, turn off the affected caller, cancel active runs, or revert to a previously verified adapter pin. For an exposure or runaway quota, revoke the dedicated proxy key and tailnet federated identity and remove surviving nodes. Reissue credentials only into the protected environment.
- Provision the proxy before cutting over the required gate: a gateway or model error cannot produce a passing `ai-merge-gate`. Check other consumers before revoking old direct-provider credentials.

Local checks: `python3 -B -m unittest discover -s scripts/tests` exercises the authorization, artifact and publication contracts. Set `OPENCODE_TEST_CLI` to the verified V2.3.0 binary to include a loopback test of the actual Responses request, including authentication, model ID and zero advertised tools. With Pillow and ImageMagick 7 available, `python3 -B scripts/test_visual_inference.py` exercises both capture paths. These use disposable data and do not verify hosted connectivity.
