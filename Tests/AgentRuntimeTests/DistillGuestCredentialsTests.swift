import XCTest
@testable import AgentRuntime

/// The in-guest agent signs in with copies of the user's Mac Distill accounts.
/// Claude and ChatGPT rotate refresh tokens and revoke an account whose spent
/// token is reused, so the guest must never hold a usable refresh token, yet
/// the account must still look signed in (Distill refuses a file without the
/// key). The guest owns its home, so nothing it plants there may redirect the
/// app's writes or deletes onto the Mac's real credentials.
final class DistillGuestCredentialsTests: XCTestCase {
    private var root: URL!
    private var hostHome: URL!
    private var guestHome: URL!

    static let claudeRefresh = "RT-CLAUDE-HOST-ONLY-1111"
    static let codexRefresh = "RT-CODEX-HOST-ONLY-2222"
    static let grokRefresh = "RT-GROK-HOST-ONLY-3333"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-credentials-\(UUID().uuidString)", isDirectory: true)
        hostHome = root.appendingPathComponent("host/.distill", isDirectory: true)
        guestHome = root.appendingPathComponent("bot-guests/bot-1/home/.distill", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: guestHome.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures (fake tokens only)

    static func claudeStore(access: String = "AT-CLAUDE-1") -> [String: Any] {
        [
            "access_token": access,
            "refresh_token": claudeRefresh,
            "expires_at": "2026-10-06T13:20:39.039343Z",
            "scopes": ["user:inference", "user:profile"],
            "account_uuid": "00000000-0000-4000-8000-000000000001",
            "email": "ada@example.com",
            "organization_uuid": "00000000-0000-4000-8000-000000000002",
        ]
    }

    static var codexStore: [String: Any] {
        [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": "h.e.s",
                "access_token": "AT-CODEX-1",
                "refresh_token": codexRefresh,
                "account_id": "acct-1",
            ],
            "last_refresh": "2026-10-05T23:57:17.502220Z",
        ]
    }

    static var grokStore: [String: Any] {
        [
            "https://auth.x.ai::user-1": [
                "key": "AT-GROK-1",
                "auth_mode": "oidc",
                "create_time": "2026-10-06T00:49:32.191102Z",
                "user_id": "user-1",
                "email": "ada@example.com",
                "refresh_token": grokRefresh,
                "expires_at": "2026-10-06T06:49:32.191102Z",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "client-1",
            ],
            "xai::api_key": ["key": "XAI-KEY-1", "auth_mode": "api_key"],
        ]
    }

    private func writeHost(_ name: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try writeHostData(name, data)
    }

    private func writeHostData(_ name: String, _ data: Data) throws {
        let temp = hostHome.appendingPathComponent(".\(name).tmp")
        try data.write(to: temp)
        chmod(temp.path, 0o600)
        XCTAssertEqual(rename(temp.path, hostHome.appendingPathComponent(name).path), 0)
    }

    private func writeAllHostAccounts() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        try writeHost("codex-auth.json", Self.codexStore)
        try writeHost("auth.json", Self.grokStore)
        try writeHost("openrouter-auth.json", ["key": "sk-or-1"])
    }

    private func guestJSON(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: guestHome.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: Sync

    func test_guestCopiesKeepEveryAccountSignedInButCarryNoRefreshToken() throws {
        try writeAllHostAccounts()

        let result = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)

        XCTAssertEqual(Set(result.written), Set(DistillAccountProvider.allCases))
        // Claude/Codex: Distill requires the key, so it stays, blank.
        let claude = try guestJSON("claude-auth.json")
        XCTAssertEqual(claude["refresh_token"] as? String, "")
        XCTAssertEqual(claude["access_token"] as? String, "AT-CLAUDE-1")
        XCTAssertEqual(claude["email"] as? String, "ada@example.com")
        XCTAssertEqual(claude["expires_at"] as? String, "2026-10-06T13:20:39.039343Z")
        let codexTokens = try XCTUnwrap(try guestJSON("codex-auth.json")["tokens"] as? [String: Any])
        XCTAssertEqual(codexTokens["refresh_token"] as? String, "")
        XCTAssertEqual(codexTokens["access_token"] as? String, "AT-CODEX-1")
        XCTAssertTrue(try guestJSON("codex-auth.json")["OPENAI_API_KEY"] is NSNull)
        // Grok: the field is optional, so every scope just loses it.
        let grok = try guestJSON("auth.json")
        let oauth = try XCTUnwrap(grok["https://auth.x.ai::user-1"] as? [String: Any])
        XCTAssertNil(oauth["refresh_token"])
        XCTAssertEqual(oauth["key"] as? String, "AT-GROK-1")
        XCTAssertEqual((grok["xai::api_key"] as? [String: Any])?["key"] as? String, "XAI-KEY-1")
        XCTAssertEqual(try guestJSON("openrouter-auth.json")["key"] as? String, "sk-or-1")
        // The app's own account status reads them as connected, like Distill.
        XCTAssertTrue(DistillAccounts.connectedAccounts(home: guestHome).allSatisfy(\.connected))

        for name in DistillAccountProvider.allCases.map(\.credentialFileName) {
            let bytes = try String(contentsOf: guestHome.appendingPathComponent(name), encoding: .utf8)
            for secret in [Self.claudeRefresh, Self.codexRefresh, Self.grokRefresh] {
                XCTAssertFalse(bytes.contains(secret), "\(name) carries a refresh token")
            }
            XCTAssertEqual(try mode(guestHome.appendingPathComponent(name)), 0o600, name)
        }
        XCTAssertEqual(try mode(guestHome), 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: guestHome.path)
            .filter { $0.hasPrefix(DistillGuestCredentials.temporaryPrefix) }
        XCTAssertEqual(leftovers, [])
    }

    func test_resyncPicksUpAMacRenewalAndLeavesUnchangedCopiesAlone() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)
        let copy = guestHome.appendingPathComponent("claude-auth.json")
        let firstInode = try inode(copy)

        let unchanged = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)
        XCTAssertEqual(unchanged.unchanged, [.claude])
        XCTAssertEqual(try inode(copy), firstInode, "an unchanged copy must not be rewritten")

        try writeHost("claude-auth.json", Self.claudeStore(access: "AT-CLAUDE-2"))
        let renewed = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)
        XCTAssertEqual(renewed.written, [.claude])
        XCTAssertEqual(try guestJSON("claude-auth.json")["access_token"] as? String, "AT-CLAUDE-2")
        XCTAssertEqual(try guestJSON("claude-auth.json")["refresh_token"] as? String, "")
    }

    func test_signOutOnTheMacOrAnUnreadableMacFileRemovesTheGuestCopy() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        try writeHost("codex-auth.json", Self.codexStore)
        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)

        try FileManager.default.removeItem(at: hostHome.appendingPathComponent("claude-auth.json"))
        // A file that does not parse could hold anything, a refresh token included.
        try writeHostData("codex-auth.json", Data("{\"tokens\": {\"refresh_token\": \"\(Self.codexRefresh)\"".utf8))
        let result = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)

        XCTAssertEqual(result.removed, [.claude])
        XCTAssertEqual(result.unreadable, [.chatgpt])
        XCTAssertFalse(FileManager.default.fileExists(atPath: guestHome.appendingPathComponent("claude-auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guestHome.appendingPathComponent("codex-auth.json").path))
    }

    func test_aGuestSymlinkToTheMacCredentialsIsNeverWrittenOrDeleted() throws {
        // The guest agent replaces its .distill with a link to the Mac's.
        try writeHost("claude-auth.json", Self.claudeStore())
        let original = try Data(contentsOf: hostHome.appendingPathComponent("claude-auth.json"))
        try FileManager.default.createSymbolicLink(at: guestHome, withDestinationURL: hostHome)

        XCTAssertThrowsError(try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)) { error in
            XCTAssertEqual(error as? DistillGuestCredentialError, .unsafeDirectory(path: self.guestHome.path))
        }
        XCTAssertThrowsError(try DistillGuestCredentials.removeCopies(guestDistillHome: guestHome))
        DistillGuestCredentials.removeAllCopies(guestHomeRoot: root.appendingPathComponent("bot-guests"))

        XCTAssertEqual(try Data(contentsOf: hostHome.appendingPathComponent("claude-auth.json")), original)
    }

    func test_aGuestSymlinkInPlaceOfACopyIsReplacedNotFollowed() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        let original = try Data(contentsOf: hostHome.appendingPathComponent("claude-auth.json"))
        try FileManager.default.createDirectory(at: guestHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: guestHome.appendingPathComponent("claude-auth.json"),
            withDestinationURL: hostHome.appendingPathComponent("claude-auth.json"))

        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)

        XCTAssertEqual(try Data(contentsOf: hostHome.appendingPathComponent("claude-auth.json")), original)
        let copy = guestHome.appendingPathComponent("claude-auth.json")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path))
        XCTAssertEqual(try guestJSON("claude-auth.json")["refresh_token"] as? String, "")
    }

    func test_cleanupRemovesCredentialsLocksAndTempsButKeepsTheRestOfTheHome() throws {
        try FileManager.default.createDirectory(
            at: guestHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        for name in [
            "claude-auth.json", "claude-auth.json.lock", "codex-auth.json", "auth.json.12.3.tmp",
            "auth.json.corrupt.1700000000000", "openrouter-auth.json",
            "\(DistillGuestCredentials.temporaryPrefix)A.tmp", "config.toml", "sessions/s.jsonl",
        ] {
            try Data("x".utf8).write(to: guestHome.appendingPathComponent(name))
        }

        try DistillGuestCredentials.removeCopies(guestDistillHome: guestHome)

        let left = try FileManager.default.contentsOfDirectory(atPath: guestHome.path).sorted()
        XCTAssertEqual(left, ["config.toml", "sessions"])
        XCTAssertNoThrow(try DistillGuestCredentials.removeCopies(
            guestDistillHome: root.appendingPathComponent("missing/.distill")))
    }

    func test_launchSweepRemovesEveryBotsCopies() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        let second = root.appendingPathComponent("bot-guests/bot-2/home/.distill", isDirectory: true)
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: guestHome)
        try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: second)

        DistillGuestCredentials.removeAllCopies(guestHomeRoot: root.appendingPathComponent("bot-guests"))

        for home in [guestHome!, second] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        }
    }

    // MARK: Which sign-in a model needs

    func test_accountProviderFollowsDistillsCatalogAndHostConfig() {
        let config = """
        [models]
        default = "claude/claude-opus-5-5"

        [model.codex-subscription]
        model = "gpt-5.6-sol"
        base_url = "https://chatgpt.com/backend-api/codex"

        [model.anthropic-key]
        base_url = "https://api.anthropic.com/v1"
        env_key = "ANTHROPIC_API_KEY"

        [model.anthropic-oauth]
        base_url = "https://api.anthropic.com/v1"

        [model.openrouter-qwen37]
        base_url = "https://openrouter.ai/api/v1"
        env_key = "OPENROUTER_API_KEY"
        """
        func provider(_ model: String?) -> DistillAccountProvider? {
            DistillGuestCredentials.accountProvider(model: model, hostConfig: config)
        }
        XCTAssertEqual(provider("claude/claude-sonnet-5-5"), .claude)
        XCTAssertEqual(provider("chatgpt/gpt-6-luna"), .chatgpt)
        XCTAssertEqual(provider("grok-4.6"), .grok)
        XCTAssertEqual(provider("codex-subscription"), .chatgpt)
        XCTAssertEqual(provider("anthropic-oauth"), .claude)
        // A model with its own key spends no subscription sign-in.
        XCTAssertNil(provider("anthropic-key"))
        XCTAssertNil(provider("openrouter-qwen37"))
        XCTAssertNil(provider("some-local-model"))
        XCTAssertEqual(provider(nil), .claude, "no model means the config's default")
        XCTAssertEqual(provider("  "), .claude)
    }

    // MARK: Mirror (watch while a guest run is live)

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func test_mirrorFollowsMacRenewalsDuringARunAndCleansUpAfterTheLastRun() throws {
        try writeHost("claude-auth.json", Self.claudeStore())
        let mirror = DistillGuestCredentialMirror(hostHome: hostHome, debounce: 0.05)
        let runA = UUID().uuidString
        let runB = UUID().uuidString

        let first = try mirror.begin(runID: runA, guestDistillHome: guestHome)
        XCTAssertEqual(first.written, [.claude], "the pre-run sync happens before begin returns")
        try mirror.begin(runID: runB, guestDistillHome: guestHome)

        // A Mac Distill process renews the token (temp + rename).
        try writeHost("claude-auth.json", Self.claudeStore(access: "AT-CLAUDE-RENEWED"))
        XCTAssertTrue(waitUntil {
            (try? self.guestJSON("claude-auth.json")["access_token"] as? String) == "AT-CLAUDE-RENEWED"
        }, "the guest copy must follow a Mac renewal while the run is live")
        XCTAssertEqual(try guestJSON("claude-auth.json")["refresh_token"] as? String, "")

        // A later sign-in on the Mac reaches the live run too.
        try writeHost("codex-auth.json", Self.codexStore)
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: self.guestHome.appendingPathComponent("codex-auth.json").path)
        })

        mirror.end(runID: runA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: guestHome.appendingPathComponent("claude-auth.json").path),
                      "another live run of this bot still needs the copies")
        mirror.end(runID: runB)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guestHome.path), [])

        // No run left: a renewal no longer writes into the guest.
        try writeHost("claude-auth.json", Self.claudeStore(access: "AT-CLAUDE-3"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guestHome.path), [])
    }
}
