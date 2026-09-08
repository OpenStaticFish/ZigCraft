# CI Review Security Boundary

## PR Review Threat Model

PR diffs, filenames, descriptions, previous comments, repository agent instructions/config, scripts, local actions, dependencies, and model output are untrusted. An attacker can place shell commands, prompt injections, tool requests, or fake verdicts in any of them.

`opencode-pr.yml` preserves static review of the diff and bounded previous review context, but does not run an autonomous OpenCode agent. A small trusted Python client makes one tool-free request to the existing Zhipu AI Coding Plan provider (`open.bigmodel.cn`, `glm-5.2`, `ZHIPU_API_KEY`), not the separate Z.AI endpoint/key namespace. There is no shell/read/write/browser tool, tool dispatcher, plugin loader, repository configuration discovery, or model-controlled URL. This is a capability restriction, not reliance on a prompt saying "read only".

## Guarantees

- `pull_request_target` uses a trusted workflow; only trusted-base review tooling is sparsely checked out. PR-head code, scripts, actions, `AGENTS.md`, and package/devenv configuration are never executed or loaded as instructions.
- Dispatch is restricted to the repository's default branch workflow and checks that the requested PR is open, non-draft, and still at the requested head. Callers must dispatch on the default branch; the existing `pr_number` and `head_sha` inputs remain supported.
- Fork PRs are explicitly excluded from provider review, including manual dispatch. No fallback PAT, provider credential, or extra token is invented. Missing provider credentials fail the review rather than fabricating success.
- The review job has read-only GitHub permissions, no OIDC/write credentials, no persisted checkout credentials, and no GitHub token in the provider step's environment. Only that step receives the provider token; it is not part of model input. Python isolated mode avoids importing workspace modules.
- The provider request is fixed-endpoint, bounded, non-streaming, does not follow redirects/proxies, and registers no tools. Partial/tool-call/oversized responses fail. Provider errors, raw responses, hidden state, auth files, and caches are never logged or uploaded.
- Only an allowlisted JSON file containing PR number, head SHA, and review text crosses to a separate publication runner. Publication has no checkout, local actions, or provider secret and never evaluates artifact text. It validates size/type/metadata and rechecks the live PR head before posting. Mentions and HTML in output are neutralized.
- Publication can comment and report `ai-review` completion, but cannot write repository contents. It never approves a PR, enables auto-merge, or interprets model output as authorization.

## Limitations And Rollout

Static review can miss bugs and can be misled by prompt injection into producing bad advice. This cannot be solved by a prompt; the security boundary instead prevents advice from becoming tool execution or merge authority. Review text may quote code from the PR, which is intentionally sent to the existing provider. No whole-repository context, linked-issue verification, build, test execution, or factual merge-readiness score is claimed. Oversized/missing diffs fail instead of being silently truncated; descriptions and prior-review context are bounded and may be incomplete.

Trust still rests on maintainers of the protected base/default branch, the pinned GitHub actions, GitHub-hosted runner/platform, Python/TLS, and the provider's handling of supplied source. This is not a general OS/network sandbox for arbitrary untrusted programs: **no such program is executed in the review job**. Maintainers able to change trusted workflows or repository secrets are outside this boundary. As with all status checks, a head can move after publication; status is attached to the reviewed SHA only.

The previous model-driven `ai-merge-gate` auto-merge call is intentionally no longer invoked, and its legacy publisher script now fails explicitly without making GitHub mutations. Before enabling this workflow as a required check, maintainers must review branch protection/autopilot rules: require human approval and actual build/test checks, and remove or replace any obsolete required `ai-merge-gate` context. No repository settings are changed by this patch. Roll out the trusted tooling/workflow on the relevant protected branch before expecting its PR reviews to use the new behavior.

Other autonomous issue/audit/test-writer workflows are not granted the guarantees of this static PR reviewer; they need their own threat-model review. Visual capture no longer invokes a credentialed agent in the same job as PR-built binaries. Coverage comments are separated from execution and report only job outcomes. Ordinary PR build jobs still execute PR code and must not be given deployment/provider credentials.
