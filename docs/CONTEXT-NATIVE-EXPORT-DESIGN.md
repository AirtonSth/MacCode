# Native contextual export review

## Intended boundary and delivered implementation

Native contextual export review now exists in both apps: macOS `BotContextExportModel` and `BotContextExportSheet`, and iOS `BotContextExportPresentation` and `BotContextExportSheet`. The flow selects saved user/assistant excerpts, chooses an explicit send-authorized destination, previews the payload, then confirms with **Confirm and Copy**. Preview locks selection and destination; confirmation binds approval to the frozen request and preview digest. Only after a matching successful export response does the client copy the summary. It does not offer Share.

The export identifies the intended destination context and returns reviewed text to the client for explicit copying. It does not deliver or import content into that context or execute provider work there. No implicit grant or export-content persistence is added. Closing/dismissing invalidates pending client results and prevents copying. An already-sent read-only request may finish; the generation check discards its stale result. Source/host or conversation changes invalidate the review; returning to an earlier source does not revive an invalidated review. The native UI uses platform presentation and existing app-native tokens/components, which take precedence over generic styling conventions.

## Verification status

### Checks completed on 17 October 2026

- macOS: 19 selected tests passed, zero failures/skips, in 3.429 seconds. They exercise the shipped presentation factory, actual AppContext/router/SQLite, explicit selection, frozen destination/request, revoked source permission, one-time copy, and selection of another canonical conversation belonging to the same Bot. Existing backend export and context-authority tests also passed. The optional owned-GUI-fixture generator passed separately (one test).
- macOS packaging: the supported native isolated build passed; deep/strict codesign verification passed. Executable SHA-256: `ca23838977298acc920c2c5e253de83b85f3dc362ff6fb938750d0ce92de2853`.
- iOS: 26 `ConnectionPhaseFourCatalogTests` passed, zero failures, in 9.748 seconds. Presentation tests call the actual HostSession and presentation model with a transport fixture; source invalidation uses actual `BotRemoteSession.selectConversationContext(nil)` and `HostSession.retargetEndpoint`. They verify no stale confirmation request/copy, permanent invalidation, delayed-preview dismissal, and no duplicate confirmation/copy. The recording transport decodes the production request codec, including compressed confirmation bodies; it is not host-authority proof.
- iPhone 17 simulator, iOS 26.5: `testBotContextExportNativeJourney` passed in 98.375 seconds and the existing `testBotContextPickerRetainsDraftWithoutSending` passed in 52.197 seconds, in the same final run. The journey enters through the native Bot menu, selects General, explicitly selects one of two canonical excerpts and Export Target, previews, returns with Back, previews again, confirms/copies once, dismisses/reopens, revokes source access before confirmation, and observes an error with no confirmed export/copy. It checks exact selected IDs/destination and retained menu access.
- iPad Pro 13-inch (M5) simulator, iOS 26.5: the export journey passed in 116.223 seconds. The existing context/draft test passed alone in 58.609 seconds. An earlier combined iPad run stalled on the baseline test's main-run-loop snapshot and failed; the standalone rerun is a bounded successful check, not proof that the combined suite is reliable.
- Native journeys use the DEBUG synthetic host, not a live paired production Mac. The fixture includes a long excerpt and a second unselected excerpt; it returns protocol-shaped results while the real client controls selection/review/copy. Host authority is covered separately by the macOS tests. Screenshots of selection, review, Copied and revoked-source error were captured; iPhone and iPad screenshots were inspected. They show native Form/sheet controls and bounded long-text review, not a redesigned chat/composer.
- Independent source review found no remaining concrete new-delta defect. The earlier macOS test race was corrected by awaiting asynchronous confirmation completion; backend authority was not weakened to satisfy the test. Review did not independently execute tests.

The tested source snapshots are macOS tree `f73fc19d8f1bdfe1ccc3dbcab92b5b755c229113` (Sources/Tests) and iOS tree `9d6b2c68f10ab604b3ea1fcdd564b59aacf3f95a` (App/Tests/UITests/project). Subsequent edits to this document do not change those source subtrees.

### Verification limits and failures retained

macOS native launch and correct Bot/conversation/General/menu readback were observed in an owned fixture. Fresh-token AX operations sometimes returned `stale_state_token`; export menu AXPress/AXPick reported success without an observable sheet or an instrumented callback-entry log. The temporary diagnostics were removed before final tests/package. Native selection/confirmation, keyboard and VoiceOver therefore remain unverified. A reused-fixture relaunch showed Legacy/no threads while SQLite retained its rows; a fresh copy of the original fixture restored the canonical readback. The restore observation remains unresolved, not evidence of data deletion or a completed reopen check. Direct shipped-model/router tests are the bounded native-input fallback, not a GUI pass.

The iPhone largest system Dynamic Type check (`accessibility-extra-extra-extra-large`) failed before reaching export: a Workspaces Bot-navigation error expanded until the Fleet/Bots control was below the viewport. Earlier launch-argument largest-text attempts also failed. This is an open navigation/accessibility issue; the export sheet has no largest-text pass. Reduced motion, full keyboard/focus behavior, full VoiceOver, concurrent windows and human usability trials are not established by these automated checks.

Initial Xcode source-inclusion/compiler issues, compressed test-transport decoding, missing fixture UUID/context readback, and lazy Form control lookup failures were corrected before the successful runs. Zero-test selector runs and failed native journeys are not counted as passes. The earlier shell pipeline's outer zero exit did not make its failing iPad test a pass; final reported outcomes use raw XCTest results and direct xcodebuild exit status.

Only task-owned simulator instances, native app processes and fixture data were used. Owned native windows/processes and the canary socket were closed; the existing debug socket and borrowed simulator were preserved. Final cleanup is verified separately from feature behavior.

### Reproduce the bounded checks

```sh
RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1 RC_CONTEXT_PROBE_ROOT=<caller-owned-root> scripts/isolated-sandbox.sh test --build-system native --filter 'BotContextExportPresentationTests|BotContextExportTests|BotConversationContextTests|BotContextAuthorityTests'
RC2_SWIFT_BUILD_SYSTEM=native scripts/isolated-sandbox.sh build
xcodebuild test -project RemoteCode2App.xcodeproj -scheme RemoteCode2App -destination 'platform=iOS Simulator,id=<exclusive-simulator-id>' -derivedDataPath .build-dd -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemoteCode2AppTests/ConnectionPhaseFourCatalogTests -only-testing:RemoteCode2AppUITests/FlowUITests/testBotContextExportNativeJourney -only-testing:RemoteCode2AppUITests/FlowUITests/testBotContextPickerRetainsDraftWithoutSending
```

This is a bounded addition to stage 4's native context controls and stage 7's explicit export flow. The eight-stage matrix remains open: destination import, durable per-export auditing, contextual provider/delegation execution and credential probes, complete restore/compatibility/capacity coverage, native accessibility gaps and the specified human trials are not delivered by this checkpoint. No merge, release, deployment or contextual-execution enablement is included.

## Skill coverage ledger

Statuses describe design guidance reflected in implementation, not verification results. The source skills were consulted earlier; no reconsultation is claimed here.

| Skill | Phase | Status | Decision / reason | Evidence |
|---|---|---|---|---|
| ui-ux-pro-max | Direction, Review | applied | Native-first review flow; avoid web defaults. | macOS `Sources/AppShell/BotContextExportSheet.swift`: `BotContextExportSheet`; iOS `App/Sources/Features/Bots/BotContextExportSheet.swift`: `BotContextExportSheet`. |
| design-system | Direction | applied | Reuse app-native design tokens/components; no export theme. | macOS `BotContextExportSheet` uses `DS.Space`, `DS.Font`, `DS.Palette`; iOS native SwiftUI `Form`. |
| ui-styling | Direction | not-applicable | CSS and web styling do not apply to SwiftUI. | Both native `BotContextExportSheet` implementations use SwiftUI. |
| brand | Direction | applied | Keep product surface and naming focused on export excerpts. | Both `BotContextExportSheet` titles and source metadata. |
| apple-design | Direction | applied | Use native controls, destination picker, and dismissible presentation. | iOS `BotContextExportSheet` `Form`, `Picker`, `NavigationStack`, `Close`; macOS `Picker`, `ScrollView`, `Close`. |
| emil-design-eng | Direction | applied | Keep review focused; no ornamental treatment. | Both `BotContextExportSheet` implementations. |
| pick-ui-library | Direction | not-applicable | SwiftUI controls already serve the flow; no third-party UI library. | Both native SwiftUI `BotContextExportSheet` implementations. |
| animation-vocabulary | Direction | not-applicable | No custom animation vocabulary; native presentation only. | Both `BotContextExportSheet` implementations; no custom animation code. |
| animate | Build | not-applicable | Web animation does not apply to native SwiftUI. | Both native `BotContextExportSheet` implementations. |
| animate-expo | Build | not-applicable | React Native/Expo does not apply. | Both native `BotContextExportSheet` implementations. |
| mobile-native | Build | not-applicable | This is native SwiftUI, not a separate mobile styling implementation. | iOS `App/Sources/Features/Bots/BotContextExportSheet.swift`: `BotContextExportSheet`. |
| prototype | Build | not-applicable | No alternate prototype requested or implemented. | Both `BotContextExportSheet` implementations. |
| ask-sonner | Build | not-applicable | No web toast system used. | Both native `BotContextExportSheet` implementations. |
| write-swift | Build | applied | Keep selection, target, preview, confirmation, and copy in native SwiftUI. | macOS `BotContextExportModel.preview`, `confirmAndCopy`; iOS `BotContextExportPresentation.previewSelected`, `confirmAndCopy`. |
| design | Build | not-applicable | No standalone graphic asset needed. | Both `BotContextExportSheet` implementations use native text and controls. |
| banner-design | Build | not-applicable | No banner requested or implemented. | Both `BotContextExportSheet` implementations. |
| slides | Build | not-applicable | No slide deck requested or implemented. | Both `BotContextExportSheet` implementations. |
| find-animation-opportunities | Review | not-applicable | No custom motion; native presentation only. | Both `BotContextExportSheet` implementations. |
| review-animations | Review | not-applicable | No custom animation to review. | Both `BotContextExportSheet` implementations. |
| improve-animations | Review | not-applicable | No custom animation to improve. | Both `BotContextExportSheet` implementations. |
| break-ui | Review | applied | Bound selection to 32; handle absent rows/targets, source invalidation, response mismatch, and long preview scrolling. | macOS `BotContextExportModel.toggle`, `preview`; iOS `BotContextExportPresentation.toggle`, `loadTargets`, `validate`; both sheet previews. |
| taste-accessibility (selected optional) | Direction, Review | applied | Provide labeled controls and selected state; further accessibility verification remains pending. | macOS `BotContextExportSheet` accessibility labels/values/identifiers; iOS `BotContextExportSheet` identifiers and selected values. |
| taste-ux-copy (selected optional) | Direction, Review | applied | Use action-specific “Review selected excerpts” and “Confirm and Copy”; no Share or generic confirmation. | iOS `BotContextExportSheet` buttons; macOS `BotContextExportSheet` “Preview” and “Confirm and Copy”. |

## Remaining verification

Run the planned native tests and GUI/device checks. Exercise empty, one, many, unavailable-destination, and long-preview cases; confirm the preview, frozen request, selected destination, and copied text match. Verify dismissal, host/source/conversation changes, keyboard/focus, VoiceOver, and platform layouts. Record results after runs; none are asserted here.

## Verification update: stable rows, binding rebinding and maximum text size

Roots and baselines: iOS `ios-app/.sandbox-worktrees/contextual-workspaces-20261015` at `5e24d1ec1ae78c800dc18695937d265b356f065f`; macOS `macos-app/.sandbox-worktrees/20261016T013608Z` at `862ae1a64dd5ff3555104044c877f32c2e578443`.

Findings from the accessibility-extra-extra-extra-large run:
- The debug fixture rebound only the General binding when the host alias rotated, so the target workspace read failed with -32602. The rebinder now moves every existing binding for the previous host without creating grants or reviving revoked state. Default binding state (active, read/send) is unchanged; the export fixture grants General export explicitly.
- The sheet showed an empty "Selected excerpts" section because rows lived in separate state from the presentation. The presentation now owns an immutable row snapshot taken when the sheet opens.
- UI test selection now freezes a concrete row identifier before scrolling, because `firstMatch` resolved a different lazy row afterwards. The confirmation control is revealed by a drag in the outer form gutter, since the nested summary consumes centered swipes.
- The preview target is a full-width wrapping read-only text instead of a truncated disabled picker; the selection screen keeps the native picker.

Results: 105 iOS unit tests with 0 failures; `testBotContextExportNativeJourney` passed on an iPhone 17 simulator at the largest accessibility text size and on an iPad Pro 13-inch simulator at default size. A red check with the old rebinder fails the preservation assertion as expected. macOS: 20 selected tests with 0 failures, including one that loads the canonical stored excerpts (IDs and bodies) into the embedded Agent App model without provider execution.

Limits: the macOS native export sheet was not driven through the GUI (automation focus and menu limitations), so macOS rendering of the hydrated timeline is not proven; the iOS largest-text Legacy-to-General roster detour failure was a test selector defect (the Bot row sat below the viewport) and is fixed on the iOS side; keyboard, VoiceOver and human usability checks are still pending.

## macOS sheet render and pre-revocation restore re-run

`BotContextExportPresentationTests.testRealSheetRendersSelectionAndFrozenReviewFromRealModel` hosts the shipped `BotContextExportSheet` in an `NSHostingView` bound to the real `BotContextExportModel` created by `BotsViewModel.makeContextExportModel` over a real AppContext fixture, renders the selecting state, then selects one excerpt and a destination, runs the real preview and renders again. It asserts that both states paint content and that the images differ. Five tests in the class passed with 0 failures on macOS tree `8eb11de816ace5fa50febf82a9990ab7546f977b` plus this test. I inspected the PNGs: the selection state lists both stored excerpts with the "Destination" row; the review state shows Destination "Export target" and only the first selected excerpt, with Back and Confirm and Copy controls.

A first run rendered "Source access is unavailable or has changed." because the test dropped its offscreen window, which made the model's `onDisappear` cancel it. The test now keeps its windows alive; no production code changed.

Limits: this is an offscreen render, not a drive of the real app window. Control labels are not drawn by `cacheDisplay` (buttons appear as blank rounded shapes), so button text, the destination menu, keyboard focus, VoiceOver and the NSMenu entry point are still unverified. The earlier mac-use attempt could not open the menu item.

The pre-revocation restore suite `HostDatabaseRestoreTests|BotContextRestoreCompatibilityTests` was re-run on `8eb11de816ace5fa50febf82a9990ab7546f977b`: 8 tests, 2 skipped (export/verify fixtures that need their own environment), 0 failures, including `testPreRevocationBackupCannotReplaceCurrentAuthorityOrReviveRuns` and `testMissingCurrentBindingNeverAdoptsBackupGrant`. No new restore code was needed.

## Continue in destination (macOS)

Plan stage 3 requires "create a new session with the approved summary when continuing in another context". After a confirmed export, the macOS review sheet now offers **Continue in Destination**. It reuses two existing authenticated host methods and adds no endpoint, queue engine or view: `bot.conversation.create` pinned to the reviewed destination context and revision, then `bot.conversation.enqueue` with the exact reviewed summary. The enqueue path already holds the text for explicit human review, so nothing is sent, run or copied into transcript history; the person reviews and sends it in the new conversation.

Guards: the action is inert until the export is confirmed and copied; it needs the source to be current; every response must echo the destination key, revision, conversation ID and `requires_user_send`; a second press creates nothing; a revoked destination refuses at the host and leaves no conversation or queued text. Back resets the state. The existing Bot routing requirement (explicit Distill Main model) still applies and surfaces as the host's error text.

Verification on macOS tree after this change: `BotContextExportPresentationTests` ran 7 tests, 0 failures, including `testContinueInDestinationCreatesNewConversationAndHoldsApprovedSummaryUnsent` (one new conversation pinned to the target, queued text equal to the reviewed summary, review hold still required, no messages or runs, source history intact, no duplicates on repeat) and `testContinueInDestinationRefusedWhenDestinationSendIsRevoked`. A wide run of the export, queue, authority, conversation-pin, dispatcher and `BotsWindowTests` suites executed 516 tests with 1 skipped and 1 failure: `test_peerHandoffMutationWithOneThousandRowsRetainsNineHundredNinetyNineUnderFiftyMillisecondP95`, a latency benchmark already recorded as a baseline failure for this repository and unrelated to contexts; it was not investigated here.

Limits: no iOS counterpart exists yet (the iOS sheet still copies only), the new button is covered by model-level tests and the offscreen render path, not a driven app window, and the destination import is a held queue item, not provider execution, which stays blocked by the open runtime probes.

## Continue in destination (iOS parity)

The iOS export sheet now has the same **Continue in Destination** action as macOS, with the same host contract: after a confirmed copy it calls `bot.conversation.create` pinned to the reviewed destination context and revision, then `bot.conversation.enqueue` with the exact reviewed summary, through the existing `HostSession.invoke` mutation ledger. The queue entry stays held for explicit human review, so nothing is sent or run. The button appears only after the copy, is single-use per review (Back resets it), validates every response against the destination key, revision, conversation ID and `requires_user_send`, and leaves the existing sheet layout otherwise unchanged.

Verification on the iOS tree after this change, on an exclusive iPhone 17 / iOS 26.5 simulator removed afterwards: `ConnectionPhaseFourCatalogTests`, `ConnectionPhaseFourIdempotencyTests` and `ConnectionPhaseFourAuthorityTests` ran 62 tests, 0 failures, including `testContinueInDestinationCreatesPinnedConversationAndHoldsReviewedSummary` (inert before the copy, create pinned to the target with revision 3, queued text equal to the reviewed summary, no `bot.send`, no second create or enqueue on repeat) and `testContinueInDestinationRefusedWhenDestinationRevokedLeavesNothingQueued`. The existing `testBotContextExportNativeJourney` UI journey still passed (1 test, 0 failures, 102 s) on the same simulator type.

Limits: the transport in these tests is a recording fake, not a live host; the new button is not driven by a UI test; no largest-text, VoiceOver or iPad pass was run for it.

## Continue in Destination: largest text and iPad

The `testBotContextExportNativeJourney` UI journey, which now taps **Continue in Destination**, also passed with the simulator content size set to `accessibility-extra-extra-extra-large` (read back with `simctl ui content_size` before the run) on an exclusive iPhone 17 / iOS 26.5 simulator (1 test, 0 failures, 159 s), and at default text on an exclusive iPad Pro 13-inch (M5) simulator (1 test, 0 failures, 111 s). Both simulators were removed afterwards.

Accessibility limits: XCUITest reads the accessibility tree (identifiers, labels, values and hittability), so the new button and confirmation are reachable by assistive technology identifiers, but no actual VoiceOver session, Switch Control, hardware keyboard navigation or reduced-motion pass was run on iOS or macOS. The macOS sheet keeps its existing keyboard shortcuts (default action, cancel) and was only rendered offscreen. These remain unverified.

## Authority matrix re-run on the current tree

On macOS tree `b68bb3ea4b2dfbb9c1d2cc870960da7217c49a80` the isolated native runner executed 13 authority suites that drive the shipped router, dispatcher, authority and SQLite repositories: `BotContextAuthorityTests`, `BotRemoteControlAuthorityTests`, `BotContextDispatcherTests` (direct), `BotContextForkAuthorityTests` and `BotConversationContextTests` (pins, fork/replay), `BotContextQueueAdmissionTests`, `BotContextPublicQueueTests`, `BotContextQueuedMessageTests` and `BotContextColdAdmissionTests` (queue and drain), `BotRoutineDispatchAuthorityTests` and `BotRoutineSchedulerTests` (routine), `BotContextExportTests` (export), and `HostDatabaseRestoreTests` (restore). Result: 147 tests, 2 skipped, 0 failures, 61 s, exit 0. The two skips are the pre-revocation export/verify fixtures that need their own environment.

This is a re-run of existing coverage, not a new single matrix file: no test enumerates principal x context x action across every endpoint in one table, the peer entry is covered through `BotContextDispatcherTests`/delegation tests rather than a live peer run, and real-provider peer behavior is blocked by the absent `RC_CONTEXT_OPENROUTER_*` credentials. Full endpoint coverage therefore remains open.

## Tabular authority matrix (macOS)

`BotContextAuthorityMatrixTests.testAllowDenyMatrixAcrossDirectQueueExportCreateAndNonContextualEntryPoints` drives the shipped `BotRemoteControlAuthority.dispatch` over a real SQLite store with three principals: Bot A (general read/send/export, workspace read/send), Bot B (general read only) and Bot C (read/send but no export, in general and workspace). It asserts an explicit allow or deny for 17 rows across list, select, create, enqueue and export-preview, varying principal, context, conversation-to-context match and policy revision (including stale revisions). It also asserts that `bot.send`, `bot.routine.run`, `bot.routine.create`, `bot.files.list`, `bot.conversation.fork`, `bot.queue.force_now` and `bot.guest.start` refuse a contextual grant instead of inferring one, and that revoking Bot A's general binding denies every previously allowed general row while the independent workspace binding stays usable. It passed (exit 0, 0.21 s).

Validation by mutation: removing only the host's `export` authorization check did not fail the test, because a second `export` check in the action classifier still denied; removing both made the test fail on the export rows (exit 1). The sources were restored afterwards and the tree has no source diff. The first draft of the matrix could not distinguish those checks, so Bot C was added to isolate them.

Limits: peer, routine execution and replay are covered here only as refusals of non-contextual entry points and by the suites listed earlier, not by a live peer or scheduler run; the host-level dispatcher admission and HTTP principal checks are covered by `BotContextDispatcherTests` and `BotContextExportTests`, not by this table.

## Busy and offline states of the export sheet (iOS)

`ConnectionPhaseFourCatalogTests.testOfflineAndBusyStatesNeverCopyOrQueueAndStayRecoverable` drives the shipped `BotContextExportPresentation` over the real `HostSession`. Busy: a second preview issued while the first is in flight sends no second `bot.conversation.export.preview`. Offline: after the transport starts throwing `notConnectedToInternet`, confirmation copies nothing, shows an error, drops the stale review, does not mark the sheet invalidated, and the person can go back and preview again. It passed with 45 other perf/catalog tests (46 total, 0 failures) on an exclusive iPhone 17 / iOS 26.5 simulator. The transport is a recording fake that throws; a real network drop, host switch or the macOS sheet's busy/offline behavior are not covered by this test (the macOS model has its own busy guards exercised in `BotContextExportPresentationTests`).
