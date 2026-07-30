import XCTest
import CoreModel
@testable import DistillCore

final class ManagedDistillCLITests: XCTestCase {
    override func tearDown() {
        TokenSaverWaveLiveRollout.resetForTesting()
        unsetenv("RC_TOKEN_SAVER_DISTILL_HINT")
        unsetenv("RC_TOKEN_SAVER_WAVE_LIVE")
        super.tearDown()
    }

    private final class AdmissionLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [Bool]
        private var checks = 0

        init(_ decisions: [Bool]) {
            self.decisions = decisions
        }

        func next() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            guard !decisions.isEmpty else { return false }
            if decisions.count == 1 { return decisions[0] }
            return decisions.removeFirst()
        }

        func checkCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return checks
        }
    }

    private actor RequestRecorder {
        private var values: [DistillRequest] = []

        func append(_ request: DistillRequest) {
            values.append(request)
        }

        func all() -> [DistillRequest] {
            values
        }
    }

    private actor CallCounter {
        private var value = 0

        func increment() -> Int {
            value += 1
            return value
        }

        func count() -> Int {
            value
        }
    }

    /// Blocks the transport until `release()` so tests can prove stdout is available
    /// before the ledger POST begins (non-blocking deferred side effect).
    private actor TransportGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilReleased() async {
            if released { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append(cont)
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for cont in pending { cont.resume() }
        }
    }

    private actor HeaderRecorder {
        private var operationIDs: [String] = []
        private var invocationIDs: [String] = []

        func append(_ request: URLRequest) {
            operationIDs.append(request.value(forHTTPHeaderField: "X-RemoteCode-Operation-ID") ?? "")
            invocationIDs.append(request.value(forHTTPHeaderField: "X-RemoteCode-Invocation-ID") ?? "")
        }

        func all() -> [String] { operationIDs }
        func invocations() -> [String] { invocationIDs }
    }

    private actor ScopeHeaderRecorder {
        private var values: [[String: String]] = []

        func append(_ request: URLRequest) {
            let names = ["Workspace-ID", "Project-ID", "Thread-ID", "Provider", "Attempt-ID"]
            values.append(Dictionary(uniqueKeysWithValues: names.map {
                ($0, request.value(forHTTPHeaderField: "X-RemoteCode-\($0)") ?? "")
            }))
        }

        func all() -> [[String: String]] { values }
    }

    private let state = ManagedDistillCLI.State(baseURL: "http://127.0.0.1:9", authToken: "t")

    func test_compress_success_emitsOutputAndHandleMarker() async {
        let resp = DistillResponse(requestID: UUID(), output: "PASS", inputCharacters: 100, inputTokens: 25, outputTokens: 1, originalHandle: "abc123")
        let data = try! JSONEncoder().encode(resp)
        let cli = ManagedDistillCLI(arguments: ["Return PASS or FAIL only."], stdin: Data("build passed\n0 failures".utf8), state: state) { _ in (data, 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("PASS"))
        XCTAssertTrue(s.contains("[[rc:abc123]]"), "handle marker embedded so the agent can retrieve the original")
    }

    func test_compressDerivesStableDistinctOperationIDsPerCanonicalRequest() async throws {
        let recorder = HeaderRecorder()
        let response = DistillResponse(requestID: UUID(), output: "compressed", inputCharacters: 10, originalHandle: "h")
        let data = try JSONEncoder().encode(response)

        func run(_ input: String) async {
            let cli = ManagedDistillCLI(arguments: ["keep errors"], stdin: Data(input.utf8), state: state) { request in
                await recorder.append(request)
                return (data, 200)
            }
            _ = await cli.run()
        }

        await run("request one")
        await run("request two")
        await run("request one")

        let ids = await recorder.all()
        let invocations = await recorder.invocations()
        XCTAssertEqual(ids.count, 3)
        XCTAssertFalse(ids[0].isEmpty)
        XCTAssertNotEqual(ids[0], ids[1], "distinct requests in one provider attempt need distinct mutation identities")
        XCTAssertEqual(ids[0], ids[2], "a byte-identical canonical retry must reuse its operation identity")
        XCTAssertEqual(Set(invocations).count, 3, "independent CLI calls need unique invocation identities even for identical bytes")
    }

    func test_completeEnvironmentEmitsExactScopeForClaudeCodexAndGrok() async throws {
        let recorder = ScopeHeaderRecorder()
        let response = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(), output: "compressed", inputCharacters: 20,
            originalHandle: "h", routeStage: .deterministic
        ))
        for provider in ["claude", "codex", "grok"] {
            let environment = [
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
                "RC_TOKEN_SAVER_PROJECT_ID": "project",
                "RC_TOKEN_SAVER_THREAD_ID": "thread",
                "REMOTE_CODE_AGENT_PROVIDER": provider,
                "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt",
            ]
            let cli = ManagedDistillCLI(
                arguments: [], stdin: Data("provider input".utf8), state: state,
                provider: provider,
                recoveryContext: ManagedDistillCLI.recoveryContext(environment: environment)
            ) { request in
                await recorder.append(request)
                return (response, 200)
            }
            _ = await cli.run()
        }

        let scopes = await recorder.all()
        XCTAssertEqual(scopes.map { $0["Provider"] ?? "" }, ["claude", "codex", "grok"])
        XCTAssertTrue(scopes.allSatisfy {
            $0["Workspace-ID"] == "workspace" && $0["Project-ID"] == "project"
                && $0["Thread-ID"] == "thread" && $0["Attempt-ID"] == "attempt"
        })
        XCTAssertNil(ManagedDistillCLI.recoveryContext(environment: [
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
        ]))
    }

    func test_compress_noState_failsOpenToRawStdin() async {
        let raw = Data("the exact tool output that must NOT be lost".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: nil) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw, "no state => echo raw stdin verbatim, never lose piped data")
    }

    func test_liveAdmissionOff_returnsByteIdenticalInputWithoutTransport() async {
        let raw = Data([0x00, 0xFF, 0x0A, 0x41, 0x00, 0x80])
        let calls = CallCounter()
        let cli = ManagedDistillCLI(
            arguments: ["stale prompt"],
            stdin: raw,
            state: state,
            distillAdmission: { false }
        ) { _ in
            _ = await calls.increment()
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw, "Token Saver OFF must be byte-identical passthrough")
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 0, "OFF admission must perform zero transport calls")
    }

    func test_liveAdmissionRechecksEveryChunkAndStopsAfterTeardown() async throws {
        let input = String(repeating: "abcdefghij", count: (ManagedDistillCLI.stdinCapBytes / 5) + 10)
        let raw = Data(input.utf8)
        let admission = AdmissionLatch([true, true, false])
        let calls = CallCounter()
        let response = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(),
            output: "compressed chunk",
            inputCharacters: input.count,
            originalHandle: "chunk"
        ))
        let cli = ManagedDistillCLI(
            arguments: ["summarize"],
            stdin: raw,
            state: state,
            distillAdmission: { admission.next() }
        ) { _ in
            _ = await calls.increment()
            return (response, 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw, "teardown during a chunked run must discard partial compressed output")
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 1, "the second chunk must not POST after live admission turns off")
        XCTAssertGreaterThanOrEqual(admission.checkCount(), 3)
    }

    func test_compress_nonemptyWhitespace_returnsExactRawBytesWithoutTransport() async {
        let raw = Data([0x20, 0x09, 0x0A, 0x0D, 0x20])
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in
            XCTFail("whitespace-only stdin must not be sent to the optimizer")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_invalidUTF8_returnsExactRawBytesWithoutTransport() async {
        let raw = Data([0x66, 0x80, 0xFF, 0x00, 0xFE])
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in
            XCTFail("undecodable stdin must not be replacement-decoded or transported")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_transportFailure_failsOpen() async {
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_non200_failsOpen() async {
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (Data("{}".utf8), 500) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_compress_sendsPerRequestReversibleStoreMinBytes() async {
        let recorder = RequestRecorder()
        let resp = DistillResponse(requestID: UUID(), output: "x", inputCharacters: 2_000, originalHandle: "h")
        let data = try! JSONEncoder().encode(resp)
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: Data(String(repeating: "line of command output\n", count: 50).utf8),
            state: state,
            reversibleStoreMinBytes: 256
        ) { request in
            if let decoded = try? JSONDecoder().decode(DistillRequest.self, from: request.httpBody ?? Data()) {
                await recorder.append(decoded)
            }
            return (data, 200)
        }
        _ = await cli.run()
        let captured = await recorder.all().first
        XCTAssertEqual(captured?.reversibleStoreMinBytes, 256,
                       "the wrap path lowers the store floor so compressed output always carries a recovery handle")
    }

    func test_distillRequest_reversibleStoreMinBytes_roundTripsAndOmissionDecodesNil() throws {
        // Round-trip the field itself (encoder + tolerant decoder).
        let encoded = try JSONEncoder().encode(DistillRequest(mode: .commandOutput, input: "x", reversibleStoreMinBytes: 2048))
        XCTAssertEqual(try JSONDecoder().decode(DistillRequest.self, from: encoded).reversibleStoreMinBytes, 2048)
        // A wire body (as the Claude hook / wrappers hand-build) that omits the key decodes to
        // nil — version-skew safe. `priority` is an Int on the wire, matching the hook's payload.
        let omitted = #"{"mode":"commandOutput","priority":1,"input":"x","maxOutputCharacters":4000}"#
        XCTAssertNil(try JSONDecoder().decode(DistillRequest.self, from: Data(omitted.utf8)).reversibleStoreMinBytes)
    }

    // MARK: - QA-mac:54 saturation -> 429 -> CLI fail-open chain

    func test_distillErrorHttpMappingSeam() {
        // The wire contract: a bounded-worker overflow is 429 queue_full; the other
        // errors keep their distinct codes so the CLI fail-opens only on the right ones.
        XCTAssertEqual(DistillError.queueFull.httpMapping.status, 429)
        XCTAssertEqual(DistillError.queueFull.httpMapping.code, "queue_full")
        XCTAssertEqual(DistillError.emptyInput.httpMapping.status, 400)
        XCTAssertEqual(DistillError.invalidOutput.httpMapping.status, 502)
    }

    func test_saturationQueueFullChainsToCLIFailOpen() async {
        // End-to-end saturation contract across the 3 already-tested links:
        //   (1) a saturated DistillScheduler throws DistillError.queueFull
        //   (2) that maps to HTTP 429 queue_full (httpMapping seam, routed through
        //       DistillService)
        //   (3) the managed CLI, seeing a non-200, FAILS OPEN -- echoes stdin
        //       verbatim, exit 0 -- so distill saturation never blocks an agent turn.
        let saturation = DistillError.queueFull
        let mapping = saturation.httpMapping
        XCTAssertEqual(mapping.status, 429, "scheduler saturation must surface as 429 over the wire")

        let raw = Data("the agent tool output that must survive saturation".utf8)
        // Transport stands in for the saturated service returning exactly the mapped status.
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in
            (Data(#"{"error":"\#(mapping.code)","message":"bounded distill worker is full"}"#.utf8), mapping.status)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0, "a saturated (429) distill service must fail-open, exit 0 -- never block the agent")
        XCTAssertEqual(out, raw, "fail-open must echo the agent's tool output verbatim under saturation, losing nothing")
    }

    func test_compress_emptyOutput_failsOpen() async {
        let resp = DistillResponse(requestID: UUID(), output: "   ", inputCharacters: 5)
        let data = try! JSONEncoder().encode(resp)
        let raw = Data("tool output".utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (data, 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
    }

    func test_emptyStdin_returnsEmptyExitZero() async {
        let cli = ManagedDistillCLI(arguments: [], stdin: Data(), state: state) { _ in (Data(), 200) }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.isEmpty)
    }

    func test_hookSubcommand_neverFallsThroughToCompress() async {
        // Malformed Claude hook envelope (wrong field names) must fail-open to {}
        // exit 0 — never non-zero, never treat the envelope itself as tool output.
        var transportCalled = false
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use", "--provider", "claude"],
            stdin: Data(#"{"tool":"bash","output":"ok"}"#.utf8),
            state: state
        ) { _ in
            transportCalled = true
            return (Data("should-not-compress".utf8), 200)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0, "hook must always exit 0 (fail-open)")
        XCTAssertFalse(transportCalled, "malformed hook envelope must not invoke compress transport")
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("should-not-compress"))
    }

    // MARK: - Wave A prepass ledger (exactly one recordSavings)

    func test_waveAHit_emitsCompressedAndExactlyOneRecordSavingsWithCorrectDelta() async throws {
        // WHY: Wave A used to return compressed stdout before any /v1/distill POST,
        // so TokenSaverSavingsRepository never saw a row. Real byte savings were
        // computed and then silently dropped for every provider.
        //
        // WHY (BUG 1): the ledger POST must carry precomputedOutput == pre.output so
        // the sidecar records the delivered delta — NOT an independent recompute.
        // The stub intentionally returns DIFFERENT bytes than pre.output; if the
        // client (or server) used that response body for savings, numbers would diverge.
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)

        let line = "same log line that repeats many times for compression"
        var input = ""
        for _ in 0..<20 { input += line + "\n" }
        input += "exit code: 0\n"

        guard let pre = TokenSaverWaveLosslessPrepass.apply(input: input) else {
            XCTFail("Wave A live must collapse repeated logs for this fixture")
            return
        }
        XCTAssertGreaterThan(pre.savedBytes, 0)

        let expectedRecord = ManagedDistillCLI.prepassSavingsRecord(
            original: input,
            compressed: pre.output,
            provider: "grok",
            waveID: pre.waveID
        )
        XCTAssertNotNil(expectedRecord, "DistillSavingsCalculator must accept prepass delta")
        XCTAssertGreaterThan(expectedRecord?.savedTokens ?? 0, 0, "prepass must produce a positive token delta")
        XCTAssertEqual(
            expectedRecord?.savedTokens,
            max(TokenEstimator.estimate(input) - TokenEstimator.estimate(pre.output), 0)
        )

        // DIFFERENT from pre.output — proves the client does not rely on the response body
        // for the ledger delta (precomputed-output path ignores recompute).
        let independentSidecarOutput = "INDEPENDENT_SIDECAR_RECOMPUTE_NOT_PRE_OUTPUT"
        XCTAssertNotEqual(independentSidecarOutput, pre.output)
        let sidecarResponse = DistillResponse(
            requestID: UUID(),
            output: independentSidecarOutput,
            inputCharacters: input.count,
            inputTokens: TokenEstimator.estimate(input),
            outputTokens: TokenEstimator.estimate(independentSidecarOutput),
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(sidecarResponse)

        let recorder = RequestRecorder()
        let calls = CallCounter()
        let cli = ManagedDistillCLI(
            arguments: ["summarize logs"],
            stdin: Data(input.utf8),
            state: state,
            provider: "grok"
        ) { request in
            _ = await calls.increment()
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (encoded, 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(pre.output), "caller must receive Wave A compressed output")
        XCTAssertFalse(text.contains(independentSidecarOutput), "caller must not see independent sidecar recompute")
        XCTAssertNotEqual(out, Data(input.utf8), "Wave A hit must not fail-open to raw stdin")

        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 1, "Wave A must emit exactly one recordSavings POST (no double-count)")
        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        let posted = try XCTUnwrap(requests.first)
        XCTAssertEqual(posted.recordSavings, true)
        XCTAssertEqual(posted.input, input, "ledger POST must send original pre-prepass bytes")
        XCTAssertEqual(
            posted.precomputedOutput,
            pre.output,
            "ledger POST must carry the delivered Wave A output, not leave delta to server recompute"
        )
        XCTAssertEqual(posted.cacheState, "wave_prepass_\(pre.waveID)")
        XCTAssertEqual(posted.provider, "grok")

        // Honest delta is original→pre.output (precomputed path), not original→independentSidecarOutput.
        let honest = DistillSavingsCalculator.record(
            for: posted,
            response: try XCTUnwrap(posted.responseUsingPrecomputedOutput())
        )
        XCTAssertEqual(honest?.savedTokens, expectedRecord?.savedTokens)
        let wrongIfRecomputed = DistillSavingsCalculator.record(
            for: DistillRequest(
                mode: .commandOutput,
                input: input,
                provider: "grok",
                recordSavings: true
            ),
            response: DistillResponse(
                requestID: UUID(),
                output: independentSidecarOutput,
                inputCharacters: input.count,
                inputTokens: TokenEstimator.estimate(input),
                outputTokens: TokenEstimator.estimate(independentSidecarOutput),
                routeStage: .deterministic
            )
        )
        XCTAssertNotEqual(
            honest?.savedTokens,
            wrongIfRecomputed?.savedTokens,
            "fixture must distinguish pre.output delta from independent sidecar recompute"
        )
    }

    func test_waveAHit_runResultDeliversStdoutBeforeLedgerTransport() async {
        // WHY (BUG 2): interactive consumers must not wait on the ledger POST RTT
        // for bytes Wave A already produced. runResult returns stdout + deferred work.
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)

        let line = "same log line that repeats many times for compression"
        var input = ""
        for _ in 0..<20 { input += line + "\n" }
        input += "exit code: 0\n"
        guard let pre = TokenSaverWaveLosslessPrepass.apply(input: input) else {
            XCTFail("expected Wave A hit")
            return
        }

        let calls = CallCounter()
        let gate = TransportGate()
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: Data(input.utf8),
            state: state,
            provider: "claude"
        ) { _ in
            await gate.waitUntilReleased()
            _ = await calls.increment()
            return (Data("{}".utf8), 200)
        }

        let result = await cli.runResult()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), pre.output + "\n")
        XCTAssertNotNil(result.deferredSideEffect, "Wave A must defer ledger POST")
        let before = await calls.count()
        XCTAssertEqual(before, 0, "ledger transport must not run before deferred side effect")

        // Unblock transport and run deferred work.
        await gate.release()
        if let deferred = result.deferredSideEffect {
            await deferred()
        }
        let after = await calls.count()
        XCTAssertEqual(after, 1, "exactly one ledger POST after deferred side effect")
    }

    func test_waveAHit_sidecarUnreachable_stillReturnsCompressedFailOpen() async {
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)

        let line = "same log line that repeats many times for compression"
        var input = ""
        for _ in 0..<20 { input += line + "\n" }
        input += "exit code: 0\n"
        guard let pre = TokenSaverWaveLosslessPrepass.apply(input: input) else {
            XCTFail("expected Wave A hit")
            return
        }

        let calls = CallCounter()
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: Data(input.utf8),
            state: state,
            provider: "claude"
        ) { _ in
            _ = await calls.increment()
            return nil // sidecar down
        }

        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), pre.output + "\n")
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 1, "still attempts one best-effort recordSavings POST")
    }

    // MARK: - hook post-tool-use

    func test_hookPostToolUse_reachableSidecar_returnsUpdatedToolOutput() async throws {
        let rawToolOutput = String(repeating: "build line noise that should compress away\n", count: 40)
            + "BUILD FAILED: 3 errors\n"
        let compressed = "BUILD FAILED: 3 errors"
        let sidecarResponse = DistillResponse(
            requestID: UUID(),
            output: compressed,
            inputCharacters: rawToolOutput.count,
            inputTokens: TokenEstimator.estimate(rawToolOutput),
            outputTokens: TokenEstimator.estimate(compressed),
            originalHandle: "hook1",
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(sidecarResponse)
        let recorder = RequestRecorder()

        // Claude PostToolUse envelope field names from ClaudeAgentSDKBridge.mjs.
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"],
            "tool_response": rawToolOutput,
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)

        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state,
            provider: "claude"
        ) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (encoded, 200)
        }

        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)

        let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        let hookOut = obj?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hookOut?["hookEventName"] as? String, "PostToolUse")
        let updated = hookOut?["updatedToolOutput"] as? String ?? ""
        XCTAssertTrue(updated.hasPrefix(compressed), "updatedToolOutput must carry compressed tool text")
        XCTAssertTrue(updated.contains("[[rc:hook1]]") || updated.hasPrefix(compressed))

        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recordSavings, true)
        XCTAssertEqual(requests.first?.input, rawToolOutput)
        XCTAssertEqual(requests.first?.provider, "claude")
    }

    func test_hookPostToolUse_waveA_deliversUpdatedToolOutputBeforeLedgerTransport() async throws {
        // WHY (BUG 2): the Claude PostToolUse hook has a tight timeout; Wave A
        // compressed output must leave the hook without waiting on the ledger POST.
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)

        let line = "same log line that repeats many times for compression"
        var rawToolOutput = ""
        for _ in 0..<20 { rawToolOutput += line + "\n" }
        rawToolOutput += "exit code: 0\n"
        guard let pre = TokenSaverWaveLosslessPrepass.apply(input: rawToolOutput) else {
            XCTFail("expected Wave A hit for hook fixture")
            return
        }

        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "make test"],
            "tool_response": rawToolOutput,
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)

        let calls = CallCounter()
        let gate = TransportGate()
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state,
            provider: "claude"
        ) { request in
            await gate.waitUntilReleased()
            _ = await calls.increment()
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                // Must carry precomputed Wave A output even if transport is slow.
                XCTAssertEqual(decoded.precomputedOutput, pre.output)
            }
            return (Data("{}".utf8), 200)
        }

        let result = await cli.runResult()
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let hookOut = obj?["hookSpecificOutput"] as? [String: Any]
        let updated = hookOut?["updatedToolOutput"] as? String ?? ""
        // Hook strips trailing newlines when building updatedToolOutput (same as shrink check).
        let expected = ManagedDistillCLI.stripTrailingNewlines(pre.output)
        XCTAssertEqual(
            updated,
            expected,
            "hook must return Wave A compressed tool output before ledger POST"
        )
        XCTAssertNotNil(result.deferredSideEffect, "hook must propagate nested Wave A deferred ledger")
        let before = await calls.count()
        XCTAssertEqual(before, 0, "hook output must not wait on ledger transport")

        await gate.release()
        if let deferred = result.deferredSideEffect {
            await deferred()
        }
        let after = await calls.count()
        XCTAssertEqual(after, 1, "exactly one deferred ledger POST after hook output is ready")
    }

    func test_hookPostToolUse_sidecarUnreachable_returnsEmptyObjectExitZero() async throws {
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
            "tool_response": "lots of tool output that would be compressed if the sidecar were up\n",
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state
        ) { _ in nil }

        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    func test_hookPostToolUse_malformedInput_returnsEmptyObjectExitZero() async {
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: Data("not-json{{{".utf8),
            state: state
        ) { _ in
            XCTFail("malformed hook input must not call transport")
            return nil
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    func test_retrieve_success_returnsOriginal() async {
        let json = #"{"handle":"h","found":true,"original":"the original bytes"}"#
        let cli = ManagedDistillCLI(arguments: ["retrieve", "h"], stdin: Data(), state: state) { request in
            XCTAssertTrue(request.url?.path.contains("/v1/retrieve/h") ?? false)
            return (Data(json.utf8), 200)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "the original bytes")
    }

    func test_retrieve_miss_exitsNonZero() async {
        let json = #"{"handle":"h","found":false,"original":null}"#
        let cli = ManagedDistillCLI(arguments: ["retrieve", "h"], stdin: Data(), state: state) { _ in (Data(json.utf8), 404) }
        let (_, code) = await cli.run()
        XCTAssertEqual(code, 1, "retrieve has no stdin to preserve => loud non-zero on miss")
    }

    func test_statsSubcommandFetchesStatsWithoutCompressingPipedInput() async {
        let raw = Data("transcript or stats input must not become a compression prompt".utf8)
        let snapshot = DistillStatsSnapshot(
            totalSavedTokens: 150,
            totalRuns: 3,
            providers: [DistillStatsProviderSavings(provider: "claude", savedTokens: 150, inputTokens: 500, outputTokens: 350, runs: 3)],
            modes: [DistillStatsModeSavings(provider: "claude", mode: "command-output", savedTokens: 150, runs: 3)]
        )
        let encoded = try! JSONEncoder().encode(snapshot)
        let cli = ManagedDistillCLI(arguments: ["stats"], stdin: raw, state: state) { request in
            XCTAssertEqual(request.url?.path, "/v1/stats")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return (encoded, 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("saved_tokens=150"))
        XCTAssertTrue(text.contains("provider claude: saved=150"))
        XCTAssertNotEqual(out, raw, "stats must not fail-open as command-output compression")
    }

    func test_dslLearnThreadConsumesTranscriptWithoutCompression() async {
        let raw = Data("S start\nD patch\nP pass\n".utf8)
        let cli = ManagedDistillCLI(arguments: ["dsl", "learn-thread", "--stdin"], stdin: raw, state: state) { _ in
            XCTFail("dsl learn-thread must not call /v1/distill")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("accepted \(raw.count) bytes"))
    }

    func test_reservedRankAndWrapSubcommandsDoNotCompressPipedInput() async {
        let raw = Data("rank or wrap input must not become a compression prompt".utf8)
        for subcommand in ["rank", "wrap"] {
            let cli = ManagedDistillCLI(arguments: [subcommand], stdin: raw, state: state) { _ in
                XCTFail("reserved \(subcommand) must not call /v1/distill")
                return nil
            }

            let (out, code) = await cli.run()

            XCTAssertEqual(code, 1)
            XCTAssertNotEqual(out, raw)
            XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("reserved subcommand"))
        }
    }

    // MARK: - stdin cap (WHY: oversized stdin must not OOM the CLI)

    func test_exceedsStdinCap_pureSeam_flagsAboveCapForChunking() {
        // Inputs above the cap must be flagged so the reject path fires before any
        // String/JSONEncoder allocation. Business rule: cap + 1 byte is over limit.
        XCTAssertTrue(
            ManagedDistillCLI.exceedsStdinCap(byteCount: ManagedDistillCLI.stdinCapBytes + 1, cap: ManagedDistillCLI.stdinCapBytes),
            "one byte over cap must be rejected"
        )
    }

    func test_exceedsStdinCap_pureSeam_acceptsAtCap() {
        // Exactly at the cap is allowed; the cap is an exclusive upper bound.
        XCTAssertFalse(
            ManagedDistillCLI.exceedsStdinCap(byteCount: ManagedDistillCLI.stdinCapBytes, cap: ManagedDistillCLI.stdinCapBytes),
            "exactly at cap must be accepted"
        )
    }

    func test_exceedsStdinCap_pureSeam_acceptsUnderCap() {
        XCTAssertFalse(
            ManagedDistillCLI.exceedsStdinCap(byteCount: 1_024, cap: ManagedDistillCLI.stdinCapBytes),
            "small input well under cap must be accepted"
        )
    }

    func test_compress_oneMegabyteInputChunksInsteadOfRejecting() async throws {
        // A 1 MB test log is a normal agent artifact. Token Saver must split it into
        // bounded service calls, emit compressed chunks plus retrieve handles, and keep
        // exit 0 so the shell pipeline remains usable.
        let oneMB = Data(repeating: UInt8(ascii: "x"), count: 1_024 * 1_024)
        let response = DistillResponse(
            requestID: UUID(),
            output: "chunk summary",
            inputCharacters: ManagedDistillCLI.stdinCapBytes,
            inputTokens: 1_000,
            outputTokens: 10,
            originalHandle: "h"
        )
        let encoded = try JSONEncoder().encode(response)
        let recorder = RequestRecorder()
        let cli = ManagedDistillCLI(arguments: ["summarize"], stdin: oneMB, state: state) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (encoded, 200)
        }

        let (out, code) = await cli.run()
        let decodedRequests = await recorder.all()

        XCTAssertEqual(code, 0)
        XCTAssertGreaterThan(decodedRequests.count, 1, "over-cap input must be split into multiple bounded requests")
        XCTAssertTrue(decodedRequests.allSatisfy { $0.input.utf8.count <= ManagedDistillCLI.stdinCapBytes })
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("chunk summary"))
        XCTAssertTrue(text.contains("[[rc:h]]"), "each lossy chunk must remain retrievable")
        XCTAssertNotEqual(out, oneMB, "successful chunked compression should not fall back to raw output")
    }

    func test_compress_overCapChunkFailureFailsOpenToExactRawInput() async {
        // If any chunk cannot be compressed, the whole CLI must return the exact raw
        // input. Partial lossy summaries would hide missing bytes.
        let oneMB = Data(repeating: UInt8(ascii: "z"), count: 1_024 * 1_024)
        let calls = CallCounter()
        let cli = ManagedDistillCLI(arguments: ["summarize"], stdin: oneMB, state: state) { _ in
            await calls.increment() == 1 ? nil : (Data(), 500)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, oneMB, "chunk failure must fail open to byte-exact stdin")
    }

    func test_compress_atCapStdin_proceedsNormally_failsOpenOnTransportFailure() async {
        // A stdin exactly at the cap must not be rejected; normal fail-open applies.
        let atCap = Data(repeating: UInt8(ascii: "x"), count: ManagedDistillCLI.stdinCapBytes)
        let cli = ManagedDistillCLI(arguments: [], stdin: atCap, state: state) { _ in nil }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0, "at-cap stdin is accepted; transport failure => fail-open, exit 0")
        XCTAssertEqual(out, atCap, "fail-open echoes stdin verbatim")
    }
}
