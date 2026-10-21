import XCTest
import CoreModel
import RemoteCodeTreaty
@testable import AppShell
@testable import Surfaces

/// The Titio "Now" strip mirrors Activity's running and needs-you sections:
/// the host must show what needs the user first and never more than 5 rows.
final class BotsWindowNowStripTests: XCTestCase {
    private func item(_ id: String, state: AgentActivityState, title: String = "t", workspace: String? = "WS", origin: String? = nil) -> AgentActivityItem {
        AgentActivityItem(
            id: id, kind: .agent, state: state, title: title, workspaceName: workspace,
            occurredAt: Date(timeIntervalSince1970: 1_792_094_460), startedAt: nil,
            originLabel: origin
        )
    }

    private func page(_ items: [AgentActivityItem], running: Int, needsYou: Int) -> AgentActivityPage {
        AgentActivityPage(
            items: items,
            counts: AgentActivityCounts(running: running, queued: 0, needsYou: needsYou, finished: 0, newResults: 0),
            generatedAt: Date(timeIntervalSince1970: 1_792_094_460)
        )
    }

    func test_needsYouComesFirstThenRunning() {
        // WHY: a decision the user owes must not sit below a run that needs nothing.
        let snapshot = BotsViewModel.nowStripSnapshot(
            running: page([item("r1", state: .running)], running: 1, needsYou: 0),
            needsYou: page([item("n1", state: .needsYou)], running: 0, needsYou: 1)
        )

        XCTAssertEqual(snapshot.items.map(\.id), ["n1", "r1"])
        XCTAssertEqual(snapshot.items.map(\.state), [.needsYou, .running])
    }

    func test_capsRowsAtFiveKeepingNeedsYouFirst() {
        // WHY: the strip is a glance; a flood of runs must not push out the needs-you rows.
        let running = (0..<6).map { item("r\($0)", state: .running) }
        let needs = [item("n0", state: .needsYou), item("n1", state: .needsYou)]
        let snapshot = BotsViewModel.nowStripSnapshot(
            running: page(running, running: 6, needsYou: 0),
            needsYou: page(needs, running: 0, needsYou: 2)
        )

        XCTAssertEqual(snapshot.items.count, 5)
        XCTAssertEqual(snapshot.items.prefix(2).map(\.id), ["n0", "n1"])
    }

    func test_countsComeFromPageCountsNotRowCount() {
        // WHY: the badge must show the real totals even when only the first rows are loaded.
        let snapshot = BotsViewModel.nowStripSnapshot(
            running: page([item("r1", state: .running)], running: 9, needsYou: 0),
            needsYou: page([], running: 0, needsYou: 4)
        )

        XCTAssertEqual(snapshot.running, 9)
        XCTAssertEqual(snapshot.needsYou, 4)
    }

    func test_sameIdInBothPagesYieldsOneNeedsYouRowWithoutTrapping() {
        // WHY: a run can be in both sections at once; a duplicate id must not trap the
        // host, and the row must show as needs-you (the decision outranks the run).
        let shared = item("run:1", state: .running)
        let needs = item("run:1", state: .needsYou, title: "Needs you")
        let snapshot = BotsViewModel.nowStripSnapshot(
            running: page([shared], running: 1, needsYou: 0),
            needsYou: page([needs], running: 0, needsYou: 1)
        )

        XCTAssertEqual(snapshot.items.map(\.id), ["run:1"])
        XCTAssertEqual(snapshot.items.first?.state, .needsYou)
        XCTAssertEqual(snapshot.items.first?.title, "Needs you")
    }

    func test_subtitleJoinsWorkspaceAndOriginLabel() {
        // WHY: the strip row must say where a run lives, and omit empty parts.
        let snapshot = BotsViewModel.nowStripSnapshot(
            running: page([item("r1", state: .running, workspace: "Acme", origin: "Ops")], running: 1, needsYou: 0),
            needsYou: page([item("n1", state: .needsYou, workspace: nil, origin: nil)], running: 0, needsYou: 1)
        )

        XCTAssertNil(snapshot.items.first { $0.id == "n1" }?.subtitle)
        XCTAssertEqual(snapshot.items.first { $0.id == "r1" }?.subtitle, "Acme · Ops")
    }
}
