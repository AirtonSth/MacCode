# Canonical contextual navigation — design and verification

## Existing-system-first direction

This checkpoint extends existing navigation rather than replacing either app's layout. macOS Activity and Scheduled Tasks use the shared canonical destination resolver: an authorized context-pinned Bot conversation takes precedence over its workspace fallback. Unpinned workspace threads preserve their existing destination. iOS adds “Open Bot conversation” to the existing workspace thread actions menu and resolves the requested thread/conversation through fresh host-owned read grants and canonical conversation metadata. Actor and workspace fields identify a candidate, never authority.

Reuse current DS typography, spacing, colors, native menus and sheets. Preserve Studio, teams, Titio, browser, workspace selection, pin/rename/read/export/delete controls and bot-free conversations. No new sidebar, chat engine, library, palette or decorative animation is introduced. Exact targets must fail visibly when unavailable rather than open another Bot, context, thread or host. Bound drafts remain with their existing conversation; an unbound draft must be saved or cleared before changing context, matching the existing selector policy. Owned asynchronous progress disables stale chat interaction and provides Cancel; superseded tasks cannot clear a newer owner's progress or destination.

The required UI-UX Pro Max generator suggested a real-time operations web pattern, OLED colors and Fira typography. Those suggestions are overridden by the user's preservation requirement and both products' existing native design systems. The generator was consultation only and did not write a new design system into either product.

## Consultation evidence

The installed checker `python3 ~/.grok/skills/sam-design/scripts/check_design_skills.py --json` completed with exit 0: all 21 mandatory skills installed. Every mandatory installed `~/.grok/skills/<skill>/SKILL.md` was read in manifest phase order; the ledger records SHA-256 prefixes of those successful reads. The generator `python3 ~/.grok/skills/ui-ux-pro-max/scripts/search.py 'native productivity workspace bot thread navigation' --design-system -p 'RemoteCode Navigation Consultation'` completed with exit 0. Existing-system and platform guidance override generated web advice. No optional visual genre or new component catalog is needed for this constrained native extension.

| Skill | Phase | Status | Applied decision / not-applicable reason | Evidence |
|---|---|---|---|---|
| ui-ux-pro-max | Direction + Review | applied | Ran required generator; rejected its new web-like visual direction in favor of existing native systems. | `search.py` result below; installed skill read, SHA-256 `ea087c34…` |
| design-system | Direction | applied | Extend existing tokens/components only; no new system. | Read, `8aa5ff93…`; repo sidebar |
| ui-styling | Direction | not-applicable | No Tailwind, shadcn, or web styling work. | Read, `625e302c…` |
| brand | Direction | applied | No identity or palette changes; the new action uses established Bot/conversation terminology. | Read, `1c241396…` |
| apple-design | Direction | applied | Keep platform-native navigation, expected selection behavior, and existing layout. | Read, `77bb63b7…`; macOS `SidebarView.swift` |
| emil-design-eng | Direction | applied | Prefer one small, legible contextual extension; no decorative redesign. | Read, `ffbe68e6…` |
| pick-ui-library | Direction | not-applicable | No new capability or library needed. | Read, `675fdce3…` |
| animation-vocabulary | Direction | not-applicable | No motion requested. | Read, `40d2b27a…` |
| animate | Build | not-applicable | No web animation work. | Read, `b8ede161…` |
| animate-expo | Build | not-applicable | App is native SwiftUI, not Expo. | Read, `9a01a917…` |
| mobile-native | Build | not-applicable | Web mobile techniques do not apply to native iOS. | Read, `888b7651…` |
| prototype | Build | not-applicable | User asks for smallest extension, not visual alternatives. | Read, `bba39c95…` |
| ask-sonner | Build | not-applicable | No React toast work. | Read, `39f3ee18…` |
| write-swift | Build | applied | Existing SwiftUI/AppKit routing, native menu controls, and typed host/context checks are reused. | Read, `16a4b6ad…`; macOS sidebar |
| design | Build | not-applicable | No identity assets in scope. | Read, `c84f3ecf…` |
| banner-design | Build | not-applicable | No banners in scope. | Read, `ccb89ddc…` |
| slides | Build | not-applicable | No presentation in scope. | Read, `86c07f19…` |
| find-animation-opportunities | Review | not-applicable | No extra motion is justified; existing native navigation and owned progress provide feedback. | Read, `d52a3778…` |
| review-animations | Review | not-applicable | No animation changed. | Read, `6ff590d2…` |
| improve-animations | Review | not-applicable | No multi-file motion roadmap requested. | Read, `73962447…` |
| break-ui | Review | applied | Negative route fixtures cover revoked, foreign, stale and mismatched destinations; native worst-case verification is recorded below. | Read, `e7eec1d7…` |

## Verification scope

Relevant checks cover workspace/Bot/context/conversation/thread identity, current host/read grant, unchanged legacy routing, revocation, malformed or foreign metadata, exact ID mismatch, asynchronous owner changes and saved drafts. Native journeys must exercise the existing workspace thread action and Activity destination, not only render a screenshot. Full sidebar grouping, every notification/deep-link variant, simultaneous-window behavior, complete accessibility/human usability trials and the rest of the eight-stage plan remain pending unless separately proven.

## Current test evidence

- macOS tree `60454b90236477126e15cfadf31ed56b2cf237a5`: native isolated filters `ActiveThreadsWindowTests|AgentSurfaceThreadBindingRouterTests` passed, 57 tests, 0 failures, exit 0, 46.272 seconds. Coverage includes real Activity open to the exact visible Bot Desk, including cold-cache; legacy uncached/unlinked and linked workspace selection; and revoked pinned context with no mutation. Earlier compile errors (`??` and optional chaining on `NSWindow`) were fixed. A teardown crash was fixed with test-only `isReleasedWhenClosed=false`. Source and tests were not modified for this documentation update.
- iOS tree `1edace211cc005ebd2fadace678cc60b5fb9c068`: filters `IOSLoadingBotsTests/ReadyForYouPresentationTests/BotRemoteControlTests` passed, 254 tests, 0 failures, exit 0, 10.040 seconds. Coverage includes pending-send refusal, orphan-draft refusal, fresh same-context target, and cancellation/owner fences. Source and tests were not modified for this documentation update.
- Real iPhone UI test passed on tree `7c28cf5d584dadfbd1cf9870c9956105fff90b1c`: `FlowUITests/test_realHostContextAccessCanonicalNavigation`, 1 test, 0 failures, exit 0, 89.569 seconds. Run used task-exclusive clean iPhone 17 / iOS 26.5 and signed packaged debug macOS host tree `60454b90236477126e15cfadf31ed56b2cf237a5`, port 18228. Native pair had a bound General draft, system-thread URL workspace, and separate workspace Agent draft. Existing Thread actions → “Open Bot conversation” twice opened exact workspace canonical chip/context; General draft restored and workspace Agent draft remained. Five captures were exported: parent opened workspace Agent, canonical workspace Bot, and restored General. No model Send was performed; execution remains unavailable.
- UI test fixes changed only system-URL delivery (removed `app.open` relaunch reset) and made absent General-chip assertion safe. Unit and app tests remain unchanged from tree `1edace211cc005ebd2fadace678cc60b5fb9c068`. Warm reuse attempts 2 and 4 failed readiness before navigation; fresh simulator was required by real-pair setup. Cause of readiness loss is unproven; do not claim warm reconnect. Earlier UI attempts 1 and 3 failed test-harness URL delivery / absent-element assertion, not passes.
- Cleanup verified exact PID 86364 gone, port 18228 without listener, simulator `81E1ADE7-8B98-4C8D-815E-82EF5A3BB3AC` deleted, two task-created copied navigation fixture roots removed, and debug window list empty. Pre-existing sandbox home and personal host untouched.
- `mac-use` input failed with `stale_state_token`. The verification plan permits an actual AppKit action and readback fallback for this environmental failure; the passing Activity test exercises that path. This does not establish a successful `mac-use` input run or completion of the full plan.

Full sidebar grouping, every notification/deep-link variant, simultaneous-window behavior, complete accessibility/human usability trials and the rest of the eight-stage plan remain pending unless separately proven.

## Notification and Pet entrance checkpoint

On macOS tree `c154ebc182d2f2035a7a17ef7d57d669ff734b20`, combined native isolated filters `NotificationDeepLinkRouteTests|PetWorkspaceSurfaceRoutingTests|PetAttentionStoreTests|ActiveThreadsWindowTests|AgentSurfaceThreadBindingRouterTests|PerfMainThreadHogsTests.test_petResolvesLinkedBotOnceOffMainAndReusesItAcrossActiveRunRefreshes` passed 109 tests, 0 failures, exit 0, in 50.724 seconds. The AppKit notification dispatcher pinned the exact workspace/General Bot conversation; revoked or foreign destinations stayed in place. Message reveal fenced the exact Bot and conversation. Pet's actual `onOpenItem` and `onOpenActiveThread` paths used the same canonical context and refused revoked targets; an actionable question remained unacknowledged. Store verification received the same refreshed item, with regression coverage catching `attentionID` retargeting from A to B. A reviewer identified a stale-source P1 before the fix; follow-up review resolved it. Existing legacy routing and linked-cache performance remained preserved.

No layout, tokens, or UI controls changed; ledger direction remains unchanged. AppKit tests used the existing environmental native-input fallback for `stale_state_token`. This does not establish physical mac-use clicks or a new packaged-host end-to-end run for this follow-up. iOS remained unchanged: published commit `eae9b77504964bb9afa5bdf9b1c97fbdf57d0934` retains its 254 passing tests and the prior actual-iPhone proof.

Earlier Pet test failures came from no durable run history: `listAttention` deliberately excludes linked empty threads. The fixture was corrected to include a synthetic completed run and durable question. The async test harness runloop hung; its owned process 17590 was killed, the test was converted to synchronous form with a bound, and the exact orphan fixture was removed. Port 18228 had no listener. Source matches the tested tree except for this documentation update. Sidebar, accessibility, full isolation, and human-trial gaps remain; this checkpoint does not claim the full plan is complete.
