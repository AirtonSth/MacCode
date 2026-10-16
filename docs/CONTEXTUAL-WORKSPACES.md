# Contextual workspaces implementation and verification

## Scope and baselines

The implementation source is `/Users/samuelfajreldines/dev/remote-code/plan/agent-plan.md` and its adjacent `plan-report.json`. The current objective authorizes product changes and checkpoint commits/pushes, overriding the historical dossier-only restrictions. It does not authorize changes to the running personal host, its database, or production data.

- macOS source repository: `/Users/samuelfajreldines/dev/remote-code/macos-app`; baseline `640bf7662b808df0f8f68ae355f1ad1c7ec2a49f`.
- macOS implementation worktree: `/Users/samuelfajreldines/dev/remote-code/macos-app/.sandbox-worktrees/20261016T013608Z`.
- iOS source repository: `/Users/samuelfajreldines/dev/remote-code/ios-app`; baseline `1db208d05ee0302dadfa186e48197e79abb2d8e6`.
- iOS implementation worktree: `/Users/samuelfajreldines/dev/remote-code/ios-app/.sandbox-worktrees/contextual-workspaces-20261015`.
- Delivery branch in each repository: `feat/contextual-workspaces-20261015`.

No baseline test result is inferred from the commit IDs. The iOS primary checkout has pre-existing untracked `TODO.md` and Xcode Cloud files; those are outside this change.

## Required stage-to-change-and-proof map

This table tracks requirements, not completion claims. An entry remains pending until its shipped paths and observations are recorded below.

| Stage | Product requirements and existing owners | Required proof | Status |
|---|---|---|---|
| S-001 | Explicit context and separate operational memory; human-reviewed export; no autonomous project bridge. Credential, copied-data and resource probes precede restricted execution. | U-001–U-004, V-001; copied fixtures, authentication renewal/revocation, actual runtime measurements. | Decisions authorized by objective; technical probes pending. |
| S-002 | Stable bot identity, unique host/bot/context bindings, versioned policies and central authority. Extend `BotStore`, `BotRemoteControlAuthority` and shared contract. Legacy `workspaceID` is affinity only. | V-002: direct, peer, queue, routine, replay/export allow/deny, guessed resources, stale/revoked revisions; additive migration. | Bindings, immutable pins and scoped-resource refusal verified; contextual resource admission and complete endpoint coverage pending. |
| S-003 | Reuse canonical Agent App thread, actor lock, draft and events. Resolve explicit context before create/send; context fixed after start. New context requires a new conversation and selected summary. | V-003: same IDs across bot/workspace/activity/search/link, destination stable under concurrent selection and windows. | Immutable context/thread pins and collision protection verified; native creation/navigation convergence pending. |
| S-004 | General/project bot projections; preserve workspace panels, bot-free conversations, Studio, teams, Titio and links. Header identifies actor, host/context, runtime and state. Host-scoped restoration and generation guards. | V-004: native navigation/send/Stop/back, empty/busy/offline, keyboard, VoiceOver, Dynamic Type and concurrent windows. Separate human usability trial below. | Existing controls retained; contextual navigation pending. |
| S-005 | Lazy bot/context runtime, isolated operational home/browser/memory; explicit authorized roots or self-contained copy; no mount union or Mac fallback. Restriction unavailable until credentials/filesystem/network/gateway pass. Confirm actual cleanup. | V-005: real A/B markers, cookies, paths/network/tools/cache, provisioning failures, revocation during execution and descendant Stop. | Docker available; current bot-only runtime and broad credential copies are not an isolation proof. |
| S-006 | Contextual teams/groups and peer admission before disclosure. Preserve consult/reply_only/consultation_id; bounded chain, queue, time and budget, cycle rejection, idempotency and supervised recovery. | V-006: same-context collaboration; deny bridges/escalation; cycles, invalid IDs, timeout, duplicates, late replies and descendant cancellation. | Existing collaboration engine retained; contextual extension pending. |
| S-007 | Context/revision revalidation on queue drain/routines; offline durable messages require human send. Authorized attention/search/notifications/replay, host switches and browser parity. Durable content-free authority/cleanup receipts. | V-007: offline/reopen/reconnect, host switch, stale generations, revoke before drain, restart and receipt failures with honest partial cleanup. | iOS destination-safe receipts, unknown-send recovery, replay and timeout checks passed; full contextual propagation pending. |
| S-008 | Additive opt-in migration, copied backup/restore, stable identity/history/queue, old/new client matrix, rollback without revived grants or runs. | V-008: real fixtures and compatibility matrix, two-platform builds/launches, cold and at least five comparable warm samples, measured concurrency bounds. | Pending. |

## Material probes

- **U-001 — scoped credentials:** The existing `DistillGuestCredentials.sync` distributes host access tokens and registered accounts, stripping refresh tokens but not provider authority. Separate directories do not scope those tokens. No restricted execution claim is permitted until actual contextual authentication, renewal, revocation and out-of-scope denial are demonstrated. No personal credentials are copied for verification.
- **U-002 — legacy inventory:** Use synthetic legacy fixtures and copies of test databases. The personal production database remains unopened. Real-data adoption remains conditional on an authorized copied-data inventory; legacy `workspaceID` never creates a binding.
- **U-003 — resource calibration:** Docker CLI and daemon are available (server `29.4.0` at initial discovery). Existing images include `remotecode/computer:r5`; existing containers are not task-owned and must not be modified. Measure task-owned runtime cold/warm, memory and disk before increasing concurrency.
- **U-004 — product decisions:** The current objective authorizes the dossier's proposed separate memory, explicit human export, immutable conversation context, same-identity bindings and contextual runtime direction. It does not turn missing technical probes into passes.

## Native design and usability

Preserve the existing SwiftUI controls, layouts, tokens, composer and browser targets. The prescribed design generator's web/marketing palette and typography yield to the user's preservation requirement and native design systems. All 21 mandatory design skills are installed and were consulted; the consultation ledger is recorded separately before UI implementation. Runtime accessibility and visual proof remain pending.

The human usability trial is a rollout condition, not an automated test result: five new and three experienced participants perform four tasks, identify host/bot/context/result recipient before send, and produce zero wrong-context send/export. At least four new and all experienced participants must complete unaided; prior-work retrieval must not regress against the baseline. No participants or results are claimed here.

## Checkpoint evidence

Historical dossier generation, its council, images and broken formal validator are not product implementation gates.

### Explicit-binding foundation

Schema step 94 adds only `bot_context_bindings`. `BotStore+Contexts` owns explicit grant, revocation and exact host/bot/context/action/revision checks. Unsupported records fail closed and cannot reset policy history. Legacy bot affinity is not a grant. Workspace existence is intentionally a host-boundary responsibility because SQLite has no workspace identity table. This checkpoint is persistence, not a claim that every execution or disclosure endpoint already enforces contexts.

The orchestrator ran `scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextStoreTests|TitioNoticeRepositoryTests.test_step93AppliesOnAVersion92Database'`: 7 tests passed, 0 failed, exit 0. The migration fixture starts before step 94, preserves the bot and existing event history across reopen, and verifies absence of an inferred grant. Tests also cover explicit permissions, wrong targets/actions/revisions, revocation, deleted bots, malformed and future-version policy rows, and revision conflicts.

### Canonical pins and authenticated management

Schema step 95 pins new conversations to one unique thread and context snapshot. Database constraints prevent moving that association or linking a legacy conversation to the same thread, while ordinary title and read-state updates remain available. The reader checks persisted integer storage types instead of accepting SQLite's fractional coercion. Failed pin insertion rolls back both the row and newly inserted cache entry.

Authenticated `bot.context.grant` and `bot.context.revoke` use the existing durable mutation and Bot receipt paths. The host replaces a caller-declared host ID with the authenticated host. Provider Unix entry refuses grants. A scoped resource request, including the router-intercepted fork path, is rejected before any legacy resource handler runs. Stale policy changes receive a known failed receipt rather than an invented successful grant or an unknown execution outcome.

The orchestrator ran the integrated isolated filter `BotContextStoreTests|BotConversationContextTests|BotContextAuthorityTests|BotContextDispatcherTests|BotContextRuntimeTests|TitioNoticeRepositoryTests.test_step93AppliesOnAVersion92Database`: 23 passed, 0 failed, exit 0. This includes real SQLite authority and receipt repositories, fresh-instance durable replay, forged host identity, revoked and fractional policies, canonical thread collision and rollback, normal metadata updates, and pre-router scoped fork refusal. Runtime identity tests establish only distinct storage keys; they are not a real guest isolation probe. Contextual resource execution remains unavailable and is not advertised as implemented.

Final combined checkpoint verification ran the isolated runner over those suites plus `BotRemoteControlAuthorityTests`, `Phase4MutationReceiptContractTests`, `RemoteCodeHostCatalogDispatcherTests` and `ThreadActorRemoteTests`: 196 passed, 0 failed, exit 0. The canonical manifest now matches all 183 actual mutation methods, including the previously omitted existing activity methods; activity selection preflight preserves singular acknowledgment and empty/200-item bulk boundaries. A real local listener probe and `lsof` identified OrbStack listeners on the failing random ports. The test fixture now binds exactly to loopback, retries only an occupied listener port before effects, and cleans up failed handshakes; it does not retry RPC effects or weaken durability/no-replay assertions. The shared URLSession remains unchanged.

Independent review identified three defects and confirmed all three closed after fixes: scoped fork bypass, legacy/contextual thread aliasing, and fractional persisted policy values. No further concrete defect was reported in that focused review. This is a staged authority checkpoint, not completion of all eight product stages.

### iOS destination-safe receipts

Commit `97b6a1a450678bb406c246bf247a9730f7064923` was pushed and read back from `origin/feat/contextual-workspaces-20261015`. Receipt matching and adoption now preserve exact host/bot/conversation/request identity. The orchestrator ran the real `BotSendHandoffTests` XCTest suite on a task-created iPhone 17 / iOS 26.5 simulator: 22 tests passed, 0 failed/skipped, exit 0, including session adoption, foreign-target receipts, queued promotion and relaunch restoration. The exclusive simulator was removed and its absence verified. `scripts/test-test-unit.sh` also passed after including handoff tests in the Bots profile and repairing stale selection assertions.

The earlier broader Bots run failed `ConnectionReliabilityE2ETests.testDroppedSendIsUnknownOnceWithNoBlindResend` at lines 221 and 230. Its fixture consumed a response-loss flag on any background HTTP request rather than the intended send. Commit `07df463e753be08975346493ea5ee35bcd52c59d` scopes the loss to `agent.message.send`, synchronizes arming, and requires the write to land before throwing. The orchestrator reran all three `ConnectionReliabilityE2ETests` on another exclusive simulator: 3 passed, 0 failed, exit 0, and verified simulator removal. This proves the real client reports the accepted-but-lost send as unknown without blind resend and preserves reconnect replay and timeout cleanup. The entire broader profile was not rerun; no full-profile pass is claimed. No native contextual navigation, isolation or human usability result is claimed by these tests.
