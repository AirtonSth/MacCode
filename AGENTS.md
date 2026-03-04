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

## Mobile Data Loading Rules

- Workspaces screen must fetch only the workspace list fields required for rendering: `id`, `name`, `path`.
- Threads screen must fetch only the thread list fields required for rendering: `id`, `title`, `updatedAt`.
- Chat screen must fetch only chat context, chat messages, stream events, and runtime metadata needed to render the chat experience.
- Secondary panels (for example, workspace drawers) must load lazily when opened and reuse cache when available.
- Golden rule: each screen must request only the data required by that visible screen.
