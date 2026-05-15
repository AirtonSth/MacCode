import Foundation
import CoreModel

/// Test-only deterministic fixture builder. Never used by production builds.
/// Each scenario returns a fully formed in-memory or disk-backed state that
/// downstream tests/UI suites can rely on without reading real user data.
public enum FixtureScenario: String, Sendable {
    case empty
    case singleWorkspaceAgentApp
    case threeSurfaceLayout
}

public final class FixtureFactory {
    public init() {}

    public struct Built {
        public let db: SQLiteDB
        public let state: LayoutState
        public let threads: [AgentThread]
        public let messages: [AgentMessage]
    }

    public func build(_ scenario: FixtureScenario, dbPath: String) throws -> Built {
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        let reducer = LayoutReducer()
        var state = LayoutState()
        var threads: [AgentThread] = []
        var messages: [AgentMessage] = []
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)

        switch scenario {
        case .empty:
            break
        case .singleWorkspaceAgentApp:
            let wsId = WorkspaceID(UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111")!)
            var pane = PaneNode(id: PaneID(UUID(uuidString: "BBBBBBBB-2222-2222-2222-222222222222")!))
            let surface = SurfaceDescriptor(
                id: SurfaceID(UUID(uuidString: "CCCCCCCC-3333-3333-3333-333333333333")!),
                type: .agentApp, title: "Agent App"
            )
            pane.surfaces = [surface]
            pane.selectedSurfaceID = surface.id
            let ws = Workspace(
                id: wsId, name: "fixture-ws",
                cwd: "/tmp/fixture-ws",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                layout: .pane(pane), focusedPaneID: pane.id
            )
            state.workspaces[wsId] = ws
            state.window.workspaces.append(wsId)
            state.window.selectedWorkspaceID = wsId
            let t = AgentThread(
                id: AgentThreadID(UUID(uuidString: "DDDDDDDD-4444-4444-4444-444444444444")!),
                workspaceId: wsId,
                title: "Fixture thread",
                provider: .codex, model: "gpt-5"
            )
            try threadRepo.upsert(t)
            threads = [t]
            let m1 = AgentMessage(
                id: AgentMessageID(UUID(uuidString: "EEEEEEEE-5555-5555-5555-555555555555")!),
                threadId: t.id, role: .user, content: "Hello fixture"
            )
            let m2 = AgentMessage(
                id: AgentMessageID(UUID(uuidString: "FFFFFFFF-6666-6666-6666-666666666666")!),
                threadId: t.id, role: .assistant, content: "Hi from fixture"
            )
            try messageRepo.append(m1)
            try messageRepo.append(m2)
            messages = [m1, m2]
        case .threeSurfaceLayout:
            state = try reducer.reduce(state, .createWorkspace(name: "fixture-3", cwd: "/tmp/fixture-3", initial: nil))
            let wid = state.window.selectedWorkspaceID!
            let term = SurfaceDescriptor(type: .terminal, title: "terminal")
            let agent = SurfaceDescriptor(type: .agentApp, title: "Agent App")
            let browser = SurfaceDescriptor(type: .browser, title: "browser")
            state = try reducer.reduce(state, .addSurface(wid, paneID: nil, descriptor: term))
            let pid = state.workspaces[wid]!.layout.paneIDs().first!
            state = try reducer.reduce(state, .splitPane(wid, paneID: pid, direction: .right, newSurface: agent))
            let rightPane = state.workspaces[wid]!.layout.paneIDs().last!
            state = try reducer.reduce(state, .splitPane(wid, paneID: rightPane, direction: .down, newSurface: browser))
        }

        return Built(db: db, state: state, threads: threads, messages: messages)
    }
}
