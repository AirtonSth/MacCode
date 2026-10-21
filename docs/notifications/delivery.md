# Notifications integration verification — 2026-10-21

This audit covers macOS, iOS, and the private push relay. The changes are review candidates; they are not a deployment or a claim of unconditional delivery by the operating system.

## Corrections

- The Mac carries the notification category, grouping identifier, sound preference, and occurrence ID through the private relay. APNs and Firebase preserve those fields. Titio pushes use the same sound preference as local alerts.
- Firebase catch-up messages are background pushes without a visible notification or sound. Concurrent relay requests for the same idempotency key share one delivery; successful repeats retain the existing cache policy.
- Denied or failed macOS local scheduling no longer consumes the notification ID. Authorization is refreshed when the app becomes active. The explicit Settings test can present while the app is foregrounded and respects the selected sound preference.
- Titio direct replies respect Bot, workspace, and completion-alert preferences and retain their linked thread route.
- Committed Titio notices retain their pending delivery marker until the relay accepts the push. Failed attempts reuse the existing backoff and 10-minute restart recovery window, preserving the occurrence ID and the single inbox message. Resolved decisions are excluded from retries.
- Mirrored iOS notifications retain run, final-message, activity-item, grouping, and sound metadata. Ordinary task notifications use ordinary sound/interruption levels, without requesting unsupported critical-alert or Focus-bypass behavior.
- Notifications have their own native macOS Settings destination. The iOS Activity menu exposes **Local notification categories**, including one Titio preference shared by notices and questions, even when the feed is empty.
- A remotely started Live Activity uses the projected title, including Titio, in its start alert.

## Verification matrix

| Path | Evidence |
|---|---|
| Mac local scheduling, permission recovery, deduplication, Titio policy, relay metadata | 91 focused sandbox tests passed; an additional 35-test relay recovery selection passed before the final broad run. Final broad selection: 470 tests, 462 passed, 3 skipped, 5 baseline failures. Native Settings and its test action exercised through mac-use. |
| Titio generation, questions, recovery, exact routes, scheduled outcomes | Existing notification/Titio suites exercised; the full macOS selection retains the baseline failures listed below. No new run option or scheduled-task field was introduced. |
| iOS token registration, routing, lifecycle adoption, stale generations, local copy and sound | 307 selected unit tests: 306 passed, 1 simulator-only signing-profile check skipped, 0 failures. |
| iOS category controls | Native UI test passed and captured `evidence/ios-local-notification-categories.png`. |
| iOS system notification tap | A host-coordinated `simctl push` reached SpringBoard; tapping it opened the authenticated `ws-2` workspace. Existing UI test passed after updating its initial home-screen assertion. `evidence/ios-system-notification-route.png`. |
| Private relay/APNs/Firebase/Live Activity v2 | 133 tests passed, 788 assertions, and backend TypeScript checking and targeted ESLint passed. Includes concurrent idempotency, silent Firebase catch-up, APNs category/grouping/sound, ownership and monotonic Live Activity timestamps. |
| Physical iPhone APNs | The modified local relay sent an APNs alert successfully and the Titio test banner was observed on the phone. Live Activity start/update/end were accepted by APNs; the start card and its eventual removal were observed. The intermediate updated text was not independently observed. |
| Native macOS sizing | Notifications Settings inspected at 1100×780 and 1600×960 with existing responsive controls. `evidence/mac-notifications-narrow.png` and `evidence/mac-notifications-wide.png` in the macOS repository. |

Physical checks used the already installed iOS build **2.0.55 (2026101803)** and the modified backend sender locally. They prove transport to that installation; the new iOS code was exercised in the isolated simulator. No installed user app was replaced.

The macOS permission was enabled for `io.remotecode.desktop.debug`. `usernoted` and `NotificationCenter` confirmed delivery to alert/lock-screen/history destinations and storage in notification history. The floating banner was not visible to mac-use, so visual banner presentation is not claimed. The explicit test foreground policy is covered by a regression test. Relay failure/recovery and cancellation of resolved decisions are verified by deterministic sandbox tests; a relay outage was not injected into the native GUI session.

## Limits and known findings

- The broad macOS baseline already failed five tests: two stale sidebar source assertions, two existing notification-copy expectations, and a Titio delegation test requiring a ready Docker Desktop. The final audit reproduced exactly those five baseline failures; focused changed-path tests pass. These are not five newly introduced regressions and are not reported as a green full suite.
- `titio_notice_key` selects Titio as the phone alert owner; it is not an OS presentation receipt. Committed notices now retry transient relay failure and recover after restart within the existing 10-minute window. Outages beyond that window and direct chat replies do not have an indefinite durable alert outbox. The inbox message remains available.
- A Live Activity and a banner may both describe an occurrence because no receipt proves the same occurrence is already visible. An OS policy, revoked permission, expired token, disconnection, or delivery budget can still prevent an interruption.
- Live Activity navigation for registered operations remains workspace-scoped. Exact thread, run, final-message, and Titio targets retain their existing authenticated routes.
- The iOS category menu controls local mirrored notifications. Remote alert preferences remain host-owned; the copy now says so explicitly.
- Physical Reply/Open action completion, acoustic sound output, VoiceOver, Reduce Motion, provider-backed Bot prompts, and every production network state were not exercised. No performance improvement is claimed.

The phone test activity was ended and its removal observed. The phone automation session was closed and its task-owned runner removed. The macOS debug app and isolated simulator are stopped after verification. The user's stable MacCode process and data are preserved.

## Design and delivery

See [design coverage](design-coverage.md) for the 21-skill ledger and Appllama references. Native controls, existing DS tokens, English interface copy, truthful permission state, and immediate navigation are retained. No new dependency or design pattern was introduced.

External CI: the private relay pipeline passed type checking and lint. The iOS Xcode Cloud status is failed; App Store Connect requires sign-in to retrieve the diagnostic log, so its cause is not attributed to this change. The macOS repository has no MR pipeline for this branch.

Companion merge requests are linked in each MR description. The private relay must ship with the host metadata changes for remote sound/category parity. No merge, tag, or deployment was performed.

Payload behavior follows Apple's [remote-notification payload documentation](https://developer.apple.com/documentation/UserNotifications/generating-a-remote-notification) and [ActivityKit push lifecycle documentation](https://developer.apple.com/documentation/ActivityKit/starting-and-updating-live-activities-with-activitykit-push-notifications).
