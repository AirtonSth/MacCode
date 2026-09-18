import CryptoKit
import XCTest
import CoreModel
import Persistence
@testable import DistillCore

private let managedDistillCLITestRootRunID = "managed-distill-cli-tests"
private let managedDistillCLITestReceiptKey = Data(repeating: 0x42, count: 32)

private extension ManagedDistillCLI {
    init(
        arguments: [String],
        stdin: Data,
        state: State?,
        provider: String? = nil,
        recoveryContext: TokenSaverRecoveryRequestContext? = nil,
        invocationID: String = UUID().uuidString.lowercased(),
        maxOutputCharacters: Int = 4_000,
        reversibleStoreMinBytes: Int? = nil,
        distillAdmission: @escaping DistillAdmission = { true },
        transport: @escaping Transport
    ) {
        self.init(
            arguments: arguments,
            stdin: stdin,
            state: state,
            rootRunID: managedDistillCLITestRootRunID,
            provider: provider,
            recoveryContext: recoveryContext,
            invocationID: invocationID,
            maxOutputCharacters: maxOutputCharacters,
            reversibleStoreMinBytes: reversibleStoreMinBytes,
            distillAdmission: distillAdmission,
            transport: transport
        )
    }
}

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

    private let state = ManagedDistillCLI.State(
        baseURL: "http://127.0.0.1:9",
        authToken: "t",
        receiptKey: managedDistillCLITestReceiptKey
    )

    func test_compress_success_recordsSidecarBodySavingsAndConfirmsRecoverySeparately() async throws {
        let raw = Data(String(repeating: "verbose build output that passed\n", count: 20).utf8)
        let resp = DistillResponse(
            requestID: UUID(), output: "PASS", inputCharacters: raw.count,
            inputTokens: 25, outputTokens: 1, originalHandle: "abc123",
            recoveryIdempotencyKey: "delivery-key", routeStage: .llmMLX
        )
        let data = try! JSONEncoder().encode(resp)
        let recorder = RequestRecorder()
        let cli = ManagedDistillCLI(arguments: ["Return PASS or FAIL only."], stdin: raw, state: state) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
                if decoded.recordSavings == true && decoded.precomputedOutput == nil {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-RemoteCode-Delivery-Deferred"), "1")
                }
            }
            return (data, 200)
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("PASS"))
        XCTAssertTrue(s.contains("[[rc:abc123]]"), "handle marker embedded so the agent can retrieve the original")
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(s), "an actual lossy replacement must carry an applied receipt")
        XCTAssertTrue(s.hasSuffix("\n"), "successful CLI output must preserve its terminal LF contract")
        XCTAssertLessThan(out.count, raw.count, "recovery and receipt lines are part of the net UTF-8 shrink gate")

        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 2, "compression (savings) and recovery confirmation must be separate requests")
        let compress = try XCTUnwrap(requests.first)
        XCTAssertEqual(compress.recordSavings, true, "displayed savings use the sidecar compressed body")
        XCTAssertNil(compress.precomputedOutput)
        let confirm = try XCTUnwrap(requests.last)
        XCTAssertEqual(confirm.recordSavings, false, "recovery confirm must not write a second savings row")
        XCTAssertEqual(confirm.precomputedOutput, s)
        XCTAssertEqual(
            confirm.precomputedRecoveryConfirmations,
            [.init(capability: "abc123", idempotencyKey: "delivery-key")]
        )
        let record = try XCTUnwrap(DistillSavingsCalculator.record(
            for: compress,
            response: resp
        ))
        XCTAssertEqual(record.outputTokens, 1)
        XCTAssertEqual(record.savedTokens, max(25 - 1, 0))
        XCTAssertEqual(record.routeStage, .llmMLX)
        let bodyDelta = max(TokenEstimator.estimate(String(decoding: raw, as: UTF8.self)) - TokenEstimator.estimate("PASS"), 0)
        let deliveredDelta = max(TokenEstimator.estimate(String(decoding: raw, as: UTF8.self)) - TokenEstimator.estimate(s), 0)
        XCTAssertGreaterThan(bodyDelta, deliveredDelta, "sidecar body must out-save receipt-inclusive stdout")
    }

    func test_compress_deterministicWithoutHandle_emitsAppliedReceiptAfterNetUTF8Shrink() async throws {
        // WHY: lossless/deterministic compression has no recovery handle, so the
        // distinct applied receipt is the only durable proof that bytes changed.
        let rawText = String(repeating: "é: unchanged semantic field with excess spacing\n", count: 20)
        let compact = "é: unchanged semantic field"
        let response = DistillResponse(
            requestID: UUID(),
            output: compact + "\n",
            inputCharacters: rawText.count,
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(response)
        let raw = Data(rawText.utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (encoded, 200) }

        let (out, code) = await cli.run()
        let emitted = String(decoding: out, as: UTF8.self)

        XCTAssertEqual(code, 0)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(emitted))
        XCTAssertTrue(emitted.hasSuffix("\n"), "successful CLI output must retain a terminal LF")
        XCTAssertEqual(DistillAppliedReceipt.strip(emitted), compact)
        XCTAssertFalse(emitted.contains("\n\n[[rcd:"), "an existing output LF must serve as the receipt separator")
        XCTAssertFalse(DistillAppliedReceipt.strip(emitted).contains("[[rc:"), "lossless output needs no recovery handle")
        XCTAssertLessThan(out.count, raw.count, "the comparison must use UTF-8 bytes, including the receipt")
    }

    func test_compressWithReceiptKeyAndRootEmitsVerifiableV2BoundToExactPrefix() async throws {
        // WHY: a marker is trustworthy only when it authenticates the exact bytes
        // the provider sees under this root run and the current On-lifecycle key.
        let raw = Data(String(repeating: "verbose output line\n", count: 40).utf8)
        let encoded = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(),
            output: "COMPRESSED\n",
            inputCharacters: raw.count,
            routeStage: .deterministic
        ))
        let key = Data(0..<32)
        let rootRunID = "123e4567-e89b-12d3-a456-426614174000"
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: raw,
            state: .init(baseURL: "http://127.0.0.1:9", authToken: "t", receiptKey: key),
            rootRunID: rootRunID
        ) { _ in (encoded, 200) }

        let (out, code) = await cli.run()
        let parsed = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(in: out))
        let prefix = out.prefix(parsed.markerByteRange.lowerBound)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(prefix, Data("COMPRESSED\n".utf8))
        XCTAssertTrue(DistillAppliedReceipt.verify(
            parsed,
            rootRunID: rootRunID,
            payloadByteCount: prefix.count,
            payloadSHA256: Data(SHA256.hash(data: prefix)),
            key: key
        ))
    }

    func test_compressWithoutReceiptKeyOrRootFailsOpenVerbatim() async throws {
        // WHY: lossy output without receipt authority cannot be authenticated by
        // the host, so legacy state must preserve the exact input instead.
        let raw = Data(String(repeating: "verbose output line\n", count: 40).utf8)
        let encoded = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(), output: "short", inputCharacters: raw.count,
            routeStage: .deterministic
        ))
        let key = Data(repeating: 0x55, count: 32)
        let withoutKey = ManagedDistillCLI(
            arguments: [], stdin: raw,
            state: .init(baseURL: "http://127.0.0.1:9", authToken: "t"),
            rootRunID: "root"
        ) { _ in (encoded, 200) }
        let withoutRoot = ManagedDistillCLI(
            arguments: [], stdin: raw,
            state: .init(baseURL: "http://127.0.0.1:9", authToken: "t", receiptKey: key),
            rootRunID: nil
        ) { _ in (encoded, 200) }

        for result in [await withoutKey.run(), await withoutRoot.run()] {
            XCTAssertEqual(result.1, 0)
            XCTAssertNil(DistillAppliedReceipt.parseTrailingV2Marker(in: result.0))
            XCTAssertEqual(result.0, raw, "missing receipt authority must fail open to verbatim stdin")
        }
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

    func test_threadIdOnlyEnvironmentStillForwardsSavingsHeader() async throws {
        // WHY: complete recovery scope is for store-before-loss. The transcript
        // chip only needs X-RemoteCode-Thread-ID on the distill POST.
        let recorder = ScopeHeaderRecorder()
        let response = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(), output: "compressed", inputCharacters: 20,
            originalHandle: nil, routeStage: .deterministic
        ))
        let environment = [
            "RC_TOKEN_SAVER_THREAD_ID": "thread-only",
            "REMOTE_CODE_AGENT_PROVIDER": "grok",
        ]
        let cli = ManagedDistillCLI(
            arguments: [], stdin: Data("provider input".utf8), state: state,
            provider: "grok",
            recoveryContext: ManagedDistillCLI.recoveryContext(environment: environment)
        ) { request in
            await recorder.append(request)
            return (response, 200)
        }
        _ = await cli.run()
        let scopes = await recorder.all()
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?["Thread-ID"], "thread-only")
        XCTAssertEqual(scopes.first?["Workspace-ID"], "")
        XCTAssertEqual(scopes.first?["Project-ID"], "")
        XCTAssertEqual(scopes.first?["Attempt-ID"], "")
    }

    func test_alwaysOnSubagentThreadForwardsSavingsHeaderWhenTokenSaverThreadMissing() async throws {
        // WHY: PATH wraps that only inherited RC_REMOTE_CODE_SUBAGENT_THREAD_ID
        // used to POST distill without X-RemoteCode-Thread-ID, so the footer
        // never saw the delivered savings.
        let recorder = ScopeHeaderRecorder()
        let response = try JSONEncoder().encode(DistillResponse(
            requestID: UUID(), output: "compressed", inputCharacters: 20,
            originalHandle: nil, routeStage: .deterministic
        ))
        let thread = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let environment = [
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": thread,
            "REMOTE_CODE_AGENT_PROVIDER": "claude",
        ]
        XCTAssertEqual(
            TokenSaverRecoveryRequestContext.savingsThreadID(environment: environment),
            thread
        )
        let cli = ManagedDistillCLI(
            arguments: [], stdin: Data("provider input".utf8), state: state,
            provider: "claude",
            recoveryContext: ManagedDistillCLI.recoveryContext(environment: environment)
        ) { request in
            await recorder.append(request)
            return (response, 200)
        }
        _ = await cli.run()
        let scopes = await recorder.all()
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?["Thread-ID"], thread)
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
        XCTAssertFalse(DistillAppliedReceipt.containsMarker(String(decoding: out, as: UTF8.self)))
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

    func test_compress_verbatimAndIdentityResponsesFailOpenWithoutAppliedReceipt() async throws {
        // WHY: a successful HTTP response is not proof that Distill changed bytes.
        // Verbatim routing and identity output must remain exact passthrough.
        let rawText = String(repeating: "original tool output line\n", count: 12)
        let raw = Data(rawText.utf8)
        let cases = [
            DistillResponse(
                requestID: UUID(), output: "short but explicitly verbatim",
                inputCharacters: rawText.count, routeStage: .verbatim
            ),
            DistillResponse(
                requestID: UUID(), output: rawText,
                inputCharacters: rawText.count, routeStage: .deterministic
            ),
        ]

        for response in cases {
            let encoded = try JSONEncoder().encode(response)
            let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in (encoded, 200) }
            let (out, code) = await cli.run()

            XCTAssertEqual(code, 0)
            XCTAssertEqual(out, raw)
            XCTAssertFalse(DistillAppliedReceipt.containsMarker(String(decoding: out, as: UTF8.self)))
        }
    }

    func test_compress_markerInclusiveNoNetShrinkFailsOpenWithoutAppliedReceipt() async throws {
        // WHY: comparing only the compressed body would claim a saving even when
        // the mandatory receipt makes the provider-visible payload larger.
        let receiptOverhead = Data(("\n" + DistillAppliedReceipt.makeMarker() + "\n").utf8).count
        let rawText = String(repeating: "a", count: receiptOverhead + 16)
        let almostSameSize = String(repeating: "b", count: rawText.utf8.count - 1)
        let response = DistillResponse(
            requestID: UUID(),
            output: almostSameSize,
            inputCharacters: rawText.count,
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(response)
        let raw = Data(rawText.utf8)
        let recorder = RequestRecorder()
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (encoded, 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, raw)
        XCTAssertFalse(DistillAppliedReceipt.containsMarker(String(decoding: out, as: UTF8.self)))
        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recordSavings, true, "display savings use the sidecar body even if the receipt gate fail-opens")
        XCTAssertNil(requests.first?.precomputedOutput)
    }

    func test_wrapperFaithfulnessRejectionStillRecordedSidecarBodySavings() async throws {
        // WHY: displayed savings follow the sidecar compressed body. Wrapper
        // faithfulness may drop the emitted stdout and skip recovery confirm,
        // but the compress POST already recorded the body delta.
        let rawText = String(repeating: "verbose compiler progress line\n", count: 80)
        let response = DistillResponse(
            requestID: UUID(),
            output: "x",
            inputCharacters: rawText.count,
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(response)
        let recorder = RequestRecorder()
        let cli = ManagedDistillCLI(arguments: [], stdin: Data(rawText.utf8), state: state) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (encoded, 200)
        }

        let result = await cli.runResult()
        let emitted = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertNil(result.deferredSideEffect, "no recovery handle → no deferred confirm POST")
        XCTAssertFalse(CommandWrapPolicy.isFaithfulCompression(
            rawByteCount: Data(rawText.utf8).count,
            compressedContentByteCount: CommandWrapPolicy.compressedContentByteCount(emitted)
        ))

        // Mirror the wrapper rejection: emit raw and deliberately drop `deferredSideEffect`.
        await Task.yield()
        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recordSavings, true, "sidecar-body savings already landed on the compress POST")
        XCTAssertNil(requests.first?.precomputedOutput)
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
        // Display accounting records the Wave A prepass body (no receipt). The stub
        // returns DIFFERENT bytes than pre.output; if the client used that response
        // body for savings, numbers would diverge.
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
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(text), "a delivered Wave A shrink must carry an applied receipt")
        XCTAssertTrue(text.hasSuffix("\n"), "Wave A CLI output must retain its terminal LF")
        XCTAssertEqual(
            ManagedDistillCLI.stripTrailingNewlines(DistillAppliedReceipt.strip(text)),
            ManagedDistillCLI.stripTrailingNewlines(pre.output),
            "caller must receive the Wave A compressed output before the receipt"
        )
        XCTAssertLessThan(out.count, input.utf8.count, "Wave A receipt-inclusive output must still shrink")
        XCTAssertFalse(text.contains(independentSidecarOutput), "caller must not see independent sidecar recompute")
        XCTAssertNotEqual(out, Data(input.utf8), "Wave A hit must not fail-open to raw stdin")

        let expectedRecord = ManagedDistillCLI.prepassSavingsRecord(
            original: input,
            compressed: pre.output,
            provider: "grok",
            waveID: pre.waveID
        )
        XCTAssertNotNil(expectedRecord, "DistillSavingsCalculator must accept the sidecar-body delta")
        XCTAssertEqual(
            expectedRecord?.savedTokens,
            max(TokenEstimator.estimate(input) - TokenEstimator.estimate(pre.output), 0)
        )
        XCTAssertGreaterThanOrEqual(
            expectedRecord?.savedTokens ?? 0,
            max(TokenEstimator.estimate(input) - TokenEstimator.estimate(text), 0),
            "prepass body savings must not be smaller than the receipt-inclusive delivered delta"
        )

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
            "ledger POST must carry the Wave A sidecar body, not the receipt-inclusive stdout"
        )
        XCTAssertEqual(posted.precomputedRouteStage, .deterministic)
        XCTAssertEqual(posted.cacheState, "wave_prepass_\(pre.waveID)")
        XCTAssertEqual(posted.provider, "grok")

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
        let emitted = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(emitted))
        XCTAssertTrue(emitted.hasSuffix("\n"))
        XCTAssertEqual(
            ManagedDistillCLI.stripTrailingNewlines(DistillAppliedReceipt.strip(emitted)),
            ManagedDistillCLI.stripTrailingNewlines(pre.output)
        )
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
        let emitted = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(emitted))
        XCTAssertEqual(
            ManagedDistillCLI.stripTrailingNewlines(DistillAppliedReceipt.strip(emitted)),
            ManagedDistillCLI.stripTrailingNewlines(pre.output)
        )
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 2, "one bounded retry after the initial failure, then gives up")
    }

    func test_waveAHit_transientLedgerFailure_recoveredByOneRetry() async {
        // WHY: bestEffortRecordPrepassSavings used to swallow ANY transport failure on
        // a single attempt with zero observability — a resident sidecar racing its own
        // restart window could silently drop a real, already-computed saving. One
        // bounded retry recovers exactly that transient case without turning the ledger
        // POST into a blocking gate on the interactive hook path.
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
            let attempt = await calls.increment()
            if attempt == 1 {
                return nil // transient failure on the first attempt only
            }
            return (Data("{}".utf8), 200)
        }

        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        let emitted = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(emitted))
        XCTAssertEqual(
            ManagedDistillCLI.stripTrailingNewlines(DistillAppliedReceipt.strip(emitted)),
            ManagedDistillCLI.stripTrailingNewlines(pre.output)
        )
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 2, "retry must recover the saving after one transient failure, then stop")
    }

    func test_waveAHit_lostFirstHTTP200DoesNotDoubleSavingsLedger() async throws {
        // WHY: the server can commit savings and send 200 while the client loses
        // that response. Its bounded retry reuses the exact DistillRequest UUID,
        // so persistence must credit the delivered bytes exactly once.
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = TokenSaverSavingsRepository(db: db)
        let token = "lost-200-token"
        let configuration = try DistillServiceConfiguration(
            authToken: token,
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1),
            onSuccess: { request, response, threadID in
                guard let record = DistillSavingsCalculator.record(
                    for: request,
                    response: response,
                    threadID: threadID
                ) else { return }
                do {
                    _ = try repo.record(
                        provider: record.provider,
                        mode: record.mode,
                        inputTokens: record.inputTokens,
                        outputTokens: record.outputTokens,
                        savedTokens: record.savedTokens,
                        cacheState: record.cacheState,
                        engine: record.routeStage?.rawValue ?? "unknown",
                        attributability: record.attributability,
                        delivered: record.delivered,
                        threadID: record.threadID,
                        idempotencyKey: record.idempotencyKey
                    )
                } catch {
                    XCTFail("savings persistence failed: \(error)")
                }
            }
        )
        let ready = try await server.start()
        defer { server.stop() }

        let line = "same log line that repeats many times for compression"
        let input = String(repeating: line + "\n", count: 20) + "exit code: 0\n"
        let calls = CallCounter()
        let liveState = ManagedDistillCLI.State(
            baseURL: ready.baseURL,
            authToken: token,
            receiptKey: managedDistillCLITestReceiptKey
        )
        let cli = ManagedDistillCLI(
            arguments: [],
            stdin: Data(input.utf8),
            state: liveState,
            provider: "claude"
        ) { request in
            let attempt = await calls.increment()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if attempt == 1 { return nil } // server committed; client lost 200
                return (data, status)
            } catch {
                return nil
            }
        }

        let (output, exitCode) = await cli.run()

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(String(decoding: output, as: UTF8.self)))
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 2, "the hidden first 200 must trigger exactly one retry")
        let summary = try repo.summary()
        XCTAssertEqual(summary.totalRuns, 1, "both HTTP requests represent one delivered saving")
        XCTAssertGreaterThan(summary.totalSavedTokens, 0)
    }

    func test_waveAHit_smallerBodyButReceiptEliminatesGain_failsOpenWithoutLedger() async throws {
        // Three short repeated lines are byte-exact collapsible, but save only two
        // bytes. The applied receipt would inflate the final payload, so Wave A must
        // return the exact input and must not record a saving that was not delivered.
        TokenSaverWaveLiveRollout.activate(.waveA)
        setenv("RC_TOKEN_SAVER_DISTILL_HINT", "1", 1)

        let input = "abcde\nabcde\nabcde"
        let pre = try XCTUnwrap(TokenSaverWaveLosslessPrepass.apply(input: input))
        XCTAssertGreaterThan(pre.savedBytes, 0)
        XCTAssertLessThan(pre.savedBytes, Data(("\n" + DistillAppliedReceipt.makeMarker() + "\n").utf8).count)

        let calls = CallCounter()
        let raw = Data(input.utf8)
        let cli = ManagedDistillCLI(arguments: [], stdin: raw, state: state) { _ in
            _ = await calls.increment()
            return (Data("{}".utf8), 200)
        }

        let result = await cli.runResult()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, raw)
        XCTAssertNil(result.deferredSideEffect)
        XCTAssertFalse(DistillAppliedReceipt.containsMarker(String(decoding: result.stdout, as: UTF8.self)))
        let transportCalls = await calls.count()
        XCTAssertEqual(transportCalls, 0, "an undelivered Wave A candidate must not write savings")
    }

    // MARK: - hook pre-tool-pipe

    func test_hookPreToolPipe_rewritesWrapEligibleGrokShellAndPreservesOtherFields() async throws {
        // WHY: Grok cannot rewrite tool *output*. PreToolUse updatedInput is the
        // documented way to make wrap-eligible run_terminal_command actually pipe.
        let stdin = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "pre_tool_use",
            "toolName": "run_terminal_command",
            "toolInput": [
                "command": "swift test --filter Foo",
                "description": "run tests",
                "background": false,
            ],
        ] as [String: Any])
        let cli = ManagedDistillCLI(
            arguments: ["hook", "pre-tool-pipe"],
            stdin: stdin,
            state: state,
            distillAdmission: { true }
        ) { _ in
            XCTFail("pre-tool-pipe must not call the sidecar")
            return nil
        }
        let result = cli.hookPreToolPipe(
            processArguments: ["/tmp/not-distill"],
            environment: ["RC_REMOTE_CODE_MANAGED_BIN": "/opt/rc-bin"],
            homeDirectory: "/tmp",
            fileExists: { $0 == "/opt/rc-bin/distill" }
        )
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let hookOut = obj?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hookOut?["hookEventName"] as? String, "PreToolUse")
        let updated = try XCTUnwrap(hookOut?["updatedInput"] as? [String: Any])
        let command = try XCTUnwrap(updated["command"] as? String)
        XCTAssertTrue(command.hasPrefix("swift test --filter Foo | "))
        XCTAssertTrue(command.contains("/opt/rc-bin/distill"))
        XCTAssertEqual(updated["description"] as? String, "run tests")
        XCTAssertEqual(updated["background"] as? Bool, false)
    }

    func test_hookPreToolPipe_exactOutputAndAdmissionOffFailOpen() async throws {
        let exact = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "rg -n FAIL Sources"],
        ] as [String: Any])
        let admitted = ManagedDistillCLI(
            arguments: ["hook", "pre-tool-pipe"],
            stdin: exact,
            state: state,
            distillAdmission: { true }
        ) { _ in nil }
        let exactResult = admitted.hookPreToolPipe(fileExists: { _ in true })
        XCTAssertEqual(exactResult.exitCode, 0)
        XCTAssertEqual(String(decoding: exactResult.stdout, as: UTF8.self), "{}")

        let wrap = try JSONSerialization.data(withJSONObject: [
            "toolName": "run_terminal_command",
            "toolInput": ["command": "swift test"],
        ] as [String: Any])
        let denied = ManagedDistillCLI(
            arguments: ["hook", "pre-tool-pipe"],
            stdin: wrap,
            state: state,
            distillAdmission: { false }
        ) { _ in
            XCTFail("denied admission must not transport")
            return nil
        }
        let (out, code) = await denied.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
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
            recoveryIdempotencyKey: "hook-delivery-key",
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(sidecarResponse)
        let recorder = RequestRecorder()

        // Non-Bash tools retain their exact response string in the hook envelope,
        // so PostToolUse remains a valid compression lane for those tools.
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.invalid/build-log"],
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
        XCTAssertTrue(updated.contains("[[rc:hook1]]"), "lossy hook output must retain its recovery handle")
        XCTAssertTrue(
            DistillAppliedReceipt.containsMarker(updated),
            "the nested CLI receipt must survive the hook JSON replacement automatically"
        )
        XCTAssertLessThan(updated.utf8.count, rawToolOutput.utf8.count)

        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.recordSavings, true, "hook compress POST records sidecar-body savings")
        XCTAssertEqual(requests.first?.input, rawToolOutput)
        XCTAssertEqual(requests.first?.provider, "claude")
        XCTAssertEqual(requests.last?.recordSavings, false, "recovery confirm must not double-count savings")
        XCTAssertEqual(requests.last?.precomputedOutput, updated)
        XCTAssertEqual(requests.last?.precomputedRouteStage, .deterministic)
        XCTAssertEqual(
            requests.last?.precomputedRecoveryConfirmations,
            [.init(capability: "hook1", idempotencyKey: "hook-delivery-key")]
        )
    }

    func test_hookPostToolUse_receiptInclusiveRejectionStillRecordsSidecarBodySavings() async throws {
        // WHY: displayed savings use the sidecar body. The hook still fail-opens
        // stdout when the receipt wipes the shrink, but the compress POST already
        // recorded the body delta.
        let rawToolOutput = String(repeating: "tool diagnostic line\n", count: 60)
        let response = DistillResponse(
            requestID: UUID(),
            output: String(repeating: "x", count: rawToolOutput.utf8.count - 1),
            inputCharacters: rawToolOutput.count,
            routeStage: .deterministic
        )
        let encoded = try JSONEncoder().encode(response)
        let recorder = RequestRecorder()
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.invalid/large"],
            "tool_response": rawToolOutput,
        ]
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: try JSONSerialization.data(withJSONObject: hookJSON),
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
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recordSavings, true)
        XCTAssertNil(requests.first?.precomputedOutput)
    }

    func test_hookPostToolUse_bashObject_withOrWithoutTerminalLF_failsOpenWithoutTransport() async throws {
        // WHY: Claude Code normalizes Bash stdout before PostToolUse and removes
        // leading/trailing blank lines. The hook receives the same object shape for
        // a process that emitted a terminal LF and one that did not, so storing
        // either string as the byte-exact original would be dishonest. PATH wrappers
        // capture the real bytes before Claude normalization; Bash PostToolUse must
        // therefore fail open and leave Claude's original response object untouched.
        let recorder = RequestRecorder()
        let base = String(repeating: "build line noise that should compress away\n", count: 40)
            + "BUILD FAILED: 3 errors"

        for rawToolOutput in [base, base + "\n"] {
            let hookJSON: [String: Any] = [
                "hook_event_name": "PostToolUse",
                "tool_name": "Bash",
                "tool_input": ["command": "make test"],
                "tool_response": [
                    "stdout": rawToolOutput,
                    "stderr": "compiler warning kept verbatim",
                    "interrupted": false,
                    "isImage": false,
                    "noOutputExpected": false,
                ] as [String: Any],
            ]
            let stdin = try JSONSerialization.data(withJSONObject: hookJSON)
            let cli = ManagedDistillCLI(
                arguments: ["hook", "post-tool-use"],
                stdin: stdin,
                state: state,
                provider: "claude"
            ) { request in
                await recorder.append(try! JSONDecoder().decode(DistillRequest.self, from: request.httpBody!))
                return nil
            }

            let (out, code) = await cli.run()
            XCTAssertEqual(code, 0)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
        }

        let requests = await recorder.all()
        XCTAssertTrue(
            requests.isEmpty,
            "ambiguous Bash stdout must never be stored or compressed by PostToolUse"
        )
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
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.invalid/build-log"],
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
                XCTAssertEqual(decoded.recordSavings, true)
                XCTAssertEqual(decoded.precomputedOutput, pre.output)
                XCTAssertFalse(DistillAppliedReceipt.containsMarker(decoded.precomputedOutput ?? ""))
            }
            return (Data("{}".utf8), 200)
        }

        let result = await cli.runResult()
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let hookOut = obj?["hookSpecificOutput"] as? [String: Any]
        let updated = hookOut?["updatedToolOutput"] as? String ?? ""
        XCTAssertTrue(
            DistillAppliedReceipt.containsMarker(updated),
            "the nested Wave A receipt must survive updatedToolOutput replacement"
        )
        XCTAssertEqual(
            ManagedDistillCLI.stripTrailingNewlines(DistillAppliedReceipt.strip(updated)),
            ManagedDistillCLI.stripTrailingNewlines(pre.output),
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
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.invalid/large"],
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

    func test_hookPostToolUse_editTool_skipsCompressionWithoutTransport() async throws {
        // WHY: mutation tools must stay byte-exact so the model never patches from a lossy view.
        let large = String(repeating: "old line that would compress\n", count: 40)
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Edit",
            "tool_input": ["path": "Foo.swift"],
            "tool_response": large,
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state
        ) { _ in
            XCTFail("Edit tool must not call Distill transport")
            return nil
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    func test_hookPostToolUse_bashRg_skipsCompressionWithoutTransport() async throws {
        // Council O-exact-output: Bash + rg must stay raw even when stdout is large.
        let large = String(repeating: "Sources/Foo.swift:1: match\n", count: 40)
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "rg -n match Sources"],
            "tool_response": large,
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state
        ) { _ in
            XCTFail("exact-output Bash must not call Distill transport")
            return nil
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    func test_hookPostToolUse_imagePayload_skipsCompressionWithoutTransport() async throws {
        let jpegish = String(repeating: "/9j/4AAQSkZJRgABAQAAAQABAAD", count: 80)
        let hookJSON: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_input": ["path": "shot.png"],
            "tool_response": #"{"type":"image","data":"\#(jpegish)"}"#,
        ]
        let stdin = try JSONSerialization.data(withJSONObject: hookJSON)
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use"],
            stdin: stdin,
            state: state
        ) { _ in
            XCTFail("image tool output must not call Distill transport")
            return nil
        }
        let (out, code) = await cli.run()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    // MARK: - hook post-tool-use-grok (grok-build ≥ 1.0.34 updatedToolOutput)

    /// Analyzed ReadFile result: the model receives `content`, while
    /// `absolute_path` / `offset` / `total_lines` / `raw_output` are recovered scope
    /// the replacement must preserve byte for byte.
    private func grokReadFileEnvelope(content: String, raw: String = "raw bytes") -> [String: Any] {
        [
            "hookEventName": "post_tool_use",
            "hook_event_name": "PostToolUse",
            "toolName": "read_file",
            "tool_name": "read_file",
            "toolInput": ["target_file": "Sources/Big.swift"],
            "toolResultTruncated": false,
            "toolResult": [
                "type": "ReadFile",
                "FileContent": [
                    "content": content,
                    "content_concise": content,
                    "absolute_path": "/tmp/Sources/Big.swift",
                    "offset": NSNull(),
                    "raw_output": raw,
                    "total_lines": 200,
                ],
            ],
        ]
    }

    private func grokResponse(output: String, handle: String) -> Data {
        let response = DistillResponse(
            requestID: UUID(),
            output: output,
            inputCharacters: 4_000,
            inputTokens: 1_000,
            outputTokens: 80,
            originalHandle: handle,
            recoveryIdempotencyKey: "grok-delivery-key",
            routeStage: .deterministic
        )
        return try! JSONEncoder().encode(response)
    }

    func test_hookPostToolUseGrok_readFile_replacesContentAndKeepsRecoveryScope() async throws {
        let content = String(repeating: "1→line of body text that compresses away\n", count: 60)
        let envelope = grokReadFileEnvelope(content: content)
        let stdin = try JSONSerialization.data(withJSONObject: envelope)
        let compressed = "SIGNATURE: func thing()"
        let recorder = RequestRecorder()

        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { request in
            if let body = request.httpBody,
               let decoded = try? JSONDecoder().decode(DistillRequest.self, from: body) {
                await recorder.append(decoded)
            }
            return (self.grokResponse(output: compressed, handle: "grok1"), 200)
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let hookOut = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hookOut["hookEventName"] as? String, "PostToolUse")
        let updated = try XCTUnwrap(hookOut["updatedToolOutput"] as? [String: Any])
        XCTAssertEqual(updated["type"] as? String, "ReadFile", "replacement must keep grok's tagged shape")
        let fileContent = try XCTUnwrap(updated["FileContent"] as? [String: Any])
        let replaced = try XCTUnwrap(fileContent["content"] as? String)
        XCTAssertTrue(replaced.hasPrefix(compressed))
        XCTAssertTrue(replaced.contains("[[rc:grok1]]"), "lossy grok output must keep its recovery handle")
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(replaced))
        XCTAssertLessThan(replaced.utf8.count, content.utf8.count)
        XCTAssertEqual(
            fileContent["content_concise"] as? String,
            replaced,
            "both model-facing copies must agree"
        )
        XCTAssertEqual(fileContent["absolute_path"] as? String, "/tmp/Sources/Big.swift")
        XCTAssertEqual(fileContent["total_lines"] as? Int, 200)
        XCTAssertEqual(fileContent["raw_output"] as? String, "raw bytes")
        XCTAssertTrue(fileContent["offset"] is NSNull)

        let requests = await recorder.all()
        XCTAssertEqual(requests.first?.provider, "grok", "grok hook compression is attributed to grok")
        XCTAssertEqual(requests.first?.recordSavings, true)
    }

    func test_hookPostToolUseGrok_listDir_replacesContentAndKeepsRootPath() async throws {
        let content = String(repeating: "- Sources/SomeDirectory/File.swift\n", count: 80)
        let stdin = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "post_tool_use",
            "toolName": "list_dir",
            "toolResult": [
                "type": "ListDir",
                "Content": [
                    "content": content,
                    "absolute_root_path": "/tmp/repo/.",
                ],
            ],
        ])
        let compressed = "- Sources/SomeDirectory/"
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { _ in (self.grokResponse(output: compressed, handle: "grok2"), 200) }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let hookOut = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(hookOut["updatedToolOutput"] as? [String: Any])
        let listed = try XCTUnwrap(updated["Content"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(listed["content"] as? String).hasPrefix(compressed))
        XCTAssertEqual(listed["absolute_root_path"] as? String, "/tmp/repo/.")
    }

    func test_hookPostToolUseGrok_webFetch_replacesContentAndKeepsMetadata() async throws {
        let content = "<html>" + String(repeating: "<div class=\"nav\">chrome</div>", count: 120)
        let stdin = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "post_tool_use",
            "toolName": "web_fetch",
            "toolResult": [
                "type": "WebFetch",
                "Content": [
                    "url": "https://example.invalid/docs",
                    "content": content,
                    "content_type": "text/html",
                    "status_code": 200,
                    "bytes": content.utf8.count,
                ],
            ],
        ])
        let compressed = "Docs: install steps and API signature."
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { _ in (self.grokResponse(output: compressed, handle: "grok3"), 200) }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let hookOut = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(hookOut["updatedToolOutput"] as? [String: Any])
        let payload = try XCTUnwrap(updated["Content"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(payload["content"] as? String).hasPrefix(compressed))
        XCTAssertEqual(payload["url"] as? String, "https://example.invalid/docs")
        XCTAssertEqual(payload["status_code"] as? Int, 200)
    }

    /// Shell (byte-exact), search matches, mutation and unknown variants must never
    /// be rewritten: they fail open before any transport call.
    func test_hookPostToolUseGrok_unverifiedVariants_failOpenWithoutTransport() async throws {
        let cases: [[String: Any]] = [
            ["type": "Bash", "output": [1, 2, 3], "output_for_prompt": "exit: 0\n", "exit_code": 0],
            ["type": "GrepSearch", "stdout": [1, 2, 3], "match_count": 1],
            ["type": "EditsApplied", "EditsApplied": ["old_string": "a", "new_string": "b"]],
            ["type": "FutureVariant", "Content": ["content": String(repeating: "x", count: 4_000)]],
        ]
        for result in cases {
            let stdin = try JSONSerialization.data(withJSONObject: [
                "hookEventName": "post_tool_use",
                "toolName": "run_terminal_command",
                "toolResult": result,
            ])
            let cli = ManagedDistillCLI(
                arguments: ["hook", "post-tool-use-grok"],
                stdin: stdin,
                state: state
            ) { _ in
                XCTFail("variant \(result["type"] ?? "?") must not call Distill transport")
                return nil
            }
            let (out, code) = await cli.run()
            XCTAssertEqual(code, 0)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}", "variant \(result["type"] ?? "?")")
        }
    }

    func test_hookPostToolUseGrok_truncatedResult_failsOpenWithoutTransport() async throws {
        let content = String(repeating: "1→long file read output\n", count: 60)
        var envelope = grokReadFileEnvelope(content: content)
        envelope["toolResultTruncated"] = true
        let stdin = try JSONSerialization.data(withJSONObject: envelope)
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { _ in
            XCTFail("a truncated tool result is not the full output and must not be rewritten")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    func test_hookPostToolUseGrok_smallOutput_failsOpenBelowThreshold() async throws {
        let stdin = try JSONSerialization.data(withJSONObject: grokReadFileEnvelope(content: "1→tiny\n2→file\n"))
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { _ in
            XCTFail("below-threshold reads must not call Distill transport")
            return nil
        }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "{}")
    }

    /// The provider-visible replacement must always carry both the applied receipt
    /// and the recovery handle, whatever the sidecar body looked like.
    func test_hookPostToolUseGrok_replacementAlwaysCarriesReceiptAndHandle() async throws {
        let content = String(repeating: "1→line of body text that compresses away\n", count: 60)
        let stdin = try JSONSerialization.data(withJSONObject: grokReadFileEnvelope(content: content))
        let cli = ManagedDistillCLI(
            arguments: ["hook", "post-tool-use-grok"],
            stdin: stdin,
            state: state
        ) { _ in (self.grokResponse(output: "unreceipted compression", handle: "grok4"), 200) }

        let (out, code) = await cli.run()

        XCTAssertEqual(code, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let hookOut = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(hookOut["updatedToolOutput"] as? [String: Any])
        let fileContent = try XCTUnwrap(updated["FileContent"] as? [String: Any])
        let replaced = try XCTUnwrap(fileContent["content"] as? String)
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(replaced))
        XCTAssertTrue(replaced.contains("[[rc:grok4]]"))
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
            originalHandle: "h",
            recoveryIdempotencyKey: "chunk-delivery-key",
            routeStage: .encoderBERT
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
        let savingsRequests = decodedRequests.filter { $0.recordSavings == true }
        let confirmRequests = decodedRequests.filter { $0.recordSavings != true }
        XCTAssertGreaterThan(savingsRequests.count, 1, "over-cap input must be split into multiple bounded savings requests")
        XCTAssertTrue(savingsRequests.allSatisfy { $0.input.utf8.count <= ManagedDistillCLI.stdinCapBytes })
        XCTAssertTrue(savingsRequests.allSatisfy { $0.precomputedOutput == nil })
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("chunk summary"))
        XCTAssertTrue(text.contains("[[rc:h]]"), "each lossy chunk must remain retrievable")
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(text), "the completed chunk set must carry one trailing applied receipt")
        XCTAssertTrue(text.hasSuffix("\n"), "chunked CLI output must retain its terminal LF")
        XCTAssertLessThan(out.count, oneMB.count, "all chunk handles plus the final receipt must be a net UTF-8 shrink")
        XCTAssertNotEqual(out, oneMB, "successful chunked compression should not fall back to raw output")
        XCTAssertEqual(confirmRequests.count, 1, "one recovery-confirm POST after all chunks")
        let confirm = try XCTUnwrap(confirmRequests.first)
        XCTAssertEqual(confirm.input, String(decoding: oneMB, as: UTF8.self))
        XCTAssertEqual(confirm.precomputedOutput, text)
        XCTAssertEqual(confirm.precomputedRouteStage, .encoderBERT)
        XCTAssertEqual(confirm.precomputedRecoveryConfirmations?.count, savingsRequests.count)
        XCTAssertTrue(confirm.precomputedRecoveryConfirmations?.allSatisfy {
            $0.capability == "h" && $0.idempotencyKey == "chunk-delivery-key"
        } == true)
        XCTAssertNil(DistillSavingsCalculator.record(
            for: confirm,
            response: try XCTUnwrap(confirm.responseUsingPrecomputedOutput())
        ), "recovery confirm must not mint a second savings row")
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
