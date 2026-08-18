import XCTest
import CoreModel
@testable import Surfaces

final class AgentComposerChromeTests: XCTestCase {
    func test_permissionDisplayNameIsAutoEdit_becauseDeskAndAgentAppMustShareOneLabel() {
        // WHY: Desk header used to say "Auto-accept edits" while the Agent App
        // chip said "Auto-edit". One displayName is the contract.
        XCTAssertEqual(AgentPermissionMode.supervised.displayName, "Supervised")
        XCTAssertEqual(AgentPermissionMode.autoAcceptEdits.displayName, "Auto-edit")
        XCTAssertEqual(AgentPermissionMode.fullAccess.displayName, "Full access")
        XCTAssertEqual(AgentPermissionMode.supervised.pickerHelpText, "Ask before tool actions")
        XCTAssertEqual(AgentPermissionMode.autoAcceptEdits.pickerHelpText, "Apply edits without asking")
        XCTAssertEqual(AgentPermissionMode.fullAccess.pickerHelpText, "Run tools without asking")
    }

    func test_modelPillAccessibilityNamesAutoAndManualParts() {
        let auto = AgentModelPillPresentation(title: "Auto", loading: true)
        XCTAssertEqual(auto.accessibilityLabel, "Auto model routing, loading")
        XCTAssertTrue(auto.isAuto)

        let manual = AgentModelPillPresentation(
            title: "gpt-5.5",
            effort: "Medium",
            serviceTier: "Fast",
            contextWindow: "272K"
        )
        XCTAssertEqual(manual.accessibilityLabel, "Model gpt-5.5, effort Medium, tier Fast")
        XCTAssertFalse(manual.isAuto)
    }

    func test_runAsPresentationLocksWhileRunningOrIdentityLocked() {
        XCTAssertTrue(
            AgentRunAsUserPresentation.isInteractive(userCount: 2, identityLocked: false, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 1, identityLocked: false, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 3, identityLocked: true, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 3, identityLocked: false, runLocked: true)
        )
    }

    func test_agentAndBotsShareComposerChromeTypes() throws {
        // WHY: Desk used private deskChipLabel forks for the same controls
        // Agent App paints. Both call sites must mount the shared views.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentComposerChrome.swift"),
            encoding: .utf8
        )
        let agent = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let bots = try String(
            contentsOf: repo.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chrome.contains("struct AgentSourceCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentPermissionCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentRunAsUserCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentModelPillLabel"))
        XCTAssertTrue(chrome.contains("struct AgentCompactMenuRow"))
        XCTAssertTrue(chrome.contains("struct AgentQueuedHeader"))

        XCTAssertTrue(agent.contains("AgentSourceCapsule("))
        XCTAssertTrue(agent.contains("AgentPermissionCapsule("))
        XCTAssertTrue(agent.contains("AgentRunAsUserCapsule("))
        XCTAssertTrue(agent.contains("AgentModelPillLabel("))
        XCTAssertTrue(agent.contains("AgentQueuedHeader("))
        XCTAssertFalse(agent.contains("private func sourceCapsuleLabelView"))
        XCTAssertFalse(agent.contains("private var permissionLabel"))

        XCTAssertTrue(bots.contains("AgentSourceCapsule("))
        XCTAssertTrue(bots.contains("AgentPermissionCapsule("))
        XCTAssertTrue(bots.contains("AgentRunAsUserCapsule("))
        XCTAssertTrue(bots.contains("AgentModelPillLabel("))
        XCTAssertTrue(bots.contains("AgentCompactMenuRow("))
        XCTAssertTrue(bots.contains("AgentQueuedHeader("))
        XCTAssertFalse(
            bots.contains("func deskChipLabel"),
            "Desk must not keep a private capsule fork after the shared chrome exists"
        )
        XCTAssertFalse(
            bots.contains("Auto-accept edits"),
            "Desk must use AgentPermissionMode.displayName, not a second permission string"
        )
    }
}
