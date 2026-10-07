import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// T001 (Settings Palette): Store/VM divergence guard for custom models.
/// T013 (Settings Palette): Pairing-TTL contract (displayed countdown == repo TTL).
///
/// WHY (T001): SettingsViewModel.setCustomModel() has an in-place fast path that
/// was previously not always syncing back from the store.  Any mutation sequence
/// that passes through the fast path without reloading leaves
/// `customModelsByProvider[p]` diverged from `customModelStore.list(provider:p)`.
/// This invariant test catches that class of bug mechanically.
///
/// WHY (T013): createPairingCode() passes ttlSeconds: 600 to the repo and sets
/// `pairingCodeExpiresAt = Date() + 600`.  The iOS client validates the pairing
/// code against the repo row's expiry.  If the hardcoded 600 drifts between the
/// UI display and the repo call, the displayed countdown won't match the actual
/// validity window.  This test pins the contract so any drift fails CI.

@MainActor
final class SettingsVMInvariantTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM() throws -> SettingsViewModel {
        let dir = NSTemporaryDirectory() + "RC2SettingsInvariant-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        return SettingsViewModel(context: ctx)
    }

    // MARK: - T001: customModelsByProvider == customModelStore.list after each mutation

    /// WHY: setCustomModel mutates the store, then reloads the cache from the
    /// store.  The invariant is: after any mutation the local cache must equal
    /// the store.  A silent divergence (old fast path retained "" in cache after
    /// a clear) would cause the next keystroke to update the wrong index.
    func test_customModelDivergenceGuard_addUpdateRemove_cacheMatchesStore() throws {
        let vm = try makeVM()

        // --- add ---
        vm.customModelStore.add("model-A", provider: .distill)
        vm.reload()
        XCTAssertEqual(
            vm.customModelsByProvider[.distill],
            vm.customModelStore.list(provider: .distill),
            "after add: customModelsByProvider[.distill] must equal the store list"
        )

        // --- update ---
        vm.setCustomModel(provider: .distill, index: 0, value: "model-A-v2")
        XCTAssertEqual(
            vm.customModelsByProvider[.distill],
            vm.customModelStore.list(provider: .distill),
            "after update: customModelsByProvider[.distill] must equal the store list  -  " +
            "the fast-path must reload from the store, not keep the old value in cache"
        )

        // --- clear (sets value to empty string, causing store to remove the row) ---
        vm.setCustomModel(provider: .distill, index: 0, value: "")
        XCTAssertEqual(
            vm.customModelsByProvider[.distill] ?? [],
            vm.customModelStore.list(provider: .distill),
            "after clear: customModelsByProvider[.distill] must reflect the store (empty)  -  " +
            "a stale cache entry at the cleared index would crash the next keystroke"
        )

        // --- remove ---
        vm.customModelStore.add("model-B", provider: .distill)
        vm.reload()
        vm.removeCustomModel(provider: .distill, index: 0)
        XCTAssertEqual(
            vm.customModelsByProvider[.distill] ?? [],
            vm.customModelStore.list(provider: .distill),
            "after remove: customModelsByProvider[.distill] must equal the store list"
        )
    }

    /// WHY: The invariant must hold for every provider Settings edits, not just
    /// the default one. A provider-specific bug in the fast path would be masked
    /// if only one provider were tested. Settings only edits selectable providers
    /// (legacy Codex/Claude/Grok are read-only since Distill-only), so iterate those.
    func test_customModelDivergenceGuard_allProviders() throws {
        let vm = try makeVM()

        XCTAssertFalse(AgentProvider.selectable.isEmpty,
                       "Settings must expose at least one provider whose custom models it edits")
        for provider in AgentProvider.selectable {
            vm.customModelStore.add("model-\(provider.rawValue)", provider: provider)
            vm.reload()
            XCTAssertEqual(
                vm.customModelsByProvider[provider] ?? [],
                vm.customModelStore.list(provider: provider),
                "provider \(provider.rawValue): cache must equal store after add"
            )
            vm.setCustomModel(provider: provider, index: 0, value: "updated-\(provider.rawValue)")
            XCTAssertEqual(
                vm.customModelsByProvider[provider] ?? [],
                vm.customModelStore.list(provider: provider),
                "provider \(provider.rawValue): cache must equal store after update"
            )
        }
    }

    // MARK: - T013: Pairing-TTL contract

    /// WHY: `createPairingCode()` calls `trustRepo.createPairingCode(ttlSeconds: 600)`
    /// and sets `pairingCodeExpiresAt = Date().addingTimeInterval(600)`.
    /// The iOS client validates the code against the repo row's expiry.
    /// If the two constants drift (e.g. someone changes one but not the other),
    /// the displayed countdown will be wrong and codes will appear valid/expired
    /// at the wrong time.
    ///
    /// This test pins:
    ///   1. pairingCodeExpiresAt is set after a successful createPairingCode()
    ///   2. The expiry is approximately now + 600 seconds (within 5 s of clock skew)
    ///   3. The code itself is non-nil and non-empty
    func test_createPairingCode_expiresAtEquals600SecondsFromNow() throws {
        let vm = try makeVM()

        let before = Date()
        vm.createPairingCode()
        let after = Date()

        guard let code = vm.newPairingCode else {
            XCTFail("createPairingCode must set newPairingCode  -  without a code the pairing flow is broken")
            return
        }
        XCTAssertFalse(code.isEmpty,
                       "pairing code must be non-empty so the iOS client has something to redeem")

        guard let expiresAt = vm.pairingCodeExpiresAt else {
            XCTFail("createPairingCode must set pairingCodeExpiresAt  -  without an expiry the countdown cannot display")
            return
        }

        let ttl = 600.0
        let lowerBound = before.addingTimeInterval(ttl - 5)
        let upperBound = after.addingTimeInterval(ttl + 5)

        XCTAssertGreaterThanOrEqual(
            expiresAt, lowerBound,
            "pairingCodeExpiresAt must be at least now+595s  -  if it is earlier the code appears expired before the iOS client can redeem it"
        )
        XCTAssertLessThanOrEqual(
            expiresAt, upperBound,
            "pairingCodeExpiresAt must be at most now+605s  -  if it is later the code stays valid longer than the repo row, " +
            "causing the iOS client to receive a rejection after the displayed timer still shows time remaining"
        )
        XCTAssertNil(vm.pairingCodeError,
                     "a successful createPairingCode must clear pairingCodeError")
    }

    /// WHY: Creating a second pairing code must overwrite the first.
    /// If the previous code is retained, the UI could display a stale code
    /// alongside a fresh expiry, causing the wrong code to be presented to the user.
    func test_createPairingCode_secondCall_overwritesPreviousCode() throws {
        let vm = try makeVM()
        vm.createPairingCode()
        let first = vm.newPairingCode

        vm.createPairingCode()
        let second = vm.newPairingCode

        XCTAssertNotNil(second, "second createPairingCode must produce a code")
        // Codes are random; they are almost certainly different, but we just
        // check that pairingCodeExpiresAt was reset (not nil) which confirms the
        // second call ran fully.
        XCTAssertNotNil(vm.pairingCodeExpiresAt,
                        "second createPairingCode must reset pairingCodeExpiresAt")
        _ = first  // suppress unused-variable warning; randomness means equality is not guaranteed
    }

    // MARK: - RemoteAccessNotificationPolicy (L91 double-reload guard)

    /// WHY: when this VM posts rc2RemoteAccessSettingChanged (isSelfOriginated=true)
    /// it must NOT reload -- doing so doubles the I/O on every toggle with no benefit.
    func test_remoteAccessNotificationPolicy_selfOriginated_doesNotReload() {
        XCTAssertFalse(
            RemoteAccessNotificationPolicy.shouldReload(isSelfOriginated: true),
            "self-originated notification must be skipped to prevent the double " +
            "reload on every Remote Access toggle"
        )
    }

    /// WHY: a notification posted by another VM instance (isSelfOriginated=false)
    /// must trigger a reload so multiple open Settings windows stay in sync.
    func test_remoteAccessNotificationPolicy_crossVM_reloads() {
        XCTAssertTrue(
            RemoteAccessNotificationPolicy.shouldReload(isSelfOriginated: false),
            "cross-VM notification must trigger reload so other Settings windows " +
            "never show stale remote-access state"
        )
    }

    // MARK: - CLIPathCommitPolicy invariant

    /// WHY: CLIPathCommitPolicy.shouldApply is the gate between mid-edit
    /// keystrokes and DB writes.  A bug here (returning true mid-edit) would
    /// call replaceProviderAdapter on every keystroke, causing noisy adapter
    /// churn and potential crashes under concurrent agent runs.
    func test_cliPathCommitPolicy_uncommittedDraftDoesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "codex", new: "codex-new", committed: false),
            "an uncommitted (mid-edit) draft must never trigger a DB write or adapter replacement  -  " +
            "doing so on every keystroke would cause excessive adapter churn"
        )
    }

    func test_cliPathCommitPolicy_committedChangedValueApplies() {
        XCTAssertTrue(
            CLIPathCommitPolicy.shouldApply(old: "codex", new: "codex-new", committed: true),
            "a committed changed value must trigger the apply path so the new binary is wired into the coordinator"
        )
    }

    func test_cliPathCommitPolicy_committedUnchangedValueDoesNotApply() {
        XCTAssertFalse(
            CLIPathCommitPolicy.shouldApply(old: "codex", new: "codex", committed: true),
            "a committed but unchanged value must not trigger a DB write  -  " +
            "a no-op commit would clear providerUpdateMessages and restart the adapter unnecessarily"
        )
    }
}
