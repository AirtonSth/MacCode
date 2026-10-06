# M-S9: hidden Agent App tab cold reveal (S-F4c review follow-up)

Date: 2026-10-06. Branch: `fix/stability-long-sessions`.

## What changed after review

- Reveal no longer decodes the archive on the main actor. `setVisibility(.visible)`
  publishes on the interaction turn (durable messages and chrome; the timeline is an
  empty stand-in, like a cache-miss thread open). The visibility session stays
  `.restoring` while `restoreColdTimelineOffMain` decodes in a detached task. The result
  applies in one publish, and only if the same archive is still the tab's tree and
  nothing wrote `timeline` since the reveal. If something did write it, the tab takes
  the normal off-main full open instead of overwriting the newer state.
- Stream flushes and scheduled-poll suffixes that reach an archived tab no longer thaw
  on main. Stream events stay batched and the restore flushes them. The poll returns
  without moving its cursor, so the next tick applies the same attested suffix to the
  restored tree.
- A failed restore takes the normal full open (off-main bundle). The old fallback, a
  main-thread replay of only the hot window, is gone.
- Archiving is skipped below 1 MiB of hot text (`hiddenArchiveMinimumHotTextBytes`).
  The size is measured off-main. A hidden tab re-arms the 30 s reclaim after a thaw
  and after a selected-thread run finishes.
- A thread switch drops the archive, because it belongs to the thread that was
  selected at hide. A hide that lands before a reveal's restore keeps the archive.

## Receipt

Method: XCTest in the debug build (`scripts/isolated-sandbox.sh test`), same machine
and process for every row. The transcripts are synthetic but use multiple item types,
not one repeated line: per turn, 1 reasoning item, 3 command items with variable-length
output drawn from an 88-word vocabulary with numbers, and 1 assistant answer. One warm-up
sample is discarded, then 7 samples are taken. Times are medians.

| Turns / items | Hot text | Archive | Live tree (pre-M-S9) reveal | M-S9 as committed: sync reveal (main) | This fix: reveal on main | This fix: settled (restore applied) |
|---|---|---|---|---|---|---|
| 150 / 750 | 1.07 MiB | 0.26 MiB | 0.02 ms | 4.95 ms | 0.044 ms | 4.94 ms |
| 600 / 3,000 | 3.87 MiB | 0.99 MiB | 0.03 ms | 17.82 ms | 0.052 ms | 17.71 ms |
| 1,500 / 7,500 | 9.46 MiB | 2.45 MiB | 0.03 ms | 44.72 ms | 0.053 ms | 43.93 ms |

- With the archive, main-thread time at reveal drops from 5–45 ms to about 0.05 ms.
- Settled latency does not regress against the committed slice: it is within 1 ms at
  every size, well inside `max(25 ms, 5%)`.
- Against a tab that was never archived, settled latency is higher by the decode time
  (about 5, 18 and 44 ms at these sizes). That is the cost of the archive, and the
  user does not wait on main for it.
- On this vocabulary the archive is about 25% of the JSON form.

## Not measured

- First frame and settled latency in the real app with SwiftUI rendering. The
  "settled" figure stops when the restored tree is assigned, not when it paints.
- Release-build timings.
- The RSS saving in a long real session, and the compression ratio on real transcripts.
