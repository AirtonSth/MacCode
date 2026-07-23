import XCTest
@testable import CoreModel

private final class AlwaysOKExecutor: TokenSaverTurnBatchRuntime.ActionExecutor {
    var outputKnownByID: [String: Bool] = [:]
    var failIDs: Set<String> = []
    func perform(_ action: TokenSaverTurnBatchRuntime.Action) -> TokenSaverTurnBatchRuntime.ExecutionResult {
        if failIDs.contains(action.id) {
            return .init(success: false, outputKnown: false)
        }
        let known = outputKnownByID[action.id] ?? true
        return .init(success: true, outputKnown: known)
    }
}

private final class RecordingExecutor: TokenSaverTurnBatchRuntime.ActionExecutor {
    private let lock = NSLock()
    private(set) var performed: [String] = []

    func perform(_ action: TokenSaverTurnBatchRuntime.Action) -> TokenSaverTurnBatchRuntime.ExecutionResult {
        lock.lock()
        performed.append(action.id)
        lock.unlock()
        return .init(success: true)
    }
}

final class TokenSaverTurnBatchPrefetchTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverTurnBatchPrefetch.defaultEnabled)
        let rt = TokenSaverTurnBatchRuntime()
        XCTAssertTrue(rt.readyActions(from: [.init(id: "r1", kind: .read, approved: true)]).isEmpty)
        XCTAssertFalse(rt.mutationsEnabled)
    }

    func test_runtime_dagIndependentReadsAndUnknownOutput() {
        let rt = TokenSaverTurnBatchRuntime()
        rt.readOnlyLive = true
        let exec = AlwaysOKExecutor()
        exec.outputKnownByID = ["r1": false, "r2": true]
        rt.executor = exec
        let result = rt.run(actions: [
            .init(id: "r1", kind: .read, approved: true),
            .init(id: "r2", kind: .read, approved: true),
            .init(id: "m1", kind: .read, dependsOn: ["r1"], requiresPriorOutput: true, approved: true),
            .init(id: "d1", kind: .read, dependsOn: ["unknown"], requiresPriorOutput: true, approved: true),
        ])
        XCTAssertEqual(result.outcomes["r1"], .completed)
        XCTAssertEqual(result.outcomes["r2"], .completed)
        XCTAssertFalse(result.knownOutputIDs.contains("r1"))
        XCTAssertEqual(result.outcomes["m1"], .skippedUnknownDep)
        XCTAssertEqual(result.outcomes["d1"], .skippedUnknownDep)
    }

    func test_runtime_transitiveFailFast() {
        let rt = TokenSaverTurnBatchRuntime()
        rt.readOnlyLive = true
        let exec = AlwaysOKExecutor()
        exec.failIDs = ["a"]
        rt.executor = exec
        let result = rt.run(actions: [
            .init(id: "a", kind: .read, approved: true),
            .init(id: "b", kind: .read, dependsOn: ["a"], requiresPriorOutput: true, approved: true),
            .init(id: "c", kind: .read, dependsOn: ["b"], requiresPriorOutput: true, approved: true),
        ])
        XCTAssertEqual(result.outcomes["a"], .failed)
        XCTAssertEqual(result.outcomes["b"], .failed)
        XCTAssertEqual(result.outcomes["c"], .failed)
        XCTAssertTrue(result.aborted)
    }

    func test_runtime_requiresExecutorForCompletion() {
        let rt = TokenSaverTurnBatchRuntime()
        rt.readOnlyLive = true
        let result = rt.run(actions: [.init(id: "r1", kind: .read, approved: true)])
        XCTAssertEqual(result.outcomes["r1"], .missingExecutor)
    }

    func test_runtime_mutationGateSeparateFromReadOnly() {
        let rt = TokenSaverTurnBatchRuntime()
        rt.readOnlyLive = true
        XCTAssertEqual(rt.admit(.init(id: "m", kind: .mutation, approved: true)), .deniedMutationGate)
        rt.mutationsEnabled = true
        XCTAssertEqual(
            rt.admit(.init(id: "m", kind: .mutation, approved: true)),
            .deniedMissingIdempotency
        )
        XCTAssertEqual(
            rt.admit(.init(id: "m", kind: .mutation, approved: true, idempotencyKey: "mutation-m")),
            .completed
        )
        XCTAssertEqual(rt.admit(.init(id: "m2", kind: .mutation, approved: false)), .deniedNoApproval)
        XCTAssertEqual(rt.admit(.init(id: "mx", kind: .mutation, approved: true, proposedByMLX: true)), .rejectedMLXMutation)
    }

    func test_runtime_idempotencyRelaunchAndRetryAfterFail() {
        let store = TokenSaverTurnBatchRuntime.MemoryIdempotencyStore()
        let rtF = TokenSaverTurnBatchRuntime(idempotency: store)
        rtF.readOnlyLive = true
        let execF = AlwaysOKExecutor()
        execF.failIDs = ["x"]
        rtF.executor = execF
        _ = rtF.run(actions: [.init(id: "x", kind: .read, approved: true, idempotencyKey: "retry-me")])
        XCTAssertFalse(store.seen("retry-me")) // released after failure
        execF.failIDs = []
        let rtF2 = TokenSaverTurnBatchRuntime(idempotency: store)
        rtF2.readOnlyLive = true
        rtF2.executor = execF
        XCTAssertEqual(rtF2.run(actions: [.init(id: "x", kind: .read, approved: true, idempotencyKey: "retry-me")]).outcomes["x"], .completed)
        XCTAssertTrue(store.seen("retry-me"))

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("idem-\(UUID().uuidString)")
        let fileStore = try! TokenSaverTurnBatchRuntime.FileIdempotencyStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rt1 = TokenSaverTurnBatchRuntime(idempotency: fileStore)
        rt1.readOnlyLive = true
        rt1.executor = AlwaysOKExecutor()
        XCTAssertEqual(rt1.run(actions: [.init(id: "x", kind: .read, approved: true, idempotencyKey: "f1")]).outcomes["x"], .completed)
        let rt2 = TokenSaverTurnBatchRuntime(idempotency: try! TokenSaverTurnBatchRuntime.FileIdempotencyStore(directory: dir))
        rt2.readOnlyLive = true
        XCTAssertEqual(rt2.admit(.init(id: "y", kind: .read, approved: true, idempotencyKey: "f1")), .duplicateIdempotent)
    }

    /// Duplicate action IDs make receipts ambiguous and must fail before any action runs.
    func test_runtime_rejectsDuplicateActionIDsBeforeExecution() {
        let executor = RecordingExecutor()
        let runtime = TokenSaverTurnBatchRuntime()
        runtime.readOnlyLive = true
        runtime.executor = executor

        let result = runtime.run(actions: [
            .init(id: "duplicate", kind: .read),
            .init(id: "duplicate", kind: .read),
            .init(id: "independent", kind: .read),
        ])

        XCTAssertTrue(result.aborted)
        XCTAssertEqual(result.outcomes["duplicate"], .invalidBatch)
        XCTAssertEqual(result.outcomes["independent"], .invalidBatch)
        XCTAssertTrue(executor.performed.isEmpty, "an ambiguous batch must not execute any action")
    }

    func test_fileIdempotencyReservation_isAtomicAcrossStoreInstances() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idem-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores = try (0..<32).map { _ in
            try TokenSaverTurnBatchRuntime.FileIdempotencyStore(directory: dir)
        }
        let lock = NSLock()
        var winners = 0

        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            if stores[index].tryReserve("one-approved-mutation") {
                lock.lock()
                winners += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(winners, 1, "exactly one process/store instance may reserve a mutation")
    }

    func test_runtime_cancelTimeoutAndPerActionTimeout() {
        let rtCancel = TokenSaverTurnBatchRuntime()
        rtCancel.readOnlyLive = true
        rtCancel.executor = AlwaysOKExecutor()
        rtCancel.onAfterAction = { id in if id == "a" { rtCancel.cancel() } }
        let cancelled = rtCancel.run(actions: [
            .init(id: "a", kind: .read, approved: true),
            .init(id: "b", kind: .read, approved: true),
        ])
        XCTAssertTrue(cancelled.outcomes.values.contains(.cancelled) || cancelled.aborted)

        let rtTO = TokenSaverTurnBatchRuntime()
        rtTO.readOnlyLive = true
        rtTO.executor = AlwaysOKExecutor()
        rtTO.onAfterAction = { id in if id == "a" { rtTO.markTimedOut() } }
        let timed = rtTO.run(actions: [
            .init(id: "a", kind: .read, approved: true),
            .init(id: "b", kind: .read, approved: true),
        ])
        XCTAssertTrue(timed.outcomes.values.contains(.timedOut) || timed.aborted)

        // Per-action timeout
        final class SlowExec: TokenSaverTurnBatchRuntime.ActionExecutor {
            func perform(_ action: TokenSaverTurnBatchRuntime.Action) -> TokenSaverTurnBatchRuntime.ExecutionResult {
                Thread.sleep(forTimeInterval: 0.2)
                return .init(success: true, outputKnown: true)
            }
        }
        let rtPA = TokenSaverTurnBatchRuntime()
        rtPA.readOnlyLive = true
        rtPA.executor = SlowExec()
        let r = rtPA.run(actions: [.init(id: "slow", kind: .read, approved: true, timeoutMs: 20)])
        XCTAssertEqual(r.outcomes["slow"], .timedOut)
    }

    /// AC-07: mutation timeout keeps idempotency reserved so a retry cannot double-apply.
    func test_runtime_mutationTimeout_keepsIdempotencyReservedAgainstRetry() {
        final class SlowMut: TokenSaverTurnBatchRuntime.ActionExecutor {
            private(set) var performCount = 0
            func perform(_ action: TokenSaverTurnBatchRuntime.Action) -> TokenSaverTurnBatchRuntime.ExecutionResult {
                performCount += 1
                Thread.sleep(forTimeInterval: 0.25)
                return .init(success: true, outputKnown: true)
            }
        }
        let store = TokenSaverTurnBatchRuntime.MemoryIdempotencyStore()
        let exec = SlowMut()
        let rt = TokenSaverTurnBatchRuntime(idempotency: store)
        rt.readOnlyLive = true
        rt.mutationsEnabled = true
        rt.executor = exec
        let first = rt.run(actions: [
            .init(id: "m", kind: .mutation, approved: true, idempotencyKey: "mut-once", timeoutMs: 30),
        ])
        XCTAssertEqual(first.outcomes["m"], .timedOut)
        XCTAssertTrue(store.seen("mut-once"), "mutation timeout must keep key reserved")
        // Retry with same key must be treated as duplicate, not a second perform start.
        let rt2 = TokenSaverTurnBatchRuntime(idempotency: store)
        rt2.readOnlyLive = true
        rt2.mutationsEnabled = true
        rt2.executor = exec
        let second = rt2.run(actions: [
            .init(id: "m", kind: .mutation, approved: true, idempotencyKey: "mut-once", timeoutMs: 30),
        ])
        XCTAssertEqual(second.outcomes["m"], .duplicateIdempotent)
        // Only the first perform was started (background may still be finishing).
        XCTAssertEqual(exec.performCount, 1)
    }

    func test_prefetchRuntime_hostPathValidationAndExecute() {
        let root = NSTemporaryDirectory() + "ts-prefetch-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = TokenSaverDiscoveryPrefetchRuntime.RecordingRunner()
        runner.digest = "digest-abc"
        let pref = TokenSaverDiscoveryPrefetchRuntime(
            workspaceRoot: root,
            bindingDigest: "bind",
            runner: runner
        )
        pref.live = true

        XCTAssertEqual(pref.admit(.init(name: "curl_remote")), .notAllowlisted)
        XCTAssertEqual(pref.admit(.init(name: "rg_workspace", pathArgument: "--pre=evil")), .outOfWorkspace)
        let outside = "/tmp/outside-token-saver-\(UUID().uuidString)"
        XCTAssertEqual(pref.admit(.init(name: "fs_stat", pathArgument: outside)), .outOfWorkspace)

        let linkPath = (root as NSString).appendingPathComponent("escape-link")
        let outsideDir = NSTemporaryDirectory() + "ts-out-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }
        try! FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outsideDir)
        XCTAssertEqual(pref.admit(.init(name: "fs_stat", pathArgument: "escape-link")), .outOfWorkspace)

        let insideRel = "file.txt"
        FileManager.default.createFile(atPath: (root as NSString).appendingPathComponent(insideRel), contents: Data("x".utf8))
        let rec = pref.execute(.init(name: "fs_stat", pathArgument: insideRel), selected: true)
        XCTAssertNotNil(rec)
        XCTAssertFalse(rec!.used)

        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        // Unrelated measure without evidence → markUsed fails
        _ = led.markProviderMeasured("op", experimentalPair: true, providerTokensSaved: 7, bindingDigest: "bind", evidenceDigest: "")
        XCTAssertFalse(pref.markUsed(recipe: "fs_stat", consumedDigest: "digest-abc", ledger: led, operationDigest: "op"))
        // Measure with matching evidence
        let led2 = TokenSaverAccountingV2.Ledger()
        _ = led2.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        _ = led2.markProviderMeasured("op", experimentalPair: true, providerTokensSaved: 7, bindingDigest: "bind", evidenceDigest: "digest-abc")
        XCTAssertTrue(pref.markUsed(recipe: "fs_stat", consumedDigest: "digest-abc", ledger: led2, operationDigest: "op"))
        XCTAssertEqual(pref.usefulnessCredit(recipe: "fs_stat", ledger: led2), 7)
        let crossBinding = TokenSaverAccountingV2.Ledger()
        _ = crossBinding.record(TokenSaverAccountingV2.Operation(
            digest: "cross",
            generation: 1,
            state: .providerApplied
        ))
        _ = crossBinding.markProviderMeasured(
            "cross",
            experimentalPair: true,
            providerTokensSaved: 99,
            bindingDigest: "other-bind",
            evidenceDigest: "digest-abc"
        )
        XCTAssertFalse(pref.markUsed(
            recipe: "fs_stat",
            consumedDigest: "digest-abc",
            ledger: crossBinding,
            operationDigest: "cross"
        ))
        // live=false never credits even with used receipt
        pref.live = false
        XCTAssertEqual(pref.usefulnessCredit(recipe: "fs_stat", ledger: led2), 0)
        pref.live = true
        // Wrong ledger op evidence cannot credit
        let led3 = TokenSaverAccountingV2.Ledger()
        _ = led3.record(TokenSaverAccountingV2.Operation(digest: "other", generation: 1, state: .providerApplied))
        _ = led3.markProviderMeasured("other", experimentalPair: true, providerTokensSaved: 99, bindingDigest: "bind", evidenceDigest: "other-ev")
        XCTAssertEqual(pref.usefulnessCredit(recipe: "fs_stat", ledger: led3), 0)

        // Post-execution deadline discards receipt
        pref.deadlineMs = 5
        var t = 1000
        pref.nowMs = { t }
        runner.digest = "late"
        // admit at t=1000 start, then advance past deadline after "run"
        let slow = SlowRunner(inner: runner, onRun: { t = 2000 })
        let pref2 = TokenSaverDiscoveryPrefetchRuntime(workspaceRoot: root, runner: slow)
        pref2.live = true
        pref2.deadlineMs = 5
        pref2.nowMs = { t }
        t = 1000
        XCTAssertNil(pref2.execute(.init(name: "git_status"), selected: true, startedAtMs: 1000))
    }

    func test_prefetchAndMLX_policyFacade() {
        XCTAssertFalse(TokenSaverTurnBatchPrefetch.mlxMayMutate())
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured("op", experimentalPair: true, providerTokensSaved: 5, bindingDigest: "bind", evidenceDigest: "e1")
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: "op")
        // Default OFF: no credit even with valid receipt
        XCTAssertEqual(TokenSaverTurnBatchPrefetch.unusedPrefetchSavings(used: true, receipt: r, creditBindingDigest: "bind"), 0)
        XCTAssertEqual(TokenSaverTurnBatchPrefetch.unusedPrefetchSavings(used: false, receipt: r, creditBindingDigest: "bind", live: true), 0)
        XCTAssertEqual(TokenSaverTurnBatchPrefetch.unusedPrefetchSavings(used: true, receipt: r, creditBindingDigest: "bind", live: true), 5)
    }
}

private final class SlowRunner: TokenSaverDiscoveryPrefetchRuntime.HostRunner {
    let inner: TokenSaverDiscoveryPrefetchRuntime.RecordingRunner
    let onRun: () -> Void
    init(inner: TokenSaverDiscoveryPrefetchRuntime.RecordingRunner, onRun: @escaping () -> Void) {
        self.inner = inner
        self.onRun = onRun
    }
    func run(argv: [String], cwd: String) -> (exitCode: Int, stdoutDigest: String) {
        onRun()
        return inner.run(argv: argv, cwd: cwd)
    }
}
