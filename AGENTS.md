# AGENTS Instructions

## Language and Communication

- All code, comments, documentation, tests, and commit messages must be written in English.
- Do not introduce non-English prose, labels, or prose-style identifiers in source files.
- Branch and file names should use English words or clear technical abbreviations.

## Existing Project Constraints

- Keep changes aligned with the active architecture and test strategy defined by this repository.
- Preserve compatibility requirements and existing public contracts unless explicitly requested otherwise.
- Desktop UI must always be designed to run inside ElectroBun (native window chrome).
- Do not add simulated desktop chrome in-app: no outer fake window padding, no fake minimize/maximize/close controls, and no fake title bars.
- Live Activity delivery on iOS must use direct APNS. Do not route Live Activity start/update/end through Firebase/FCM.

## Mobile Data Loading Rules

- Workspaces screen must fetch only the workspace list fields required for rendering: `id`, `name`, `path`.
- Threads screen must fetch only the thread list fields required for rendering: `id`, `title`, `updatedAt`.
- Chat screen must fetch only chat context, chat messages, stream events, and runtime metadata needed to render the chat experience.
- Secondary panels (for example, workspace drawers) must load lazily when opened and reuse cache when available.
- Golden rule: each screen must request only the data required by that visible screen.

## Agentic Desktop Automation (Playwright + Electrobun)

- Use test automation assets from `desktop/playwright-e2e`.
- Main smoke command:
  - `bun run --cwd desktop automation:cdp-screenshot`
- Artifact output:
  - `desktop/playwright-e2e/artifacts/electrobun-cdp-screenshot.png`

### Agentic execution protocol

- Prefer this sequence when validating desktop automation:
  1. Run `automation:cdp-screenshot` first to prove CDP is reachable and rendering non-blank content.
  2. Confirm screenshot dimensions match window defaults (`1200x700`) unless the task requires a different size.
  3. Run MCP server with `mcp:playwright-electron` only after CDP smoke is green.
- When a screenshot is blank or missing:
  1. Re-run with explicit window env vars: `ELECTROBUN_WINDOW_WIDTH`, `ELECTROBUN_WINDOW_HEIGHT`.
  2. Re-run with a fresh CDP port via `ELECTROBUN_CDP_PORT`.
  3. Verify no stale app instance is locking the CEF profile before retrying.

### Environment controls

- `ELECTROBUN_CDP=1` enables CEF mode with Chromium remote debugging flags.
- `ELECTROBUN_CDP_PORT` controls CDP endpoint port (default `9333`).
- `ELECTROBUN_WINDOW_WIDTH` and `ELECTROBUN_WINDOW_HEIGHT` control capture viewport size.
- `ELECTROBUN_CDP_TIMEOUT_MS`, `ELECTROBUN_PAGE_TIMEOUT_MS`, `ELECTROBUN_CAPTURE_RETRIES`, and `ELECTROBUN_CAPTURE_RETRY_DELAY_MS` tune startup and retry behavior.
