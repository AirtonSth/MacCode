# Initial design consultation

## Direction

Work concerns existing native RemoteCode macOS and iOS apps, not a new web surface. Keep current dark, dense developer-tool visual language and existing SwiftUI design systems as the baseline: macOS `DS.Palette`, `DS.Space`, `DS.Font`, `DS.Motion` and shared `DesignSystemKit` controls; iOS `DS.Color`, `DS.Space`, `DS.Font`, `DS.Motion`, `DS.Chrome`, and shared `DSCard`/button controls. Preserve current layouts, controls, workflow, and cross-platform parity while adding required navigation/context capabilities. Avoid new UI libraries, web typography, marketing layouts, decorative effects, and gratuitous motion. Keep accessibility, readable contrast, labeling, focus, touch targets, and reduced-motion support. Preserve immediate acknowledgement and honest loading/error states; animation must not delay the first useful frame.

The prescribed `ui-ux-pro-max` generator recommended a Real-Time / Operations Landing pattern, Soft UI Evolution, light/dark palette, Inter, marketing sections, CTA placement, and web breakpoint checks. These suggestions do not fit the native operational product and conflict with current dark-only macOS tokens and compact iOS remote-control UI. Existing repository design takes precedence; none of the generated palette, fonts, pattern, or layout is adopted. Contextual native UI now uses the repository's native components and compact 44-point header; it does not adopt generated styling.

## Coverage ledger

| Skill | Phase | Status | What changed or decided / reason | Evidence |
|---|---|---|---|---|
| ui-ux-pro-max | Direction + Review | applied | Ran prescribed generator; preserve existing native system over generated web/marketing direction. Pre-delivery review remains pending until UI changes exist. | Generator exit 0; result summarized above; checker exit 0. |
| design-system | Direction | applied | Reuse current native token systems; no token changes. | `macos-app/Sources/DesignSystemKit/Tokens.swift`; `ios-app/App/Sources/DesignSystem/DesignSystem.swift`. |
| ui-styling | Direction | not-applicable | Guide is for shadcn/Radix/Tailwind and web styling; target is native SwiftUI/UIKit, with existing controls. | Same native token paths; no web UI. |
| brand | Direction | not-applicable | No copy, logo, identity, or brand-color change requested in design consultation. | Scope is preserving existing UI/UX. |
| apple-design | Direction | applied | Native platform conventions guide gestures, materials, type, and motion; preserve them alongside the established product system. | Native SwiftUI target; contextual header uses native 44-point layout and keyboard-accessible controls. |
| emil-design-eng | Direction | applied | Keep craft focused on hierarchy, responsive feedback, and implementation-specific polish; do not invent new surface or components. | Shared native components; contextual compact header and cached fixed-header behavior verified. |
| pick-ui-library | Direction | applied | No library needed; reuse existing native shared controls and platform frameworks. | Existing design-system modules. |
| animation-vocabulary | Direction | applied | Existing motion tokens name the limited motion vocabulary; avoid new animation without clear interaction need. | `DS.Motion` in both platform token files. |
| animate | Build | not-applicable | Web animation implementation; no web UI or motion change in scope. | Native SwiftUI/UIKit target; no implementation. |
| animate-expo | Build | not-applicable | React Native/Expo only; iOS app uses native SwiftUI/UIKit. | `ios-app/App/Sources/DesignSystem/DesignSystem.swift`. |
| mobile-native | Build | not-applicable | Mobile-web CSS and meta-tag guidance; native iOS app is not a web page. | Native SwiftUI/UIKit target. |
| prototype | Build | not-applicable | No request for alternate visual directions; preservation is explicit. | Goal requires UI/UX closest to current. |
| ask-sonner | Build | not-applicable | Sonner applies to React toasts; no React toast UI is being added or changed. | Native SwiftUI/UIKit target. |
| write-swift | Build | applied | Native SwiftUI is the implementation context; maintain current module ownership and idioms if UI implementation proceeds. No Swift changed now. | Native source/token files; consultation only. |
| design | Build | not-applicable | Umbrella asset guidance is for identity, logos, icons, banners, and slides; none requested. | Scope covers existing app UI. |
| banner-design | Build | not-applicable | No banner, hero visual, ad, or print asset in scope. | Native operational app objective. |
| slides | Build | not-applicable | No presentation or slide deck in scope. | Native operational app objective. |
| find-animation-opportunities | Review | applied | Treat motion as opt-in for meaningful feedback; no changed UI exists to inspect, so opportunity review is pending implementation. | Existing motion tokens; no UI edits. |
| review-animations | Review | not-applicable | No motion was added or changed; review applies when such code exists. | No UI edits in this consultation. |
| improve-animations | Review | not-applicable | No multi-file motion audit or motion roadmap requested; no motion changed. | No UI edits in this consultation. |
| break-ui | Review | applied | Worst-case data testing applies to changed data-driven surfaces; no surface changed, so test remains pending and must not be fabricated. | No UI edits; no runtime proof. |

## Selected optional source

| Skill | Phase | Status | What changed or decided / reason | Evidence |
|---|---|---|---|---|
| taste-accessibility | Direction | applied | Carry accessibility through native controls: readable contrast, visible focus, accessible names, usable targets, explicit non-color status, and reduced motion. Validate against platform behavior rather than copying web-only semantic HTML/WCAG implementation recipes. | Installed skill read; native token/control files inspected. |

## iOS implementation follow-up — commit `8780451af7bd29db26413bd00013526a26328659`

The iOS implementation uses a native authorized-context picker built with existing SwiftUI `List` and `NavigationStack`, and existing menu/header components and design-system tokens. It does not infer grants; the legacy badge remains unchanged when no context exists. Header context labeling for VoiceOver and Large Content Viewer was reviewed and fixed. Narrow-column iPad layout can visually truncate the runtime line; its accessible label remains full, and the sheet is explicit.

Reported verification for this iOS commit: parent final run completed 242 iOS unit/session tests with 0 failures (exit 0). Native iPad Pro 13-inch, M4, iOS 26.5 journey completed 1 pass, 0 failures (exit 0) at 09:28:58; covered tap/cancel, reopen General, settled hydration, type/send refusal, exact draft, and no Bot send or upload. The phone journey passed earlier; stronger assertions also passed after the combined wrapper failed on a fixture test, then the fixture was isolated and corrected and passed. Phone and iPad screenshots were inspected; no viewport dimensions are asserted. No real-host provider, UI grants/revocation, workspace journey, Dynamic Type, VoiceOver navigation, reduced-motion, human-trial, or full-plan verification is claimed.

The initial verification-pending statement below records the consultation-stage state only; it does not supersede this implementation follow-up. The existing skill coverage ledger and consultation claims remain unchanged.

## Precedence and verification

- User requirement to preserve current UI/UX and repository-native token/control systems override generated web direction and visual recommendations.
- Accessibility and native platform behavior remain constraints, not reasons to restyle unrelated UI. No new library or dependency.
- Skill checker: `python3 /Users/samuelfajreldines/.distill/skills/sam-design/scripts/check_design_skills.py` — exit 0; 46/46 available, including all 21 mandatory skills.
- Generator: `python3 /Users/samuelfajreldines/.distill/skills/ui-ux-pro-max/scripts/search.py "native developer tool collaboration assistant macOS iOS SwiftUI preserve existing design system" --design-system -p "RemoteCode"` — exit 0; returned web-oriented pattern, palette, and checklist summarized above.
- Verification is pending. No app or simulator was run; no browser/device, viewport, keyboard, reduced-motion, interaction, worst-case-data, or visual proof is claimed. Perform platform verification on changed surfaces during implementation, including accessibility and data-edge coverage; do not impose web-browser checks on native apps.
