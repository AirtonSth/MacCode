import XCTest
@testable import AppShell
import AgentRuntime

final class DistillAccountsInlineDisclosureTests: XCTestCase {
    func test_defaultExpandedFollowsAutoSetup_becauseTheEmptyStateShowsWhatTheUserStillNeeds() {
        // WHY: the editor is open until Auto routing has options to route to,
        // and stays collapsed afterwards so the empty state stops leading with
        // accounts. Before the state loads nothing is known, so it stays
        // collapsed instead of jumping open once the load lands.
        let disabled = DistillAutoRouting(enabled: false, options: [.init(id: "o", accountID: "a", mainModel: "m")])
        let enabledEmpty = DistillAutoRouting(enabled: true, options: [])
        let configured = DistillAutoRouting(enabled: true, options: [.init(id: "o", accountID: "a", mainModel: "m")])

        XCTAssertFalse(DistillAccountsInlineDisclosure.defaultExpanded(loaded: false, routing: .init()), "not loaded must not jump open")
        XCTAssertTrue(DistillAccountsInlineDisclosure.defaultExpanded(loaded: true, routing: .init()), "routing off: set it up")
        XCTAssertTrue(DistillAccountsInlineDisclosure.defaultExpanded(loaded: true, routing: disabled), "routing disabled with options: still not set up")
        XCTAssertTrue(DistillAccountsInlineDisclosure.defaultExpanded(loaded: true, routing: enabledEmpty), "enabled without options routes nowhere")
        XCTAssertFalse(DistillAccountsInlineDisclosure.defaultExpanded(loaded: true, routing: configured), "configured Auto stays collapsed")
    }
}
