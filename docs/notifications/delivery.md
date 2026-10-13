# Notifications delivery status

Status: **review candidate; full acceptance remains blocked by the limits below**. The implementation covers host-owned Activity, durable exact results, viewed/Undo receipts, explicit failure acknowledgment, shared counts, scheduled and registered operations, safe grouped alerts, and macOS/iOS navigation. Two draft merge requests are the requested delivery; no merge, tag, deployment, or stable-app replacement is authorized.

## Verified

- **macOS final42:** 335 selected tests passed: Surfaces 5, Socket 67, Persistence 52, AppShell 190, AgentRuntime 21. The runtime tests include 7 cold-catalog tests and 14 session-parameter tests. These are selected regression suites, not a full-suite claim.
- **macOS native debug:** viewing and Undo changed unseen counts from 2 to 0 to 2 in the same session. Acknowledgment cleared Needs you in the sidebar without the former false missing-result alert and preserved failed history. View changes automatically opened the saved checkpoint at default content width with the outer sidebar visible; the saved patch differed from current workspace content. Run detail showed the saved summary and recorded duration. Narrow 1225×835 and wide 1600×1000 layouts were exercised.
- **iOS final45:** 232 selected unit tests passed, including Activity, Live Activity, Bot routing, and notification-route suites.
- **iOS final48:** all 4 native Activity UI tests passed. Flows cover 51-result pagination, filtered viewed/Undo, viewed versus failure acknowledgment, exact old-run checkpoint preview and full diff when the bounded checkpoint list omits the target, and legacy-host presentation across portrait/landscape at accessibility XXXL text size.
- **Design:** the 21-skill ledger records 10 applied decisions and 11 not-applicable decisions. It is a design record, not proof of every accessibility or device gate.

Synthetic screenshot evidence is stored under `docs/notifications/evidence/`. Machine-local test logs use `/tmp/plan-notifications-macos-final42.log`, `/tmp/plan-notifications-ios-final45.log`, and `/tmp/plan-notifications-ios-final48.log`. Screenshots supplement interaction tests; they are not standalone behavioral proof.

## Remaining acceptance limits

- The private remote-alert API exposes no sound toggle. Local sound preferences are implemented; remote sound parity remains blocked by that API.
- No durable receipt proves that the same occurrence is already visible in Live Activity. Delivery remains conservative rather than suppressing unrelated alerts; a banner and Live Activity may duplicate.
- The Live Activity transport supports workspace/thread targets, not an exact registered-operation surface target. Operation-card navigation remains workspace-scoped.
- Physical APNS delivery, VoiceOver, and Reduce Motion were not exercised. Accessibility labels and large-text UI tests do not replace those checks.
- No performance improvement is claimed and no five-sample before/after benchmark was performed.
- The Bot VM Main/Worker cold-catalog selection path has regression coverage. No real paid Bot VM prompt was run; the live guest's missing ChatGPT catalog and credential cause remain unproven. This is not a claim that the live VM is fixed or deployed.

The isolated debug app was stopped after native checks. The running stable macOS app and primary user data were preserved. Draft merge requests must retain these limits until external contracts and hardware checks establish full acceptance.
