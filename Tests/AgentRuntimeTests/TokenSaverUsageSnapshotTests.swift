import XCTest
@testable import AgentRuntime
import CoreModel

/// Token Saver empty snapshot must reserve a slot for every managed agent provider.
final class TokenSaverUsageSnapshotTests: XCTestCase {
    func test_emptySnapshotIncludesGrokProviderSlot() {
        // WHY: Grok has a purple usage ring in the Token Saver card. Without a
        // reserved provider row, the UI only appears after the first Grok run.
        let providers = Set(TokenSaverUsageSnapshot.empty().providers.map(\.provider))
        XCTAssertTrue(providers.contains(.grok),
                      "empty usage snapshot must include .grok for the purple Token Saver ring")
        XCTAssertTrue(providers.contains(.claude))
        XCTAssertTrue(providers.contains(.codex))
    }

    func test_ensuringManagedProviders_addsMissingGrokToLegacySnapshot() {
        // WHY: usage.json written before Grok support only has claude/codex;
        // load must backfill Grok so the UI never treats it as absent.
        let legacy = TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(provider: .claude, actualProviderTokens: 10, weeklyUsedPercent: 50),
            TokenSaverProviderUsage(provider: .codex, actualProviderTokens: 20, weeklyUsedPercent: 30)
        ])
        let fixed = TokenSaverUsageStore.ensuringManagedProviders(legacy)
        let byProvider = Dictionary(uniqueKeysWithValues: fixed.providers.map { ($0.provider, $0) })
        XCTAssertNotNil(byProvider[.grok], "legacy snapshots must gain a Grok row")
        XCTAssertEqual(byProvider[.claude]?.actualProviderTokens, 10,
                       "backfill must not wipe existing Claude totals")
        XCTAssertEqual(byProvider[.codex]?.weeklyUsedPercent, 30)
    }

    /// WHY: inactive Claude left the Token Saver card locked at 45% because the
    /// last successful probe was never expired or cleared.
    func test_effectiveWeeklyUsedPercent_expiresWhenResetIsPast() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_999_000),
                now: now
            ),
            0,
            "a past weekly reset must read as 0% so the ring cannot stay locked mid-window"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_100_000),
                now: now
            ),
            45,
            "an unexpired window must keep the live probe percent"
        )
    }

    func test_providersMissingFromAccountUsageRefresh_listsInactiveProviders() {
        let missing = TokenSaverUsageStore.providersMissingFromAccountUsageRefresh(
            returned: [.codex, .grok]
        )
        XCTAssertEqual(missing, [.claude],
                       "Claude omitted from a partial refresh must be cleared as inactive")
        XCTAssertTrue(
            TokenSaverUsageStore.providersMissingFromAccountUsageRefresh(returned: []).isEmpty == false,
            "empty returned set marks all managed providers missing (caller must not clear on full timeout)"
        )
    }

    /// WHY: Grok frequently showed 0% after a Codex-only partial refresh even
    /// though its weekly credit window was still open (billing log scan missed
    /// the newest `creditUsagePercent` line). Unexpired windows must survive.
    func test_providersToClearAfterPartialRefresh_keepsUnexpiredGrokWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = [
            TokenSaverProviderUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_500_000)
            ),
            TokenSaverProviderUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: nil
            )
        ]
        let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [.codex],
            existing: existing,
            now: now
        )
        XCTAssertFalse(toClear.contains(.grok),
                       "Grok with an unexpired weeklyResetsAt must not be zeroed by a flaky probe miss")
        XCTAssertTrue(toClear.contains(.claude),
                      "Claude without an unexpired window still clears so frozen 45% cannot stick forever")
    }

    func test_providersToClearAfterPartialRefresh_clearsExpiredGrokWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = [
            TokenSaverProviderUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_500_000)
            )
        ]
        let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [.codex],
            existing: existing,
            now: now
        )
        XCTAssertTrue(toClear.contains(.grok),
                      "expired Grok windows may clear; effective % already reads 0")
    }

    func test_clearAccountUsagePercentages_zerosWeeklyButKeepsSavings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TokenSaverUsageStore(appSupportDirectory: dir)
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 2_000,
            eligibleRuns: 3
        )
        _ = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 45,
            weeklyWindowDurationMinutes: 10_080
        )
        _ = try store.clearAccountUsagePercentages(provider: .claude)
        let claude = store.load().providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.weeklyUsedPercent, 0,
                       "inactive Claude must drop to 0% used, not keep the frozen 45%")
        XCTAssertEqual(claude?.actualProviderTokens, 1_000,
                       "clearing rate-limit % must not wipe measured Token Saver savings counters")
    }

    func test_expiringStaleWeeklyUsage_zerosPastWindows() {
        let now = Date(timeIntervalSince1970: 5_000)
        let snap = TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_000)
            ),
            TokenSaverProviderUsage(
                provider: .codex,
                weeklyUsedPercent: 23,
                weeklyResetsAt: Date(timeIntervalSince1970: 6_000)
            )
        ])
        let fixed = TokenSaverUsageStore.expiringStaleWeeklyUsage(snap, now: now)
        let by = Dictionary(uniqueKeysWithValues: fixed.providers.map { ($0.provider, $0) })
        XCTAssertEqual(by[.claude]?.weeklyUsedPercent, 0)
        XCTAssertEqual(by[.codex]?.weeklyUsedPercent, 23)
    }

    func test_record_knownBilledDelta_populatesDayBucketAndWindow() throws {
        // WHY: production must supply known windowed billed units end-to-end;
        // day buckets are the only windowed source (provider totals are cumulative).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-day-billed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedNow = Date(timeIntervalSince1970: 1_784_000_000)
        let store = TokenSaverUsageStore(
            appSupportDirectory: dir,
            calendar: Calendar(identifier: .gregorian),
            now: { fixedNow }
        )
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 8_000,
            estimatedRawTokens: 8_000,
            actualProviderBilledTokenUnits: 1_000,
            estimatedRawBilledTokenUnits: 1_000,
            eligibleRuns: 1
        )
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 2_000,
            estimatedRawTokens: 2_000,
            actualProviderBilledTokenUnits: 250,
            estimatedRawBilledTokenUnits: 250,
            eligibleRuns: 1
        )
        let day = try XCTUnwrap(store.load().daily.first)
        XCTAssertEqual(day.actualProviderTokens, 10_000)
        XCTAssertEqual(day.actualProviderBilledTokenUnits ?? -1, 1_250, accuracy: 0.001)
        XCTAssertEqual(
            TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(
                daily: store.load().daily,
                now: fixedNow
            ) ?? -1,
            1_250,
            accuracy: 0.001
        )
    }

    func test_record_unknownBilledContribution_makesDayBilledNil() throws {
        // WHY: fail-closed — mixing known and unknown billed on one day must not
        // keep a partial sum that pretends to be a complete billed window.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-day-billed-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedNow = Date(timeIntervalSince1970: 1_784_000_000)
        let store = TokenSaverUsageStore(
            appSupportDirectory: dir,
            calendar: Calendar(identifier: .gregorian),
            now: { fixedNow }
        )
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 8_000,
            estimatedRawTokens: 8_000,
            actualProviderBilledTokenUnits: 1_000,
            eligibleRuns: 1
        )
        // Omit billed → provider usage defaults billed-from-raw, but known is nil.
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 2_000,
            estimatedRawTokens: 2_000,
            eligibleRuns: 1
        )
        let day = try XCTUnwrap(store.load().daily.first)
        XCTAssertEqual(day.actualProviderTokens, 10_000)
        XCTAssertNil(day.actualProviderBilledTokenUnits)
        XCTAssertNil(
            TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(
                daily: store.load().daily,
                now: fixedNow
            )
        )
    }

    func test_dayUsage_decodeMissingBilledKey_yieldsNilNotRaw() throws {
        // WHY: historical usage.json without the billed key must stay UNKNOWN
        // (nil), never decode as raw-derived billed and silently re-inflate.
        let seed = TokenSaverDayUsage(
            dayStart: Date(timeIntervalSince1970: 1_784_000_000),
            actualProviderTokens: 8_000,
            estimatedRawTokens: 8_000,
            eligibleRuns: 1,
            actualProviderBilledTokenUnits: 999
        )
        let encoded = try JSONEncoder().encode(seed)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "actualProviderBilledTokenUnits")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TokenSaverDayUsage.self, from: stripped)
        XCTAssertEqual(decoded.actualProviderTokens, 8_000)
        XCTAssertNil(
            decoded.actualProviderBilledTokenUnits,
            "missing JSON key must decode to nil, not Double(actualProviderTokens)"
        )
    }

    /// WHY: bare session 0% from a probe miss painted every Today ring as empty
    /// even when weekly usage was 80%+. Only a live unexpired session window may
    /// keep a true 0%; otherwise session % is missing so the UI can fall back.
    func test_effectiveSessionUsedPercent_ignoresBareZeroWithoutLiveWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: nil,
                now: now
            ),
            "bare 0 without a session reset window must not paint Today as 0% used"
        )
        XCTAssertNil(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 1_500_000),
                now: now
            ),
            "expired session window must not keep a frozen 0%"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 2_500_000),
                now: now
            ),
            0,
            "true mid-window 0% with a future reset must still display as 0%"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 37,
                currentSessionResetsAt: nil,
                now: now
            ),
            37,
            "positive session % without reset metadata remains usable"
        )
    }

    func test_providerBilledProvenance_roundTripPreservesUnknownAndMeasured() throws {
        // WHY: the stored raw-token fallback must not become a provider-billed
        // measurement merely because JSONEncoder wrote its numeric value.
        let unknown = TokenSaverProviderUsage(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200
        )
        let measured = TokenSaverProviderUsage(
            provider: .codex,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200,
            actualProviderBilledTokenUnits: 250
        )

        let encoded = try JSONEncoder().encode([unknown, measured])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(
            object[0]["actualProviderBilledTokenUnitsProvenance"] as? String,
            "unknown"
        )
        XCTAssertEqual(
            object[1]["actualProviderBilledTokenUnitsProvenance"] as? String,
            "measured"
        )

        let decoded = try JSONDecoder().decode(
            [TokenSaverProviderUsage].self,
            from: encoded
        )

        XCTAssertEqual(decoded[0].actualProviderBilledTokenUnits, 1_000, accuracy: 0.001)
        XCTAssertNil(
            decoded[0].knownActualProviderBilledTokenUnits,
            "unknown fallback must stay unknown after persistence"
        )
        XCTAssertEqual(
            try XCTUnwrap(decoded[1].knownActualProviderBilledTokenUnits),
            250,
            accuracy: 0.001,
            "an explicitly measured billed value must stay measured after persistence"
        )
    }

    func test_providerBilledProvenance_legacyJSONIsConservativelyUnknown() throws {
        // WHY: historical JSON has a numeric billed key but no origin bit, so it
        // cannot prove whether the number was measured or synthesized from raw.
        let legacy = """
        {
          "provider": "claude",
          "actualProviderTokens": 1000,
          "estimatedRawTokens": 1200,
          "actualProviderBilledTokenUnits": 250,
          "estimatedRawBilledTokenUnits": 300,
          "eligibleRuns": 1,
          "currentSessionTokens": 0,
          "currentSessionLimitTokens": 0
        }
        """

        let decoded = try JSONDecoder().decode(
            TokenSaverProviderUsage.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.actualProviderBilledTokenUnits, 250, accuracy: 0.001)
        XCTAssertNil(
            decoded.knownActualProviderBilledTokenUnits,
            "legacy numeric values without provenance must not be promoted to measurements"
        )
    }

    func test_providerBilledProvenance_mergeAndAccountUpdateStayConservative() throws {
        // WHY: managed providers start as empty unknown rows. That zero-value
        // placeholder must not poison a first measured delta, while any real
        // unknown token contribution must keep the aggregate unknown.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-billed-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TokenSaverUsageStore(appSupportDirectory: directory)
        _ = try store.recordAccountUsage(provider: .grok, weeklyUsedPercent: 12)
        let accountOnly = try XCTUnwrap(store.load().providers.first { $0.provider == .grok })
        XCTAssertNil(
            accountOnly.knownActualProviderBilledTokenUnits,
            "an account quota update alone must not invent a billed measurement"
        )
        _ = try store.record(
            provider: .grok,
            actualProviderTokens: 0,
            estimatedRawTokens: 0,
            eligibleRuns: 0
        )
        let emptyMerge = try XCTUnwrap(store.load().providers.first { $0.provider == .grok })
        XCTAssertNil(
            emptyMerge.knownActualProviderBilledTokenUnits,
            "merging two empty unknown rows must not manufacture a known zero"
        )

        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200,
            actualProviderBilledTokenUnits: 250
        )
        var claude = try XCTUnwrap(store.load().providers.first { $0.provider == .claude })
        XCTAssertEqual(
            try XCTUnwrap(claude.knownActualProviderBilledTokenUnits),
            250,
            accuracy: 0.001,
            "the empty managed-provider row is not an unknown usage contribution"
        )

        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 200,
            estimatedRawTokens: 240,
            actualProviderBilledTokenUnits: 50
        )
        claude = try XCTUnwrap(store.load().providers.first { $0.provider == .claude })
        XCTAssertEqual(
            try XCTUnwrap(claude.knownActualProviderBilledTokenUnits),
            300,
            accuracy: 0.001,
            "two measured deltas must merge into a measured aggregate"
        )

        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 20)
        claude = try XCTUnwrap(store.load().providers.first { $0.provider == .claude })
        XCTAssertEqual(
            try XCTUnwrap(claude.knownActualProviderBilledTokenUnits),
            300,
            accuracy: 0.001,
            "account quota updates must preserve, not manufacture or erase, billed provenance"
        )

        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 100,
            estimatedRawTokens: 100
        )
        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 21)
        claude = try XCTUnwrap(store.load().providers.first { $0.provider == .claude })
        XCTAssertNil(
            claude.knownActualProviderBilledTokenUnits,
            "a real unknown contribution must keep the merged total unknown across account updates"
        )
    }

    func test_crossProcessLock_serializesEveryMutationWhileReadsRemainComplete() throws {
        // WHY: provider proxies and the app update the same usage.json. Without
        // one stable cross-process lock, two valid read-modify-writes can each
        // atomically replace the file while silently dropping the other's delta.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-cross-process-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TokenSaverUsageStore(appSupportDirectory: directory)
        try store.save(TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(
                provider: .grok,
                actualProviderTokens: 10,
                estimatedRawTokens: 10
            )
        ]))
        let lockURL = directory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.lock", isDirectory: false)

        let readHolder = try ExternalUsageLockHolder.acquire(path: lockURL.path)
        let readCompleted = DispatchSemaphore(value: 0)
        let readResult = UsageMutationResult()
        DispatchQueue.global().async {
            let loaded = store.load()
            readResult.setSnapshot(loaded)
            readCompleted.signal()
        }
        XCTAssertEqual(
            readCompleted.wait(timeout: .now() + 1),
            .success,
            "atomic replacement lets readers return a complete old/new snapshot without waiting on writers"
        )
        XCTAssertEqual(readResult.snapshot?.providers.first(where: { $0.provider == .grok })?.actualProviderTokens, 10)
        XCTAssertEqual(readHolder.releaseAndWait(), 0)

        let mutations: [(String, @Sendable () throws -> Void)] = [
            ("direct save", { try store.save(store.load()) }),
            ("record", {
                _ = try store.record(
                    provider: .grok,
                    actualProviderTokens: 7,
                    estimatedRawTokens: 7
                )
            }),
            ("account update", {
                _ = try store.recordAccountUsage(provider: .grok, weeklyUsedPercent: 44)
            }),
            ("account clear", {
                _ = try store.clearAccountUsagePercentages(provider: .grok)
            })
        ]

        for (name, mutation) in mutations {
            let holder = try ExternalUsageLockHolder.acquire(path: lockURL.path)
            let completed = DispatchSemaphore(value: 0)
            let result = UsageMutationResult()
            DispatchQueue.global().async {
                do {
                    try mutation()
                } catch {
                    result.setError(error)
                }
                completed.signal()
            }
            XCTAssertEqual(
                completed.wait(timeout: .now() + 0.15),
                .timedOut,
                "\(name) must wait while another process owns usage.lock"
            )
            XCTAssertEqual(holder.releaseAndWait(), 0, "native lock-holder process must exit cleanly")
            XCTAssertEqual(
                completed.wait(timeout: .now() + 2),
                .success,
                "\(name) must resume after the cross-process lock is released"
            )
            if let error = result.error {
                XCTFail("\(name) failed after lock release: \(error)")
            }
        }

        let loaded = store.load()
        let grok = try XCTUnwrap(loaded.providers.first(where: { $0.provider == .grok }))
        XCTAssertEqual(grok.actualProviderTokens, 17)
        XCTAssertEqual(grok.weeklyUsedPercent, 0)
        let usageURL = lockURL.deletingLastPathComponent().appendingPathComponent("usage.json")
        _ = try JSONDecoder().decode(TokenSaverUsageSnapshot.self, from: Data(contentsOf: usageURL))

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600, "the stable sibling lock must be owner-only")
    }
}

private final class UsageMutationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedSnapshot: TokenSaverUsageSnapshot?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var snapshot: TokenSaverUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func setSnapshot(_ snapshot: TokenSaverUsageSnapshot) {
        lock.lock()
        storedSnapshot = snapshot
        lock.unlock()
    }
}

/// `/usr/bin/lockf` is a separate native process that uses the same BSD flock
/// contract as production. Its command writes a ready file only after acquiring
/// the lock, then waits for the parent to write a release file.
private final class ExternalUsageLockHolder {
    private let process: Process
    private let releaseURL: URL
    private var released = false

    private init(process: Process, releaseURL: URL) {
        self.process = process
        self.releaseURL = releaseURL
    }

    static func acquire(path: String) throws -> ExternalUsageLockHolder {
        let markerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-lock-holder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let readyURL = markerDirectory.appendingPathComponent("ready")
        let releaseURL = markerDirectory.appendingPathComponent("release")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            "-k",
            "-w",
            path,
            "/bin/sh",
            "-c",
            "/usr/bin/touch \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.01; done",
            "usage-lock-holder",
            readyURL.path,
            releaseURL.path
        ]
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyURL.path),
              process.isRunning,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path), process.isRunning else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: markerDirectory)
            throw NSError(
                domain: "TokenSaverUsageSnapshotTests.ExternalUsageLockHolder",
                code: Int(process.terminationStatus)
            )
        }
        return ExternalUsageLockHolder(process: process, releaseURL: releaseURL)
    }

    @discardableResult
    func releaseAndWait() -> Int32 {
        guard !released else { return process.terminationStatus }
        released = true
        FileManager.default.createFile(atPath: releaseURL.path, contents: Data())
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: releaseURL.deletingLastPathComponent())
        return process.terminationStatus
    }

    deinit {
        _ = releaseAndWait()
    }
}
