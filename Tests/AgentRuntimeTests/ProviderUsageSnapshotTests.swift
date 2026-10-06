import XCTest
@testable import AgentRuntime
import CoreModel

/// Token Saver empty snapshot must reserve a slot for every managed agent provider.
final class ProviderUsageSnapshotTests: XCTestCase {
    func test_emptySnapshotIncludesGrokProviderSlot() {
        // WHY: Grok has a purple usage ring in the Token Saver card. Without a
        // reserved provider row, the UI only appears after the first Grok run.
        let providers = Set(ProviderUsageSnapshot.empty().providers.map(\.provider))
        XCTAssertTrue(providers.contains(.grok),
                      "empty usage snapshot must include .grok for the purple Token Saver ring")
        XCTAssertTrue(providers.contains(.claude))
        XCTAssertTrue(providers.contains(.codex))
    }

    func test_ensuringManagedProviders_addsMissingGrokToLegacySnapshot() {
        // WHY: usage.json written before Grok support only has claude/codex;
        // load must backfill Grok so the UI never treats it as absent.
        let legacy = ProviderUsageSnapshot(period: .sevenDays, providers: [
            ProviderTokenUsage(provider: .claude, actualProviderTokens: 10, weeklyUsedPercent: 50),
            ProviderTokenUsage(provider: .codex, actualProviderTokens: 20, weeklyUsedPercent: 30)
        ])
        let fixed = ProviderUsageStore.ensuringManagedProviders(legacy)
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
            ProviderTokenUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_999_000),
                now: now
            ),
            0,
            "a past weekly reset must read as 0% so the ring cannot stay locked mid-window"
        )
        XCTAssertEqual(
            ProviderTokenUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_100_000),
                now: now
            ),
            45,
            "an unexpired window must keep the live probe percent"
        )
    }

    func test_providersMissingFromAccountUsageRefresh_listsInactiveProviders() {
        let missing = ProviderUsageStore.providersMissingFromAccountUsageRefresh(
            returned: [.codex, .grok]
        )
        XCTAssertEqual(missing, [.claude],
                       "Claude omitted from a partial refresh must be cleared as inactive")
        XCTAssertTrue(
            ProviderUsageStore.providersMissingFromAccountUsageRefresh(returned: []).isEmpty == false,
            "empty returned set marks all managed providers missing (caller must not clear on full timeout)"
        )
    }

    /// WHY: Grok frequently showed 0% after a Codex-only partial refresh even
    /// though its weekly credit window was still open (billing log scan missed
    /// the newest `creditUsagePercent` line). Unexpired windows must survive.
    func test_providersToClearAfterPartialRefresh_keepsUnexpiredGrokWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = [
            ProviderTokenUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_500_000)
            ),
            ProviderTokenUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: nil
            )
        ]
        let toClear = ProviderUsageStore.providersToClearAfterPartialAccountUsageRefresh(
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
            ProviderTokenUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_500_000)
            )
        ]
        let toClear = ProviderUsageStore.providersToClearAfterPartialAccountUsageRefresh(
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

        let store = ProviderUsageStore(appSupportDirectory: dir)
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
        let snap = ProviderUsageSnapshot(period: .sevenDays, providers: [
            ProviderTokenUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_000)
            ),
            ProviderTokenUsage(
                provider: .codex,
                weeklyUsedPercent: 23,
                weeklyResetsAt: Date(timeIntervalSince1970: 6_000)
            )
        ])
        let fixed = ProviderUsageStore.expiringStaleWeeklyUsage(snap, now: now)
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
        let store = ProviderUsageStore(
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
    }

    func test_record_unknownBilledContribution_makesDayBilledNil() throws {
        // WHY: fail-closed — mixing known and unknown billed on one day must not
        // keep a partial sum that pretends to be a complete billed window.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-day-billed-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedNow = Date(timeIntervalSince1970: 1_784_000_000)
        let store = ProviderUsageStore(
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
    }

    func test_dayUsage_decodeMissingBilledKey_yieldsNilNotRaw() throws {
        // WHY: historical usage.json without the billed key must stay UNKNOWN
        // (nil), never decode as raw-derived billed and silently re-inflate.
        let seed = ProviderDayUsage(
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
        let decoded = try JSONDecoder().decode(ProviderDayUsage.self, from: stripped)
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
            ProviderTokenUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: nil,
                now: now
            ),
            "bare 0 without a session reset window must not paint Today as 0% used"
        )
        XCTAssertNil(
            ProviderTokenUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 1_500_000),
                now: now
            ),
            "expired session window must not keep a frozen 0%"
        )
        XCTAssertEqual(
            ProviderTokenUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 2_500_000),
                now: now
            ),
            0,
            "true mid-window 0% with a future reset must still display as 0%"
        )
        XCTAssertEqual(
            ProviderTokenUsage.effectiveSessionUsedPercent(
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
        let unknown = ProviderTokenUsage(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200
        )
        let measured = ProviderTokenUsage(
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
            [ProviderTokenUsage].self,
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
            ProviderTokenUsage.self,
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

        let store = ProviderUsageStore(appSupportDirectory: directory)
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

    /// WHY: `AppDelegate.tokenSaverAccountUsageRefreshInterval` is 60 s, so the
    /// probe re-records the same percentages ~1.440×/day while the app is open,
    /// and each repeat used to run the whole read-modify-write (cross-process
    /// flock + encode + atomic replace of the file) on the MainActor for a row
    /// that did not change. Live evidence for the redundancy: in the owner's DB
    /// (26 days, `agent_stream_events`), 56 of 80 `.accountUsage` events repeated
    /// the previous percentage for the same provider.
    func test_recordAccountUsage_unchangedPercentagesLeaveTheFileUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-account-usage-noop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderUsageStore(appSupportDirectory: directory)
        let file = directory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)

        _ = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 57,
            weeklyWindowDurationMinutes: 10_080,
            currentSessionUsedPercent: 3
        )
        let writtenBytes = try Data(contentsOf: file)
        let writtenAt = try modificationDate(of: file)

        let started = Date()
        for _ in 0..<50 {
            _ = try store.recordAccountUsage(
                provider: .claude,
                weeklyUsedPercent: 57,
                weeklyWindowDurationMinutes: 10_080,
                currentSessionUsedPercent: 3
            )
        }
        let repeatedWallClock = Date().timeIntervalSince(started)

        XCTAssertEqual(
            try modificationDate(of: file),
            writtenAt,
            "a probe that re-reports the same percentages must not rewrite usage.json"
        )
        XCTAssertEqual(
            try Data(contentsOf: file),
            writtenBytes,
            "skipped writes must leave the stored bytes identical, not merely equivalent"
        )

        // A real change still lands immediately, and the file is rewritten.
        _ = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 58,
            weeklyWindowDurationMinutes: 10_080,
            currentSessionUsedPercent: 3
        )
        XCTAssertGreaterThan(
            try modificationDate(of: file),
            writtenAt,
            "a changed percentage must still be persisted"
        )
        let reloaded = try XCTUnwrap(
            store.load().providers.first { $0.provider == .claude }
        )
        XCTAssertEqual(reloaded.weeklyUsedPercent, 58)
        XCTAssertEqual(
            reloaded.currentSessionUsedPercent,
            3,
            "the no-op path must not drop the fields it did not touch"
        )
        NSLog(
            "[perf-proof] accountUsage noop_wall_clock_ms=%.2f for 50 repeats, file_bytes=%d",
            repeatedWallClock * 1000,
            writtenBytes.count
        )
    }

    /// WHY: nil arguments mean "keep the stored value", so a probe that omits
    /// them cannot make the row differ — it must take the same no-op path and
    /// still preserve what is on disk.
    func test_recordAccountUsage_nilFieldsKeepStoredValuesAndSkipTheWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-account-usage-nil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderUsageStore(appSupportDirectory: directory)
        let file = directory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)

        let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 40,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: resetsAt,
            currentSessionUsedPercent: 12,
            currentSessionResetsAt: resetsAt
        )
        let writtenAt = try modificationDate(of: file)

        _ = try store.recordAccountUsage(provider: .grok, weeklyUsedPercent: 40)

        XCTAssertEqual(
            try modificationDate(of: file),
            writtenAt,
            "weeklyUsedPercent alone, equal to the stored value, is a no-op write"
        )
        let stored = try XCTUnwrap(store.load().providers.first { $0.provider == .grok })
        XCTAssertEqual(stored.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(stored.weeklyResetsAt, resetsAt)
        XCTAssertEqual(stored.currentSessionUsedPercent, 12)
    }

    /// WHY: `.empty` covers a missing, unreadable and wrong-period file, and its
    /// rows read as 0%. A 0% report with no window attached is exactly the shape
    /// that matches such a row, so deciding from `.empty` would skip the write
    /// that creates usage.json. The comparison must run against a decode that
    /// really happened.
    func test_recordAccountUsage_zeroPercentOnMissingFileStillCreatesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-account-usage-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderUsageStore(appSupportDirectory: directory)
        let file = directory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)

        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "recording 0% with no usage.json on disk must still create it"
        )
        let stored = try XCTUnwrap(store.load().providers.first { $0.provider == .codex })
        XCTAssertEqual(stored.weeklyUsedPercent, 0)
    }

    /// WHY: the no-op decision must compare against what the file holds, not
    /// against the read model `load()` exposes. An expired weekly window reads as
    /// 0% (`expiringStaleWeeklyUsage`), so comparing the folded value would treat
    /// a real 45% → 0% write as a no-op and leave the stale 45% on disk.
    func test_recordAccountUsage_expiredWindowStillPersistsTheZeroItReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-account-usage-expired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderUsageStore(appSupportDirectory: directory)
        let file = directory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)

        let expired = Date(timeIntervalSince1970: 1_600_000_000)
        _ = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 45,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: expired
        )
        XCTAssertEqual(
            store.load().providers.first { $0.provider == .claude }?.weeklyUsedPercent,
            0,
            "fixture check: the read model folds the expired window to 0%"
        )

        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 0)

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let providers = (persisted?["providers"] as? [[String: Any]]) ?? []
        let claude = providers.first { $0["provider"] as? String == "claude" }
        XCTAssertEqual(
            (claude?["weeklyUsedPercent"] as? NSNumber)?.doubleValue,
            0,
            "the reported 0% must reach the file, not be folded away by the comparison"
        )
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    func test_crossProcessLock_serializesEveryMutationWhileReadsRemainComplete() throws {
        // WHY: provider proxies and the app update the same usage.json. Without
        // one stable cross-process lock, two valid read-modify-writes can each
        // atomically replace the file while silently dropping the other's delta.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-cross-process-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProviderUsageStore(appSupportDirectory: directory)
        try store.save(ProviderUsageSnapshot(period: .sevenDays, providers: [
            ProviderTokenUsage(
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
        _ = try JSONDecoder().decode(ProviderUsageSnapshot.self, from: Data(contentsOf: usageURL))

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600, "the stable sibling lock must be owner-only")
    }

    // Moved from the deleted TokenSaverInstallTests: the usage.json store backs
    // the account usage feature, which stays.

    func test_usageStoreAggregatesProviderTokenEventsWithoutRawText() throws {
        let store = ProviderUsageStore(appSupportDirectory: tempDir())

        _ = try store.record(provider: .claude, actualProviderTokens: 420, estimatedRawTokens: 1_000)
        let updated = try store.record(provider: .claude, actualProviderTokens: 80, estimatedRawTokens: 120)

        let claude = try XCTUnwrap(updated.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.actualProviderTokens, 500)
    }

    func test_usageStorePersistsCurrentSessionLimitTelemetryWithoutRawText() throws {
        let store = ProviderUsageStore(appSupportDirectory: tempDir())

        _ = try store.record(
            provider: .codex,
            actualProviderTokens: 740,
            estimatedRawTokens: 1_100,
            currentSessionTokens: 740,
            currentSessionLimitTokens: 1_000
        )
        let updated = try store.record(
            provider: .codex,
            actualProviderTokens: 20,
            estimatedRawTokens: 40,
            currentSessionTokens: 120,
            currentSessionLimitTokens: 1_000
        )

        let codex = try XCTUnwrap(updated.providers.first { $0.provider == .codex })
        XCTAssertEqual(codex.currentSessionTokens, 740,
                       "account usage rings must preserve the highest current-session pressure so the UI can switch at 70%")
        XCTAssertEqual(codex.currentSessionLimitTokens, 1_000)
        XCTAssertEqual(store.load().providers.first { $0.provider == .codex }?.currentSessionLimitTokens, 1_000)
    }

    func test_usageStorePersistsWeeklyAccountLimitPercentagesWithoutRawText() throws {
        let store = ProviderUsageStore(appSupportDirectory: tempDir())

        _ = try store.record(provider: .claude, actualProviderTokens: 400, estimatedRawTokens: 1_000)
        let updated = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 57,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: Date().addingTimeInterval(10_080 * 60)
        )

        let claude = try XCTUnwrap(updated.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.actualProviderTokens, 400,
                       "account usage refresh must not double-count prompt tokens")
        XCTAssertEqual(claude.weeklyUsedPercent, 57)
        XCTAssertEqual(claude.weeklyRemainingPercent, 43)
        XCTAssertEqual(claude.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(store.load().providers.first { $0.provider == .claude }?.weeklyUsedPercent, 57)
    }

    func test_usageStoreRecordsSevenDayChartBucketsWithoutRawText() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_783_036_800))
        let store = ProviderUsageStore(
            appSupportDirectory: tempDir(),
            calendar: calendar,
            now: { clock.value }
        )

        _ = try store.record(provider: .claude, actualProviderTokens: 100, estimatedRawTokens: 250)
        _ = try store.record(provider: .codex, actualProviderTokens: 40, estimatedRawTokens: 100)
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        let updated = try store.record(provider: .claude, actualProviderTokens: 80, estimatedRawTokens: 200)

        XCTAssertEqual(updated.daily.count, 2,
                       "the account usage chart needs real daily buckets, not a text-only aggregate")
        XCTAssertEqual(updated.daily[0].actualProviderTokens, 140)
        XCTAssertEqual(updated.daily[1].actualProviderTokens, 80)
        XCTAssertEqual(store.load().daily, updated.daily)
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProviderUsageStore-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class UsageTestClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private final class UsageMutationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedSnapshot: ProviderUsageSnapshot?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var snapshot: ProviderUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func setSnapshot(_ snapshot: ProviderUsageSnapshot) {
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
                domain: "ProviderUsageSnapshotTests.ExternalUsageLockHolder",
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
