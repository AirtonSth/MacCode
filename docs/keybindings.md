# Keybindings

RemoteCode 2's default shortcuts are inspired by T3 Code's defaults (`KEYBINDINGS.md`, MIT) and cmux conventions. They are **not yet user-configurable**; the schema below is reserved for a future implementation of `~/.remotecode2/keybindings.json`.

## V1 defaults (hard-coded in the main menu)

| Shortcut       | Command                | Notes |
|----------------|------------------------|-------|
| ⌘N             | New Workspace…         | Opens folder picker. |
| ⌘T             | New Terminal Surface   | In the active workspace. |
| ⌘B             | New Browser Surface    | In the active workspace. |
| ⌘G             | New Agent App Surface  | In the active workspace. |
| ⌘⇧K            | Toggle Command Palette | Floating panel; ESC closes. |
| ⌘W             | Close Window           | Saves session snapshot first. |
| ⌘M             | Minimize Window        | Native AppKit. |
| ⌘Q             | Quit                   | Saves session snapshot. |
| ⌘H             | Hide Application       | Native AppKit. |

## Reserved command IDs

These IDs are reserved so they can be bound when keybinding config lands.

- `terminal.toggle`, `terminal.split`, `terminal.new`, `terminal.close`
- `commandPalette.toggle`
- `chat.new`, `chat.newLocal`
- `editor.openFavorite`
- `script.{id}.run`
- `workspace.create`, `workspace.close`, `workspace.rename`
- `surface.create.terminal`, `surface.create.browser`, `surface.create.agent`
- `surface.split.right`, `surface.split.down`, `surface.split.left`, `surface.split.up`
- `surface.focus.{up,down,left,right,next,previous}`
- `agent.run.stop`, `agent.thread.new`, `agent.thread.resume`

## Schema (planned)

```jsonc
[
  { "key": "mod+j", "command": "terminal.toggle" },
  { "key": "mod+d", "command": "terminal.split", "when": "terminalFocus" },
  { "key": "mod+n", "command": "terminal.new",  "when": "terminalFocus" },
  { "key": "mod+w", "command": "terminal.close","when": "terminalFocus" },
  { "key": "mod+k", "command": "commandPalette.toggle", "when": "!terminalFocus" },
  { "key": "mod+n", "command": "chat.new", "when": "!terminalFocus" }
]
```

`when` expressions follow T3 Code semantics: identifiers like `terminalFocus`, `terminalOpen`, `composerFocus`, with `!` for negation. Last matching rule wins; invalid rules are dropped with a warning event.

## Attribution

Default IDs and `when` semantics adapted from T3 Code (`KEYBINDINGS.md`, MIT). See `THIRD_PARTY_NOTICES.md`.
