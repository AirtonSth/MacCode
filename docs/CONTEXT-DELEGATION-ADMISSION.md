# Context delegation admission checkpoint

At exact macOS tree `e85bf6a84e3ba7bb47bd167aace15d5e5adfc0b8`, selected `BotContextResolverCleanupFailureDockerTests` passed: 1 test, 0 skips, 0 failures, 9.998 seconds, exit 0. Runner: `scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextResolverCleanupFailureDockerTests'`, with `RC_LIVE_DOCKER=1 RC_LIVE_DOCKER1=1` and an ephemeral caller-supplied `RC_CONTEXT_PROBE_ROOT` (no hardcoded path). Sources unchanged versus `d8463ad88`; prior 45-test/build proof reused, not rerun.

The new 12-line probe uses a real scoped gateway HTTP request through `bot_ask_peer`: HTTP 200 with JSON-RPC `-32602` (message contains `not available`). Child conversation IDs remain unchanged; specific child edge and marker remain absent. Existing assertions then perform actual Stop, injected physical-stop failure during revocation, recovery and listener closure. This is negative-admission proof only: no descendants are created.

Reviewer `01a148a0-8a96-7b53-9090-962f032eb82f` found no supported defect in the admission block and confirmed internal blockers by read-only inspection:

- `BotGuestRunResolver` (lines 143–161) uses an `async throws -> Never` pinned path: it prepares resources, cancels them and unconditionally refuses provider launch.
- `SocketServer`/`BotGuestMCPGateway` (85–117, 258–266) allow tools but deny peer calls.
- `AppCommandRouter` (3555–3557) returns pinned-caller `-32084` after managed auth.
- `BotsWindow` (1143–1177) uses legacy peer path with nil workspace and no pin.
- `BotGuestRunResolver` factory (813–823) omits `parentRunID`, whose default is nil; resource defaults are at lines 48–58.
- `BotStore+ContextDelegations` (46) requires `parent.running`, but real prepared parent remains pending.

These are implementation blockers independent of credentials. A valid account alone does not unlock admission. Positive integrated probe remains blocked until scoped child admission, canonical pin, ancestry handoff and nonpublic valid-provider admission exist while public gates stay closed. No forged status or test-only bypass.

External refresh proof needs a dedicated authorized account: either Claude OAuth (`claude-auth.json` with `access_token`, `refresh_token` and `expires_at`) refreshing `https://platform.claude.com/v1/oauth/token`, or ChatGPT OAuth (`codex-auth.json` with `tokens.access_token`, `tokens.refresh_token`, account identity via `tokens.account_id`/`tokens.id_token`, and `last_refresh`) refreshing `https://auth.openai.com/oauth/token`. Refresh window is 45 minutes. Static API key is not refresh proof. Fixture must legitimately refresh; do not forge expiry or expose credentials in chat or personal-sign-in copies. Legacy refresher uses host home and is not integrated into context-scoped provider lifecycle. No personal credential read occurred.

Live Activity `invalidResponse` and expected injected Stop errors limit lifecycle claims. UI unchanged; positive probe and whole plan remain pending. Public contextual execution gates remain unchanged.
