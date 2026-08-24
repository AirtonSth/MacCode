import XCTest
import CoreModel
@testable import Surfaces

@MainActor
final class AgentChatRowContextPerformanceTests: XCTestCase {
    func test_paintContextPreservesPeerHeadersAndDuplicateFinalDecisions() {
        let first = turn("first", final: "same answer")
        let duplicate = turn("duplicate", final: "A same answer, expanded")
        let unrelated = turn("unrelated", final: "different")
        let entries: [AgentAppView.TranscriptEntry] = [
            .turn(first),
            .turn(duplicate),
            .turn(unrelated),
            .message(peerMessage(ceo, text: "one", seconds: 4)),
            .message(peerMessage(ceo, text: "two", seconds: 5)),
            .message(peerMessage(ceo, text: "three", seconds: 6)),
            .message(peerMessage(cfo, text: "other", seconds: 7))
        ]
        let rows = entries.map(AgentAppView.ChatFlowRow.entry)
        let context = AgentAppView.makeChatRowPaintContext(
            rows: rows,
            visibleEntries: entries,
            bots: [ceo, cfo]
        )

        var expectedHide: [String: Bool] = [:]
        var priorTurns: [AssistantTurnSnapshot] = []
        for entry in entries {
            guard case .turn(let turn) = entry else { continue }
            expectedHide[turn.turnId] = AgentChatLiveTurnChrome.shouldHideAssistantOutput(
                turn,
                previousTurns: priorTurns
            )
            priorTurns.append(turn)
        }
        let actualHide = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Bool)? in
            guard case .entry(.turn(let turn)) = row else { return nil }
            return (turn.turnId, context.hidesAssistantOutput(for: row))
        })
        XCTAssertEqual(actualHide, expectedHide, "the compact forward pass must preserve duplicate-final chrome")
        XCTAssertEqual(actualHide["duplicate"], true)
        XCTAssertEqual(actualHide["unrelated"], false)

        let headers = context.peerGroupHeadersByRowID
        XCTAssertEqual(headers.count, 1, "only the three-message contiguous peer run gets a banner")
        let peerHeader = headers[rows[3].id]
        XCTAssertEqual(peerHeader?.peerHandle, "ceo")
        XCTAssertEqual(peerHeader?.count, 3)
        XCTAssertNil(headers[rows[4].id], "a contiguous peer run paints one banner at its first row")
    }

    func test_paintContextBenchmarkHasBoundedMetadataAndMatchesLegacy() {
        let turnCount = 320
        let entries: [AgentAppView.TranscriptEntry] = (0..<turnCount).flatMap { index in
            let turn = self.turn("turn-\(index)", final: "answer \(index)")
            return [
                AgentAppView.TranscriptEntry.turn(turn),
                AgentAppView.TranscriptEntry.message(peerMessage(ceo, text: "peer-\(index)-one", seconds: Double(index * 3 + 1))),
                AgentAppView.TranscriptEntry.message(peerMessage(ceo, text: "peer-\(index)-two", seconds: Double(index * 3 + 2)))
            ]
        }
        let rows = entries.map(AgentAppView.ChatFlowRow.entry)

        var legacyWarmups: [Double] = []
        var greenWarmups: [Double] = []
        for _ in 0..<2 {
            legacyWarmups.append(measure { _ = legacyPaintInput(rows: rows, entries: entries) })
            greenWarmups.append(measure {
                _ = AgentAppView.makeChatRowPaintContext(rows: rows, visibleEntries: entries, bots: [ceo])
            })
        }
        var legacySamples: [Double] = []
        var greenSamples: [Double] = []
        for _ in 0..<5 {
            legacySamples.append(measure { _ = legacyPaintInput(rows: rows, entries: entries) })
            greenSamples.append(measure {
                _ = AgentAppView.makeChatRowPaintContext(rows: rows, visibleEntries: entries, bots: [ceo])
            })
        }

        let legacy = legacyPaintInput(rows: rows, entries: entries)
        let context = AgentAppView.makeChatRowPaintContext(rows: rows, visibleEntries: entries, bots: [ceo])
        let contextHeaders = context.peerGroupHeadersByRowID.mapValues {
            HeaderValue(handle: $0.peerHandle, count: $0.count)
        }
        XCTAssertEqual(contextHeaders, legacy.headers, "header mapping must remain byte-for-byte equivalent")
        XCTAssertEqual(context.hideAssistantOutputByTurnId, legacy.hidden, "duplicate-final decisions must remain equivalent")
        XCTAssertEqual(context.hideAssistantOutputByTurnId.count, turnCount,
                       "one final decision per turn keeps metadata linear, without prefix arrays")

        let greenMedian = median(greenSamples)
        let greenP95 = p95(greenSamples)
        let legacyMedian = median(legacySamples)
        let legacyP95 = p95(legacySamples)
        let legacyWarmupText = format(legacyWarmups)
        let legacySampleText = format(legacySamples)
        let greenWarmupText = format(greenWarmups)
        let greenSampleText = format(greenSamples)
        let legacyMedianText = format(legacyMedian)
        let legacyP95Text = format(legacyP95)
        let greenMedianText = format(greenMedian)
        let greenP95Text = format(greenP95)
        print(
            "CHAT_ROW_CONTEXT_BENCH legacy_warmups=\(legacyWarmupText) "
                + "legacy_samples=\(legacySampleText) legacy_median_ms=\(legacyMedianText) "
                + "legacy_p95_ms=\(legacyP95Text) green_warmups=\(greenWarmupText) "
                + "green_samples=\(greenSampleText) green_median_ms=\(greenMedianText) "
                + "green_p95_ms=\(greenP95Text)"
        )
        let allowedMedian = legacyMedian + max(25, legacyMedian * 0.05)
        let allowedP95 = legacyP95 + max(25, legacyP95 * 0.05)
        XCTAssertLessThanOrEqual(greenMedian, allowedMedian, "row-context median regressed beyond the 25ms/5% budget")
        XCTAssertLessThanOrEqual(greenP95, allowedP95, "row-context p95 regressed beyond the 25ms/5% budget")
        XCTAssertLessThanOrEqual(
            greenMedian,
            legacyMedian * 0.75,
            "shared row derivation must materially beat the legacy per-row rescan"
        )
        XCTAssertLessThanOrEqual(
            greenP95,
            legacyP95 * 0.75,
            "shared row derivation p95 must materially beat the legacy per-row rescan"
        )
    }

    private struct PeerIdentity {
        let name: String
        let handle: String
        let symbol: String?
    }

    private struct HeaderValue: Equatable {
        let handle: String
        let count: Int
    }

    private let ceo = BotDefinition(handle: "ceo", name: "Ceo", title: "CEO", description: "", avatarSymbol: "star.fill")
    private let cfo = BotDefinition(handle: "cfo", name: "Cfo", title: "CFO", description: "", avatarSymbol: "briefcase.fill")
    private let threadID = AgentThreadID()

    private func turn(_ id: String, final: String) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(turnId: id, finalAssistantMessage: final, finished: true)
    }

    private func peerMessage(_ bot: BotDefinition, text: String, seconds: TimeInterval) -> AgentMessage {
        AgentMessage(
            threadId: threadID,
            role: .assistant,
            content: BotPeerTranscript.encode(peer: bot, text: text),
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func peerIdentity(_ row: AgentAppView.ChatFlowRow) -> PeerIdentity? {
        guard case .entry(.message(let message)) = row,
              let peer = BotPeerTranscript.parse(message.content) else { return nil }
        return PeerIdentity(name: peer.name, handle: peer.handle, symbol: peer.avatarSymbol)
    }

    private func legacyPaintInput(
        rows: [AgentAppView.ChatFlowRow],
        entries: [AgentAppView.TranscriptEntry]
    ) -> (headers: [String: HeaderValue], hidden: [String: Bool]) {
        var headers: [String: HeaderValue] = [:]
        for index in rows.indices {
            guard let peer = peerIdentity(rows[index]) else { continue }
            if index > 0,
               let previous = peerIdentity(rows[index - 1]),
               previous.handle.caseInsensitiveCompare(peer.handle) == .orderedSame {
                continue
            }
            var count = 0
            for later in rows[index...] {
                guard let next = peerIdentity(later),
                      next.handle.caseInsensitiveCompare(peer.handle) == .orderedSame else { break }
                count += 1
            }
            if count >= 2 {
                headers[rows[index].id] = HeaderValue(handle: peer.handle, count: count)
            }
        }

        var hidden: [String: Bool] = [:]
        for row in rows {
            guard case .entry(.turn(let turn)) = row else { continue }
            var priorTurns: [AssistantTurnSnapshot] = []
            for entry in entries {
                guard case .turn(let prior) = entry else { continue }
                if prior.turnId == turn.turnId { break }
                priorTurns.append(prior)
            }
            hidden[turn.turnId] = AgentChatLiveTurnChrome.shouldHideAssistantOutput(
                turn,
                previousTurns: priorTurns
            )
        }
        return (headers, hidden)
    }

    private func measure(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func p95(_ values: [Double]) -> Double {
        values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))]
    }

    private func format(_ values: [Double]) -> String {
        "[" + values.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
