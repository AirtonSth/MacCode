# Contextual offline intent

## Security contract

A contextual offline outbox row records the user's pinned intent; it is not authorization and does not enable contextual execution. Public contextual provider/peer execution and restricted-mode gates remain closed. Online contextual send stays unavailable, even when authority is valid. Existing UI and layout remain unchanged; legacy unpinned queue behavior remains intact.

Context identity is immutable: host, Bot, context key/version, policy revision, conversation, and thread stay bound to the original intent. Contextual entries require the existing explicit review/approve action. Merely enqueueing, reopening, reconnecting, or backgrounding never approves or sends one. Revoked, foreign, malformed, unsupported, or mismatched context fails closed. No queue path may silently retarget, discard, duplicate, or mint a replacement logical ID. Queueing must not create a conversation, grant, message, or run, and must not upload attachments.

The encrypted envelope uses schema v2 when any entry carries context metadata and v1 for legacy-only entries. Context-bearing data requires v2; a v1-only reader refuses rather than ignore context and reinterpret an entry as legacy. Contextual v2 uses version-bound authenticated data (AAD); older encrypted data fails closed without deleting the original. Missing optional metadata remains legacy; unknown bounded context metadata remains non-authoritative and cannot pass strict drain validation.

## Implemented behavior and existing controls

The changes add durable contextual offline intent through existing Send/offline-outbox UX, without a new control or layout. Existing explicit-review captions are reused for contextual entries; their exact contextual target wording is not confirmed here. The existing target chip presents the selected identity. Explicit approval remains the only approval boundary. Online contextual execution remains refused; public contextual provider/peer execution and restricted-mode gates remain closed.

Context intent retains original host/Bot/context/version/policy and conversation/thread identity. Queue/retry/reopen preserves original request ID, body, attachment bytes/metadata, and target. Matching duplicate requests do not mint a new logical intent; conflicting contextual payloads do not silently resolve to another target. Unsupported data fails closed without deleting the encrypted source. A source-plan laundering refusal was found, fixed, and tested; no gate was enabled.

## Baselines and worktrees

- macOS baseline: `85db47b3198b43c225445a9ce32d612b9c81934e`; worktree: `/Users/samuelfajreldines/dev/remote-code/macos-app/.sandbox-worktrees/20261016T013608Z`.
- iOS baseline: `41f87783f6dfaff00ad1e1eff526796c6ca11361`; worktree: `/Users/samuelfajreldines/dev/remote-code/ios-app/.sandbox-worktrees/contextual-workspaces-20261015`.

## Verification evidence

- iOS App/Tests tree `a721f1f62fe8f9cb4aa3156ee0ae40e30e8b4e3a`: 388 tests, 0 failures, 1 pre-existing optional render-probe skip, exit 0, 11.750 seconds. This final run follows whitespace-only cleanup of the test file; production sources are unchanged from tree `fc3d1b3f916cba45c652573ae9556c6afdfd5242`.
- iOS App/Tests/UITests tree `852b7fec5da800b517ad8672734180b48838d3b0`: real-host cold UI, 1 pass, 53.720 seconds, exit 0, on owned iPhone 17 / iOS 26.5. Native first pairing used a dedicated persistent profile; its keychain flag was reset only for first launch. Offline enqueue used controlled app network-policy injection (observer loopback HTTP remained healthy; this was not a radio outage). After full app termination/relaunch, the canonical target chip, same request ID/body, and empty composer restored without re-pairing or navigation repair. Message count had no pre-revocation effect. Real observer revoked authority A (revision 2) while B remained active (revision 1); reconnect did not send. Explicit “Send now” was refused and preserved the same row/body/ID. Parent visually inspected cold, restored, and refusal captures; no stuck loader appeared. No personal data was accessed.
- macOS current tree `a69e1f50696f43522fb8b07499f054768ff65cf9`: packaged-host verification; 17 tests, 0 failures, 4.195 seconds, including source-plan guard. No cold native macOS runtime result is claimed.

The real-route UI test initially failed because its shell reset did not restore pairing directly; the test was fixed. A second run exposed residual pairing state from an earlier simulator run before queueing; clean owned-simulator rerun passed. These earlier failures are not hidden as passing runs.

After stopping the owned host, the read-only copied-database verifier and queue suite passed 18 tests with 0 failures in 4.702 seconds on macOS tree `a69e1f50696f43522fb8b07499f054768ff65cf9`. A stayed revoked at revision 2, B and A’s workspace stayed active at revision 1, canonical pins remained unchanged, user messages stayed zero, and each original synthetic completed run count stayed 1. The verifier opens the database read-only twice.

Cleanup confirmed owned host PID 77531 gone, port 18228 absent, owned simulator `EDA3CA43-7E2D-4972-89D5-44C376238C44` deleted, and both task-owned copied fixture directories removed. The final unit-test simulator `BCB33A33-5695-4D45-8B8A-FA38CF17E78A` was also deleted and its absence verified. The pre-existing sandbox home was preserved.

Full routines, replay, restore, interoperability, isolation, full keyboard/VoiceOver accessibility, and human coverage remain pending. The cold iOS scenario is not proof of full accessibility or routine lifecycle coverage. No successful contextual provider execution is claimed.

## Design skill coverage ledger

All 21 mandatory installed `SKILL.md` source files were read for this checkpoint. Checker: `python3 /Users/samuelfajreldines/.grok/skills/sam-design/scripts/check_design_skills.py` — exit 0, 46/46 installed. The parent ran `python3 /Users/samuelfajreldines/.grok/skills/ui-ux-pro-max/scripts/search.py 'native productivity offline message queue explicit review' --design-system -p 'RemoteCode Existing Native Outbox'`; it exited 0. Existing native product controls take precedence over generic marketing-layout recommendations. No complete accessibility verification is claimed.

| Skill | Phase | Status | Checkpoint application / reason |
|---|---|---|---|
| ui-ux-pro-max | Direction + Review | applied | Existing native outbox/action hierarchy and contextual review captions retained; exact target wording not confirmed. |
| design-system | Direction | applied | Reused existing native controls/tokens; no new styling system. |
| ui-styling | Direction | not-applicable | No web styling, theme, or Tailwind/shadcn surface in this native checkpoint. |
| brand | Direction | not-applicable | No brand identity, logo, or brand-color decision. |
| apple-design | Direction | applied | Kept native existing outbox controls and visible refusal path; full accessibility remains pending. |
| emil-design-eng | Direction | applied | Kept predictable explicit review action; added no motion. |
| pick-ui-library | Direction | not-applicable | Existing native UX reused; no new capability needed a library. |
| animation-vocabulary | Direction | not-applicable | No motion design requested or changed. |
| animate | Build | not-applicable | No web animation changed. |
| animate-expo | Build | not-applicable | iOS app is native, not Expo; no animation changed. |
| mobile-native | Build | not-applicable | No mobile web/CSS surface. |
| prototype | Build | not-applicable | Existing interaction preserved; no alternate visual directions requested. |
| ask-sonner | Build | not-applicable | No React toast surface. |
| write-swift | Build | applied | Shipped Swift queue, session, and UI code reviewed/changed in this checkpoint. |
| design | Build | not-applicable | No logo, icon, or visual asset work. |
| banner-design | Build | not-applicable | No banner or campaign asset. |
| slides | Build | not-applicable | No presentation deliverable. |
| find-animation-opportunities | Review | not-applicable | Checkpoint adds no visual interaction needing motion; no animation was proposed. |
| review-animations | Review | not-applicable | No animation implementation changed. |
| improve-animations | Review | not-applicable | No motion audit or motion changes in scope. |
| break-ui | Review | applied | Negative, cold-reopen, and revocation fixtures exercised; one real-host cold UI scenario passed as detailed above. This is not full accessibility or human validation. |

Existing native controls and explicit user authorization took precedence over generic design suggestions. Device evidence is limited to the iPhone 17 cold scenario described above; full keyboard, VoiceOver, and human validation remain unverified.
