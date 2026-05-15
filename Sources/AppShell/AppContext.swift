import Foundation
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces

@MainActor
public final class AppContext {
    public let channel: ReleaseChannel
    public let db: SQLiteDB
    public let bootstrapReport: BootstrapReport
    public let projectRepo: ProjectRepository
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let runRepo: AgentRunRepository
    public let snapshotRepo: SessionSnapshotRepository
    public let settingsRepo: SettingsRepository
    public let eventLog: EventLogRepository

    public let reducer = LayoutReducer()
    public var state = LayoutState()

    public let coordinator: AgentRunCoordinator
    public var router: AppCommandRouter!
    public var socketServer: UnixSocketServer?

    public init(channel: ReleaseChannel = .debug, dbPathOverride: String? = nil, appSupportOverride: String? = nil) throws {
        self.channel = channel
        let bs = Bootstrap(channel: channel, dbPathOverride: dbPathOverride, appSupportOverride: appSupportOverride)
        let (rep, db) = try bs.run()
        self.bootstrapReport = rep
        self.db = db
        self.projectRepo = ProjectRepository(db: db)
        self.threadRepo = AgentThreadRepository(db: db)
        self.messageRepo = AgentMessageRepository(db: db)
        self.runRepo = AgentRunRepository(db: db)
        self.snapshotRepo = SessionSnapshotRepository(db: db)
        self.settingsRepo = SettingsRepository(db: db)
        self.eventLog = EventLogRepository(db: db)
        let codex = CodexRunner()
        let claude = ClaudeRunner()
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: codex, .claude: claude]
        )
        try coordinator.reconcileOnLaunch()
        // restore last snapshot if any
        if let snap = try snapshotRepo.latest() {
            self.state = snap.layout
        }
    }

    public func apply(_ action: LayoutAction) throws {
        state = try reducer.reduce(state, action)
    }

    public func saveSnapshot() {
        let snap = SessionSnapshot(layout: state)
        _ = try? snapshotRepo.save(snap)
    }
}
