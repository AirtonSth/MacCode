import XCTest
import Combine
import CoreModel
@testable import Surfaces
@testable import AgentRuntime
@testable import Persistence

/// Pure-seam coverage for the Token Saver per-thread savings footer under final replies.
@MainActor
final class TokenSaverThreadFooterTests: XCTestCase {
    func test_footerText_disabled_reportsZeroBecauseDeactivated() {
        // WHY: Image #1 hid the chip while Token Saver was off. Off still
        // reports 0 tokens saved, and says why — never a positive total.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 100_000,
            measuredTokens: 100_000,
            enabled: false
        )
        XCTAssertEqual(
            text,
            "Token Saver: 0 tokens saved because Token Saver is deactivated"
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(enabled: false),
            .deactivated
        )
        XCTAssertFalse(text?.contains("177") == true)
        XCTAssertFalse(text?.contains("100K") == true)
    }

    func test_footerText_zeroSaved_stillPresentNotDeactivated() {
        // WHY: Token Saver on with a proven zero is a problem chip — yellow,
        // still present, never the red deactivated copy.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 0,
            measuredTokens: 0,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 0 tokens saved because something went wrong"
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: true,
                measuredTokens: 0
            ),
            .problem
        )
        XCTAssertFalse(text?.localizedCaseInsensitiveContains("deactivated") == true)
    }

    func test_footerText_zeroMeasured_doesNotInventEstimate() {
        // WHY: estimates may only raise a proven ledger figure — never invent a
        // savings total from assistant text alone (measured == 0).
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 12_000,
            measuredTokens: 0,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 0 tokens saved because something went wrong"
        )
        XCTAssertFalse(text?.contains("12K") == true)
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: true,
                measuredTokens: 0
            ),
            .problem
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: true,
                measuredTokens: 0
            ),
            .savings
        )
    }

    func test_footerPresentation_pendingSnapshotIsNotDeactivated() {
        // WHY: thread-switch publishes enabled=false + 0 until reload. That
        // pending snapshot must not paint the red deactivated chip.
        XCTAssertNil(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: false,
                snapshotReady: false
            )
        )
        XCTAssertNil(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: 0,
                measuredTokens: 0,
                enabled: false,
                snapshotReady: false
            )
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: true,
                snapshotReady: false
            ),
            nil
        )
    }

    func test_footerText_includesFullStackCopyNotToolOutputOnly() {
        // WHY: chip lists every leg the user can understand without jargon soup.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 100_000,
            measuredTokens: 100_000,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 100K tokens saved (tool output, shorter answers, multi-turn cache)"
        )
    }

    func test_footerText_estimatedAboveMeasured_sameScopeCopy() {
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 150_000,
            measuredTokens: 100_000,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 150K tokens saved (tool output, shorter answers, multi-turn cache)"
        )
    }

    func test_footerText_autoRouting_usesPlusAutoNote() {
        // WHY: Auto is a real savings leg; say cheaper models without sales fluff.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_100,
            measuredTokens: 2_000,
            enabled: true,
            autoRoutingActive: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 3.1K tokens saved (tool output, shorter answers, multi-turn cache) · Auto picked cheaper models at the same quality"
        )
    }

    func test_footerText_autoRouting_measuredOnly_sameForm() {
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_100,
            measuredTokens: 3_100,
            enabled: true,
            autoRoutingActive: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 3.1K tokens saved (tool output, shorter answers, multi-turn cache) · Auto picked cheaper models at the same quality"
        )
    }

    func test_footerText_accumulation_updatesAmount() {
        // WHY: the single chip shows the running thread total as savings grow.
        let first = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 12_500,
            measuredTokens: 12_500,
            enabled: true
        )
        let later = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 410_000,
            measuredTokens: 410_000,
            enabled: true
        )
        XCTAssertEqual(
            first,
            "Token Saver: 12.5K tokens saved (tool output, shorter answers, multi-turn cache)"
        )
        XCTAssertEqual(
            later,
            "Token Saver: 410K tokens saved (tool output, shorter answers, multi-turn cache)"
        )
        XCTAssertNotEqual(first, later)
    }

    func test_footerText_doesNotClaimToolOutputOnly() {
        // WHY: chip must name answer + cache legs, not look like pure tool-output.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 3_800,
            measuredTokens: 3_399,
            enabled: true
        )!
        XCTAssertTrue(text.contains("tool output"))
        XCTAssertTrue(text.contains("shorter answers"))
        XCTAssertTrue(text.contains("multi-turn cache"))
        XCTAssertFalse(text.contains("not total provider usage"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("you saved"))
    }

    func test_displayTokens_atLeastMeasuredWhenEnabled() {
        // WHY: enabling estimates must never lower the thread figure (inversion).
        let measured = 50_000
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false
        )
        XCTAssertGreaterThanOrEqual(display, measured)
    }

    func test_displayTokens_disabled_returnsMeasuredOnly() {
        // WHY: paid-feature off → no dialect/graphify/cache inflation.
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: 80_000,
            assistantChars: 400_000,
            tokenSaverEnabled: false,
            graphifyActive: true,
            graphifySignalCount: 20,
            turnCount: 40,
            cacheReadInputTokens: 5_000_000,
            autoRoutingActive: true
        )
        XCTAssertEqual(display, 80_000)
    }

    func test_displayTokens_assistantCharsCanRaiseDialect() {
        // WHY: same bare-user estimator as sidebar; assistant-char floor can add dialect.
        let measured = 10_000
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 200_000, // ~50K tokens floor × (V-1) dialect
            tokenSaverEnabled: true,
            graphifyActive: false
        )
        XCTAssertGreaterThan(display, measured,
                             "large assistant output should raise credible total above pure ledger")
    }

    func test_sharedReloadSnapshot_usesPermanentRunsWhenTimelineIsShort() {
        // WHY: cache-first paint often has 0–1 timeline turns. The day/week
        // card multiplies permanent saved × (runs − 1); the footer must use
        // that same floor or the chip collapses to bare measured.
        let observation = TokenSaverThreadFooterReload.Observation(
            assistantChars: 0,
            turnCount: 1,
            cacheReadInputTokens: 0,
            providerRawTokens: 4_534,
            providerBilledTokenUnits: 4_534,
            autoRoutingActive: false
        )
        let shortTimeline = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 4_534,
            eligible: true,
            graphifyActive: false,
            observation: observation,
            deliveredRuns: 0
        )
        let restored = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 4_534,
            eligible: true,
            graphifyActive: false,
            observation: observation,
            deliveredRuns: 51
        )
        XCTAssertGreaterThan(restored.displayTokens, shortTimeline.displayTokens)
        XCTAssertGreaterThan(
            restored.displayTokens,
            4_534 * 10,
            "permanent runs must restore the large cache-amortized chip"
        )
        XCTAssertEqual(restored.measuredTokens, 4_534)
        let off = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 4_534,
            eligible: false,
            graphifyActive: false,
            observation: observation,
            deliveredRuns: 51
        )
        XCTAssertEqual(off.displayTokens, 4_534, "off must not invent amort")
    }

    func test_displayTokens_multiTurnCacheAmortizationRaisesFigure() {
        // WHY: elephant-class long threads must credit multi-turn re-read impact
        // of tool-output savings — not show bare measured alone.
        let measured = 4_534
        let noTurns = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            turnCount: 1
        )
        let manyTurns = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            turnCount: 77,
            cacheReadInputTokens: 5_000_000
        )
        XCTAssertGreaterThan(manyTurns, noTurns)
        XCTAssertGreaterThan(manyTurns, measured * 10,
                             "77-turn thread must show large cache-amortized savings")
    }

    func test_displayTokens_autoRoutingAddsOrchestration() {
        let measured = 10_000
        let without = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            turnCount: 1,
            autoRoutingActive: false
        )
        let withAuto = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measured,
            assistantChars: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            turnCount: 1,
            autoRoutingActive: true
        )
        XCTAssertGreaterThan(withAuto, without)
    }

    func test_loadMeasured_distinguishesMissingZeroFromFailedRead() async throws {
        // WHY: a real zero must clear a stale footer, while a failed ledger read
        // must preserve it. The optional result is the only public signal that
        // lets callers make that distinction without inventing a test VM.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = TokenSaverSavingsRepository(db: db)
        let missing = await TokenSaverThreadFooterReload.loadMeasured(
            eligible: true,
            threadId: AgentThreadID(),
            repo: repo
        )
        XCTAssertEqual(missing, 0, "an eligible thread with no ledger row is a genuine zero")

        let unreadableDB = try SQLiteDB(path: ":memory:")
        let unreadableRepo = TokenSaverSavingsRepository(db: unreadableDB)
        let failed = await TokenSaverThreadFooterReload.loadMeasured(
            eligible: true,
            threadId: AgentThreadID(),
            repo: unreadableRepo
        )
        XCTAssertNil(failed, "a ledger read failure must remain distinct from zero")
    }

    func test_sharedReloadSnapshot_includesGraphifyObservationInBothSurfaces() {
        // WHY: Graphify is part of the shared observation contract; dropping its
        // count would make Agent App and Bot Desk under-report the same thread.
        let base = TokenSaverThreadFooterReload.Observation(
            assistantChars: 0,
            turnCount: 1,
            cacheReadInputTokens: 0,
            providerRawTokens: 10_000,
            providerBilledTokenUnits: 10_000,
            autoRoutingActive: false,
            graphifySignalCount: 0
        )
        let graphified = TokenSaverThreadFooterReload.Observation(
            assistantChars: base.assistantChars,
            turnCount: base.turnCount,
            cacheReadInputTokens: base.cacheReadInputTokens,
            providerRawTokens: base.providerRawTokens,
            providerBilledTokenUnits: base.providerBilledTokenUnits,
            autoRoutingActive: base.autoRoutingActive,
            graphifySignalCount: 4
        )
        let withoutGraphify = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 1_000,
            eligible: true,
            graphifyActive: true,
            observation: base
        )
        let withGraphify = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 1_000,
            eligible: true,
            graphifyActive: true,
            observation: graphified
        )
        XCTAssertGreaterThan(
            withGraphify.displayTokens,
            withoutGraphify.displayTokens,
            "shared snapshot must carry Graphify signals into the displayed total"
        )
    }

    func test_agentAppFooter_dropsStaleReadAfterThreadSelectionChanges() async throws {
        // WHY: a slow read for A may finish after the user selects B; it must
        // never publish A's ledger value into B's footer, while B still gets
        // its own value once its read completes.
        let tmp = NSTemporaryDirectory() + "rc2-token-saver-race-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        let reader = BlockingFooterReader(values: [
            threadA.value.uuidString: 111,
            threadB.value.uuidString: 222
        ])
        let publishedValues = Task { @MainActor in
            var values: [Int] = []
            for await value in vm.$tokenSaverThreadMeasuredTokens.values {
                values.append(value)
                if value == 222 { return values }
            }
            return values
        }
        defer { publishedValues.cancel() }

        vm.bindTokenSaverThreadFooter(
            savingsRepo: TokenSaverSavingsRepository(db: db),
            isEligible: { true },
            measuredLoader: { _, threadId, _ in
                guard let threadId else { return nil }
                return await reader.read(threadId.value.uuidString)
            }
        )
        vm.selectThread(threadA, markRead: false)
        await reader.waitUntilStarted(threadA.value.uuidString)
        vm.selectThread(threadB, markRead: false)
        await reader.waitUntilStarted(threadB.value.uuidString)

        await reader.release(threadA.value.uuidString)
        await reader.waitUntilReturned(threadA.value.uuidString)
        await reader.release(threadB.value.uuidString)
        let observedValues = await publishedValues.value

        XCTAssertEqual(vm.selectedThreadId, threadB)
        XCTAssertFalse(observedValues.contains(111),
                       "A's late read must never publish into selected B")
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 222)
    }

    func test_agentAppFooter_preservesPositiveSnapshotWhenNextLedgerReadFails() async throws {
        // WHY: a transient ledger read failure must not erase a savings total
        // that the Agent App already published for the selected thread.
        let tmp = NSTemporaryDirectory() + "rc2-token-saver-ledger-failure-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        vm.createThread(title: "Ledger failure")
        await vm.waitForSelectThreadHydrationForTesting()
        let loader = SequencedFooterLoader(results: [321, nil])
        let positiveSnapshotPublished = expectation(description: "positive footer snapshot published")
        let positiveSnapshotCancellable = vm.$tokenSaverThreadMeasuredTokens
            .combineLatest(vm.$tokenSaverThreadSavedTokens)
            .sink { measured, displayed in
                if measured == 321 && displayed >= 321 {
                    positiveSnapshotPublished.fulfill()
                }
            }
        defer { positiveSnapshotCancellable.cancel() }

        vm.bindTokenSaverThreadFooter(
            savingsRepo: TokenSaverSavingsRepository(db: db),
            isEligible: { true },
            graphifySignalCount: { 0 },
            measuredLoader: { _, _, _ in await loader.read() }
        )
        let positiveCall = await loader.waitForCall()
        XCTAssertEqual(positiveCall.result, 321)
        await loader.release(positiveCall)
        await loader.waitUntilReturned(positiveCall)
        await fulfillment(of: [positiveSnapshotPublished], timeout: 5)
        let positiveDisplayTokens = vm.tokenSaverThreadSavedTokens
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 321)
        XCTAssertGreaterThanOrEqual(positiveDisplayTokens, 321)
        let expectedPositiveFooter =
            "Token Saver: \(AgentAppView.formatTokenCountForFooter(positiveDisplayTokens)) tokens saved (tool output, shorter answers, multi-turn cache)"
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: positiveDisplayTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            ),
            expectedPositiveFooter
        )

        vm.reloadTokenSaverThreadSavings()
        let failedCall = await loader.waitForCall()
        XCTAssertNil(failedCall.result)
        await loader.release(failedCall)
        await loader.waitUntilReturned(failedCall)

        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 321)
        XCTAssertEqual(vm.tokenSaverThreadSavedTokens, positiveDisplayTokens)
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: vm.tokenSaverThreadSavedTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            ),
            expectedPositiveFooter
        )
    }

    func test_agentAppFooter_refreshesFromDeliveredLedgerAfterUsageChanged() async throws {
        // WHY: the production path is ledger record -> usage-changed signal ->
        // selected-thread reload -> exact footer copy. Testing only the loader
        // or only the notification leaves the regression that caused the chip
        // to disappear unprotected.
        let tmp = NSTemporaryDirectory() + "rc2-token-saver-composed-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        vm.createThread(title: "Delivered ledger")
        await vm.waitForSelectThreadHydrationForTesting()
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let repo = TokenSaverSavingsRepository(db: db)
        let loaderProbe = LedgerFooterLoadProbe()
        vm.bindTokenSaverThreadFooter(
            savingsRepo: repo,
            isEligible: { true },
            measuredLoader: { eligible, threadId, repo in
                let ordinal = await loaderProbe.markStarted()
                let result = await TokenSaverThreadFooterReload.loadMeasured(
                    eligible: eligible,
                    threadId: threadId,
                    repo: repo
                )
                await loaderProbe.markFinished(ordinal)
                return result
            }
        )

        let initialLoad = await loaderProbe.waitForStart()
        await loaderProbe.waitUntilFinished(initialLoad)
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 0)

        XCTAssertEqual(
            try repo.record(
                provider: "codex",
                mode: "command-output",
                inputTokens: 1_000,
                outputTokens: 250,
                delivered: true,
                threadID: threadId.value.uuidString,
                idempotencyKey: "composed-footer-1"
            ),
            750
        )

        let footerPublished = expectation(description: "selected thread footer published")
        let cancellable = vm.$tokenSaverThreadMeasuredTokens
            .combineLatest(vm.$tokenSaverThreadSavedTokens)
            .sink { measured, displayed in
                if measured == 750 && displayed >= 750 {
                    footerPublished.fulfill()
                }
            }
        defer { cancellable.cancel() }

        NotificationCenter.default.post(
            name: Notification.Name("rc2TokenSaverUsageChanged"),
            object: nil
        )
        let refreshLoad = await loaderProbe.waitForStart()
        await loaderProbe.waitUntilFinished(refreshLoad)
        await fulfillment(of: [footerPublished], timeout: 5)

        XCTAssertEqual(try repo.savedTokens(forThreadID: threadId.value.uuidString), 750)
        XCTAssertEqual(vm.selectedThreadId, threadId)
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 750)
        let footer = try XCTUnwrap(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: vm.tokenSaverThreadSavedTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled
            )
        )
        XCTAssertEqual(
            footer,
            "Token Saver: \(AgentAppView.formatTokenCountForFooter(vm.tokenSaverThreadSavedTokens)) tokens saved (tool output, shorter answers, multi-turn cache)"
        )
        let chromeSource = try String(
            contentsOfFile: "Sources/Surfaces/AgentChatTokenSaverChrome.swift",
            encoding: .utf8
        )
        XCTAssertTrue(chromeSource.contains(".accessibilityIdentifier(\"agent.tokenSaver.threadFooter\")"))
        XCTAssertTrue(
            chromeSource.contains("case deactivated"),
            "red off-state must live on the shared footer control"
        )
        XCTAssertTrue(
            chromeSource.contains("case problem"),
            "yellow on-zero problem must live on the shared footer control"
        )
        XCTAssertTrue(chromeSource.contains("DS.Palette.danger"))
        XCTAssertTrue(chromeSource.contains("DS.Palette.warning"))
        XCTAssertTrue(chromeSource.contains("DS.Palette.success"))
    }

    func test_agentAppFooter_clearsPublishedSnapshotOnThreadSwitch() async throws {
        // WHY: AC3 — the chip is the selected thread's ledger. Switching A→B
        // must not keep A's 177K on B while B's read is in flight (Desk already
        // resets; Agent App previously only cancelled the task).
        let tmp = NSTemporaryDirectory() + "rc2-token-saver-switch-clear-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(threadA, markRead: false)
        let reader = BlockingFooterReader(values: [
            threadA.value.uuidString: 177_043,
            threadB.value.uuidString: 750
        ])
        vm.bindTokenSaverThreadFooter(
            savingsRepo: TokenSaverSavingsRepository(db: db),
            isEligible: { true },
            measuredLoader: { _, threadId, _ in
                guard let threadId else { return nil }
                return await reader.read(threadId.value.uuidString)
            }
        )

        let aPublished = expectation(description: "thread A footer published")
        var aCancellable: AnyCancellable?
        aCancellable = vm.$tokenSaverThreadMeasuredTokens.sink { value in
            if value == 177_043 { aPublished.fulfill() }
        }
        defer { aCancellable?.cancel() }

        await reader.waitUntilStarted(threadA.value.uuidString)
        await reader.release(threadA.value.uuidString)
        await fulfillment(of: [aPublished], timeout: 5)
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 177_043)
        XCTAssertGreaterThanOrEqual(vm.tokenSaverThreadSavedTokens, 177_043)
        let expectedA =
            "Token Saver: \(AgentAppView.formatTokenCountForFooter(vm.tokenSaverThreadSavedTokens)) tokens saved (tool output, shorter answers, multi-turn cache)"
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: vm.tokenSaverThreadSavedTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled
            ),
            expectedA
        )

        vm.selectThread(threadB, markRead: false)
        XCTAssertEqual(vm.selectedThreadId, threadB)
        XCTAssertFalse(vm.tokenSaverFooterEnabled)
        XCTAssertFalse(vm.tokenSaverFooterSnapshotReady)
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 0)
        XCTAssertEqual(vm.tokenSaverThreadSavedTokens, 0)
        XCTAssertNil(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: vm.tokenSaverThreadSavedTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            )
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: vm.tokenSaverFooterEnabled,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            ),
            .deactivated,
            "A→B reset must not claim Token Saver is deactivated while the new ledger is in flight"
        )
        XCTAssertFalse(
            AgentAppView.shouldShowTokenSaverThreadFooter(
                runIsLive: false,
                footerText: AgentAppView.tokenSaverThreadFooterText(
                    displayTokens: vm.tokenSaverThreadSavedTokens,
                    measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                    enabled: vm.tokenSaverFooterEnabled,
                    snapshotReady: vm.tokenSaverFooterSnapshotReady
                )
            )
        )

        let bPublished = expectation(description: "thread B footer published")
        var bCancellable: AnyCancellable?
        bCancellable = vm.$tokenSaverThreadMeasuredTokens.sink { value in
            if value == 750 { bPublished.fulfill() }
        }
        defer { bCancellable?.cancel() }
        await reader.waitUntilStarted(threadB.value.uuidString)
        await reader.release(threadB.value.uuidString)
        await fulfillment(of: [bPublished], timeout: 5)
        XCTAssertEqual(vm.tokenSaverThreadMeasuredTokens, 750)
        XCTAssertTrue(vm.tokenSaverFooterSnapshotReady)
        let expectedB =
            "Token Saver: \(AgentAppView.formatTokenCountForFooter(vm.tokenSaverThreadSavedTokens)) tokens saved (tool output, shorter answers, multi-turn cache)"
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: vm.tokenSaverThreadSavedTokens,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                enabled: vm.tokenSaverFooterEnabled,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            ),
            expectedB
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverThreadFooterPresentation(
                enabled: vm.tokenSaverFooterEnabled,
                measuredTokens: vm.tokenSaverThreadMeasuredTokens,
                snapshotReady: vm.tokenSaverFooterSnapshotReady
            ),
            .savings
        )
    }

    func test_footerText_image1Copy_usesLiveFormattedAmount() {
        // WHY: Image #1 is the green leaf chip under a finished Agent App answer.
        // 177043 formats as 177.0K — exact thousands would drop the decimal.
        let text = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 177_043,
            measuredTokens: 177_043,
            enabled: true
        )
        XCTAssertEqual(
            text,
            "Token Saver: 177.0K tokens saved (tool output, shorter answers, multi-turn cache)"
        )
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(177_043), "177.0K")
    }

    func test_shouldShowFooter_hidesWhileRunIsLive() {
        // WHY: the working strip owns the live turn; the savings chip must not
        // appear until the selected thread is finished, even with a proven total.
        let onText = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 177_043,
            measuredTokens: 177_043,
            enabled: true
        )
        let offText = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 0,
            measuredTokens: 0,
            enabled: false
        )
        let problemText = AgentAppView.tokenSaverThreadFooterText(
            displayTokens: 0,
            measuredTokens: 0,
            enabled: true
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(runIsLive: true, footerText: onText),
            false
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(runIsLive: false, footerText: onText),
            true
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(runIsLive: false, footerText: offText),
            true,
            "a finished turn must still show the red 0/deactivated chip"
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(runIsLive: false, footerText: problemText),
            true,
            "a finished turn with Token Saver on and 0 measured must still show the yellow problem chip"
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(
                runIsLive: false,
                footerText: offText,
                hasFinishedTurn: false
            ),
            false,
            "an empty thread with no finished turn stays chip-less"
        )
        XCTAssertEqual(
            AgentAppView.shouldShowTokenSaverThreadFooter(runIsLive: false, footerText: nil),
            false
        )
    }

    func test_formatTokenCount_millions() {
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(1_500_000), "1.5M")
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(12_000_000), "12M")
    }

    func test_formatTokenCount_smallExact() {
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(42), "42")
        XCTAssertEqual(AgentAppView.formatTokenCountForFooter(999), "999")
    }

    func test_sharedReloadSnapshot_matchesAgentAppCalculator_becauseBotsMustNotForkMath() {
        // WHY: Bot Desk mounts TokenSaverThreadFooterReload so identical
        // ledger+observation inputs cannot produce a second number.
        let observation = TokenSaverThreadFooterReload.Observation(
            assistantChars: 200_000,
            turnCount: 12,
            cacheReadInputTokens: 80_000,
            providerRawTokens: 40_000,
            providerBilledTokenUnits: 41_000,
            autoRoutingActive: true,
            graphifySignalCount: 3
        )
        let snapshot = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 12_500,
            eligible: true,
            graphifyActive: true,
            observation: observation
        )
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: 12_500,
            assistantChars: 200_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            graphifySignalCount: 3,
            turnCount: 12,
            cacheReadInputTokens: 80_000,
            providerRawTokens: 40_000,
            providerBilledTokenUnits: 41_000,
            autoRoutingActive: true
        )
        XCTAssertEqual(snapshot.displayTokens, display)
        XCTAssertEqual(snapshot.measuredTokens, 12_500)
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(
            AgentChatTokenSaverDisplayMode.footerText(
                displayTokens: display,
                measuredTokens: 12_500,
                enabled: true,
                autoRoutingActive: true
            ),
            AgentAppView.tokenSaverThreadFooterText(
                displayTokens: display,
                measuredTokens: 12_500,
                enabled: true,
                autoRoutingActive: true
            )
        )
        let off = TokenSaverThreadFooterReload.snapshot(
            measuredDelivered: 12_500,
            eligible: false,
            graphifyActive: true,
            observation: observation
        )
        XCTAssertEqual(off.displayTokens, 12_500)
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(
            AgentChatTokenSaverDisplayMode.footerPresentation(enabled: off.enabled),
            .deactivated
        )
        XCTAssertEqual(
            AgentChatTokenSaverDisplayMode.footerText(
                displayTokens: off.displayTokens,
                measuredTokens: off.measuredTokens,
                enabled: off.enabled,
                autoRoutingActive: true
            ),
            "Token Saver: 0 tokens saved because Token Saver is deactivated"
        )
    }
}

private actor BlockingFooterReader {
    private let values: [String: Int]
    private var started = Set<String>()
    private var released = Set<String>()
    private var returned = Set<String>()
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var returnWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var waiters: [String: [CheckedContinuation<Int?, Never>]] = [:]

    init(values: [String: Int]) {
        self.values = values
    }

    func read(_ id: String) async -> Int? {
        started.insert(id)
        let starts = startWaiters.removeValue(forKey: id) ?? []
        for continuation in starts {
            continuation.resume()
        }

        let value: Int?
        if released.contains(id) {
            value = values[id]
        } else {
            value = await withCheckedContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
        }

        returned.insert(id)
        let returns = returnWaiters.removeValue(forKey: id) ?? []
        for continuation in returns {
            continuation.resume()
        }
        return value
    }

    func waitUntilStarted(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { continuation in
            startWaiters[id, default: []].append(continuation)
        }
    }

    func waitUntilReturned(_ id: String) async {
        if returned.contains(id) { return }
        await withCheckedContinuation { continuation in
            returnWaiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        released.insert(id)
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            continuation.resume(returning: values[id])
        }
    }
}

private actor SequencedFooterLoader {
    struct Call: Sendable {
        let ordinal: Int
        let result: Int?
    }

    private let results: [Int?]
    private var nextOrdinal = 0
    private var pendingCalls: [Call] = []
    private var callWaiters: [CheckedContinuation<Call, Never>] = []
    private var released = Set<Int>()
    private var returned = Set<Int>()
    private var returnWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var resultWaiters: [Int: [CheckedContinuation<Int?, Never>]] = [:]

    init(results: [Int?]) {
        self.results = results
    }

    func read() async -> Int? {
        let planned = nextOrdinal < results.count ? results[nextOrdinal] : nil
        let call = Call(ordinal: nextOrdinal, result: planned)
        nextOrdinal += 1
        if let continuation = callWaiters.first {
            callWaiters.removeFirst()
            continuation.resume(returning: call)
        } else {
            pendingCalls.append(call)
        }

        let result: Int?
        if released.contains(call.ordinal) {
            result = call.result
        } else {
            result = await withCheckedContinuation { continuation in
                resultWaiters[call.ordinal, default: []].append(continuation)
            }
        }

        returned.insert(call.ordinal)
        let returns = returnWaiters.removeValue(forKey: call.ordinal) ?? []
        for continuation in returns {
            continuation.resume()
        }
        return result
    }

    func waitForCall() async -> Call {
        if !pendingCalls.isEmpty {
            return pendingCalls.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func waitUntilReturned(_ call: Call) async {
        if returned.contains(call.ordinal) { return }
        await withCheckedContinuation { continuation in
            returnWaiters[call.ordinal, default: []].append(continuation)
        }
    }

    func release(_ call: Call) {
        released.insert(call.ordinal)
        let continuations = resultWaiters.removeValue(forKey: call.ordinal) ?? []
        for continuation in continuations {
            continuation.resume(returning: call.result)
        }
    }
}

private actor LedgerFooterLoadProbe {
    private var nextOrdinal = 0
    private var pendingStarts: [Int] = []
    private var startWaiters: [CheckedContinuation<Int, Never>] = []
    private var finishedOrdinals = Set<Int>()
    private var finishWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted() -> Int {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        if let waiter = startWaiters.first {
            startWaiters.removeFirst()
            waiter.resume(returning: ordinal)
        } else {
            pendingStarts.append(ordinal)
        }
        return ordinal
    }

    func waitForStart() async -> Int {
        if !pendingStarts.isEmpty {
            return pendingStarts.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markFinished(_ ordinal: Int) {
        finishedOrdinals.insert(ordinal)
        let waiters = finishWaiters.removeValue(forKey: ordinal) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilFinished(_ ordinal: Int) async {
        if finishedOrdinals.contains(ordinal) { return }
        await withCheckedContinuation { continuation in
            finishWaiters[ordinal, default: []].append(continuation)
        }
    }
}
