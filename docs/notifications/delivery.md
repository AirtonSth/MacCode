# Notifications delivery status

Status: **review candidate; full acceptance remains blocked by the limits below**. The implementation covers host-owned Activity, durable exact results, viewed/Undo receipts, explicit failure acknowledgment, shared counts, scheduled and registered operations, safe grouped alerts, and macOS/iOS navigation. Two draft merge requests are the requested delivery; no merge, tag, deployment, or stable-app replacement is authorized.

## Verified

- **macOS integrated50:** 337 selected tests passed: Surfaces 5, Socket 67, Persistence 52, AppShell 190, AgentRuntime 23. The runtime tests include 7 cold-catalog tests and 16 session-parameter tests. These are selected regression suites, not a full-suite claim.
- **macOS native debug:** viewing and Undo changed unseen counts from 2 to 0 to 2 in the same session. Acknowledgment cleared Needs you in the sidebar without the former false missing-result alert and preserved failed history. View changes automatically opened the saved checkpoint at default content width with the outer sidebar visible; this check was repeated after rebasing onto `2fbf5db58` with production account integration. The saved patch differed from current workspace content. Run detail showed the saved summary and recorded duration. Narrow 1225×835 and wide 1600×1000 layouts were exercised.
- **iOS integrated49:** 232 unit tests and all 4 native Activity UI tests passed against current `main`. Simulator diagnostics collection timed out after tests; `xcodebuild` exited 0, so this was not a test failure. These are selected regression suites, not a full-suite claim.
- **Design:** the 21-skill ledger records 10 applied decisions and 11 not-applicable decisions. It is a design record, not proof of every accessibility or device gate.

Synthetic screenshot evidence is stored under `docs/notifications/evidence/`. Machine-local test logs use `/tmp/plan-notifications-macos-integrated50.log` and `/tmp/plan-notifications-ios-integrated49.log`. Screenshots supplement interaction tests; they are not standalone behavioral proof.

## Remaining acceptance limits

- The private remote-alert API exposes no sound toggle. Local sound preferences are implemented; remote sound parity remains blocked by that API.
- No durable receipt proves that the same occurrence is already visible in Live Activity. Delivery remains conservative rather than suppressing unrelated alerts; a banner and Live Activity may duplicate.
- The Live Activity transport supports workspace/thread targets, not an exact registered-operation surface target. Operation-card navigation remains workspace-scoped.
- Physical APNS delivery, VoiceOver, and Reduce Motion were not exercised. Accessibility labels and large-text UI tests do not replace those checks.
- No performance improvement is claimed and no five-sample before/after benchmark was performed.
- The Bot VM Main/Worker cold-catalog selection path has regression coverage. No real paid Bot VM prompt was run; the live guest's missing ChatGPT catalog and credential cause remain unproven. This is not a claim that the live VM is fixed or deployed.

The isolated debug app was stopped after native checks. The running stable macOS app and primary user data were preserved. Draft merge requests must retain these limits until external contracts and hardware checks establish full acceptance.

## Draft merge requests

- macOS: https://gitlab.com/desenvolvimento-ninja/remodecode/remotecode/-/merge_requests/435 — draft, conflict-free at check; not merged or deployed.
- iOS: https://gitlab.com/desenvolvimento-ninja/remotecode2-ios/-/merge_requests/73 — draft, conflict-free at check; not merged or deployed. Previous external pipeline failed, but API returned no job logs. Current pipeline is pending/running, not green.
