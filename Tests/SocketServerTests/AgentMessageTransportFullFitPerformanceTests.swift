import CoreModel
import Foundation
import Persistence
import XCTest
@testable import SocketServer

final class AgentMessageTransportFullFitPerformanceTests: XCTestCase {
    /// Mirrors the production Dispatcher's default message payload encoder.
    private let wireEncoder = JSONEncoder()
    /// Canonical key ordering is required for byte-for-byte assertions because
    /// JSON object ordering is otherwise intentionally unspecified.
    private let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private let responseID: JSONRPCID = .number(7)

    func test_fullFitFastPath_listAndGetMatchLegacyBytesAndEncodeOnce() throws {
        let listSource = makeListSource()
        let legacyList = fitList(
            listSource,
            maxResponseBytes: 192 * 1_024,
            useFullFitFastPath: false
        )
        let fastList = fitList(
            listSource,
            maxResponseBytes: 192 * 1_024,
            useFullFitFastPath: true
        )

        XCTAssertEqual(fastList.result, legacyList.result)
        XCTAssertEqual(
            try encodedResponse(fastList.result),
            try encodedResponse(legacyList.result),
            "the encode-once list path must preserve the exact JSON-RPC bytes"
        )
        XCTAssertEqual(fastList.responseEncodingCount, 1)
        XCTAssertGreaterThanOrEqual(
            legacyList.responseEncodingCount,
            16,
            "the fixture must exercise the prior logarithmic envelope fitter"
        )
        XCTAssertEqual(
            AgentMessageTransport.v1ListResult(
                from: listSource,
                maxResponseBytes: 192 * 1_024,
                responseID: responseID,
                basePayload: basePayload,
                encodeCursor: encodeCursor
            ),
            fastList.result,
            "the public list path must use the measured encode-once result"
        )

        let getChunk = makeGetChunk()
        let legacyGet = fitGet(
            getChunk,
            maxResponseBytes: 128 * 1_024,
            useFullFitFastPath: false
        )
        let fastGet = fitGet(
            getChunk,
            maxResponseBytes: 128 * 1_024,
            useFullFitFastPath: true
        )

        XCTAssertEqual(fastGet.result, legacyGet.result)
        XCTAssertEqual(
            try encodedResponse(fastGet.result),
            try encodedResponse(legacyGet.result),
            "the encode-once get path must preserve the exact JSON-RPC bytes"
        )
        XCTAssertEqual(fastGet.responseEncodingCount, 1)
        XCTAssertGreaterThanOrEqual(
            legacyGet.responseEncodingCount,
            16,
            "the fixture must exercise the prior logarithmic chunk fitter"
        )
        XCTAssertEqual(
            AgentMessageTransport.v1GetResult(
                chunk: getChunk,
                maxResponseBytes: 128 * 1_024,
                responseID: responseID,
                basePayload: basePayload
            ),
            fastGet.result,
            "the public get path must use the measured encode-once result"
        )
    }

    func test_oversizedListAndGetFallBackToByteEquivalentBinaryFit() throws {
        let listBudget = 32 * 1_024
        let listSource = makeListSource(
            messageCount: 8,
            lineRepetitions: 700
        )
        let legacyList = fitList(
            listSource,
            maxResponseBytes: listBudget,
            useFullFitFastPath: false
        )
        let fastList = fitList(
            listSource,
            maxResponseBytes: listBudget,
            useFullFitFastPath: true
        )
        let fastListBytes = try encodedResponse(fastList.result)

        XCTAssertEqual(fastList.result, legacyList.result)
        XCTAssertEqual(
            fastListBytes,
            try encodedResponse(legacyList.result),
            "oversized list fallback must preserve the exact fitted bytes"
        )
        XCTAssertEqual(
            fastList.responseEncodingCount,
            legacyList.responseEncodingCount,
            "an obviously oversized list must not add a doomed full-fit encode"
        )
        XCTAssertGreaterThan(fastList.responseEncodingCount, 1)
        XCTAssertLessThanOrEqual(fastListBytes.count, listBudget)
        guard case .object(let listEnvelope)? = fastList.result,
              case .array(let messages)? = listEnvelope["messages"] else {
            return XCTFail("oversized list fallback must retain a pageable v1 envelope")
        }
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.contains { message in
            message.objectValue?["body_truncated"] == .bool(true)
        })

        let getBudget = 32 * 1_024
        let getChunk = makeGetChunk(lineRepetitions: 5_000)
        let legacyGet = fitGet(
            getChunk,
            maxResponseBytes: getBudget,
            useFullFitFastPath: false
        )
        let fastGet = fitGet(
            getChunk,
            maxResponseBytes: getBudget,
            useFullFitFastPath: true
        )
        let fastGetBytes = try encodedResponse(fastGet.result)

        XCTAssertEqual(fastGet.result, legacyGet.result)
        XCTAssertEqual(
            fastGetBytes,
            try encodedResponse(legacyGet.result),
            "oversized get fallback must preserve the exact fitted bytes"
        )
        XCTAssertEqual(
            fastGet.responseEncodingCount,
            legacyGet.responseEncodingCount,
            "a capped long-message page must not add a doomed full-fit encode"
        )
        XCTAssertGreaterThan(fastGet.responseEncodingCount, 1)
        XCTAssertLessThanOrEqual(fastGetBytes.count, getBudget)
        guard case .object(let getEnvelope)? = fastGet.result,
              case .object(let message)? = getEnvelope["message"] else {
            return XCTFail("oversized get fallback must retain the v1 chunk envelope")
        }
        XCTAssertEqual(message["body_truncated"], .bool(true))
        XCTAssertNotEqual(getEnvelope["body_next_offset"], .null)
    }

    func test_microbench_v1ListFullFit_encodeOnceBeatsBinarySearch() {
        let source = makeListSource()
        let iterations = 6
        let warmups = 2
        let sampleCount = 5

        func legacy() -> AgentMessageTransport.V1FitMeasurement {
            fitList(
                source,
                maxResponseBytes: 192 * 1_024,
                useFullFitFastPath: false
            )
        }

        func encodeOnce() -> AgentMessageTransport.V1FitMeasurement {
            fitList(
                source,
                maxResponseBytes: 192 * 1_024,
                useFullFitFastPath: true
            )
        }

        for _ in 0..<warmups {
            _ = elapsedMilliseconds(iterations: iterations, operation: legacy)
            _ = elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
        }
        var before: [Double] = []
        var after: [Double] = []
        for sample in 0..<sampleCount {
            if sample.isMultiple(of: 2) {
                before.append(
                    elapsedMilliseconds(iterations: iterations, operation: legacy)
                )
                after.append(
                    elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
                )
            } else {
                after.append(
                    elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
                )
                before.append(
                    elapsedMilliseconds(iterations: iterations, operation: legacy)
                )
            }
        }

        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        let legacyEncodes = legacy().responseEncodingCount
        let fastEncodes = encodeOnce().responseEncodingCount
        print(
            "[perf-proof] messageTransportV1ListFullFit "
                + "legacy_ms=\(beforeMedian) encode_once_ms=\(afterMedian) "
                + "improvement_pct=\(improvement) legacy_encodes=\(legacyEncodes) "
                + "fast_encodes=\(fastEncodes) iterations=\(iterations) "
                + "warmups=\(warmups) samples=\(sampleCount) "
                + "before=\(before) after=\(after)"
        )
        XCTAssertEqual(fastEncodes, 1)
        XCTAssertGreaterThanOrEqual(legacyEncodes, 16)
        XCTAssertGreaterThan(
            improvement,
            5,
            "full-fit list encode-once must beat binary fitting beyond noise"
        )
    }

    func test_microbench_v1GetFullFit_encodeOnceBeatsBinarySearch() {
        let chunk = makeGetChunk()
        let iterations = 12
        let warmups = 2
        let sampleCount = 5

        func legacy() -> AgentMessageTransport.V1FitMeasurement {
            fitGet(
                chunk,
                maxResponseBytes: 128 * 1_024,
                useFullFitFastPath: false
            )
        }

        func encodeOnce() -> AgentMessageTransport.V1FitMeasurement {
            fitGet(
                chunk,
                maxResponseBytes: 128 * 1_024,
                useFullFitFastPath: true
            )
        }

        for _ in 0..<warmups {
            _ = elapsedMilliseconds(iterations: iterations, operation: legacy)
            _ = elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
        }
        var before: [Double] = []
        var after: [Double] = []
        for sample in 0..<sampleCount {
            if sample.isMultiple(of: 2) {
                before.append(
                    elapsedMilliseconds(iterations: iterations, operation: legacy)
                )
                after.append(
                    elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
                )
            } else {
                after.append(
                    elapsedMilliseconds(iterations: iterations, operation: encodeOnce)
                )
                before.append(
                    elapsedMilliseconds(iterations: iterations, operation: legacy)
                )
            }
        }

        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        let legacyEncodes = legacy().responseEncodingCount
        let fastEncodes = encodeOnce().responseEncodingCount
        print(
            "[perf-proof] messageTransportV1GetFullFit "
                + "legacy_ms=\(beforeMedian) encode_once_ms=\(afterMedian) "
                + "improvement_pct=\(improvement) legacy_encodes=\(legacyEncodes) "
                + "fast_encodes=\(fastEncodes) iterations=\(iterations) "
                + "warmups=\(warmups) samples=\(sampleCount) "
                + "before=\(before) after=\(after)"
        )
        XCTAssertEqual(fastEncodes, 1)
        XCTAssertGreaterThanOrEqual(legacyEncodes, 16)
        XCTAssertGreaterThan(
            improvement,
            5,
            "full-fit get encode-once must beat binary fitting beyond noise"
        )
    }

    private func fitList(
        _ source: AgentMessageBodyBudgetResult,
        maxResponseBytes: Int,
        useFullFitFastPath: Bool
    ) -> AgentMessageTransport.V1FitMeasurement {
        AgentMessageTransport.v1ListResultForTesting(
            from: source,
            maxResponseBytes: maxResponseBytes,
            responseID: responseID,
            basePayload: basePayload,
            encodeCursor: encodeCursor,
            useFullFitFastPath: useFullFitFastPath
        )
    }

    private func fitGet(
        _ chunk: AgentMessageBodyChunk,
        maxResponseBytes: Int,
        useFullFitFastPath: Bool
    ) -> AgentMessageTransport.V1FitMeasurement {
        AgentMessageTransport.v1GetResultForTesting(
            chunk: chunk,
            maxResponseBytes: maxResponseBytes,
            responseID: responseID,
            basePayload: basePayload,
            useFullFitFastPath: useFullFitFastPath
        )
    }

    private func makeListSource(
        messageCount: Int = 12,
        lineRepetitions: Int = 120
    ) -> AgentMessageBodyBudgetResult {
        let threadID = AgentThreadID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let line = #"{"phase":"compile","status":"ok","path":"Sources/File.swift"}"#
            + "\n"
        let content = String(repeating: line, count: lineRepetitions)
        let rows = (0..<messageCount).map { index in
            AgentMessage(
                id: AgentMessageID(
                    UUID(
                        uuidString: String(
                            format: "00000000-0000-0000-0002-%012d",
                            index
                        )
                    )!
                ),
                threadId: threadID,
                role: .assistant,
                content: content,
                createdAt: Date(
                    timeIntervalSinceReferenceDate: 800_000_000
                        + Double(index)
                )
            )
        }
        return AgentMessageBodyBudgetResult(
            rows: rows,
            blanked: 0,
            originalByteCounts: Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0.id, $0.content.utf8.count)
                }
            ),
            attachmentCounts: Dictionary(
                uniqueKeysWithValues: rows.map { ($0.id, 0) }
            ),
            prefersNewestBodies: true
        )
    }

    private func makeGetChunk(
        lineRepetitions: Int = 1_400
    ) -> AgentMessageBodyChunk {
        let content = String(
            repeating:
                #"{"token":"RemoteCode","state":"streaming","ok":true}"#
                    + "\n",
            count: lineRepetitions
        )
        let threadID = AgentThreadID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        return AgentMessageBodyChunk(
            id: AgentMessageID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            content: content,
            bodyByteCount: content.utf8.count,
            bodySHA256: AgentMessageTransport.bodySHA256Hex(content),
            bodyRevision: 1,
            bodyOffset: 0,
            metadata: AgentMessageBodyChunkMetadata(
                threadId: threadID,
                role: .assistant,
                createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                attachments: [],
                attachmentCount: 0,
                attachmentsTruncated: false
            )
        )
    }

    private func basePayload(_ message: AgentMessage) -> JSONValue {
        guard let data = try? wireEncoder.encode(message),
              case .object(var object)? = try? decoder.decode(
                JSONValue.self,
                from: data
              ) else {
            return .null
        }
        object["attachments"] = .array([])
        return .object(object)
    }

    private func encodeCursor(_ cursor: AgentMessageCursor) -> JSONValue {
        .object([
            "created_at": .number(cursor.createdAt.timeIntervalSinceReferenceDate),
            "id": .string(cursor.id.value.uuidString),
        ])
    }

    private func encodedResponse(_ result: JSONValue?) throws -> Data {
        try canonicalEncoder.encode(JSONRPCResponse(id: responseID, result: result))
    }

    private func elapsedMilliseconds(
        iterations: Int,
        operation: () -> AgentMessageTransport.V1FitMeasurement
    ) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations {
            let measurement = autoreleasepool(invoking: operation)
            sink &+= measurement.responseEncodingCount
            sink &+= measurement.result == nil ? 0 : 1
        }
        let end = DispatchTime.now().uptimeNanoseconds
        XCTAssertGreaterThan(sink, 0)
        return Double(end - start) / 1_000_000
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
