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

Limits: the macOS native export sheet was not driven through the GUI (automation focus and menu limitations), so macOS rendering of the hydrated timeline is not proven; the largest-text route through the Legacy-to-General roster detour intermittently hangs and remains unresolved; keyboard, VoiceOver and human usability checks are still pending.
