# Electrobun Hello World

A simple Electrobun app to get you started with the framework.

## What You'll See

This hello world app demonstrates:
- **Native Window**: A cross-platform desktop window
- **Web-based UI**: Modern HTML, CSS, and JavaScript interface
- **Simple Architecture**: Clean separation between Bun process and UI

## Getting Started

1. Install dependencies:
   ```bash
   bun install
   ```

2. Run in development mode:
   ```bash
   bun run dev
   ```

3. Build for production:
   ```bash
   bun run build
   ```

## Headless Backend Server

To run only the desktop backend without Electrobun, Vite, or the desktop UI:

```bash
bun run start:server
```

To start the backend and also authenticate the private relay:

```bash
bun run start:server --login=dev@example.com --password=super-secret
```

Notes:
- `--login` and `--password` are optional, but they must be provided together.
- When credentials are provided, startup only succeeds after the private relay is connected and ready for web/private access.
- If login fails or the relay never becomes ready, the process exits non-zero.
- The command still respects the existing server environment variables such as `REMOTECODE_SERVER_HOST`, `REMOTECODE_SERVER_PORT`, `REMOTECODE_LOCAL_TOKEN`, `REMOTECODE_DB_PATH`, and `REMOTECODE_PRIVATE_BACKEND_URL`.

## Project Structure

```
src/
├── bun/
│   └── index.ts      # Main process - creates and manages windows
└── react/
    ├── index.html    # Your app's UI
    ├── index.css     # Styles
    └── main.tsx      # View bootstrap
```

## Next Steps

Ready to build something more complex? Check out:

- **[Documentation](https://docs.electrobun.dev)** - Learn about all Electrobun features
- **[Examples](https://github.com/blackboardsh/electrobun/tree/main/playground)** - See advanced features like RPC, menus, and system tray
- **[GitHub](https://github.com/blackboardsh/electrobun)** - Star the repo and join the community

### Add More Features

Want to extend this app? Try adding:
- RPC communication between Bun and webview
- Native menus and system tray
- File dialogs and system integration
- Multiple windows and views

Happy building! 🚀

## Playwright MCP for Electron Automation

To run Playwright MCP Server against this Electrobun app:

```bash
bun run --cwd desktop mcp:playwright-electron
```

Optional overrides:

```bash
ELECTROBUN_EXECUTABLE_PATH="/absolute/path/to/electrobun" PLAYWRIGHT_MCP_PORT=8931 bun run --cwd desktop mcp:playwright-electron
```

The server starts in SSE mode on `http://localhost:8931` and prints the MCP client
snippet on startup.

MCP config template:
- `desktop/playwright-e2e/playwright-electron.mcp.json`
- Automation utilities overview:
  - `desktop/playwright-e2e/README.md`

## CEF + CDP Screenshot Automation

For automation via DevTools/CDP (works with BrowserView when CEF is enabled):

```bash
cd desktop
ELECTROBUN_CDP=1 ELECTROBUN_CDP_PORT=9333 ELECTROBUN_WINDOW_WIDTH=1200 ELECTROBUN_WINDOW_HEIGHT=700 bun run automation:cdp-screenshot
```

This launches the app with `bundleCEF=true`, enables:
- `--remote-debugging-address=127.0.0.1`
- `--remote-debugging-port=<ELECTROBUN_CDP_PORT>`
- `ELECTROBUN_WINDOW_WIDTH` / `ELECTROBUN_WINDOW_HEIGHT` (defaults: `1200x700`)

and captures a screenshot from the active page using `puppeteer-core` into
`desktop/playwright-e2e/artifacts/electrobun-cdp-screenshot.png`.
