# Playwright E2E Utilities

This folder contains TypeScript utilities for desktop automation against Electrobun.

## Commands

- Start Playwright MCP server (Electron mode):
  - `bun run --cwd desktop mcp:playwright-electron`
- Capture a CDP screenshot (CEF mode):
  - `bun run --cwd desktop automation:cdp-screenshot`

## Artifacts

- Screenshot output:
  - `desktop/playwright-e2e/artifacts/electrobun-cdp-screenshot.png`

The `artifacts` folder is ignored by git.

## Useful Environment Variables

- `ELECTROBUN_CDP_PORT` (default `9333`)
- `ELECTROBUN_WINDOW_WIDTH` (default `1200`)
- `ELECTROBUN_WINDOW_HEIGHT` (default `700`)
- `ELECTROBUN_CDP_TIMEOUT_MS` (default `120000`)
- `ELECTROBUN_PAGE_TIMEOUT_MS` (default `60000`)
- `ELECTROBUN_CAPTURE_RETRIES` (default `6`)
- `ELECTROBUN_CAPTURE_RETRY_DELAY_MS` (default `1200`)
- `ELECTROBUN_SKIP_WHITE_CHECK=1` to disable blank-frame protection
