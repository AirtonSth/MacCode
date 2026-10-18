# Legacy RESTORE adoption — implemented checkpoint

## Current implementation scope

This document records the actual uncommitted legacy RESTORE implementation checkpoint, replacing the earlier design-only account below. The host restore foundation is documented in `CONTEXT-HOST-RESTORE.md`; the contextual-workspace stage mapping remains bounded in `CONTEXTUAL-WORKSPACES.md`. This checkpoint adds legacy queue/schedule adoption behind explicit review and authority guards; it does not complete the broader contextual-workspaces plan.

Legacy records are enumerated without exposing record bodies, prompts, secrets, or credentials. Adoption requires matching fingerprint review and explicit confirmation; stale or mismatched confirmation is refused. Current authority wins, and restored queue/schedule identity and history are retained. An exact held queue item requires explicit approval, and only after the context guard succeeds. Automatic drain and force actions cannot bypass that guard. Bot receipt processing is asynchronous: the receipt remains queued until acceptance. Rejection does not consume the queue item. Schedules remain disabled until a user explicitly re-enables them. Restored work does not auto-run.

These statements describe implementation scope, not broad completion. The final bounded verification below covers the recorded legacy restore and held-queue paths; it does not establish live provider credential or isolation safety. This docs-only update makes no code/UI changes, builds, commits, or test runs.

## Historical design checkpoint

The prior checkpoint described design only and must not be read as the current implementation status. Its proposed constraints remain relevant only where consistent with the implementation above: no new UI, preserve existing controls, and enforce safety below presentation. Historical claim that no behavior was implemented is superseded.

## Bounded historical verification

At `f249b93dc480c02d5481e8a41d353635517f67ac`, schema tests reported **7 executed, 1 skipped, 0 failed, 3.565 seconds**. This remains historical evidence only and is superseded for current behavior by the final bounded verification below. Earlier review findings were addressed; follow-up review reported no remaining material source objection. Earlier failed runs remain historical failures and are not presented as passing evidence. No tests were run for this documentation change.

## Final bounded verification

The exact Sources/Tests tree is `77247c43d481a84c192aff83572c6c89cd2d4faa`. Packaged CLI Sources match build tree `64a5567214ac18201f98f76584b398ca31e75c6e` (`git diff Sources` exit 0); packaged binary SHA-256 is `fa92966d2372b56227e035d46ba19fc1f4808b96d2a62330decd0bf9448cd730`.

Actual packaged CLI checks: held instance lock refused restore (exit 1); ID-only preview reported 93 records (exit 0); absent or wrong review refused with exit 1 and current database unchanged; correct review adopted 93→97 (exit 0), with 3 held items, schedules disabled, 0 revived grants or active runs, IDs/history intact, source unchanged, recovery mode 0600, and no staging files. Read-only verifier ran before mutations: 1 test passed, 0.015 seconds.

Against the same Sources/Tests tree, combined filter `HostRestoreLegacySchemaTests.test[A-Z]|HostRestoreLegacyRouterTests|HostRestoreAgentFailureTests|HostRestoreBotRestartTests.testReopenHoldsFailedBotAttemptAndForceDoesNotStartProvider` ran 10 tests, 0 skips, 0 failures, 5.849 seconds. Real Bot Force retained the queue row synchronously, queued one receipt, then accepted once with an ID-only asynchronous event. Admission refusal and Stop-before-dispatch retained the row; definite Agent failure re-paused it. Actual child-process exit/reopen preserved the failed Bot attempt and refused duplicate Force.

Reviewer follow-up `01a147cf-bd2d-7a42-bc68-d8ab3628b7e2` closed all source objections; no new material defect was reported. This is bounded restore/queue proof, not live provider credential or isolation proof. Earlier failed runs are not counted as passing evidence. Existing UI remains untouched. iOS changes are docs-only; no new simulator proof.


## 21-skill coverage ledger

All mandatory installed `SKILL.md` files were read from checker-reported paths. “Applied” means design/spec decision only, never implementation verified.

| Skill | Phase | Status | Decision / reason | Evidence |
|---|---|---|---|---|
| ui-ux-pro-max | Direction + Review | applied | Keep existing UI unchanged; generic generator result not adopted; no visual review claim. | This design; generator run |
| design-system | Direction | not-applicable | No tokens or component specs change. | Scope |
| ui-styling | Direction | not-applicable | No web styling or primitive changes. | Scope |
| brand | Direction | not-applicable | No brand or interface copy change. | Scope |
| apple-design | Direction | applied | Preserve native patterns; no gestures, materials, or motion changes. | Direction |
| emil-design-eng | Direction | not-applicable | No UI component is built or changed. | Scope |
| pick-ui-library | Direction | applied | Add no library; backend/VM gates use existing capabilities. | Constraint |
| animation-vocabulary | Direction | not-applicable | No motion design. | Scope |
| animate | Build | not-applicable | No web animation. | Scope |
| animate-expo | Build | not-applicable | No Expo UI or animation. | Scope |
| mobile-native | Build | not-applicable | No mobile web layout. | Scope |
| prototype | Build | not-applicable | No visual alternatives requested. | Scope |
| ask-sonner | Build | not-applicable | No React toast changes. | Scope |
| write-swift | Build | not-applicable | No Swift code changed in design checkpoint. | Scope |
| design | Build | not-applicable | No visual identity assets. | Scope |
| banner-design | Build | not-applicable | No banners. | Scope |
| slides | Build | not-applicable | No presentation. | Scope |
| find-animation-opportunities | Review | not-applicable | No changed UI or animation surface to inspect. | Scope |
| review-animations | Review | not-applicable | No motion code changed. | Scope |
| improve-animations | Review | not-applicable | No motion assets or multi-file motion work. | Scope |
| break-ui | Review | not-applicable | No rendered data view changed; no worst-case UI fixture applies. | Scope |

## Remaining limits

This checkpoint does not complete the broader contextual-workspaces plan. Live provider credential/isolation proof, VoiceOver and human review remain unverified. No new iOS simulator proof is claimed; iOS changes are documentation only. Schedules remain disabled until explicit user re-enable.

Adjacent regressions on the same tree ran 38 tests, with 2 optional export/verification skips and 0 failures, in 16.974 seconds. Coverage includes ordinary Agent definite-failure retry, prepared recovery, Bot queue ownership/relaunch, SQLite backup, restore, and queue leases. The focused legacy combined run above had no skips. Restart proof uses a real process boundary and database Bootstrap; it disables the separate asynchronous launch-run reconciliation job and does not claim full startup reconciliation coverage.
