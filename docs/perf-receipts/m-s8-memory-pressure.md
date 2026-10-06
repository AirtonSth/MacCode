# M-S8: memory pressure (S-F4a/b)

Date: 2026-10-06. Branch: `fix/stability-long-sessions`.

## What shipped

- `MemoryPressureMonitor` (`Sources/Surfaces/MemoryPressureMonitor.swift`), started from
  `AppDelegate.applicationDidFinishLaunching`. It installs
  `DispatchSource.makeMemoryPressureSource([.warning, .critical])` on the main queue.
- On an event it runs `TerminalMemoryBudgetAuthority.relieveMemoryPressure`, which reclaims
  **hidden terminals only** (reclaim priority 0), least recently used first, one step per
  terminal per event:
  - warning: until terminal bytes are at or below half the 64 MiB budget;
  - critical: every hidden terminal.
  One step compacts the ANSI mirror to 128 rows and releases the native Ghostty surface
  (`releaseForTerminalMemoryBudget`), including its Metal swapchain. Reveal rebuilds it
  through the existing `restoreReclaimedTerminalMemoryIfNeeded` path.
- Each event writes a `memory_pressure level=… ceilingBytes=… terminalsReclaimed=…
  terminalBytesBefore=… terminalBytesAfter=…` line to `lifecycle.log` and to the
  `io.remotecode.app` unified log.
- NSCache memos (markdown, diff, tool input) are not cleared by hand. NSCache already
  evicts on system memory pressure.

Tests: `Tests/SurfacesTests/MemoryPressureMonitorTests.swift` (5 tests). They cover:
critical reclaims every hidden terminal once even below the normal budget; a visible
terminal is never touched; warning stops at the halved ceiling and goes LRU first; a
terminal that cannot shrink is reported as 0 reclaimed; start is idempotent; and an
end-to-end run on a real `TerminalSurface` whose output comes back in order after reveal.

## What did not ship, and why

### Releasing the native surface of every terminal hidden for more than 30 s

Not implemented. With today's mirror, releasing the native surface of a terminal that
is still running a program is unsafe, and a 30 s timer would turn that into routine
behavior for every background tab instead of an emergency step:

1. **Terminal queries go unanswered while the surface is released.** Output for a
   released view is dropped before it reaches the parser
   (`GhosttyTerminalView.processOutput`, the `releasedForTerminalMemoryBudget` early
   return). `ANSIRenderer` answers no queries: no DSR `CSI 6n`, DA, XTVERSION, OSC 10/11
   colour queries, or kitty keyboard `CSI ? u`. A shell or TUI that queries while its tab
   is in the background (prompt plugins, vim, fzf, less, agent CLIs) waits for a reply
   that never comes.
2. **Input modes are lost on rebuild.** The mirror tracks only cursor visibility and the
   alternate screen (`ANSIRenderer.setPrivateModes`). Reveal replays an ANSI snapshot
   into a new surface, so DECCKM `?1`, keypad mode, mouse reporting `?1000/1002/1003/1006`,
   bracketed paste `?2004`, focus reporting `?1004` and kitty keyboard flags all reset
   while the program still expects them. Arrow keys, mouse and paste then break in vim,
   tmux and agent CLIs.
3. **The alternate screen is flattened.** `buildANSISnapshot` returns only the alternate
   grid while it is active, so the primary screen underneath is gone when the program
   exits.
4. **Scrollback and selection are lost.** Native scrollback beyond the mirror's
   2,000 rows is discarded, and so is any selection.

Under OS memory pressure, the monitor above accepts these costs for hidden terminals,
which is the existing budget authority's contract. Doing the same on a 30 s timer needs
the mirror to track and re-emit input modes, keep the primary screen under the alternate
one, and answer terminal queries while the surface is released. That is a separate,
larger change.

### GPU estimate in `retainedTerminalBytesEstimate`

Not added. The budget authority reclaims whenever the summed estimate is over 64 MiB.
One full-window Retina swapchain (2790×2390 px × 4 B × 3 buffers ≈ 80 MB) is already
over that on its own, so counting it would:

- release every hidden terminal on its next budget touch, which is the unsafe path above
  with no delay at all;
- rebuild visible terminals on every 256 KiB output touch, because their swapchain cannot
  shrink and `compactVisibleTerminalMemory` would run again and again.

A GPU term is only useful with its own budget that counts hidden terminals only, and that
depends on the release above being made safe first.

### Reveal-paint receipt (≤ 100 ms p95)

Not measured. The 30 s release did not ship, so no new reveal path exists to time. A
terminal reclaimed under pressure reveals through the same, unchanged
`restoreReclaimedTerminalMemoryIfNeeded` path as before.

## Not verified

- No real OS pressure event was triggered against the sandbox app. `memory_pressure`
  (for example `memory_pressure -S -l warn` or `-l critical`) affects the whole host,
  so the handler was tested through `handle(_:)`, not through the dispatch source.
- In the test host the Ghostty native renderer may not create a Metal surface, so the
  end-to-end test proves the mirror was reclaimed and rebuilt, not that a real
  swapchain was freed. The IOSurface drop per hidden terminal still needs a
  `vmmap -summary` before/after on the sandbox app.
- The footprint-slope pass criterion (≤ 25 MB/h) was not measured, and this slice alone
  is not expected to meet it: it acts only when the OS reports pressure.
