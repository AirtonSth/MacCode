# Notifications design coverage — 2026-10-21

All 21 mandatory `sam-design` skills were read. The existing macOS `DESIGN.md` and iOS `docs/design-system.md` govern implementation. This ledger records decisions for this audit, not a claim that every possible design or accessibility check passed.

## Appllama references

Thirty returned screens were inspected. The relevant precedents were OmniFocus 4 Notifications (`1542143627/oth_vbb3t`), Driversnote Notifications (`924418916/oth_mp61u`), Timery Live Activities (`1425368544/oth_nmg15`), and Slack Later (`618783545/oth_5uilg`). They informed grouped native preferences, separation of OS permission from app preferences, and clear state/action wording. Existing app colors, typography, components, and navigation were retained.

| Skill | Status | Concrete decision / evidence |
|---|---|---|
| ui-ux-pro-max | applied; generator blocked | Used the native UX checklist. The installed `scripts` entry is a packaged symlink placeholder rather than an executable directory; no generated palette was used. |
| design-system | applied | Reused Settings category/hero/row controls, DS colors, system fonts, and the existing Activity menu. |
| ui-styling | not applicable | Both surfaces are SwiftUI; no CSS, Tailwind, or Radix work. |
| brand | applied | Direct English copy: “Notifications,” “Local notification categories,” and an actionable permission-denied explanation. |
| apple-design | applied | Native permission deep link, grouped preferences, notification actions, and system Live Activity presentation. |
| emil-design-eng | applied | Kept frequent status controls immediate and stable; made the explicit test button produce an explicit test presentation. |
| pick-ui-library | applied | Existing native components suffice. No dependency added. |
| animation-vocabulary | not applicable | No new motion effect needed identification. |
| animate | not applicable | No web animation. |
| animate-expo | not applicable | No React Native or Expo runtime. |
| mobile-native | not applicable | Native SwiftUI already supplies platform controls and touch behavior. |
| prototype | not applicable | A focused correction to existing screens did not need alternative product prototypes. |
| ask-sonner | not applicable | No React toast system. Native notifications and existing in-app history remain authoritative. |
| write-swift | applied | Preserve value payloads, exact route keys, existing isolation, and the same notification scheduler seam. |
| design | applied | Appllama reference review informed information hierarchy and the dedicated Notifications destination. |
| banner-design | not applicable | No marketing banner or generated artwork requested. |
| slides | not applicable | No presentation requested. |
| find-animation-opportunities | applied | No additional animation was justified for repeated operational updates. |
| review-animations | applied | Retained existing native motion; no navigation-boundary animation added. Reduced Motion runtime remains unverified. |
| improve-animations | not applicable | No animation defect or animation redesign was required. |
| break-ui | applied | Exercised denied authorization, failed scheduling/retry, duplicate concurrent delivery, silent catch-up, missing signing profile, stale activity ownership, exact routes, and narrow/wide Settings. |

## Native evidence

- macOS: Notifications category persisted across view models/relaunch; settings, toggles, permission recovery, and test action exercised through mac-use in `io.remotecode.desktop.debug`. Narrow 1100×780 and wide 1600×960 captures are in the macOS `docs/notifications/evidence/` folder.
- iOS: the real Activity menu exposes local categories and Titio. A real SpringBoard notification tap routes into the fixture's authenticated workspace. Screenshots are in the iOS `docs/notifications/evidence/` folder.
- Physical iPhone: real APNs alert and Live Activity start were observed; the test activity was removed after the end push. These checks used the already installed app, not the new simulator build.

See [delivery verification](delivery.md) for test counts, baseline failures, hardware limitations, and the boundary between APNs acceptance and visible delivery. VoiceOver, acoustic output, and reduced-motion behavior are not inferred from screenshots.
