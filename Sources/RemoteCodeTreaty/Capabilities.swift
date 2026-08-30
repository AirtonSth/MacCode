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

        public init(
            providers: [String],
            supportsStreamEvents: Bool,
            supportsResume: Bool
        ) {
            self.providers = providers
            self.supportsStreamEvents = supportsStreamEvents
            self.supportsResume = supportsResume
        }

        private enum CodingKeys: String, CodingKey {
            case providers
            case supportsStreamEvents = "supports_stream_events"
            case supportsResume = "supports_resume"
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

        public init(queueControls: [String]) {
            self.queueControls = queueControls
        }

        private enum CodingKeys: String, CodingKey {
            case queueControls = "queue_controls"
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
