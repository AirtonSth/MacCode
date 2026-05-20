# Third-Party Notices

RemoteCode 2 is implemented in-house, but its design takes inspiration from two open-source projects. No source code from either project is currently copied into this repository; this file exists so that when we adapt patterns, attribution is already in place.

## cmux

- Repository: https://github.com/manaflow-ai/cmux
- License: GPL-3.0-or-later **or** commercial (dual-licensed). Copyright (c) 2024-present Manaflow, Inc.
- Use in RemoteCode 2: behavioral reference only. We study the cmux Swift code under `~/dev/remotecode2/.references/cmux/` for window/workspace/pane/surface architecture, terminal/browser surfaces, socket/CLI shapes, session restore, and notifications. **No cmux source is currently copied into RemoteCode 2.** If we later choose to adopt cmux code, a license decision must be recorded in `project/09-risks-decisions.html` and this file must list the affected files.

## T3 Code

- Repository: https://github.com/pingdotgg/t3code
- License: MIT. Copyright (c) 2026 T3 Tools Inc.
- Use in RemoteCode 2: behavioral and UX reference. We study the T3 Code web UI under `~/dev/remotecode2/.references/t3code/` for the Agent App surface (sidebar, header, branch toolbar, composer, timeline, diff panel, command palette, terminal drawer, keybindings).
- MIT requires preservation of the license and copyright notice. When we directly adapt text or logic from a T3 Code file, we will reproduce the notice here. As of 2026-05-14, no T3 Code source is copied; the Swift UI structure was informed by the public file names only.

If you adapt code from these projects, update this file in the same change.
