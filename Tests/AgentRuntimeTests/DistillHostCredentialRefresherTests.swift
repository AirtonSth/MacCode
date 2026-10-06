import XCTest
@testable import AgentRuntime

/// The guest's sign-in copies cannot refresh themselves, so the Mac renews a
/// Claude or ChatGPT token that would expire during the run. Doing it wrong is
/// worse than not doing it: a refresh token is spent by the request, so the
/// request must be exactly Distill's, must be serialised with every Mac
/// Distill process through Distill's own lock, and a failure must leave the
/// user's file exactly as it was. No token may leak into an error message.
final class DistillHostCredentialRefresherTests: XCTestCase {
    private var hostHome: URL!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let claudeRefresh = "RT-CLAUDE-HOST-ONLY-1111"
    private let codexRefresh = "RT-CODEX-HOST-ONLY-2222"

    override func setUpWithError() throws {
        hostHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-refresh-\(UUID().uuidString)/.distill", isDirectory: true)
        try FileManager.default.createDirectory(at: hostHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hostHome.deletingLastPathComponent())
    }

    // MARK: Stub token endpoint (no network)

    final class TokenEndpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(url: URL, body: [String: Any])] = []
        var reply: Result<(Data, Int), Error> = .success((Data(), 500))

        var requests: [(url: URL, body: [String: Any])] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        var post: DistillAccounts.HTTPPost {
            { url, body in
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                self.lock.lock()
                self._requests.append((url, json))
                let reply = self.reply
                self.lock.unlock()
                return try reply.get()
            }
        }

        func respond(status: Int, _ object: Any) {
            reply = .success(((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), status))
        }
    }

    private func refresher(_ endpoint: TokenEndpoint, lockTimeout: TimeInterval = 2) -> DistillHostCredentialRefresher {
        let now = now
        return DistillHostCredentialRefresher(
            hostHome: hostHome, httpPost: endpoint.post, now: { now }, lockTimeout: lockTimeout)
    }

    // MARK: Fixtures

    private func iso(_ date: Date) -> String { DistillHostCredentialRefresher.formatDate(date) }

    private func writeHost(_ name: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let url = hostHome.appendingPathComponent(name)
        try data.write(to: url)
        chmod(url.path, 0o600)
    }

    private func writeClaude(expiresIn: TimeInterval) throws {
        try writeHost("claude-auth.json", [
            "access_token": "AT-CLAUDE-OLD",
            "refresh_token": claudeRefresh,
            "expires_at": iso(now.addingTimeInterval(expiresIn)),
            "scopes": ["user:inference"],
            "account_uuid": "acct-uuid-1",
            "email": "ada@example.com",
            "organization_uuid": "org-uuid-1",
            "field_from_a_newer_distill": ["kept": true],
        ] as [String: Any])
    }

    private func jwt(_ payload: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none"])).\(part(payload)).sig"
    }

    private func idToken(account: String) -> String {
        jwt(["email": "ada@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": account]])
    }

    private func writeCodex(accessExpiresIn: TimeInterval) throws {
        try writeHost("codex-auth.json", [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "id_token": idToken(account: "acct-1"),
                "access_token": jwt(["exp": now.addingTimeInterval(accessExpiresIn).timeIntervalSince1970]),
                "refresh_token": codexRefresh,
                "account_id": "acct-1",
            ],
            "last_refresh": "2026-10-05T23:57:17.502220Z",
        ] as [String: Any])
    }

    private func hostJSON(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: hostHome.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func snapshot(_ name: String) throws -> (Data, UInt64) {
        let url = hostHome.appendingPathComponent(name)
        let inode = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        return (try Data(contentsOf: url), inode ?? 0)
    }

    private func assertUntouched(_ name: String, _ before: (Data, UInt64), file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try snapshot(name)
        XCTAssertEqual(after.0, before.0, "the file content changed", file: file, line: line)
        XCTAssertEqual(after.1, before.1, "the file was replaced", file: file, line: line)
    }

    private func assertThrows(
        _ expected: DistillGuestCredentialError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> DistillGuestCredentialError? {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
            return nil
        } catch {
            XCTAssertEqual(error as? DistillGuestCredentialError, expected, file: file, line: line)
            return error as? DistillGuestCredentialError
        }
    }

    // MARK: Claude

    func test_claudeTokenWithMoreThan45MinutesLeftIsNotRenewed() async throws {
        try writeClaude(expiresIn: 46 * 60)
        let endpoint = TokenEndpoint()
        try await refresher(endpoint).prepare(provider: .claude)
        XCTAssertEqual(endpoint.requests.count, 0, "a refresh spends the token; never do it needlessly")
    }

    func test_claudeNearExpiryIsRenewedWithDistillsExactRequestKeepingEveryOtherField() async throws {
        try writeClaude(expiresIn: 30 * 60)
        let endpoint = TokenEndpoint()
        endpoint.respond(status: 200, [
            "access_token": "AT-CLAUDE-NEW",
            "refresh_token": "RT-CLAUDE-ROTATED",
            "expires_in": 28_800,
            "scope": "user:inference user:profile",
            "token_type": "Bearer",
        ])

        try await refresher(endpoint).prepare(model: "claude/claude-opus-5-5", hostConfig: "")

        XCTAssertEqual(endpoint.requests.count, 1)
        let request = try XCTUnwrap(endpoint.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.body as NSDictionary, [
            "grant_type": "refresh_token",
            "refresh_token": claudeRefresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ] as NSDictionary)

        let store = try hostJSON("claude-auth.json")
        XCTAssertEqual(store["access_token"] as? String, "AT-CLAUDE-NEW")
        XCTAssertEqual(store["refresh_token"] as? String, "RT-CLAUDE-ROTATED", "the rotated token must be kept or the account is lost")
        let expiresAt = try XCTUnwrap((store["expires_at"] as? String).flatMap(DistillHostCredentialRefresher.parseDate))
        XCTAssertEqual(expiresAt.timeIntervalSince(now), 28_800, accuracy: 1)
        XCTAssertEqual(store["scopes"] as? [String], ["user:inference", "user:profile"])
        XCTAssertEqual(store["email"] as? String, "ada@example.com")
        XCTAssertEqual(store["account_uuid"] as? String, "acct-uuid-1")
        XCTAssertEqual(store["organization_uuid"] as? String, "org-uuid-1")
        XCTAssertEqual((store["field_from_a_newer_distill"] as? [String: Any])?["kept"] as? Bool, true)
        let mode = (try FileManager.default.attributesOfItem(
            atPath: hostHome.appendingPathComponent("claude-auth.json").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func test_claudeRenewalWithoutARotatedTokenKeepsTheCurrentOne() async throws {
        try writeClaude(expiresIn: -60)
        let endpoint = TokenEndpoint()
        endpoint.respond(status: 200, ["access_token": "AT-CLAUDE-NEW", "expires_in": 3600])
        try await refresher(endpoint).prepare(provider: .claude)
        XCTAssertEqual(try hostJSON("claude-auth.json")["refresh_token"] as? String, claudeRefresh)
        XCTAssertEqual(try hostJSON("claude-auth.json")["scopes"] as? [String], ["user:inference"])
    }

    func test_claudeRejectionLeavesTheFileUntouchedAndNeverEchoesTheToken() async throws {
        try writeClaude(expiresIn: 60)
        let before = try snapshot("claude-auth.json")
        let endpoint = TokenEndpoint()
        // A server that reflects the request must not get the token into our message.
        endpoint.respond(status: 401, ["error": "invalid_grant", "error_description": "bad token \(claudeRefresh)"])

        let error = await assertThrows(.refreshRejected(.claude, status: 401, code: "invalid_grant")) {
            try await self.refresher(endpoint).prepare(provider: .claude)
        }

        try assertUntouched("claude-auth.json", before)
        let message = try XCTUnwrap(error?.errorDescription)
        XCTAssertFalse(message.contains(claudeRefresh))
        XCTAssertFalse(message.contains("AT-CLAUDE-OLD"))
        XCTAssertTrue(message.contains("distill login --claude"), message)
    }

    func test_claudeTransientFailuresLeaveTheFileUntouched() async throws {
        try writeClaude(expiresIn: 60)
        let before = try snapshot("claude-auth.json")
        let endpoint = TokenEndpoint()

        endpoint.respond(status: 503, ["error": "overloaded"])
        _ = await assertThrows(.refreshFailed(.claude, status: 503, code: "overloaded")) {
            try await self.refresher(endpoint).prepare(provider: .claude)
        }
        endpoint.reply = .failure(URLError(.notConnectedToInternet))
        _ = await assertThrows(.refreshFailed(.claude, status: 0, code: nil)) {
            try await self.refresher(endpoint).prepare(provider: .claude)
        }
        endpoint.respond(status: 200, ["access_token": "AT-NEW"])  // no expires_in
        _ = await assertThrows(.refreshResponseInvalid(.claude)) {
            try await self.refresher(endpoint).prepare(provider: .claude)
        }

        try assertUntouched("claude-auth.json", before)
    }

    func test_aMacDistillHoldingTheLockBlocksTheRenewalInsteadOfRacingIt() async throws {
        try writeClaude(expiresIn: 60)
        let lock = open(hostHome.appendingPathComponent("claude-auth.json.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(lock, LOCK_EX), 0)
        defer { close(lock) }
        let endpoint = TokenEndpoint()

        _ = await assertThrows(.lockTimeout(.claude)) {
            try await self.refresher(endpoint, lockTimeout: 0.3).prepare(provider: .claude)
        }
        XCTAssertEqual(endpoint.requests.count, 0)
    }

    func test_aSiblingThatRenewedWhileWeWaitedForTheLockIsNotRenewedAgain() async throws {
        try writeClaude(expiresIn: 60)
        let lockPath = hostHome.appendingPathComponent("claude-auth.json.lock").path
        let lock = open(lockPath, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(lock, LOCK_EX), 0)
        let endpoint = TokenEndpoint()
        let home = hostHome!
        let renewedExpiry = iso(now.addingTimeInterval(8 * 3600))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            // The sibling writes its rotated token under the lock, then unlocks.
            let renewed: [String: Any] = [
                "access_token": "AT-SIBLING", "refresh_token": "RT-SIBLING", "expires_at": renewedExpiry,
            ]
            try? JSONSerialization.data(withJSONObject: renewed).write(to: home.appendingPathComponent("claude-auth.json"))
            flock(lock, LOCK_UN)
            close(lock)
        }

        try await refresher(endpoint).prepare(provider: .claude)

        XCTAssertEqual(endpoint.requests.count, 0, "re-sending the spent token would revoke the account")
        XCTAssertEqual(try hostJSON("claude-auth.json")["refresh_token"] as? String, "RT-SIBLING")
    }

    func test_missingSignInFailsPreflightWithAnActionableMessage() async throws {
        let endpoint = TokenEndpoint()
        let error = await assertThrows(.notSignedIn(.chatgpt)) {
            try await self.refresher(endpoint).prepare(model: "chatgpt/gpt-6-luna", hostConfig: "")
        }
        XCTAssertTrue(error?.errorDescription?.contains("distill login --chatgpt") == true)
        // API-key and unmanaged models need no sign-in at all.
        try await refresher(endpoint).prepare(model: "some-local-model", hostConfig: "")
    }

    // MARK: ChatGPT / Codex

    func test_codexTokenWithMoreThan45MinutesLeftIsNotRenewed() async throws {
        try writeCodex(accessExpiresIn: 2 * 3600)
        let endpoint = TokenEndpoint()
        try await refresher(endpoint).prepare(provider: .chatgpt)
        XCTAssertEqual(endpoint.requests.count, 0)
    }

    func test_codexNearExpiryIsRenewedWithDistillsExactRequest() async throws {
        try writeCodex(accessExpiresIn: 10 * 60)
        let endpoint = TokenEndpoint()
        let newAccess = jwt(["exp": now.addingTimeInterval(10 * 86_400).timeIntervalSince1970])
        endpoint.respond(status: 200, [
            "id_token": idToken(account: "acct-1"),
            "access_token": newAccess,
            "refresh_token": "RT-CODEX-ROTATED",
        ])

        try await refresher(endpoint).prepare(provider: .chatgpt)

        let request = try XCTUnwrap(endpoint.requests.first)
        XCTAssertEqual(endpoint.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(request.body as NSDictionary, [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "grant_type": "refresh_token",
            "refresh_token": codexRefresh,
        ] as NSDictionary)
        let store = try hostJSON("codex-auth.json")
        let tokens = try XCTUnwrap(store["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, newAccess)
        XCTAssertEqual(tokens["refresh_token"] as? String, "RT-CODEX-ROTATED")
        XCTAssertEqual(tokens["account_id"] as? String, "acct-1")
        XCTAssertEqual(store["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(store["OPENAI_API_KEY"] is NSNull, "Distill's schema requires the key, null included")
        let lastRefresh = try XCTUnwrap((store["last_refresh"] as? String).flatMap(DistillHostCredentialRefresher.parseDate))
        XCTAssertEqual(lastRefresh.timeIntervalSince(now), 0, accuracy: 1)
    }

    func test_codexRenewalForAnotherAccountIsRefusedAndTheFileKept() async throws {
        try writeCodex(accessExpiresIn: 60)
        let before = try snapshot("codex-auth.json")
        let endpoint = TokenEndpoint()
        endpoint.respond(status: 200, [
            "id_token": idToken(account: "acct-OTHER"), "access_token": "AT-OTHER", "refresh_token": "RT-OTHER",
        ])

        _ = await assertThrows(.accountChanged(.chatgpt)) {
            try await self.refresher(endpoint).prepare(provider: .chatgpt)
        }
        try assertUntouched("codex-auth.json", before)
    }

    func test_codexReusedTokenIsAPermanentRejection() async throws {
        try writeCodex(accessExpiresIn: 60)
        let before = try snapshot("codex-auth.json")
        let endpoint = TokenEndpoint()
        endpoint.respond(status: 400, ["error": ["code": "refresh_token_reused", "message": codexRefresh]])

        let error = await assertThrows(.refreshRejected(.chatgpt, status: 400, code: "refresh_token_reused")) {
            try await self.refresher(endpoint).prepare(provider: .chatgpt)
        }
        try assertUntouched("codex-auth.json", before)
        XCTAssertFalse(error?.errorDescription?.contains(codexRefresh) ?? true)
    }

    // MARK: Grok (not renewed in v1)

    private func writeGrok(expiresIn: TimeInterval?) throws {
        var entry: [String: Any] = [
            "key": "AT-GROK", "auth_mode": "oidc", "user_id": "u",
            "create_time": iso(now.addingTimeInterval(-3600)), "refresh_token": "RT-GROK",
        ]
        if let expiresIn { entry["expires_at"] = iso(now.addingTimeInterval(expiresIn)) }
        try writeHost("auth.json", ["https://auth.x.ai::u": entry])
    }

    func test_grokLoginAboutToExpireFailsPreflightAndTellsTheUserHowToRenewIt() async throws {
        try writeGrok(expiresIn: 10 * 60)
        let endpoint = TokenEndpoint()
        let before = try snapshot("auth.json")

        let error = await assertThrows(.grokLoginExpiring(expiresAt: DistillHostCredentialRefresher.parseDate(iso(now.addingTimeInterval(600)))!)) {
            try await self.refresher(endpoint).prepare(model: "grok-4.6", hostConfig: "")
        }
        let message = try XCTUnwrap(error?.errorDescription)
        XCTAssertTrue(message.contains("Grok login on this Mac"), message)
        XCTAssertTrue(message.contains("distill login"), message)
        XCTAssertEqual(endpoint.requests.count, 0, "Grok is never refreshed by the app in v1")
        try assertUntouched("auth.json", before)
    }

    func test_grokLoginWithTimeLeftOrAnAPIKeyPasses() async throws {
        let endpoint = TokenEndpoint()
        try writeGrok(expiresIn: 5 * 3600)
        try await refresher(endpoint).prepare(provider: .grok)
        // No expires_at: Distill's default lifetime from create_time (30 days).
        try writeGrok(expiresIn: nil)
        try await refresher(endpoint).prepare(provider: .grok)
        try writeHost("auth.json", ["xai::api_key": ["key": "XAI-KEY"]])
        try await refresher(endpoint).prepare(provider: .grok)
        XCTAssertEqual(endpoint.requests.count, 0)
    }

    // MARK: Formats

    func test_readsEveryDateFormChronoWrites() {
        for text in ["2026-10-06T13:20:39.039343Z", "2026-10-06T13:20:39.123456789Z", "2026-10-06T13:20:39Z",
                     "2026-10-06T13:20:39.5+00:00"] {
            XCTAssertNotNil(DistillHostCredentialRefresher.parseDate(text), text)
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000.25)
        XCTAssertEqual(DistillHostCredentialRefresher.parseDate(DistillHostCredentialRefresher.formatDate(date))!
            .timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
}
