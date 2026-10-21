import CoreModel
import XCTest
@testable import Surfaces

/// Titio notice card status: the label tells the user what happened, so every
/// kind and resolved state must map to its spec label and tone.
final class AgentChatNoticeCardTests: XCTestCase {
    private func block(kind: String, state: String = "open") -> TitioNoticeBlock {
        TitioNoticeBlock(key: "k", kind: kind, source: [:], state: state)
    }

    func test_everyOpenKindMapsToItsSpecLabelAndTone() {
        // WHY: a failed run must read as failed, not as a neutral update.
        let expected: [TitioNoticeKind: (String, AgentNoticeStatus.Tone)] = [
            .runCompleted: ("Done", .success), .gitCompleted: ("Done", .success),
            .scriptCompleted: ("Done", .success), .transferCompleted: ("Done", .success),
            .runFailed: ("Failed", .danger), .scriptFailed: ("Failed", .danger),
            .gitFailed: ("Failed", .danger), .scheduledFailed: ("Failed", .danger),
            .transferFailed: ("Failed", .danger), .providerUpdateFailed: ("Failed", .danger),
            .serverListenerFailed: ("Failed", .danger),
            .runInterrupted: ("Interrupted", .warning), .botBlocked: ("Stuck", .warning),
            .approval: ("Needs approval", .warning), .manualAction: ("Action needed", .warning),
            .botReply: ("Replied", .accent), .userInput: ("Question", .accent),
            .botQuestion: ("Question", .accent),
            .sshDisconnected: ("Update", .neutral), .fileConflict: ("Update", .neutral),
            .notificationsDenied: ("Update", .neutral), .external: ("Update", .neutral),
        ]
        XCTAssertEqual(Set(expected.keys), Set(TitioNoticeKind.allCases), "every kind needs a row")
        for (kind, want) in expected {
            let status = AgentNoticeStatus.of(block(kind: kind.rawValue))
            XCTAssertEqual(status.label, want.0, "kind \(kind.rawValue)")
            XCTAssertEqual(status.tone, want.1, "kind \(kind.rawValue)")
        }
    }

    func test_everyResolvedStateReplacesTheKindStatus() {
        // WHY: a resolved notice must not still claim it needs approval.
        let expected: [(String, String)] = [
            ("answered", "Answered"), ("approved", "Approved"), ("declined", "Declined"),
            ("done", "Done"), ("elsewhere", "Handled elsewhere"), ("expired", "Expired"),
            ("acknowledged", "Seen"), ("failed", "Didn't go through"), ("unknown_effect", "Unconfirmed"),
        ]
        for (state, label) in expected {
            let status = AgentNoticeStatus.of(block(kind: "approval", state: state))
            XCTAssertEqual(status.label, label, "state \(state)")
            XCTAssertEqual(status.tone, .neutral, "state \(state)")
        }
    }

    func test_unknownKindFallsBackToUpdate() {
        // WHY: a newer host kind must still show a card, not crash or hide.
        let status = AgentNoticeStatus.of(block(kind: "futureKind"))
        XCTAssertEqual(status.label, "Update")
        XCTAssertEqual(status.symbol, "info.circle.fill")
    }

    func test_unknownStateFallsBackToNeutralUpdate() {
        // WHY: an unknown resolved state is not a success; it stays neutral.
        let status = AgentNoticeStatus.of(block(kind: "approval", state: "future_state"))
        XCTAssertEqual(status.label, "Update")
        XCTAssertEqual(status.tone, .neutral)
    }
}
