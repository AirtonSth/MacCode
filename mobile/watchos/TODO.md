# Apple Watch App - Bugs & Issues

## CRITICAL

### 1. Snapshot out-of-order overwrite (data corruption)
**File:** `Sources/Core/WatchSnapshotPresentation.swift:61`
`applySnapshotJSONString` replaces the current snapshot without checking `updatedAtMs`. If WCSession delivers an older applicationContext after a newer one (e.g. after session reactivation), the Watch will display stale data.
**Fix:** Compare `updatedAtMs` of incoming snapshot against current snapshot; reject if older.

### 2. Race condition in WatchSnapshotSession.init()
**File:** `Sources/App/WatchSnapshotSession.swift:21-33`
`init()` reads UserDefaults first, then unconditionally overwrites with `receivedApplicationContext`. If the persisted snapshot is newer than what's in `receivedApplicationContext`, the newer state is lost.
**Fix:** Compare `updatedAtMs` from both sources and keep the most recent.

### 3. SKIP_INSTALL = YES prevents App Store distribution
**File:** `RemoteCodeWatch.xcodeproj/project.pbxproj:346,363`
Both Debug and Release configs set `SKIP_INSTALL = YES`. This means the Watch app binary won't be included in the Xcode archive, making it impossible to submit to the App Store.
**Fix:** Set `SKIP_INSTALL = NO` (or remove it, since NO is the default for app targets).

### 4. pendingSnapshot never cleared after successful push (iOS side)
**File:** `ios/RemoteCode/RemoteCodeSharedSnapshotModule.swift:87-95`
`mirrorSnapshotToWatch` sets `pendingSnapshot` before the push, but it's never cleared on success. When `sessionDidDeactivate` reactivates the session and `activationDidCompleteWith` fires, the stale `pendingSnapshot` is re-sent to the Watch, potentially overwriting a newer snapshot.
**Fix:** Set `pendingSnapshot = nil` after a successful `updateApplicationContext` call.

### 5. No app icon asset catalog
**File:** `project.yml`, `project.pbxproj:337,355`
Build settings reference `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` but there is no `.xcassets` directory in the project. The app will build and run but show a blank icon on the Watch home screen, and will be rejected by App Store review.
**Fix:** Create `Assets.xcassets` with an AppIcon set containing all required watchOS icon sizes.

---

## BUGS

### 6. Swift version inconsistency across configs
- `project.yml` declares `SWIFT_VERSION: 5.10`
- `project.pbxproj` Watch target configs use `SWIFT_VERSION = 5.1`
- `project.pbxproj` project-level configs use `SWIFT_VERSION = 5.0`
- Test target configs use `SWIFT_VERSION = 5.1`

XcodeGen-generated pbxproj appears stale or was manually edited. This can cause unexpected compilation behavior if the wrong Swift version is picked up.
**Fix:** Regenerate pbxproj from project.yml (`xcodegen generate`) and ensure 5.10 is consistent everywhere.

### 7. Timer display breaks for sessions > 59 minutes
**File:** `Sources/App/WatchSnapshotContentView.swift:3-8`
`formatFrozenDuration` only formats `MM:SS`. A 90-minute session shows `90:00` instead of `1:30:00`. This is confusing for long-running agent sessions.
**Fix:** Add hours handling: `HH:MM:SS` when >= 60 minutes, `MM:SS` otherwise.

### 8. No visual differentiation for error/failed states
**File:** `Sources/App/WatchSnapshotContentView.swift:35-38`
The badge always uses `.cyan` regardless of phase. Failed/Error states look identical to Running, giving no visual indication something went wrong.
**Fix:** Use `.red` or `.orange` for `.failed`/`.error` badge and background tint.

### 9. Scheme name mismatch
**File:** `project.yml:46-52`
project.yml defines the test scheme as `RemoteCodeWatchLogic` but the generated scheme file is `RemoteCodeWatchLogicTests.xcscheme`. This can cause CI confusion and scheme-not-found errors.
**Fix:** Align the scheme name in project.yml to `RemoteCodeWatchLogicTests`.

### 10. Version mismatch with iOS app
**File:** `project.yml:22-23`, `project.pbxproj:342,358`
Watch app is at `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 1` while the iOS app is at version `1.0.6`. Apple requires paired Watch/iOS apps to have coordinated versioning for App Store submission.
**Fix:** Sync version to `1.0.6` (or current iOS version) and keep them in lockstep.

---

## IMPROVEMENTS (should fix before shipping)

### 11. deepLink field received but never used
**File:** `Sources/Core/LiveActivitySharedSnapshot.swift:40`
The snapshot carries a `deepLink` URL string but the Watch app never uses it. This should either open the companion iOS app via `WKExtension.shared().openSystemURL()` or be used for handoff.
**Fix:** Add a tap gesture on the content view that opens the deep link on the paired iPhone.

### 12. schemaVersion not validated
**File:** `Sources/Core/WatchSnapshotPresentation.swift:73`
`applySnapshotJSONString` decodes the snapshot without checking `schemaVersion`. If the iOS app sends a future schema version with breaking changes, the Watch app will either crash on decode or display incorrect data.
**Fix:** Check `schemaVersion == 1` after decoding; ignore snapshots with unknown versions.

### 13. finalizingThreadCount and runningThreadCount are unused
**File:** `Sources/Core/LiveActivitySharedSnapshot.swift:42,46`
These fields are decoded but never referenced in presentation logic. The UI only uses `activeThreadCount`.
**Fix:** Either display these counts (e.g. "2 running, 1 finalizing") or remove them from the Watch-side model to reduce payload size.

### 14. activationDidCompleteWith ignores errors
**File:** `Sources/App/WatchSnapshotSession.swift:36-40`
The delegate method is empty. If WCSession activation fails, the app silently stays in a broken state with no retry and no feedback.
**Fix:** Log the error, and if activation failed, show a "Cannot connect to iPhone" state in the UI.

### 15. No accessibility support
**File:** `Sources/App/WatchSnapshotContentView.swift`
No `accessibilityLabel`, `accessibilityValue`, or `accessibilityHint` modifiers on any view. VoiceOver users get meaningless or auto-generated labels.
**Fix:** Add accessibility labels to timer, badge, thread count, and status views.

### 16. No empty/loading state distinction
**File:** `Sources/App/WatchSnapshotContentView.swift:26-84`
When the app launches for the first time (no persisted snapshot, WCSession not yet activated), it immediately shows "Waiting for a session" idle state. There's no way to distinguish between "loading initial data" and "genuinely idle."
**Fix:** Add a brief loading state while WCSession activates, then fall through to idle if no snapshot exists.

### 17. No haptic feedback on state transitions
The Watch app doesn't play any haptic when the session transitions between phases (e.g. running -> completed, running -> failed). This is expected behavior for watchOS apps.
**Fix:** Use `WKInterfaceDevice.current().play(.success)` on completion, `.failure` on error/failed.

### 18. Test coverage gaps
**File:** `Tests/RemoteCodeWatchLogicTests/WatchSnapshotPresentationTests.swift`
Only 4 tests covering happy paths. Missing:
- Error/failed phase presentation
- Malformed JSON handling (partial fields, wrong types)
- Schema version mismatch behavior
- Live timer state (elapsedSecondsSnapshot = nil, non-terminal phase)
- Empty string vs nil vs whitespace-only input
- Extremely large `startedAtMs` values
- `activeThreadCount = 0` with non-terminal phase

### 19. No complication / Widget support
The Watch app has no WidgetKit complications. Users have to open the app to see status. A complication showing current phase and thread count would be the primary way most users interact with the Watch app.
**Fix:** Add a WidgetKit-based complication target reading from shared UserDefaults.

### 20. No background refresh
The Watch app only updates via WCSession applicationContext, which requires the companion iPhone app to be reachable. If the iPhone is out of range or the app is killed, the Watch shows stale data with no indication it's stale.
**Fix:** Consider adding `WKApplicationRefreshBackgroundTask` and/or showing a "last updated X ago" timestamp.

### 21. WatchSnapshotSession is not testable
**File:** `Sources/App/WatchSnapshotSession.swift`
The session class directly instantiates `WCSession.default` and `UserDefaults.standard` with no injection points, making it impossible to unit test without the simulator.
**Fix:** Accept `UserDefaults` and a `WCSession` provider via init parameters for dependency injection.
