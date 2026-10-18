# Context delegation admission checkpoint

## Historical investigation before internal admission

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

## Current implementation — internal contextual admission

This section records current implementation and verification; it does not erase or supersede the historical evidence above.

`AppContext.startContextualRun` and `startContextualPeerRun` provide internal admission. Registration carries immutable canonical pins, all required grants, a genuinely running parent for peer admission, and the peer's own context-scoped provider key, and an in-memory one-use permit checked by object identity. Permit registration is not serialized. The real resolver creates a `DistillGuestLaunchPlan` only for a registered admission. The parent run ID flows through resources to `recordContextDelegation` and coordinator cascade handling.

Public router, UI and gateway admission remain closed. Internal OpenRouter admission accepts only `OPENROUTER_API_KEY` from the existing bot-by-context store; model must follow `openrouter/<vendor>/<model>`. It uses the fixed real endpoint. The key is excluded from shell and TOML values; no host-account copies, arbitrary binary, environment, extra arguments or endpoint are accepted. Coordinator canonical-pin lookup scrubs and skips the legacy secret store.

Only fresh sessions are accepted: an existing provider thread ID or a non-pending thread is rejected before registration. Durable scoped resume and OAuth refresh remain pending. Review identified registry callback execution under lock; the implementation now atomically consumes the entry and unlocks before validation. TOML slash escaping was corrected; full canonical parent pins, peer all-grant checks and race validation were tightened. Follow-up `01a148be-a387-72f2-b571-303e575549c8` found no material defect in its narrow read-only review.

At exact source tree `f02cb11b28cf7a01c236d20a152f0412a1a089cf`, selected tests passed: 51 selected, 1 skipped, 0 failed, 76.981 seconds, exit 0 (50 executed and passed). Filter: `BotContextInternalAdmissionTests|BotContextInternalAdmissionLiveDockerTests|BotContextResolverCleanupFailureDockerTests|BotContextCredentialResolverDockerProbeTests|BotContextResolverDockerProbeTests|BotContextGuestResourcesTests|BotContextDelegationDockerProbeTests|BotGuestRunResolverTests`. Runner: `scripts/isolated-sandbox.sh test --build-system native --filter '<filter above>'`, with `RC_LIVE_DOCKER=1 RC_LIVE_DOCKER1=1`, caller-supplied scratch `RC_CONTEXT_PROBE_ROOT` (no absolute path persisted). Five new unit tests passed for actual authority, negative cases, one-use registry, reentrancy and configuration.

The real-provider child/revocation probe compiled but skipped because the required dedicated inputs were absent. A presence-only check confirmed all three missing: `RC_CONTEXT_OPENROUTER_PARENT_TEST_KEY`, `RC_CONTEXT_OPENROUTER_CHILD_TEST_KEY`, and `RC_CONTEXT_OPENROUTER_TEST_MODEL`. Values were never read from personal sign-ins or printed. Therefore no positive child runtime or OAuth-refresh claim is made. When supplied, this probe uses installed Distill, Docker and the actual model, with readiness markers; it does not fake provider status. An OpenRouter scoped API key would not prove OAuth refresh. Existing 45-regression proof was rerun against current source with the listed filter. Live Activity warnings remain. Native packaging (`RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build`) passed with exit 0 from the same tested source tree and a valid signature for team `6SV3W8BFYJ`; executable SHA-256 is `b380476ed18647347d4176de10e72a533c6f98c770ff7cb6acc5ac7967891aad`. S-005/S-006 remain open; UI is unchanged. iOS changes are documentation only. Positive admitted model/child execution remains unverified.

### Context-scoped resume — latest checkpoint

Durable per-conversation scoped resume supersedes the earlier fresh-session-only ceiling; historical evidence remains unchanged. See [CONTEXT-SCOPED-RESUME.md](CONTEXT-SCOPED-RESUME.md) for implementation boundaries, exact-tree verification, skipped test, review history and unverified limits. At macOS tree `04e0466b46e6ed676c2c27d89c86ea1cddab827f`, final selected run passed 60 tests, 1 skipped, 0 failed in 88.147 seconds (exit 0). Real provider session-load after OS process restart and OAuth refresh remain unverified; iOS changes are documentation only.
