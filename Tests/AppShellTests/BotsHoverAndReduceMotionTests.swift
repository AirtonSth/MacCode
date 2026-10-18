import XCTest

// MARK: - Bots window: pointer answer and Reduce Motion
//
// WHY: the Bots roster had no hover state, and the desk thread rail, the
// inspector, the team sections and the group inspector slid 200 to 300 points
// with Reduce Motion on. These pins keep the hover on both roster row kinds
// and keep every pane animation behind the setting.

final class BotsHoverAndReduceMotionTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func slice(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker), "\(startMarker) must exist")
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex),
            "\(endMarker) must follow \(startMarker)"
        )
        return String(source[start.lowerBound..<end.upperBound])
    }

    func test_rosterRowsAnswerThePointerUnlessSelected_becauseASelectedRowKeepsTheBotColour() throws {
        // WHY: Bot rows and group rows sit in one list; one answering the
        // pointer without the other reads as broken. A selected row already
        // paints the Bot's own colour, so the hover layer is off there.
        let groups = try source("Sources/AppShell/BotsTeamsGroups.swift")
        let groupRow = try slice(
            groups,
            from: "private func groupRow(_ group: BotGroupConversation) -> some View {",
            to: ".buttonStyle(.plain)"
        )
        XCTAssertTrue(groupRow.contains(".dsHoverFill(enabled: !selected)"))
    }

    func test_paneAndTeamAnimationsAreOffUnderReduceMotion_becauseAPaneSlideIsRealMovement() throws {
        // WHY: a rail or inspector sliding in is the movement Reduce Motion
        // asks to remove. Under the setting the pane switches in one frame.
        let expected = [
            // desk rail toggle, inspector toggle, rail onHide, two value animations
            "Sources/AppShell/BotsWindow.swift": 5,
            // team collapse, group inspector toggle
            "Sources/AppShell/BotsTeamsGroups.swift": 2,
        ]
        for (path, gatedCount) in expected {
            let text = try source(path)
            XCTAssertFalse(
                text.contains("withAnimation(DS.Motion.standard)"),
                "\(path): pane animations must be gated by Reduce Motion"
            )
            XCTAssertFalse(
                text.contains(".animation(DS.Motion.standard, value:"),
                "\(path): pane animations must be gated by Reduce Motion"
            )
            XCTAssertEqual(
                text.components(separatedBy: "reduceMotion ? nil : DS.Motion.standard").count - 1,
                gatedCount,
                "\(path): every pane animation site reads the setting"
            )
            XCTAssertTrue(text.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        }
    }
}
