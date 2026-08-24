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

    func test_paintContextParityCoversSegmentsMentionsMixedCaseAndHeaderIdentity() {
        let priorTurn = turn("prior", final: "segmented answer")
        let segmentedTurn = AssistantTurnSnapshot(
            turnId: "segmented",
            items: [AssistantItem(id: "segment-item", turnId: "segmented", type: .tool, startedAtMs: 1)],
            finalAssistantMessage: "segmented answer",
            finished: true
        )
        let segment = AgentChatTurnSegmentation.TurnSegment(
            snapshot: segmentedTurn,
            firstItemId: "segment-item",
            isFirst: true,
            isLast: true
        )
        let displayBot = BotDefinition(
            handle: "ceo",
            name: "Chief Display",
            title: "Chief",
            description: "",
            avatarSymbol: "crown.fill"
        )
        let mention = userMessage("@CEO please review this", seconds: 2)
        let firstPeer = peerMessage(
            BotDefinition(handle: "CEO", name: "Chief Display", title: "Chief", description: "", avatarSymbol: "crown.fill"),
            text: "first",
            seconds: 3
        )
        let secondPeer = peerMessage(
            BotDefinition(handle: "cEo", name: "Chief Display", title: "Chief", description: "", avatarSymbol: "crown.fill"),
            text: "second",
            seconds: 4
        )
        let entries: [AgentAppView.TranscriptEntry] = [
            .turn(priorTurn),
            .turn(segmentedTurn),
            .message(mention),
            .message(firstPeer),
            .message(secondPeer)
        ]
        let rows: [AgentAppView.ChatFlowRow] = [
            .entry(.turn(priorTurn)),
            .segment(segment),
            .entry(.message(mention)),
            .entry(.message(firstPeer)),
            .entry(.message(secondPeer))
        ]
        let context = AgentAppView.makeChatRowPaintContext(
            rows: rows,
            visibleEntries: entries,
            bots: [displayBot]
        )
        let legacy = legacyPaintInput(rows: rows, entries: entries, bots: [displayBot])
        let actualHeaders = context.peerGroupHeadersByRowID.mapValues {
            HeaderValue(name: $0.peerName, handle: $0.peerHandle, symbol: $0.peerSymbol, count: $0.count)
        }

        XCTAssertEqual(actualHeaders, legacy.headers, "segments and mention-derived peers must preserve legacy grouping")
        XCTAssertEqual(
            context.hideAssistantOutputByTurnId,
            legacy.hidden,
            "a segmented row must share the same duplicate-final decision as its turn"
        )
        XCTAssertNil(context.peerGroupHeader(for: rows[1]), "a segmented ChatFlowRow is not itself a peer identity")
        XCTAssertTrue(context.hidesAssistantOutput(for: rows[1]), "a duplicate final stays hidden on a segmented turn row")
        XCTAssertFalse(context.hidesAssistantOutput(for: rows[2]), "peer message rows never inherit turn duplicate chrome")
        XCTAssertEqual(context.peerGroupHeadersByRowID[rows[2].id]?.peerName, "Chief Display")
        XCTAssertEqual(context.peerGroupHeadersByRowID[rows[2].id]?.peerSymbol, "crown.fill")
        XCTAssertEqual(context.peerGroupHeadersByRowID[rows[2].id]?.peerHandle, "ceo")
        XCTAssertEqual(context.peerGroupHeadersByRowID[rows[2].id]?.count, 3, "mixed-case handles remain one contiguous peer group")
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
            HeaderValue(name: $0.peerName, handle: $0.peerHandle, symbol: $0.peerSymbol, count: $0.count)
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
        let name: String
        let handle: String
        let symbol: String?
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

    private func userMessage(_ text: String, seconds: TimeInterval) -> AgentMessage {
        AgentMessage(
            threadId: threadID,
            role: .user,
            content: text,
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func peerIdentity(
        _ row: AgentAppView.ChatFlowRow,
        bots: [BotDefinition]
    ) -> PeerIdentity? {
        guard case .entry(.message(let message)) = row else { return nil }
        if message.role == .user {
            guard let bot = AgentAppView.messagedPeer(in: message.content, bots: bots) else { return nil }
            return PeerIdentity(name: bot.name, handle: bot.handle, symbol: bot.avatarSymbol)
        }
        guard let peer = BotPeerTranscript.parse(message.content) else { return nil }
        return PeerIdentity(
            name: peer.name,
            handle: peer.handle,
            symbol: AgentAppView.resolvedPeerAvatarSymbol(
                handle: peer.handle,
                encoded: peer.avatarSymbol,
                bots: bots
            )
        )
    }

    private func legacyPaintInput(
        rows: [AgentAppView.ChatFlowRow],
        entries: [AgentAppView.TranscriptEntry],
        bots: [BotDefinition] = []
    ) -> (headers: [String: HeaderValue], hidden: [String: Bool]) {
        var headers: [String: HeaderValue] = [:]
        for index in rows.indices {
            guard let peer = peerIdentity(rows[index], bots: bots) else { continue }
            if index > 0,
               let previous = peerIdentity(rows[index - 1], bots: bots),
               previous.handle.caseInsensitiveCompare(peer.handle) == .orderedSame {
                continue
            }
            var count = 0
            for later in rows[index...] {
                guard let next = peerIdentity(later, bots: bots),
                      next.handle.caseInsensitiveCompare(peer.handle) == .orderedSame else { break }
                count += 1
            }
            if count >= 2 {
                headers[rows[index].id] = HeaderValue(
                    name: peer.name,
                    handle: peer.handle,
                    symbol: peer.symbol,
                    count: count
                )
            }
        }

        var hidden: [String: Bool] = [:]
        for row in rows {
            let turn: AssistantTurnSnapshot
            switch row {
            case .entry(.turn(let entryTurn)):
                turn = entryTurn
            case .segment(let segment):
                turn = segment.snapshot
            case .entry(.message):
                continue
            }
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
