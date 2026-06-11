import Foundation
import CoreModel

#if DEBUG
/// Test-only deterministic fixture builder. Never used by production builds.
/// Each scenario returns a fully formed in-memory or disk-backed state that
/// downstream tests/UI suites can rely on without reading real user data.
public enum FixtureScenario: String, CaseIterable, Sendable {
    case empty
    case singleWorkspaceAgentApp
    case threeSurfaceLayout
    /// A session_snapshots row whose payload_json is intentionally malformed so
    /// SessionSnapshotRepository.latest() must fall back cleanly instead of throwing.
    case corruptSnapshot
    /// A DB that was migrated to schema v13 and then stopped; used to verify that
    /// migrating forward from any historical checkpoint succeeds without data loss.
    case legacySchemaV13
    /// Terminal output chunks whose parent surface no longer exists in the layout,
    /// simulating a crash between surface creation and snapshot save. Used to
    /// verify that orphaned chunks do not block boot or inflate memory.
    case orphanedTerminalChunks
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
        // legacySchemaV13 must NOT run Schema.migrate upfront - it builds a DB
        // stopped at v13 so forward-migration tests can apply the remaining steps.
        if scenario == .legacySchemaV13 {
            return try buildLegacySchemaV13(dbPath: dbPath)
        }

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
        case .corruptSnapshot:
            // Write one valid snapshot followed by one corrupt row. Tests can
            // call SessionSnapshotRepository.latest() and assert it falls back
            // to the valid row rather than crashing.
            let validSnap = SessionSnapshot(layout: state)
            let validJSON = (try? JSONEncoder().encode(validSnap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let ins = try db.prepare("INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(?, ?, ?);")
            try ins.bind(1, Int64(validSnap.version))
            try ins.bind(2, validJSON)
            try ins.bind(3, "2024-01-01T00:00:00Z")
            _ = try ins.step()
            // Corrupt row inserted after the valid one (higher id = preferred by latest()).
            let insCorrupt = try db.prepare("INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(?, ?, ?);")
            try insCorrupt.bind(1, Int64(1))
            try insCorrupt.bind(2, "NOT VALID JSON{{{")
            try insCorrupt.bind(3, "2024-01-02T00:00:00Z")
            _ = try insCorrupt.step()
        case .legacySchemaV13:
            // Unreachable: handled by early return above.
            break
        case .orphanedTerminalChunks:
            // Insert terminal chunks for a surface id that has no matching layout
            // entry. Simulates a crash between chunk-write and snapshot-save.
            let ghostSurfaceID = "orphaned-surface-\(UUID().uuidString)"
            let termRepo = TerminalOutputRepository(db: db)
            for i in 0..<5 {
                try termRepo.append(surfaceID: ghostSurfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("chunk-\(i)".utf8))
            }
        }

        return Built(db: db, state: state, threads: threads, messages: messages)
    }

    /// Builds a DB stopped at schema v13 by applying only steps 1..13.
    /// The tables added by steps 14+ do not exist yet, so Schema.migrate()
    /// can run them as a genuine forward migration.
    private func buildLegacySchemaV13(dbPath: String) throws -> Built {
        let db = try SQLiteDB(path: dbPath)
        let stepsTo13 = Schema.steps.filter { $0.version <= 13 }
        try Schema.migrateSteps(db, stepsTo13)
        return Built(db: db, state: LayoutState(), threads: [], messages: [])
    }
}
#endif
