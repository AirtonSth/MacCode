# Bot conversation grouping design

## Direction

Use existing native sidebar/list structures and existing design tokens, glyphs, and row treatments. In the macOS `SidebarRootView`, place General first, then workspaces; show small indented Bot conversation links immediately beneath each matching workspace. In the iOS Workspaces `List`, use the same hierarchy with existing workspace buttons and context menus. Preserve workspace reorder controls/semantics, search, and existing Studio, teams, Titio, and browser sections.

Show only read-only bindings for explicitly authorized Bots on the current host. Bind each row to canonical Bot and conversation IDs and open those exact IDs. Use the existing canonical conversation title as subtitle. For authorized Bots with no existing conversations, show a disabled, readable “No conversations” row. Never grant access implicitly, create a conversation, or infer cross-host availability. Each conversation row is individually actionable, not a group-selection or management surface.

Preserve workspace-row focus and reorder behavior. Enabled Bot links are ordinary native navigation targets after their workspace, with visible system focus. Disabled empty rows are readable but not actionable. Opening a link selects that exact conversation. Navigation return scroll/focus restoration is not fully verified and remains pending; do not claim it. Do not add shortcuts. Implemented accessibility includes full-context Bot/title labeling and the disabled trait for empty rows; selected-state announcement is not implemented. Keep section semantics; do not announce decorative glyphs or duplicate titles in hints.

Use existing system text styles and row components. Do not shrink hit targets or hard-code row heights. Long iOS titles may wrap; truncated titles remain fully available through macOS tooltip/accessibility label or iOS VoiceOver label. Keep native density and separators; add no custom animation. Search only authorized current-host rows through existing search behavior, retaining workspace/Bot context when matching conversations. Prioritize Bot identity and the start of conversation title in narrow layouts; retain the full title accessibly. Keep “No conversations” literal and non-actionable.

## Data and loading constraints

macOS performs sidebar reads asynchronously off the main thread and coalesces refresh work. Discard superseded reads so stale results cannot replace newer host/workspace state.

iOS uses only the three existing read-only RPCs, with structured task cancellation and host-identity fences. On tap, use the existing exact-fresh resolver for the selected conversation. Keep workspace controls and reorder behavior intact, with one `VStack` per workspace.

## Implementation and verification status

Applied implementation: macOS `Sources/AppShell/SidebarView.swift`; regression/negative fixtures: `Tests/AppShellTests/SidebarAuthorizedBotConversationTests.swift`. iOS implementation: `App/Sources/AppShell/MirrorShell.swift`, `App/Sources/Features/Bots/BotModels.swift`, `App/Sources/Features/Bots/BotRemoteSession.swift`; regression/negative fixtures: `Tests/IOSLoadingBotsTests.swift`, `UITests/FlowUITests.swift`.

macOS Sources/Tests evidence: tree `f543243637e675282b43da3a0885caa84cfe2319`, 25 tests, 0 failures, exit 0, 5.629 sec. Coverage includes a real-AppKit VM tap and a queued-revocation stale-result test. The packaged app AX tree and 3200×2000 screenshot showed General, a readable disabled “No conversations” row, and workspace children. Native AX input returned `stale_state_token` despite `user_activity: none`; a direct physical click is not proven. Earlier busy, wrong-back, and gesture-test failures were resolved.

iOS App/Tests/UITests evidence: tree `e37a8aedca19f0816b6388041514e4635f966cb3`; 260 unit tests, 0 failures, exit 0, 10.110 sec. Real-host UI journeys passed on task-exclusive iPhone 17 and iPad Pro 13-inch (M4) simulators in 100.345 sec and 112.473 sec respectively (one UI test each, 0 failures, exit 0, iOS 26.5 runtime, same real copied-Mac host). The iPad simulator content-size query returned `accessibility-extra-extra-extra-large`. Actual UI verified disabled “No conversations”; General’s exact chip before any selector repair; workspace group link with exact chip/context; revealed but did not activate native Pin/Remove swipe actions; regular Agent thread action; and retained General/workspace Agent drafts. Six captures per device were exported; parent opened grouping, workspace Bot, and restored General screenshots on both devices. Header accessibility variant stacks headline above existing controls; normal iPhone layout is preserved; Bot rows meet 44 pt minimum.

The newest-row selection used canonical host/Bot/context/policy, with zero implicit grant, conversation creation, or Send. Held-reply cancellation and actual retarget endpoint foreign-pin behavior are unit-covered. Native gestures stayed within the actual List viewport because translated child AX frames can extend beyond the iPad sidebar; no policy or test-navigation bypass was used. Four independent-review findings were fixed; final follow-up found no defects. Cleanup verified PID 32399 gone, port 18228 absent, owned simulators `66AF9F1C-964A-4E37-9162-F3BD60C47A84` and `51D0A470-B091-4D1C-9765-E8EDEFFA0187` deleted, one copied group fixture removed, and debug-window list empty. Pre-existing sandbox home and personal host were preserved.

Pending: full keyboard and VoiceOver validation, human trials, warm reconnect, public-provider isolation, and remaining eight stages. Narrow iPad sidebar truncates long existing headers/labels; pixel-perfect layout, whole-product VoiceOver behavior, and overall usability are not established. Navigation-return scroll/focus restoration remains unverified. Earlier mock-roster, argument-order, and semaphore-test failures were resolved.

## Design skill coverage ledger

All 21 installed `SKILL.md` files were read in Direction, Build, and Review phase order. Hashes below were recomputed directly from installed file bytes. Checker: `python3 /Users/samuelfajreldines/.grok/skills/sam-design/scripts/check_design_skills.py` — exit 0, `46/46 installed`. Generator: `python3 /Users/samuelfajreldines/.grok/skills/ui-ux-pro-max/scripts/search.py "native productivity workspace navigation" --design-system -p "RemoteCode Existing Native Grouping"` — exit 0. Existing native design system takes precedence over generic generator recommendations.

| Skill | Phase | Status | Application / evidence |
|---|---|---|---|
| ui-ux-pro-max | Direction + Review | applied | Native navigation, accessibility, disabled state, Dynamic Type, truncation; hash `ea087c341bfb`; generator exit 0. |
| design-system | Direction | applied | Reuse native rows, tokens, type, glyphs; hash `8aa5ff933205`. |
| ui-styling | Direction | not-applicable | No web styling system changes; native sidebar/List uses existing tokens; hash `625e302c60ee`. |
| brand | Direction | not-applicable | No brand voice, identity, or marketing change; hash `1c24139633e2`. |
| apple-design | Direction | applied | Native controls, hierarchy, focus, restrained interaction; hash `77bb63b7043b`. |
| emil-design-eng | Direction | applied | Predictable, interruptible interaction; no decorative motion; hash `ffbe68e6007f`. |
| pick-ui-library | Direction | not-applicable | Existing native apps; no library/dependency decision; hash `675fdce30868`. |
| animation-vocabulary | Direction | not-applicable | No motion concept or motion proposal; hash `40d2b27adfdf`. |
| animate | Build | not-applicable | No animation requested; hash `b8ede1612704`. |
| animate-expo | Build | not-applicable | Native iOS, not Expo; no animation requested; hash `9a01a91701e6`. |
| mobile-native | Build | not-applicable | Browser viewport and CSS guidance does not apply to SwiftUI; hash `888b7651d66d`. |
| prototype | Build | not-applicable | Fixed hierarchy/interaction; no alternate direction requested; hash `bba39c955eb1`. |
| ask-sonner | Build | not-applicable | No web toast surface; hash `39f3ee185b3a`. |
| write-swift | Build | applied | Swift implementation reviewed/applied in the files listed above; hash `16a4b6adb74e`. |
| design | Build | not-applicable | No asset, logo, slide, or broad visual deliverable; hash `c84f3ecfd6a0`. |
| banner-design | Build | not-applicable | No banner/campaign asset; hash `ccb89ddc848f`. |
| slides | Build | not-applicable | No presentation deliverable; hash `86c07f19ec09`. |
| find-animation-opportunities | Review | not-applicable | No animation-opportunity request; avoid new motion; hash `d52a377819b8`. |
| review-animations | Review | not-applicable | No animation implementation to review; hash `6ff590d29e43`. |
| improve-animations | Review | not-applicable | No motion audit requested; hash `739624474644`. |
| break-ui | Review | applied | Negative/worst-case fixtures applied in `Tests/AppShellTests/SidebarAuthorizedBotConversationTests.swift`, `Tests/IOSLoadingBotsTests.swift`, and `UITests/FlowUITests.swift`; hash `e7eec1d70ac5`. |

Browser-only mobile guidance is not treated as a native implementation requirement; the native minimum touch target comes from platform and accessibility guidance. User authorization/layout constraints control; native product design and platform conventions override generic styling. Unit results above do not establish end-to-end, device, accessibility, or human validation.
