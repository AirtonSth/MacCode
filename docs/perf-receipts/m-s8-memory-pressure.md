# M-S8: memory pressure (S-F4a/b)

Date: 2026-10-06. Branch: `fix/stability-long-sessions`.

## What shipped

- `MemoryPressureMonitor` (`Sources/Surfaces/MemoryPressureMonitor.swift`), started from
  `AppDelegate.applicationDidFinishLaunching`. It installs
  `DispatchSource.makeMemoryPressureSource([.warning, .critical])` on the main queue.
- On an event it runs `TerminalMemoryBudgetAuthority.relieveMemoryPressure`, which reclaims
  **hidden terminals only** (reclaim priority 0), least recently used first:
  - warning: until terminal bytes are at or below half the 64 MiB budget, and it skips
    hidden terminals running a foreground program (TUIs, agent CLIs);
  - critical: every hidden terminal, including those running a program.
  The only step it takes compacts the ANSI mirror to 128 rows and releases the native
  Ghostty surface (`releaseForTerminalMemoryBudget`), including its Metal swapchain.
  Reveal rebuilds it through the existing `restoreReclaimedTerminalMemoryIfNeeded` path.
- **Pressure relief never makes a terminal dormant.** A terminal that is already compacted
  or dormant reports `PressureState.compacted` and is skipped, on the same event and on
  every later one. Without this, a second event (two criticals, or a warning then a
  critical above the 32 MiB warning ceiling) took the already-compacted tab to the
  dormant 1x1 mirror: its reveal came back blank and output that arrived while it was
  hidden was lost. Only the normal 64 MiB budget (`enforceBudget`) can still reach the
  dormant stage, as before this slice. Regression tests:
  `test_repeatedCriticalPressureKeepsAHiddenTerminalsOutputThroughReveal` and
  `test_warningThenCriticalAboveTheWarningCeilingKeepsAHiddenTerminalsOutput` (real
  `TerminalSurface`, markers from before and during pressure must both survive reveal,
  in order), and `test_repeatedPressureNeverTakesACompactedTerminalASecondStep`. With the
  skip disabled, all three fail.
- Each event writes a `memory_pressure level=… ceilingBytes=… terminalsReclaimed=…
  terminalBytesBefore=… terminalBytesAfter=… durationMs=…` line to `lifecycle.log` and to
  the `io.remotecode.app` unified log. `durationMs` is the handler's main-thread time.
- NSCache memos (markdown, diff, tool input) are not cleared by hand. NSCache already
  evicts on system memory pressure.

Tests: `Tests/SurfacesTests/MemoryPressureMonitorTests.swift` (11 tests). They cover:
critical reclaims every hidden terminal once even below the normal budget; a visible
terminal is never touched; a terminal in history replay (priority 3) is never touched;
warning stops at the halved ceiling and goes LRU first; repeated events never step a
compacted terminal again; warning spares a hidden terminal running a foreground job
(fake owner and a real `sleep 30` shell) and critical releases it; a terminal that cannot
shrink is reported as 0 reclaimed; start is idempotent; and end-to-end runs on a real
`TerminalSurface` whose output comes back in order after reveal, after one event and
after repeated ones. The end-to-end tests use the process-wide `.shared` authority, so a
pressure event there also reclaims hidden surfaces leaked by other tests in the same
process; their assertions stay on their own surfaces.

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
which is the existing budget authority's contract. A warning accepts them only for hidden
terminals with no foreground program; a critical event accepts them for running
programs too. Doing the same on a 30 s timer needs
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

The first-frame reveal of a terminal reclaimed under pressure is **not measured**, and
that is a known risk. The reveal code path is unchanged
(`restoreReclaimedTerminalMemoryIfNeeded` -> `beginGhosttyHistoryReplay`), but before
this slice it ran only after a 64 MiB overflow, and now it runs after any critical event
and after warnings on idle hidden tabs, which are common on 8-16 GB Macs. The replay into
Ghostty is asynchronous, and the test host may not create a Metal surface, so a test
cannot time the first painted frame.

What was measured, as synchronous main-thread time in the SwiftPM test host (debug
build, this Mac, 2026-10-06; a temporary probe, not committed). Each round: 8 hidden
terminals with 2,000 rows of 108 columns; 1 warm-up round discarded, 5 warmed samples:

| Measure | Samples (ms, sorted) |
|---|---|
| `handle(.critical)`, 6 terminals reclaimed (61.9 MB -> 1.35 MB; the normal budget had already reclaimed 2 while the fixture was built) | 20.1, 20.4, 20.6, 21.2, 23.1 |
| `didBecomeVisible()` + snapshot of a reclaimed terminal (sync part only) | 0.55, 0.65, 0.65, 0.73, 0.74 |
| same for a hidden terminal that was not reclaimed | 0.07, 0.08, 0.09, 0.10, 0.10 |

So one critical event costs about 3.4 ms of main-thread time per reclaimed terminal, all
in one turn; with many large hidden tabs it can reach a visible hitch. The live
`durationMs` field is there to see this on real machines.

## Not verified

- No real OS pressure event was triggered against the sandbox app. `memory_pressure`
  (for example `memory_pressure -S -l warn` or `-l critical`) affects the whole host,
  so the handler was tested through `handle(_:)`, not through the dispatch source.
- In the test host the Ghostty native renderer may not create a Metal surface, so the
  end-to-end tests prove the mirror was reclaimed and rebuilt, not that a real
  swapchain was freed, and they do not cover terminal queries or input modes after a
  critical-event release of a running program. The IOSurface drop per hidden terminal still needs a
  `vmmap -summary` before/after on the sandbox app.
- The footprint-slope pass criterion (≤ 25 MB/h) was not measured, and this slice alone
  is not expected to meet it: it acts only when the OS reports pressure.
