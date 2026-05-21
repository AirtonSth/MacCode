# RemoteCode 2 Design System

A single source of truth for the visual language. Implemented as the
`DesignSystemKit` Swift module (`Sources/DesignSystemKit/`), consumed by
every SwiftUI view and mirrored for the AppKit chrome.

## Intent

Dense, dark, developer-grade — the cmux / T3 Code lineage. Maximize
signal density; minimize chrome. No decorative gradients, no shadows on
content (shadows reserved for transient surfaces), hairline 1px borders,
one accent color, a constrained type scale, and a strict 4/8 spacing
rhythm.

Dark is the only V1 theme (the SKILL's `color-dark-mode` rule: design the
dark palette intentionally, do not invert a light one). Light tokens are
deliberately disabled and surfaced as such in Settings.

## Apple Surface Parity Rules

These rules are shared with the iOS design system in
`../ios-app/docs/design-system.md`.

- SSH and Agent App are the approved visual baseline: compact header, dense dark
  content, direct controls, no marketing layout.
- Surface headers use the full available width and stay compact. The active
  surface body gets the rest of the window or device viewport.
- Secondary task modes that become the user's main task must replace the active
  body instead of floating as a partial overlay. On iOS this is mandatory for
  SSH Files; on macOS sidebars/drawers are allowed only when they do not cover
  the primary terminal/editor content.
- Terminal UI is shown only for real usable terminal/session states. Empty or
  disconnected states use a clear empty state and recovery action.
- Host/thread/object menus are grouped by meaning: selection first, current
  object actions next, destructive actions separated, creation last. Avoid
  repeating the object name in every action label.
- iOS may adapt layout for touch and screen size, but it must preserve every
  host capability exposed by macOS.

## Color tokens (`DS.Palette` / `DS.NS`)

| Token | Hex | Use |
|-------|-----|-----|
| `bg` | `#0F1419` | App / canvas background |
| `surface` | `#171D24` | Bars, sidebars, cards |
| `surfaceRaised` | `#1B222B` | Inputs, secondary buttons, raised cards |
| `surfaceOverlay` | `#212A34` | Neutral pill background |
| `line` | `#2A3440` | Hairline borders / dividers (1px) |
| `lineStrong` | `#394654` | Emphasized dividers |
| `text` | `#E7EDF3` | Primary text (≥ 4.5:1 on every surface) |
| `textSecondary` | `#9DA9B5` | Secondary text (≥ 3:1) |
| `textTertiary` | `#6B7785` | Meta, timestamps, captions |
| `accent` | `#7CC7FF` | Selection, primary actions, focus ring |
| `onAccent` | `#0A0E13` | Text on accent fills |
| `success` | `#8EE6A8` | Additions, completed, running-good |
| `warning` | `#FFD37A` | Dirty, tool items, cancelled |
| `danger` | `#FF8F8F` | Deletions, failures, revoked |
| `hover` | white @ 5% | Hover layer over surface |
| `pressed` | white @ 9% | Pressed layer |
| `selection` | accent @ 16% | Selected row/tab background |
| `terminalBG` / `terminalFG` | `#0B0F14` / `#D8DEE6` | Terminal viewport |

Functional color is never the only signal — status also carries a glyph
or label (SKILL `color-not-only`).

## Spacing (`DS.Space`) — 4/8 rhythm

`xxs 2 · xs 4 · sm 6 · md 8 · lg 12 · xl 16 · xxl 20 · xxxl 24 · huge 32`

## Radius (`DS.Radius`)

`control 5 · card 7 · panel 9 · modal 12 · pill 999`

## Typography (`DS.Font`)

System UI for chrome, SF Mono for code/paths/diffs.

`caption2 10 · caption 11 · bodyDense 12 · body 13 · title3 15 · title2 18 · title 22`
plus `mono 12 / monoSmall 11`. Weight expresses hierarchy: 600–700
headings, 400 body, 500 labels (SKILL `weight-hierarchy`). Tabular digits
for counts/diff stats (`number-tabular`).

## Motion (`DS.Motion`)

`micro 160ms ease-out · standard 220ms ease-out · emphasized spring`.
Within the SKILL 150–300ms window; ease-out for entrances.

## Components (`DesignSystemKit/Components.swift`)

- `dsPanel()` — the dense card (surface + hairline + radius).
- `dsBar(edge:)` — top/bottom bar with one hairline edge.
- `DSPill` — status chip, 5 tones (neutral/accent/success/warning/danger).
- `DSIconButton` — compact icon button, hover state, help tooltip.
- `DSPrimaryButtonStyle` / `DSSecondaryButtonStyle`.
- `DSSectionHeader` — uppercased tracked tertiary label + trailing slot.
- `DSEmptyState` — icon + title + subtitle, centered on `bg`.

## Where each screen uses it

| Screen / surface | File | Treatment |
|------------------|------|-----------|
| Workspace sidebar | `AppShell/SidebarView.swift` | App-identity bar, workspace rows with folder glyph + unread pill, indented thread rows with status dot, empty state. |
| Pane tab strip + toolbar | `AppShell/PaneTabsView.swift` | `surface` toolbar: left **+** pull-down, right two split icon buttons (`rectangle.split.2x1` / `1x2`). Below it a custom horizontal tab strip — each tab = SF Symbol icon + truncating title + `×` close button, selected tab on `bg` with a 2px accent underline, unselected on `surface` with hover, 1px inter-tab separators. Close button calls `closeSurface`; tab body click calls `focusSurface`. |
| Agent App | `Surfaces/AgentAppSurface.swift` | Thread rail + compact run-config chip header (provider/model/permission as pill-wrapped pickers, status pill, Stop, plan-notes toggle), conversation timeline (empty state, auto-scroll, error card, user/AI message cards, type-pill item rows with streaming spinner), composer (placeholder + ⌘↩ + primary Send), optional plan-notes sidebar. **No git or terminal here** — git is a workspace-level Git tab, terminal is its own surface. |
| Pane Git button | `AppShell/PaneTabsView.swift` | `arrow.triangle.branch` icon button left of the split icons; opens a Git tab (DiffPanelSurface: changed files + tinted diff) scoped to the workspace cwd. |
| Diff panel | `Surfaces/DiffPanelSurface.swift` | File list with status glyphs + selection, toggle bar, tinted patch body (success/danger/accent/warning), empty states. |
| Feed | `Surfaces/FeedSurface.swift` | Header + token filter field, kind-toned pills, bordered event rows, empty state. |
| Settings | `AppShell/SettingsWindow.swift` | Sectioned tabs, setting rows, CLI availability pills, pairing code, paired-device panels. |
| Command palette | `AppShell/CommandPalette.swift` | `surface` panel, raised search field, divider, token row text colors. |
| Browser chrome | `Surfaces/BrowserSurface.swift` | `surface` toolbar, SF Symbol nav buttons, mono address field, divider, dark blank page. |
| Terminal | `Surfaces/TerminalSurface.swift` + `ANSIRenderer.swift` | Directly interactive (cmux model): `TerminalTextView` is first responder, every keystroke is encoded to VT100/xterm bytes and written to the pty — no bottom input field. Solid inverse block caret at the cursor cell (always visible, survives end-of-line). Selection + ⌘C copy, ⌘V paste-to-pty. `terminalBG/FG`; ANSI default bg clear so the viewport color shows through. New workspaces and both split directions open a terminal by default. |
| Window shell / empty state | `AppShell/MainWindowController.swift` | `bg` window + container, icon+title+subtitle empty state. |

## Accessibility notes

- Every text/background pair targets ≥ 4.5:1 (primary) / ≥ 3:1
  (secondary) on its actual surface.
- Focus ring token (`focusRing`, accent @ 65%) available via
  `dsFocusRing(_:)`.
- Status is never color-only — pills and glyphs accompany every state.
- Icon buttons keep a ≥ 22pt visual / larger hit frame and carry
  `.help(...)` tooltips.

## Changing the system

Edit `Sources/DesignSystemKit/Tokens.swift`. Views reference tokens only
— there is no raw hex in any view file (SKILL `color-semantic`). A token
change propagates everywhere on the next build.
