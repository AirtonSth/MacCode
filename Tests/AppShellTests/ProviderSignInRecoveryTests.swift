import XCTest
@testable import AppShell
import CoreModel
@testable import Surfaces

@MainActor
final class ProviderSignInRecoveryTests: XCTestCase {
    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        super.tearDown()
    }

    func test_providerSignInTerminalInputsAreExactInteractiveCommands() {
        XCTAssertEqual(AppCommandRouter.providerSignInTerminalInput(for: .codex), "codex login\n")
        XCTAssertEqual(AppCommandRouter.providerSignInTerminalInput(for: .claude), "claude auth login\n")
        XCTAssertEqual(AppCommandRouter.providerSignInTerminalInput(for: .grok), "grok login\n")
    }

    func test_unauthenticatedProviderActionCreatesFocusesAndSendsToIntegratedTerminal() async throws {
        let support = NSTemporaryDirectory() + "RC2ProviderSignIn-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: support) }
        let context = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Provider sign-in", cwd: support)
        let agentDescriptor = try router.openAgentApp(workspace: workspace.id)
        let agent = try XCTUnwrap(
            SurfaceRegistry.shared.surface(agentDescriptor.id) as? AgentAppSurface
        )
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-code-fast-1", label: "Grok Code Fast", provider: .grok)],
            binaryPath: "/usr/bin/true",
            authenticated: false
        )
        agent.viewModel.provider = .grok
        agent.viewModel.providerInstanceId = snapshot.id
        agent.viewModel.providerSnapshots = [snapshot]
        var terminalInput: (surfaceID: SurfaceID, text: String)?
        router.providerSignInTerminalInputSenderForTests = { surfaceID, text in
            terminalInput = (surfaceID, text)
            return .accepted
        }

        await agent.viewModel.performProviderRecoveryAction()

        let sent = try XCTUnwrap(terminalInput)
        XCTAssertEqual(sent.text, "grok login\n")
        let terminal = try XCTUnwrap(SurfaceRegistry.shared.surface(sent.surfaceID))
        XCTAssertEqual(terminal.descriptor.type, .terminal)
        XCTAssertEqual(terminal.descriptor.title, "Sign in: Grok")
        let refreshedWorkspace = try XCTUnwrap(context.state.workspaces[workspace.id])
        let focusedPane = try XCTUnwrap(refreshedWorkspace.focusedPaneID)
        XCTAssertEqual(
            refreshedWorkspace.layout.find(paneID: focusedPane)?.selectedSurfaceID,
            sent.surfaceID,
            "the integrated sign-in Terminal must be the selected surface in the focused pane"
        )
        XCTAssertEqual(agent.viewModel.providerRecoveryActionTitle, "Retry")
        XCTAssertEqual(
            agent.viewModel.providerRecoveryStatusMessage,
            "Opened Grok sign-in in Terminal. Complete sign-in there, then choose Retry."
        )
    }
}
