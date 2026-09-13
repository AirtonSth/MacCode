# Agent App memory/performance — before/after

Baseline: `production` @ `ff5827b3`  
Branch: `perf/agent-app-memperf-20260913T151340Z`  
Isolated clone (primary `macos-app` checkout not modified)

## Executive summary

| Slice | Before | After | Estimate |
| --- | --- | --- | --- |
| ComputerUse **native zoom** (25% region) | Encode full frame then crop (PNG inflate of full pixels) | Crop live `CGImage` before PNG/base64 | **~75% fewer inflate pixels**; fixture encoded bytes **−38%** (876→544 UTF-8); less-compressible shots tend toward **~75%** less retained PNG+base64 |
| Provider **stdout** teardown (`BoundedPipeDrain`) | Retain up to full leftover pipe (`Int.max`) | Cap **2 MiB** | On 8 MiB leftover: **−75%** retained bytes (8 388 608 → 2 097 152) |
| Provider **stderr** teardown | Retain up to full leftover pipe | Cap **1 MiB** | On 8 MiB leftover: **−87.5%** retained bytes (8 388 608 → 1 048 576) |
| Chat attachment **SVG AppKit fallback** | `NSImage(contentsOf:)` even for huge SVG | Skip when on-disk **> 2 MiB** | **−100%** of AppKit SVG fallback decode for oversized files |

Detailed evidence below. Not live Instruments RSS — unit/microbench retained-byte proofs.

---

# ComputerUse zoom crop-before-PNG

Port of yesterday’s `CaptureZoomContext` + `encodePreparedCapture` path onto this production baseline.

## Before (this checkout @ ff5827b3)

Native capture PNG+base64-encoded the **full window**, then zoom inflated that PNG with `NSBitmapImageRep(data:)` to crop.

Peak retained work for a zoom:

- full-frame `CGImage` pixels
- full-frame PNG
- full-frame base64
- then a second inflate of the full PNG (tests: `imageSize` + `crop` = **2 inflates**)
- crop PNG + crop base64

`pixelScope` already reported `fullImageSize` + `region`; that wire shape is unchanged.

## After

1. `CaptureZoomContext` passes the zoom rect into NativePlatform without changing the public capture-hook arity.
2. Live `CGImage` is cropped **before** PNG/base64 (`encodePreparedCapture`).
3. `sourcePixelSize` keeps the uncropped frame so `applyPixelRegion` can skip a second inflate.
4. Encoded-PNG fallback inflates **once** (IHDR size, then crop). Screenshot size is IHDR-only (0 inflates).

## Measured (unit, this checkout)

| Case | PNG inflates | Pixels inflated | Encoded payload |
| --- | ---: | ---: | --- |
| Screenshot (32×24 encoded PNG) | **0** (was 1 via `imageSize`) | 0 | full frame (unchanged) |
| Zoom of encoded PNG 32×24 → 8×4 | **1** (was 2) | 768 once | region PNG |
| Native zoom 64×48 → 16×10 | **0** | 0 | region PNG < full PNG |
| Native 25% zoom 80×80 → 40×40 | **0** | 0 vs 6400 | base64 UTF-8 876 → 544 (**−38%** on this fixture) |
| Native already-cropped 12×8 → 4×2 | **0** | 0 | same region payload; token `fullImageSize=[12,8]`, `region=[2,1,4,2]` |

25% region **avoids ~75% of PNG inflate pixels** (6400 → 1600, or 0 when the live `CGImage` is cropped first).

Peak **encoded** capture bytes dropped **38%** on the 80×80 synthetic PNG (patterned pixels compress, so PNG size is not linear with area). For less-compressible screenshots, encoded size tends toward the pixel-area ratio — about **~75%** less PNG+base64 retained for a 25% zoom versus encode-then-crop.

Peak memory shape:

- old: full pixels + full PNG + full base64 + crop
- new native zoom: live full `CGImage` + **crop PNG + crop base64** (no full-frame encode)

## Proof

Repo `swift test` cannot load this checkout’s package graph: Vendor LFS binaries (`RCTailcat` / `GhosttyKit`) are missing (pre-existing; not reverted).

Focused run used a /tmp package that symlinked only `Sources/CoreModel` + `Tests/CoreModelTests`:

```
swift test --disable-sandbox --disable-experimental-prebuilts --filter ComputerUseNativeHostBackendTests
```

**52 passed, 0 failed.**

---

# BoundedPipeDrain teardown caps + AppKit SVG fallback

Runtime: host=grok role=routine_worker model=grok-4.6 effort=high

## Changes

- `BoundedPipeDrain.defaultStdoutMaxBytes = 2_097_152` (2 MiB); `defaultStderrMaxBytes = 1_048_576` (1 MiB). Default `maxBytes` is no longer `Int.max`.
- Provider teardown `readRemaining` sites pass those constants: Claude/Codex/Grok runners, Claude streaming CLI + Agent SDK bridge, Codex app-server stderr drain, npm-install diagnostic tail.
- Graphify already passed `GraphifyRuntimeHardening` caps (stdout 4 MiB / stderr 1 MiB); left unchanged.
- `AgentAttachmentThumbnailLoader` skips `NSImage(contentsOf:)` when on-disk size is missing or `> 2_097_152`. Ported from the 2026-09-12 reference; `AgentChatSharedChrome.swift` is filesystem-identical to that tree.

## Before → after (retained bytes)

| Slice | Before | After | Estimate |
| --- | --- | --- | --- |
| Provider stdout teardown drain (8 MiB leftover pipe) | retain `8_388_608` (`maxBytes = Int.max`) | retain `2_097_152` | **−6_291_456 (−75%)** retained bytes |
| Provider stderr teardown drain (8 MiB leftover pipe) | retain `8_388_608` | retain `1_048_576` | **−7_340_032 (−87.5%)** retained bytes |
| Combined stdout+stderr teardown (8 MiB each) | `16_777_216` | `3_145_728` | **−13_631_488 (−81.3%)** |
| SVG AppKit fallback (`NSImage(contentsOf:)`) | load full on-disk SVG (fixture `2_097_290`) | skip when `> 2_097_152` | **−2_097_290 (−100% of SVG fallback inflate)** |

These are retained-byte arithmetic from the cap constants and the 8 MiB pipe / oversized-SVG fixtures, **not** live Instruments RSS.

## Proof

Repo `swift test` cannot load this checkout’s package graph: Vendor LFS binaries (`RCTailcat` / `GhosttyKit`) are missing (pre-existing; not reverted).

Pipe proof compiled the real `Sources/AgentRuntime/BoundedPipeDrain.swift` with `swiftc -O -parse-as-library` plus an 8 MiB concurrent writer:

```
[memperf] pipe-cap payload=8388608 retained=2097152 cap=2097152
[memperf] pipe-stderr-cap payload=8388608 retained=1048576 cap=1048576
PASS BoundedPipeDrain 8 MiB caps
[memperf] thumbnail-svg-skip svg_bytes=2097290 cap=2097152
PASS SVG AppKit fallback size gate
```

XCTest equivalents (unrun via SPM here): `BoundedPipeDrainCapTests.test_eightMiBPipeRetainsAtMostStdoutCap` / `…StderrCap`, `AgentChatAttachmentThumbnailTests.test_appKitSVGFallback_sizeGate_skipsAboveTwoMiB`, `test_decodeImage_skipsOversizedSVGFallback_andKeepsImageIO`.
