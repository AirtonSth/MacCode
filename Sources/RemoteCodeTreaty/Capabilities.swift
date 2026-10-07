import Foundation

public struct AuthenticatedCapabilities: Codable, Equatable, Sendable {
    public let authenticated: Bool
    public let serverID: String
    public let bootEpoch: UInt64
    public let treaty: TreatyCompatibility?
    public let capabilities: HostCapabilities

    public init(
        authenticated: Bool,
        serverID: String,
        bootEpoch: UInt64,
        treaty: TreatyCompatibility?,
        capabilities: HostCapabilities
    ) {
        self.authenticated = authenticated
        self.serverID = serverID
        self.bootEpoch = bootEpoch
        self.treaty = treaty
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case authenticated
        case serverID = "server_id"
        case bootEpoch = "boot_epoch"
        case treaty
        case capabilities
    }
}

public struct HostCapabilities: Codable, Equatable, Sendable {
    public struct Agent: Codable, Equatable, Sendable {
        public let providers: [String]
        public let supportsStreamEvents: Bool
        public let supportsResume: Bool
        /// `agent.manual_action.list` / `agent.manual_action.resolve`,
        /// `agent.manual_action.updated` and `pending_manual_action` on thread
        /// payloads (see ManualActionContracts.swift). False for older hosts.
        public let manualActionsV1: Bool

        public init(
            providers: [String],
            supportsStreamEvents: Bool,
            supportsResume: Bool,
            manualActionsV1: Bool = false
        ) {
            self.providers = providers
            self.supportsStreamEvents = supportsStreamEvents
            self.supportsResume = supportsResume
            self.manualActionsV1 = manualActionsV1
        }

        private enum CodingKeys: String, CodingKey {
            case providers
            case supportsStreamEvents = "supports_stream_events"
            case supportsResume = "supports_resume"
            case manualActionsV1 = "manual_actions_v1"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providers = try container.decode([String].self, forKey: .providers)
            supportsStreamEvents = try container.decode(Bool.self, forKey: .supportsStreamEvents)
            supportsResume = try container.decode(Bool.self, forKey: .supportsResume)
            manualActionsV1 = try container.decodeIfPresent(Bool.self, forKey: .manualActionsV1) ?? false
        }
    }

    public struct Git: Codable, Equatable, Sendable {
        public let readOnly: Bool
        public let methods: [String]?

        public init(readOnly: Bool, methods: [String]? = nil) {
            self.readOnly = readOnly
            self.methods = methods
        }

        private enum CodingKeys: String, CodingKey {
            case readOnly = "read_only"
            case methods
        }
    }

    public struct FeatureFlags: Codable, Equatable, Sendable {
        public let remoteAccessEnabled: Bool

        public init(remoteAccessEnabled: Bool) {
            self.remoteAccessEnabled = remoteAccessEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case remoteAccessEnabled = "remote_access_enabled"
        }
    }

    public struct Bot: Codable, Equatable, Sendable {
        public let queueControls: [String]
        /// `bot.team.*` RPCs and `bot.team.updated` events.
        public let teamsV1: Bool
        /// `bot.group.*` RPCs, `bot.group.updated` / `bot.group.turn.updated`
        /// events and `kind: "group"` items in `bot.attention.list` (sent only
        /// when the call passes `include_kinds: ["group"]`).
        public let groupsV1: Bool

        public init(queueControls: [String], teamsV1: Bool = false, groupsV1: Bool = false) {
            self.queueControls = queueControls
            self.teamsV1 = teamsV1
            self.groupsV1 = groupsV1
        }

        private enum CodingKeys: String, CodingKey {
            case queueControls = "queue_controls"
            case teamsV1 = "teams_v1"
            case groupsV1 = "groups_v1"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            queueControls = try container.decode([String].self, forKey: .queueControls)
            teamsV1 = try container.decodeIfPresent(Bool.self, forKey: .teamsV1) ?? false
            groupsV1 = try container.decodeIfPresent(Bool.self, forKey: .groupsV1) ?? false
        }
    }

    public let surfaceTypes: [String]
    public let agent: Agent
    public let git: Git
    public let featureFlags: FeatureFlags
    public let ssh: RemoteCodeJSONValue?
    public let browserAutomation: RemoteCodeJSONValue?
    public let files: RemoteCodeJSONValue?
    public let bot: Bot?

    public init(
        surfaceTypes: [String],
        agent: Agent,
        git: Git,
        featureFlags: FeatureFlags,
        ssh: RemoteCodeJSONValue? = nil,
        browserAutomation: RemoteCodeJSONValue? = nil,
        files: RemoteCodeJSONValue? = nil,
        bot: Bot? = nil
    ) {
        self.surfaceTypes = surfaceTypes
        self.agent = agent
        self.git = git
        self.featureFlags = featureFlags
        self.ssh = ssh
        self.browserAutomation = browserAutomation
        self.files = files
        self.bot = bot
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceTypes = "surface_types"
        case agent, git, ssh, files, bot
        case browserAutomation = "browser_automation"
        case featureFlags = "feature_flags"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceTypes = try container.decode([String].self, forKey: .surfaceTypes)
        agent = try container.decode(Agent.self, forKey: .agent)
        git = try container.decodeIfPresent(Git.self, forKey: .git)
            ?? Git(readOnly: true)
        featureFlags = try container.decodeIfPresent(
            FeatureFlags.self,
            forKey: .featureFlags
        ) ?? FeatureFlags(remoteAccessEnabled: false)
        ssh = try container.decodeIfPresent(RemoteCodeJSONValue.self, forKey: .ssh)
        browserAutomation = try container.decodeIfPresent(
            RemoteCodeJSONValue.self,
            forKey: .browserAutomation
        )
        files = try container.decodeIfPresent(RemoteCodeJSONValue.self, forKey: .files)
        bot = try container.decodeIfPresent(Bot.self, forKey: .bot)
    }
}
