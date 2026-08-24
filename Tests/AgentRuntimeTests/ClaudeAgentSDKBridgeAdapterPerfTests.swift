import XCTest
import CoreModel
@testable import AgentRuntime

// Tests verify performance fixes in ClaudeAgentSDKBridgeAdapter:
//   (a) recoveredEventsPruneKeys: prune-eligibility logic is correct so abandoned
//       rolled-back threads do not accumulate in memory indefinitely.
//   (b) sdkInstallTimeoutSeconds / sdkInstallTimeoutNanoseconds: pure helpers are
//       consistent so the async Task.sleep matches the sync semaphore deadline.
// Pure helpers cover the algorithms; one fake Node bridge pins the public
// readThread bound through the real adapter ingest path.

final class ClaudeAgentSDKBridgeAdapterPerfTests: ProviderProcessTestCase {

    // MARK: - recoveredEventsPruneKeys

    // WHY: A thread that was rolled back and never re-connected has no open session
    // and no pending re-use cursor. It must be eligible for pruning so recoveredEvents
    // does not grow without bound across repeated rollbacks of distinct threads.
    func test_pruneKeys_returnsAbandonedRolledBackThread() {
        let abandoned = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [abandoned],
            openIds: [],
            pendingIds: []
        )
        XCTAssertEqual(keys, [abandoned],
            "A rolled-back thread with no open session and no pending cursor must be prunable")
    }

    // WHY: A thread that was rolled back AND has a pending re-use cursor (rollbackProviderThreadIds)
    // must NOT be pruned — it is about to be re-connected and its events are still needed.
    func test_pruneKeys_sparesPendingResumeThread() {
        let pending = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [pending],
            openIds: [],
            pendingIds: [pending]
        )
        XCTAssertTrue(keys.isEmpty,
            "A rolled-back thread with a pending re-use cursor must not be pruned")
    }

    // WHY: A thread with an active session also has its events in recoveredEvents
    // (snapshot written at rollback before re-start). Must not be pruned.
    func test_pruneKeys_sparesOpenSession() {
        let open = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [open],
            openIds: [open],
            pendingIds: []
        )
        XCTAssertTrue(keys.isEmpty,
            "A thread with an active session must not be pruned from recoveredEvents")
    }

    // WHY: mixed set — only the abandoned thread should be selected; open and pending must survive.
    func test_pruneKeys_selectsOnlyAbandonedFromMixedSet() {
        let abandoned1 = AgentThreadID()
        let abandoned2 = AgentThreadID()
        let open = AgentThreadID()
        let pending = AgentThreadID()

        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [abandoned1, abandoned2, open, pending],
            openIds: [open],
            pendingIds: [pending]
        )
        XCTAssertEqual(keys, [abandoned1, abandoned2],
            "Only threads that are neither open nor pending should be selected for pruning")
    }

    // WHY: empty input must never crash or return garbage.
    func test_pruneKeys_emptyInputReturnsEmpty() {
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [],
            openIds: [],
            pendingIds: []
        )
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - sdkInstallTimeout consistency

    // WHY: the Task.detached timeout guard and the continuation-based termination path
    // are both rooted in sdkInstallTimeoutSeconds(). If sdkInstallTimeoutNanoseconds()
    // diverges from that value the detached guard fires at a different wall-clock time,
    // leaving the continuation waiting beyond the intended limit.
    func test_installTimeoutNanosecondsIsConsistentWithSeconds() {
        let seconds = ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutSeconds()
        let nanoseconds = ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutNanoseconds()
        let expectedNs = UInt64(seconds * 1_000_000_000)
        XCTAssertEqual(nanoseconds, expectedNs,
            "Nanosecond timeout used by Task.detached must encode exactly the same wall-clock duration as sdkInstallTimeoutSeconds()")
    }

    // WHY: the timeout must be positive — a zero or negative value would bypass the
    // guard entirely and let npm installs run forever, re-introducing the pinned-thread bug.
    func test_installTimeoutSecondsIsPositive() {
        XCTAssertGreaterThan(
            ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutSeconds(), 0,
            "Install timeout must be > 0 so the async Task.sleep guard is meaningful")
    }

    // MARK: - readable-event retention hysteresis

    func test_readableEventPrune_waitsForHighWaterAndKeepsNewestOrder() {
        let events = (0..<9).map {
            AssistantEvent.turnStarted(turnId: "turn-\($0)")
        }

        XCTAssertNil(
            ClaudeAgentSDKBridgeAdapter.prunedReadableEvents(
                Array(events.prefix(8)), cap: 5, slack: 3
            ),
            "the internal slack must avoid a full suffix copy at and below the high-water mark"
        )
        let pruned = ClaudeAgentSDKBridgeAdapter.prunedReadableEvents(
            events, cap: 5, slack: 3
        )
        XCTAssertEqual(pruned?.compactMap(Self.turnStartedID), ["turn-4", "turn-5", "turn-6", "turn-7", "turn-8"],
                       "crossing high-water must retain exactly the newest public window in FIFO order")
    }

    /// Same-process A/B of the exact pre-checkpoint retention loop and the
    /// production hysteresis helper. Primary metric: wall time to retain 10,000
    /// representative deltas at the production 5,000-event cap (warmup=2, n=5).
    func test_microbench_readableEventHysteresis_amortizesSuffixCopies() {
        let cap = 5_000
        let inputs: [AssistantEvent] = (0..<10_000).map {
            .itemDelta(itemId: "item-\($0)", bodyAppend: "delta-\($0)", outputAppend: nil, summary: nil)
        }
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func timeLegacy() -> Double {
            var retained: [AssistantEvent] = []
            retained.reserveCapacity(cap + 1)
            let start = DispatchTime.now().uptimeNanoseconds
            for event in inputs {
                retained.append(event)
                if retained.count > cap {
                    retained = Array(retained.suffix(cap))
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(retained.count, cap)
            XCTAssertEqual(Self.itemID(retained.first), "item-5000")
            XCTAssertEqual(Self.itemID(retained.last), "item-9999")
            return Double(end - start) / 1_000_000.0
        }

        func timeHysteresis() -> Double {
            var retained: [AssistantEvent] = []
            retained.reserveCapacity(cap + ClaudeAgentSDKBridgeAdapter.readableEventPruneSlack + 1)
            let start = DispatchTime.now().uptimeNanoseconds
            for event in inputs {
                retained.append(event)
                if let pruned = ClaudeAgentSDKBridgeAdapter.prunedReadableEvents(
                    retained,
                    cap: cap,
                    slack: ClaudeAgentSDKBridgeAdapter.readableEventPruneSlack
                ) {
                    retained = pruned
                }
            }
            let readable = Array(retained.suffix(cap))
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(readable.count, cap)
            XCTAssertEqual(Self.itemID(readable.first), "item-5000")
            XCTAssertEqual(Self.itemID(readable.last), "item-9999")
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            _ = timeLegacy()
            _ = timeHysteresis()
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacy())
            after.append(timeHysteresis())
        }
        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        NSLog(
            "[perf-proof] claudeSDKRetention per_event_suffix_ms=%@ hysteresis_ms=%@ improvement_pct=%.2f before=%@ after=%@ events=%d cap=%d slack=%d",
            String(beforeMedian), String(afterMedian), improvement,
            String(describing: before), String(describing: after), inputs.count, cap,
            ClaudeAgentSDKBridgeAdapter.readableEventPruneSlack
        )
        XCTAssertGreaterThan(
            improvement,
            5,
            "retention hysteresis must beat a 5,000-event suffix copy per delta by at least 5%"
        )
    }

    func test_readThread_keepsExactPublicCapAfterInternalHysteresis() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-sdk-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = directory.appendingPathComponent("retention-bridge.mjs")
        try """
        import readline from 'node:readline';
        import { once } from 'node:events';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        async function write(obj) {
          if (!process.stdout.write(JSON.stringify(obj) + '\\n')) {
            await once(process.stdout, 'drain');
          }
        }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          if (command.type === 'rc_configure') {
            await write({ type: 'system', subtype: 'init', session_id: 'retention-session' });
          } else if (command.type === 'rc_turn') {
            for (let index = 0; index < 1200; index += 1) {
              await write({
                type: 'assistant',
                message: { id: 'message-' + index, content: [{ type: 'text', text: 'RETENTION_' + index }] },
                session_id: 'retention-session'
              });
            }
            await write({ type: 'result', subtype: 'success', is_error: false, result: 'RETENTION_DONE', session_id: 'retention-session' });
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(
            bridgeScriptPath: bridge.path,
            maxReadableEvents: 5
        )
        let threadID = AgentThreadID()
        let finished = expectation(description: "SDK retention turn finishes")
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadID,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: directory.path,
            prompt: "stream a long turn",
            providerBinary: "/usr/bin/true"
        )) { event in
            if case .finished = event { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 10)

        let readable = try await adapter.readThread(threadId: threadID)
        XCTAssertEqual(readable.count, 5,
                       "internal hysteresis must never expand the public readThread contract")
        XCTAssertTrue(readable.contains { event in
            if case .turnCompleted(_, let message) = event { return message == "RETENTION_DONE" }
            return false
        }, "the newest terminal event must survive the capped readable suffix")
        XCTAssertFalse(readable.contains { event in
            if case .itemDelta(_, let body, _, _) = event { return body == "RETENTION_0" }
            return false
        }, "the oldest assistant output must not leak through the public cap")
        try adapter.stopSession(threadId: threadID)
    }

    private static func turnStartedID(_ event: AssistantEvent) -> String? {
        guard case .turnStarted(let id) = event else { return nil }
        return id
    }

    private static func itemID(_ event: AssistantEvent?) -> String? {
        guard let event, case .itemDelta(let id, _, _, _) = event else { return nil }
        return id
    }

    // MARK: - decode-once SDK line ingest

    // WHY: handleLine used to JSONSerialization the same token line 3–4 times
    // (sdk_error probe, user_input_request, fromJSONLine, parseLine). Each
    // Claude SDK stdout line must decode once; extra parses allocate at token
    // rate without changing events.
    func test_interpretSDKLine_decodesJSONOnce() {
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let line = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"text_delta","text":"Hi"}}"#
        let parser = ClaudeParser()
        _ = parser.parseObject([
            "type": "system",
            "subtype": "init",
            "session_id": "sid",
        ], now: 1)
        _ = parser.parseObject([
            "type": "message_start",
            "message": ["id": "m1"],
        ], now: 1)
        _ = parser.parseObject([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "id": "item0"],
        ], now: 1)
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let interpretation = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(line, parser: parser)
        XCTAssertEqual(
            ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1,
            "sdk_error + user-input + runtime + parser must share one JSONSerialization"
        )
        XCTAssertFalse(interpretation.isSDKError)
        XCTAssertNil(interpretation.userInputRequest)
        XCTAssertNil(
            interpretation.runtimeEvent,
            "token-rate deltas must not mint providerRuntime; itemDelta is the product event"
        )
        XCTAssertTrue(
            interpretation.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "decode-once must still surface the text delta: \(interpretation.parsedEvents)"
        )

        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let wrapped = #"{"type":"stream_event","session_id":"sid","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#
        let wrappedInterp = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(wrapped, parser: parser)
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertNil(
            wrappedInterp.runtimeEvent,
            "SDK stream_event wrappers around content_block_delta must not mint providerRuntime"
        )
        XCTAssertTrue(
            wrappedInterp.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "wrapped delta must still surface itemDelta: \(wrappedInterp.parsedEvents)"
        )
    }

    func test_interpretSDKLine_detectsSDKErrorAndUserInputWithoutSecondParse() {
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let errorLine = #"{"type":"sdk_error","message":"spawn claude ENOENT"}"#
        let error = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(errorLine, parser: ClaudeParser())
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertTrue(error.isSDKError)
        XCTAssertEqual(error.runtimeEvent?.method, "sdk_error")

        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let inputLine = #"{"type":"user_input_request","request_id":"q1","requested_schema":{"properties":{"a":{"type":"string"}}}}"#
        let input = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(inputLine, parser: ClaudeParser())
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertEqual(input.userInputRequest?.id, "q1")
        XCTAssertNotNil(input.userInputRequest?.requestedSchema)
        XCTAssertTrue(
            input.parsedEvents.contains { event in
                if case .userInputRequested(let request) = event { return request.id == "q1" }
                return false
            },
            "user_input_request must still become a parser event: \(input.parsedEvents)"
        )
    }
}
