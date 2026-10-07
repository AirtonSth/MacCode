import Foundation

public struct AuthenticatedCapabilities: Codable, Equatable, Sendable {
    public let authenticated: Bool
    public let serverID: String
    public let bootEpoch: UInt64
    public let treaty: TreatyCompatibility?
    public let capabilities: HostCapabilities
    /// Opaque digest of `treaty` + `capabilities` (+ API version). Equals the
    /// WebSocket welcome `capabilitiesDigest` sent to clients that opt in with
    /// `X-RC2-Welcome-Fields: identity.v1`. Nil from hosts that predate it.
    public let capabilitiesDigest: String?

    public init(
        authenticated: Bool,
        serverID: String,
        bootEpoch: UInt64,
        treaty: TreatyCompatibility?,
        capabilities: HostCapabilities,
        capabilitiesDigest: String? = nil
    ) {
        self.authenticated = authenticated
        self.serverID = serverID
        self.bootEpoch = bootEpoch
        self.treaty = treaty
        self.capabilities = capabilities
        self.capabilitiesDigest = capabilitiesDigest
    }

    private enum CodingKeys: String, CodingKey {
        case authenticated
        case serverID = "server_id"
        case bootEpoch = "boot_epoch"
        case treaty
        case capabilities
        case capabilitiesDigest = "capabilities_digest"
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
        /// `actor` / `actor_locked_at` / `execution_target` / `guest_runtime` /
        /// `runs_in_guest` / `pending_mac_execution` on thread payloads,
        /// `agent.thread.actor.set`, `agent.mac_execution.resolve` and
        /// `agent.mac_execution.requested` (see ThreadActorContracts.swift).
        /// False for older hosts.
        public let threadActorV1: Bool
        /// `recovery_action` (`sign_in` | `retry` | `start_fresh` |
        /// `new_session` | null) is present on every `agent.run.error` and
        /// `agent.run.failed` event and on every replayed `error` row of
        /// `agent.thread.read`; `message` there is display text. Render the
        /// action as given (null = no action). False for older hosts: fall back
        /// to a generic Retry.
        public let runRecoveryActionV1: Bool
        /// `agent.attachment.get` (one message attachment's bytes or JPEG
        /// thumbnail) and `agent.message.appended` for bot screenshots (see
        /// AgentAttachmentGetContracts.swift). False for older hosts: show the
        /// filename chip only.
        public let attachmentGetV1: Bool
        /// `agent.account.usage.get` (stored per-provider account usage; see
        /// AgentAccountUsageContracts.swift). False for older hosts: rings stay
        /// empty until the first live `agent.account.usage` event.
        public let accountUsageGetV1: Bool

        public init(
            providers: [String],
            supportsStreamEvents: Bool,
            supportsResume: Bool,
            manualActionsV1: Bool = false,
            threadActorV1: Bool = false,
            runRecoveryActionV1: Bool = false,
            attachmentGetV1: Bool = false,
            accountUsageGetV1: Bool = false
        ) {
            self.providers = providers
            self.supportsStreamEvents = supportsStreamEvents
            self.supportsResume = supportsResume
            self.manualActionsV1 = manualActionsV1
            self.threadActorV1 = threadActorV1
            self.runRecoveryActionV1 = runRecoveryActionV1
            self.attachmentGetV1 = attachmentGetV1
            self.accountUsageGetV1 = accountUsageGetV1
        }

        private enum CodingKeys: String, CodingKey {
            case providers
            case supportsStreamEvents = "supports_stream_events"
            case supportsResume = "supports_resume"
            case manualActionsV1 = "manual_actions_v1"
            case threadActorV1 = "thread_actor_v1"
            case runRecoveryActionV1 = "run_recovery_action_v1"
            case attachmentGetV1 = "attachment_get_v1"
            case accountUsageGetV1 = "account_usage_get_v1"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providers = try container.decode([String].self, forKey: .providers)
            supportsStreamEvents = try container.decode(Bool.self, forKey: .supportsStreamEvents)
            supportsResume = try container.decode(Bool.self, forKey: .supportsResume)
            manualActionsV1 = try container.decodeIfPresent(Bool.self, forKey: .manualActionsV1) ?? false
            threadActorV1 = try container.decodeIfPresent(Bool.self, forKey: .threadActorV1) ?? false
            runRecoveryActionV1 = try container.decodeIfPresent(Bool.self, forKey: .runRecoveryActionV1) ?? false
            attachmentGetV1 = try container.decodeIfPresent(Bool.self, forKey: .attachmentGetV1) ?? false
            accountUsageGetV1 = try container.decodeIfPresent(Bool.self, forKey: .accountUsageGetV1) ?? false
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
        /// `bot.guest.state` with `observe: true`, `controlled_by_user`,
        /// `bot.guest.control` and `bot.guest.updated` with `reason: "agent_step"`
        /// (see BotGuestContracts.swift). False for older hosts: no live viewer
        /// and no Take/Release.
        public let guestObserveV1: Bool

        public init(
            queueControls: [String],
            teamsV1: Bool = false,
            groupsV1: Bool = false,
            guestObserveV1: Bool = false
        ) {
            self.queueControls = queueControls
            self.teamsV1 = teamsV1
            self.groupsV1 = groupsV1
            self.guestObserveV1 = guestObserveV1
        }

        private enum CodingKeys: String, CodingKey {
            case queueControls = "queue_controls"
            case teamsV1 = "teams_v1"
            case groupsV1 = "groups_v1"
            case guestObserveV1 = "guest_observe_v1"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            queueControls = try container.decode([String].self, forKey: .queueControls)
            teamsV1 = try container.decodeIfPresent(Bool.self, forKey: .teamsV1) ?? false
            groupsV1 = try container.decodeIfPresent(Bool.self, forKey: .groupsV1) ?? false
            guestObserveV1 = try container.decodeIfPresent(Bool.self, forKey: .guestObserveV1) ?? false
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
