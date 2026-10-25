# Docker desktop startup validation

Validated on macOS Apple Silicon on 2026-10-24 using an isolated debug build.

The original image failed to create `.browser-profiles` because npm had created
`/home/remotecode` as root before `useradd`. The recipe now assigns that home to
the guest user and advances the image recipe to revision 8. Screenshot retries
now pause after typed Docker failures, and exhausted retries report a stopped
container with a bounded log tail. Successful Stop discards the disconnected
viewer before a later Start.

## Reproduce

From the linked worktree created by `scripts/isolated-sandbox.sh ensure`:

```sh
scripts/isolated-sandbox.sh test --filter 'BotComputerDockerClientTests|BotComputerGuestSpecTests|BotComputerGuestServiceTests|BotVMFailureHandlingTests|BotsWindowTests/test_stoppingDesktopDiscardsDisconnectedViewerBeforeSameURLResume|BotsWindowTests/test_BotComputerDocker_stopDoesNotBlockMainActor'
scripts/isolated-sandbox.sh build
scripts/isolated-sandbox.sh run
# After exercising the debug app:
scripts/isolated-sandbox.sh stop
```

An image-level probe also checks PNG capture and the noVNC HTTP endpoint without
a home bind that could mask image ownership problems:

```sh
bash scripts/test-computer-guest-image.sh remotecode/computer:r8
```

The optional `BotComputerBootDockerTests` require
`RC_MACCODE_BOOT_PROBE_IMAGE=remotecode/computer:r8` and access to Docker.
They create temporary resources and must not be run against an important VM.

## Observed results and limits

- The targeted set executed 137 cases: 135 passed, two skipped, no failures.
- The fixed image produced a PNG and served noVNC. A live native service test
  provisioned, captured, stopped and resumed a container successfully.
- In the debug UI, a temporary shared VM started and displayed Chromium.
  Stop/Start resumed the same container. Opening its separate desktop window
  displayed the resumed screen.
- **Known limitation:** the embedded Bot Desk viewer remained blank after resume
  during the final UI observation. Automatic embedded reconnection is not proven
  fixed. The original user VM was not modified or used for this validation.
- The broad suite was interrupted after 3,188 passes, 70 failures and 47 skips;
  it is not green. An additional existing file-persistence test produced 12
  failed assertions, including two unexpected errors, with its fixture using a
  bot-home path instead of the expected guest-home path.
- Optional multi-context Docker validation failed during network provisioning;
  a later shared-runtime probe was interrupted. Docker had about 1.9 GiB total
  memory with existing services consuming most of it; no OOM cause was proven.

This change addresses reproducible startup defects and improves diagnostics;
it does not establish that every Docker or desktop-viewer path is fixed.
