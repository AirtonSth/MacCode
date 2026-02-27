# remodecode.io

**Code anywhere. Continue everywhere.**

remodecode.io lets developers continue their local AI coding sessions (Claude Code or Codex) directly from their mobile devices.

A lightweight server runs on your computer (macOS, Windows, or Linux) and securely streams your active coding sessions to a native iOS or Android app. Your repositories never leave your machine. Your AI tools keep running locally. Your phone becomes a remote control for your coding workflow.

---

## 🚀 The Idea

Modern AI coding tools like **Claude Code** and **Codex** are powerful — but they’re tied to your desktop.

remodecode.io bridges that gap:

- Start a session on your desktop.
- Walk away.
- Continue from your phone.
- Review diffs.
- Send instructions.
- Monitor tool output.
- Resume exactly where you left off.

Your computer does the work. Your phone becomes the interface.

---

## 🧠 How It Works
Mobile App (iOS / Android)
⇅ secure websocket
Local remodecode Server (Desktop)
⇅
Claude Code / Codex CLI
⇅
Your local repositories

### 1. Local Server

A small background server runs on your computer:

- Manages allowed project folders
- Launches and manages Claude Code / Codex sessions
- Streams structured events to mobile
- Persists session state
- Handles authentication and pairing

The server is **local-first** and does not require a cloud relay.

### 2. Secure Connection

The mobile app connects via:

- Local network (LAN)
- Or VPN (recommended: WireGuard / Tailscale)

Pairing is done via QR code:

- Server generates a one-time pairing token
- Mobile scans QR
- Long-lived secure token stored in device keychain

No public SSH ports required.

---

## 📱 Mobile App Experience

The mobile app mirrors a developer-native workflow.

### Sidebar

- Favorite Projects
- Recent Chats
- Session metadata (diff stats, timestamps)
- Quick access to Settings

### Chat View

- Streamed AI responses
- Git diffs summary (+added / -removed)
- Logs and tool output
- Structured messages
- Session controls

You can:

- Open an existing session
- Start a new session
- Send instructions
- Monitor running tools
- Resume after disconnect

---

## 🖥 Desktop Client (Optional UI)

A desktop client UI provides:

- Project selection
- Session history
- Model selector (Claude Code / Codex)
- Access level control (e.g., read-only / full access)
- Live streaming view

You can switch models per session: Claude Code | Codex

Sessions remain tied to a specific provider but can be created freely.

---

## 🔄 Session Model

### Project

- Name
- Allowed local path
- Favorite flag
- Last opened timestamp

### Chat Session

- Provider (Claude Code / Codex)
- Title
- Project reference
- Diff summary (+/-)
- Status (idle, running, error)
- Message history

### Streaming Events

The server emits structured events:

- `assistant_delta`
- `assistant_done`
- `log`
- `git_diff_update`
- `tool_start`
- `tool_end`

Mobile apps render these in real time.

---

## 🔌 Communication Layer

remodecode uses:

- WebSocket (or Socket.IO with websocket-only transport)
- Token-based authentication
- Room-based session streams
- Automatic reconnection

One mobile connection can join multiple session streams.

---

## 🔐 Security Model

Security is local-first.

- No repository data leaves your machine.
- Only explicitly allowed folders are accessible.
- Pairing via one-time QR token.
- Long-lived access token stored in secure storage.
- TLS recommended (or VPN layer).

Best practice:
Use WireGuard or Tailscale instead of exposing ports publicly.

---

## 📦 MVP Scope

The minimal viable version includes:

- Local server
- Allowlisted project folders
- Session creation & persistence
- Claude Code / Codex subprocess streaming
- Real-time mobile streaming
- Reconnection support
- Diff summary display

---

## 🛣 Future Roadmap

- Structured diff previews
- File-level change cards
- Inline patch approval from mobile
- Background session monitoring
- Push notifications on task completion
- Read-only audit mode
- Remote container support
- Multi-machine switching
- Team mode

---

## 🎯 Philosophy

remodecode.io is not a cloud IDE.

It does not replace your editor.

It extends your existing workflow beyond your desk.

Your machine remains the source of truth.
Your tools stay local.
Your AI sessions continue anywhere.

---

## 🧩 Why Not Just SSH?

SSH gives you a terminal.

remodecode gives you:

- Structured sessions
- Diff awareness
- Model switching
- Event streaming
- Reconnection logic
- Mobile-native UX

It is built specifically for AI-assisted coding workflows.

---

## 🧪 Target Users

- Developers using Claude Code or Codex locally
- Engineers running multi-repo workflows
- Founders managing code changes on the go
- Developers who want continuity without cloud IDEs

---

## 🏷 Name

**remodecode.io**

Remote mode for code.
Continue anywhere.