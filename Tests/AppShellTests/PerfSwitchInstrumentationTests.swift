import XCTest

final class PerfSwitchInstrumentationTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_focusSurfaceBeginsTabSwitchSignpost() throws {
        // WHY: PF-00 (a) starts at AppCommandRouter.focusSurface, not at a
        // debug log in applyFocusChangeInPlace. A later paint-time end is useless
        // if the begin is missing.
        let router = try source("Sources/AppShell/AppCommandRouter.swift")
        let start = try XCTUnwrap(router.range(of: "public func focusSurface(workspace:"))
        let body = router[start.lowerBound...]
        let end = body.range(of: "\n    public func focusPane")?.lowerBound ?? body.endIndex
        let focus = String(body[..<end])
        XCTAssertTrue(focus.contains("PerfSwitchMetrics.beginTabSwitch"))
        XCTAssertTrue(focus.contains("endTabSwitchCommitted"))
    }

    func test_installSelectedContentEndsTabSwitchOnCommittedFrame() throws {
        let pane = try source("Sources/AppShell/PaneTabsView.swift")
        let start = try XCTUnwrap(pane.range(of: "private func installSelectedContent"))
        let body = pane[start.lowerBound...]
        let end = body.range(of: "\n    private func ")?.lowerBound ?? body.endIndex
        let install = String(body[..<end])
        XCTAssertTrue(install.contains("PerfSwitchMetrics.endTabSwitchInstall"))
        XCTAssertTrue(install.contains("CATransaction.setCompletionBlock"))
        XCTAssertTrue(install.contains("endTabSwitchCommitted"))
    }

    func test_agentAppHostingViewDisablesIntrinsicSizing() throws {
        let agent = try source("Sources/Surfaces/AgentAppSurface.swift")
        XCTAssertTrue(
            agent.contains("host.sizingOptions = []"),
            "PF-11 (a): NSHostingView intrinsic-size passes are unused under constraint layout"
        )
    }

    func test_selectThreadRecordsConversationSwitchUntilHydrate() throws {
        let agent = try source("Sources/Surfaces/AgentAppSurface.swift")
        XCTAssertTrue(agent.contains("PerfSwitchMetrics.beginConversationSwitch"))
        XCTAssertTrue(agent.contains("PerfSwitchMetrics.markConversationFirstPublish"))
        XCTAssertTrue(agent.contains("PerfSwitchMetrics.endConversationHydrate"))
        let select = try XCTUnwrap(agent.range(of: "public func selectThread("))
        let selectBody = agent[select.lowerBound...]
        XCTAssertTrue(
            String(selectBody.prefix(4000)).contains("beginConversationSwitch"),
            "the full-open path must start the conversation interval before hydration"
        )
    }
}
