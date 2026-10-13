# Notifications implementation design coverage

This ledger covers the native macOS and iOS implementation of `plan-notifications`. All 21 installed skills were consulted. The existing RemoteCode design system, native SwiftUI controls, and accessibility requirements take precedence over generated web palettes or libraries. Paths under `Sources/` refer to the macOS repository; paths under `App/Sources/` and `Tests/` refer to the iOS worktree. Copied native test screenshots live under `docs/notifications/evidence/` in each repository.

Implementation uses three distinct views: Running, Needs you, and Finished. Viewed state and attention acknowledgement remain independent. Counts describe the complete query scope, not the currently loaded page. External notification text stays generic; detailed run summaries remain inside the authenticated app.

| Skill | Phase | Status | Decision or reason | Evidence |
|---|---|---|---|---|
| ui-ux-pro-max | Direction / review | applied | Use its checklist; retain the existing native design system instead of the generated web palette. | Existing DS tokens; Activity layouts and unavailable/error states. |
| design-system | Direction | applied | Reuse DS colors, system fonts, spacing, chips, and native list controls. | `Sources/AppShell/ActivityWindow.swift`; iOS `ActivityView.swift`. |
| ui-styling | Direction | not-applicable | Native SwiftUI; no Tailwind, Radix, or CSS. | Both application stacks. |
| brand | Direction | applied | Keep direct English interface copy and separate failed, stopped, viewed, and acknowledged states. | Activity captions and safe notification copy. |
| apple-design | Direction | applied | Native lists, segmented controls, sheets, keyboard semantics, and labelled accessibility values. | Activity and shared attention controls on both platforms. |
| emil-design-eng | Direction | applied | Prioritize result and required action; avoid decorative motion and duplicate counters. | Activity detail and simplified Pet controls. |
| pick-ui-library | Direction | applied | Add no library; reuse existing SwiftUI and RemoteCode components. | No dependency changes. |
| animation-vocabulary | Direction | not-applicable | No ambiguous new motion effect needs naming. | Navigation and data refresh remain immediate. |
| animate | Build | not-applicable | No web animation in this native task. | SwiftUI applications. |
| animate-expo | Build | not-applicable | Neither application uses React Native or Expo. | Swift application sources. |
| mobile-native | Build | not-applicable | This skill targets mobile web CSS; the iOS surface is native. | SwiftUI controls and platform touch targets. |
| prototype | Build | not-applicable | The approved plan defines one direction, not alternative visual prototypes. | `plan-notifications` specification. |
| ask-sonner | Build | not-applicable | No React or Sonner toast system. | Native notification and inline error handling. |
| write-swift | Build | applied | Use value DTOs, canonical IDs, isolated reads, and owner-checked async effects. | Activity service, stores, DTOs, and regression tests. |
| design | Build | not-applicable | No logo, identity asset, or social image requested. | Native interface scope. |
| banner-design | Build | not-applicable | No advertising banner requested. | Native interface scope. |
| slides | Build | not-applicable | No presentation requested. | Application implementation scope. |
| find-animation-opportunities | Review | applied | Frequent activity updates do not justify entrance cascades, moving targets, or delayed navigation. | No new decorative animation. |
| review-animations | Review | applied | Exact-message navigation uses existing scroll components; reduced-motion verification remains an explicit gate. | Shared transcript scroll targets and native verification report. |
| improve-animations | Review | not-applicable | No unrelated motion audit or redesign requested. | Frozen notifications and model-error scope. |
| break-ui | Review | applied | Cover empty/unknown counts, page limit +1, large counts, long CJK titles, missing summaries, failures, and stale results. | Activity fixtures, unit tests, and native UI test artifacts. |

## Precedence overrides

- Existing DS tokens and system fonts override generated palette, font, and library recommendations.
- Accessibility and truthful state override density, decorative motion, and badge compactness.
- Existing protocol compatibility overrides introducing unsupported Live Activity phase values.
- The task does not authorize production deployment, user-app teardown, provider-model substitution, or additional AI summary calls.

## Verification status

The delivery evidence document records executed checks and native observations. A skill marked applied records a concrete design or implementation decision; it does not by itself establish native interaction, VoiceOver, reduced-motion, device, push, or performance proof. Unverified gates remain listed explicitly rather than inferred from screenshots or passing unit tests.
