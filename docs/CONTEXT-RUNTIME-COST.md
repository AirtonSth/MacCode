# Contextual runtime desktop cost probe

## Scope and method

This is a bounded U-003 measurement, not rollout approval or provider-capacity calibration. Production source, UI/UX, protocol and public gates are unchanged. The test drives the shipped legacy and contextual `BotComputerGuestService.provision` paths with owned empty support roots, real SQLite bots and an explicit general-context grant. It never supplies provider credentials or requests a provider turn.

A real captured desktop PNG and Docker running state establish readiness. First creation of each new owned scope is reported separately with the existing image cached and Docker already running. This is **not machine-cold, Docker-engine-cold or image-build time**. Legacy is created first; contextual creation occurs with the first desktop already running, so the two creation samples are not a controlled one-active-desktop A/B comparison.

Five stopped-container resumes per variant then run in paired, alternating order. The other measured desktop remains otherwise idle; the warm profile has exactly two desktop environments. Timings cover actual provision through screenshot readiness, not Stop duration, stats collection, native navigation feedback or authenticated provider readiness. CPU/memory/PIDs are Docker's post-readiness samples, not settled idle measurements, peak consumption, whole-host RSS or provider-task consumption. Disk figures are the Docker writable layer and owned-home apparent bytes, not total allocated physical storage or the shared base image.

## Environment and evidence

- Repository/worktree: `macos-app/.sandbox-worktrees/20261016T013608Z`; baseline `5f6c42679c50e5552b108334cdea6901465ebda7`.
- Final Sources/Tests tree: `05647df5c029863bc0b0a4f06c37fcea97b59071`. One real probe passed, zero skips/failures, 34.109 seconds, exit 0.
- Sources equal the previously packaged repair checkpoint. No new package or UI/simulator claim is made; the prior signed executable SHA-256 remains `512f7272aa96ef3f45bf321c421d4d52bc2f71c330799bbd68a1f2c7753f1b3f`.
- Hardware readback: `Mac17,6`, Apple M5 Max, 18 processors, 137438953472 physical-memory bytes (128 GiB). OS: Version 27.0.1 (Build 26A434).
- Docker 29.4.0: 18 CPUs, 16817168384 memory bytes available to its engine. These are engine values, not per-container resource limits.
- Cached image: `sha256:b3c068f7d076bbd8d87cac8a5e15955eda4730c5483c80b96f4a7987045299d2`.
- Full unmodified measurement artifact: [evidence/context-runtime-cost.json](evidence/context-runtime-cost.json), SHA-256 `8996c5aa18a46fbb0dfdd0a31f72ee99f8c4b8fd3ea1bebd80ded95789f34e58`.

Run with caller-owned `RC_CONTEXT_PROBE_ROOT`, `RC_LIVE_DOCKER=1` and `RC_CONTEXT_RESOURCE_PROBE=1`:

```sh
scripts/isolated-sandbox.sh test --build-system native --filter BotContextRuntimeCostDockerTests
```

The probe prints the private JSON artifact filename. The first execution passed but merged stdout/stderr interleaved a runner warning and a numeric value in its long JSON line. The final test writes a private 0600 artifact before printing its short filename; the orchestrator parsed that actual artifact, validated all 12 samples and calculated the summaries below. No measurements were reconstructed from the damaged console line.

## Observed desktop-only values

| Metric | Legacy | Contextual |
|---|---:|---:|
| First owned creation, cached image | 918.229 ms | 2035.730 ms |
| Warm readiness, median of five | 799.897 ms | 1769.864 ms |
| Warm readiness range | 711.881–815.865 ms | 1739.498–1789.862 ms |
| Warm reported memory usage | 225.4–230.3 MiB | 227.4–228.5 MiB |
| Warm CPU sample range | 88.35–103.25% | 88.01–94.73% |
| Warm PID range | 110–117 | 114–117 |
| Writable layer after fifth resume | 303104 bytes | 303104 bytes |
| Owned-home apparent bytes after fifth resume | 12508458 | 8588962 |

Warm readiness samples, in index order, are preserved here for direct comparison:

- Legacy: 811.315041, 815.865041, 711.880959, 799.896667, 736.271917 ms.
- Contextual: 1766.887, 1769.864042, 1739.49775, 1777.053708, 1789.861625 ms.

Contextual median is **969.967 ms higher (121.26%)** in this desktop-only probe. This is a material observed readiness cost, not a performance-parity pass. It exceeds the repository's `max(25 ms, 5%)` tolerance if used as a comparable settled-latency result; actual native navigation first-useful-frame and settled latency were not measured here. No security check was removed to improve the result, and no concurrency limit was raised from these observations. The first legacy memory sample was 782.6 MiB versus later warm values near 228 MiB; it is retained in the artifact rather than discarded or called representative steady-state memory.

## Review, cleanup and remaining gates

Independent source review `01a1495a-9929-7e30-811f-97a3da3616a8` found no material probe-validity or ownership-cleanup defect; it ran no commands or tests. The later report-output change only preserves uncorrupted measurement evidence and clarifies workload labeling.

The test prechecks generated container/network names, verifies exact ownership label and home mount before cleanup, removes the inspected immutable container ID and exact task network, and asserts both absent. Final task fixture-directory absence was separately verified; only the requested measurement JSON artifact remains. Existing user resources, Docker engine settings and credentials were preserved.

Exactly two desktop environments were observed; this does not establish a safe production concurrency cap. U-003 remains open for authenticated workload, sustained/peak host and provider consumption, lower-memory supported hardware, resource-limit failure behavior and concurrency calibration. Public contextual execution stays closed. Dedicated `RC_CONTEXT_OPENROUTER_PARENT_TEST_KEY`, `RC_CONTEXT_OPENROUTER_CHILD_TEST_KEY` and `RC_CONTEXT_OPENROUTER_TEST_MODEL` were checked and absent; no fallback to personal accounts was used. OAuth refresh, authenticated child execution/session load, broader lifecycle and human usability acceptance remain pending. iOS receives mirrored documentation and raw evidence only, with no source or design change.

## Simultaneous desktop measurement (1, 2, 4 and 8)

Test `BotContextRuntimeCostDockerTests.testMeasureSimultaneousContextualDesktopsAtOneTwoFourEight` provisions N owned contextual desktops at the same time (N = 1, 2, 4, 8) through the real `BotComputerGuestService.provision(contextBinding:)`. For each N it records one first-creation sample (cached image) and five warm resumes of the stopped containers, plus per-container CPU and memory from `docker stats`. It never runs a provider. Raw artifact: [evidence/context-runtime-concurrency.json](evidence/context-runtime-concurrency.json), SHA-256 `fd294ca7cfd3ee20af892e0131a53607b0e9829d72dcbead75cfcf9a789f75f1`.

Environment: Apple M5 Max, 18 processors, 128 GiB, macOS 27.0.1; Docker 29.4.0 with 18 CPUs and 16817168384 bytes; image `sha256:b3c068f7d076bbd8d87cac8a5e15955eda4730c5483c80b96f4a7987045299d2`. Single run, 311 s, 0 failures, all owned containers and networks removed (pre-existing `remotecode-bot-*` containers untouched).

| Concurrent | First creation wall | Warm wall median (range, 5 samples) | Warm total memory median | Max container CPU (warm) |
|---:|---:|---:|---:|---:|
| 1 | 2002 ms | 2019 ms (1800–3000) | 227 MiB | 319% |
| 2 | 2740 ms | 2767 ms (2376–3408) | 455 MiB | 277% |
| 4 | 3256 ms | 2834 ms (2632–4153) | 911 MiB | 149% |
| 8 | 8893 ms | 3970 ms (3542–6695) | 1807 MiB | 131% |

Reading: warm memory is linear at about 228 MiB per desktop. Warm readiness grows from about 2.0 s to about 4.0 s at 8, with a 6.7 s worst sample, and first creation at 8 is 4.4 times the single case. The earlier single-desktop median was 1.77 s, so the 2.0 s here includes the same fixed provisioning cost.

Concurrency limit derived from these numbers: **4 simultaneous contextual desktops** on a machine like this one. At 4 the warm worst case stays under about 4.2 s and memory under about 0.9 GiB, while 8 raises first-creation latency to 8.9 s and the warm worst case to 6.7 s, with no failures observed. This is a recommended ceiling for rollout, **not enforced by code**; the only existing cap is the guest MCP gateway limit of 8 in-flight tool calls per run. Lower-memory hardware, authenticated provider workloads, sustained load, resource-exhaustion behavior and the first-creation tail beyond 8 desktops are not measured, so no production cap is claimed. The SQLite main-thread-wait warnings in the log come from the test's own schema migration on the test thread.
