import Foundation

/// Renews the Mac's Claude or ChatGPT sign-in before an in-guest run when it
/// would expire soon, and refuses a Grok sign-in that is about to expire.
///
/// The guest's copies have a blank refresh token, so the guest uses the access
/// token until it expires and then fails. The Mac is the only refresher. This
/// mirrors Distill 2.0.31 exactly (`distill-shell/src/claude_auth.rs` refresh_at,
/// `codex_auth.rs` refresh_at): the same endpoint, client id and JSON body, the
/// same sibling `<file>.lock` flock that every Mac Distill process takes, a
/// re-read after the lock in case one of them just refreshed, and a temp +
/// rename write that keeps every other field. On any failure the file is not
/// touched. Token values never reach an error, a log or an argv.
public struct DistillHostCredentialRefresher: Sendable {
    /// A token with less life than this is renewed before the run starts.
    public static let refreshWindow: TimeInterval = 45 * 60
    /// Grok is not renewed here (v1): a login with less than this left fails
    /// preflight. Distill itself stops sending a Grok token 5 minutes early.
    public static let grokMinimumRemaining: TimeInterval = 15 * 60

    static let claudeTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// codex_auth.rs UNKNOWN_EXPIRY_REFRESH_DAYS: an access token without a
    /// readable `exp` counts as fresh this long after `last_refresh`.
    static let codexUnknownExpiryDays: TimeInterval = 8 * 86_400
    /// Grok tokens without `expires_at` live `create_time` + 30 days (model.rs TOKEN_TTL).
    static let grokDefaultLifetime: TimeInterval = 30 * 86_400

    private let hostHome: URL
    private let httpPost: DistillAccounts.HTTPPost
    private let now: @Sendable () -> Date
    private let lockTimeout: TimeInterval

    public init(
        hostHome: URL,
        httpPost: @escaping DistillAccounts.HTTPPost = DistillAccounts.urlSessionPost,
        now: @escaping @Sendable () -> Date = { Date() },
        lockTimeout: TimeInterval = 10
    ) {
        self.hostHome = hostHome
        self.httpPost = httpPost
        self.now = now
        self.lockTimeout = lockTimeout
    }

    /// Run before every guest run, before the credential sync.
    public func prepare(model: String?, hostConfig: String) async throws {
        try await prepare(provider: DistillGuestCredentials.accountProvider(model: model, hostConfig: hostConfig))
    }

    public func prepare(provider: DistillAccountProvider?) async throws {
        switch provider {
        case .claude: try await refreshClaudeIfNeeded()
        case .chatgpt: try await refreshCodexIfNeeded()
        case .grok: try checkGrok()
        case .openrouter, nil: return
        }
    }

    /// The sign-ins `prepare(provider:)` renews itself: Grok is only checked
    /// (its own CLI renews it) and OpenRouter has nothing to renew.
    static let renewedProviders: Set<DistillAccountProvider> = [.claude, .chatgpt]

    /// The sign-ins in `hostHome` that a guest run's main model does not use
    /// (`used`) but its role models can (`[models] worker`, `session_summary`,
    /// `[subagents.models]` ...): those this refresher renews and that are
    /// signed in. The guest cannot renew any of them, so the Mac does. Never
    /// a provider in `used` and never a named account: each credential file
    /// is asked for by one caller only.
    public static func otherSignIns(
        hostHome: URL, excluding used: Set<DistillAccountProvider>
    ) -> [DistillAccountProvider] {
        DistillAccounts.connectedAccounts(home: hostHome)
            .filter { $0.legacy && $0.connected && renewedProviders.contains($0.provider) && !used.contains($0.provider) }
            .map(\.provider)
    }

    // MARK: - Claude (claude_auth.rs:506-580)

    private func refreshClaudeIfNeeded() async throws {
        let provider = DistillAccountProvider.claude
        guard let initial = try readStore(provider) else { throw DistillGuestCredentialError.notSignedIn(provider) }
        if try claudeIsFresh(initial) { return }
        let directory = try openHostDirectory()
        defer { directory.close() }
        let lock = try await AuthFileLock.acquire(directory: directory, provider: provider, timeout: lockTimeout)
        defer { lock.release() }
        // Another process may have refreshed while this one waited for the lock.
        guard var store = try readStore(provider, from: directory) else { throw DistillGuestCredentialError.notSignedIn(provider) }
        if try claudeIsFresh(store) { return }
        guard let refreshToken = nonEmpty(store["refresh_token"]) else {
            throw DistillGuestCredentialError.refreshTokenMissing(provider)
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.claudeClientID,
        ]
        let (data, status) = try await post(Self.claudeTokenURL, body: body, provider: provider)
        guard (200..<300).contains(status) else {
            // A rejected refresh token stays rejected; only 429/5xx can recover.
            if status == 400 || status == 401 {
                throw DistillGuestCredentialError.refreshRejected(provider, status: status, code: Self.errorCode(data))
            }
            throw DistillGuestCredentialError.refreshFailed(provider, status: status, code: Self.errorCode(data))
        }
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = response["access_token"] as? String,
              let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue else {
            throw DistillGuestCredentialError.refreshResponseInvalid(provider)
        }
        store["expires_at"] = Self.formatDate(now().addingTimeInterval(max(0, expiresIn.rounded(.down))))
        let scopes = (response["scope"] as? String)?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        if !scopes.isEmpty { store["scopes"] = scopes }
        // The refresh token rotates: the old one is spent once a new one is issued.
        if let rotated = nonEmpty(response["refresh_token"]) { store["refresh_token"] = rotated }
        store["access_token"] = accessToken
        try writeStore(store, provider, into: directory)
    }

    private func claudeIsFresh(_ store: [String: Any]) throws -> Bool {
        guard nonEmpty(store["access_token"]) != nil else {
            throw DistillGuestCredentialError.notSignedIn(.claude)
        }
        guard let expiresAt = (store["expires_at"] as? String).flatMap(Self.parseDate) else { return false }
        return expiresAt.timeIntervalSince(now()) > Self.refreshWindow
    }

    // MARK: - ChatGPT / Codex (codex_auth.rs:957-1074)

    private func refreshCodexIfNeeded() async throws {
        let provider = DistillAccountProvider.chatgpt
        guard let initial = try readStore(provider) else { throw DistillGuestCredentialError.notSignedIn(provider) }
        if try codexIsFresh(initial) { return }
        let directory = try openHostDirectory()
        defer { directory.close() }
        let lock = try await AuthFileLock.acquire(directory: directory, provider: provider, timeout: lockTimeout)
        defer { lock.release() }
        guard var store = try readStore(provider, from: directory) else { throw DistillGuestCredentialError.notSignedIn(provider) }
        if try codexIsFresh(store) { return }
        guard var tokens = store["tokens"] as? [String: Any] else { return }
        guard let refreshToken = nonEmpty(tokens["refresh_token"]) else {
            throw DistillGuestCredentialError.refreshTokenMissing(provider)
        }
        let priorAccountID = nonEmpty(tokens["account_id"])
            ?? nonEmpty(tokens["id_token"]).flatMap(Self.codexAccountID)
        let body: [String: Any] = [
            "client_id": Self.codexClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        let (data, status) = try await post(Self.codexTokenURL, body: body, provider: provider)
        guard (200..<300).contains(status) else {
            let code = Self.errorCode(data)
            let permanent = status == 401 || [
                "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
            ].contains(code ?? "")
            if permanent {
                throw DistillGuestCredentialError.refreshRejected(provider, status: status, code: code)
            }
            throw DistillGuestCredentialError.refreshFailed(provider, status: status, code: code)
        }
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DistillGuestCredentialError.refreshResponseInvalid(provider)
        }
        if let idToken = response["id_token"] as? String {
            guard Self.jwtPayload(idToken) != nil else {
                throw DistillGuestCredentialError.refreshResponseInvalid(provider)
            }
            let newAccountID = Self.codexAccountID(idToken)
            if let priorAccountID, let newAccountID, priorAccountID != newAccountID {
                throw DistillGuestCredentialError.accountChanged(provider)
            }
            tokens["id_token"] = idToken
            if let accountID = newAccountID ?? priorAccountID { tokens["account_id"] = accountID }
        }
        if let accessToken = response["access_token"] as? String { tokens["access_token"] = accessToken }
        if let rotated = response["refresh_token"] as? String { tokens["refresh_token"] = rotated }
        store["tokens"] = tokens
        store["last_refresh"] = Self.formatDate(now())
        try writeStore(store, provider, into: directory)
    }

    private func codexIsFresh(_ store: [String: Any]) throws -> Bool {
        guard let tokens = store["tokens"] as? [String: Any] else {
            // API-key mode has nothing to renew.
            if nonEmpty(store["OPENAI_API_KEY"]) != nil { return true }
            throw DistillGuestCredentialError.notSignedIn(.chatgpt)
        }
        guard let accessToken = nonEmpty(tokens["access_token"]) else {
            throw DistillGuestCredentialError.notSignedIn(.chatgpt)
        }
        if let exp = (Self.jwtPayload(accessToken)?["exp"] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: exp).timeIntervalSince(now()) > Self.refreshWindow
        }
        guard let lastRefresh = (store["last_refresh"] as? String).flatMap(Self.parseDate) else { return false }
        // The guest applies Distill's 8-day rule to its blank-refresh copy, so
        // the Mac renews within the same window it uses for a known `exp`.
        return now().timeIntervalSince(lastRefresh) < Self.codexUnknownExpiryDays - Self.refreshWindow
    }

    static func codexAccountID(_ idToken: String) -> String? {
        ((jwtPayload(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"]) as? String
    }

    // MARK: - Grok (no refresh in v1)

    private func checkGrok() throws {
        guard let store = try readStore(.grok) else { throw DistillGuestCredentialError.notSignedIn(.grok) }
        // DistillAccounts' rule: the first OAuth scope with a key; `xai::api_key` is a plain key.
        let oauth = store.sorted { $0.key < $1.key }.first { scope, value in
            scope != "xai::api_key" && nonEmpty((value as? [String: Any])?["key"]) != nil
        }?.value as? [String: Any]
        guard let oauth else {
            if nonEmpty((store["xai::api_key"] as? [String: Any])?["key"]) != nil { return }
            throw DistillGuestCredentialError.notSignedIn(.grok)
        }
        let expiresAt = (oauth["expires_at"] as? String).flatMap(Self.parseDate)
            ?? (oauth["create_time"] as? String).flatMap(Self.parseDate)?.addingTimeInterval(Self.grokDefaultLifetime)
        guard let expiresAt else { return }
        if expiresAt.timeIntervalSince(now()) < Self.grokMinimumRemaining {
            throw DistillGuestCredentialError.grokLoginExpiring(expiresAt: expiresAt)
        }
    }

    // MARK: - Files

    private func readStore(_ provider: DistillAccountProvider) throws -> [String: Any]? {
        let directory: PrivateDirectory
        do { directory = try openHostDirectory() }
        catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT { return nil }
        defer { directory.close() }
        return try readStore(provider, from: directory)
    }

    private func readStore(_ provider: DistillAccountProvider, from directory: PrivateDirectory) throws -> [String: Any]? {
        guard directory.entries().contains(provider.credentialFileName) else { return nil }
        guard let data = directory.read(provider.credentialFileName) else {
            throw DistillGuestCredentialError.unreadable(provider)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return nil }
        guard let store = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DistillGuestCredentialError.unreadable(provider)
        }
        return store
    }

    /// Opened before the token request: a refresh token is spent by the
    /// request, so a directory that cannot be written must fail first.
    /// `~/.distill` may be a symlink the user made; it is the user's own.
    private func openHostDirectory() throws -> PrivateDirectory {
        if hostHome.deletingLastPathComponent().lastPathComponent == "accounts" {
            let root = try PrivateDirectory(hostHome.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath(), create: false)
            defer { root.close() }
            let accounts = try root.child("accounts", create: false)
            defer { accounts.close() }
            return try accounts.child(hostHome.lastPathComponent, create: false)
        }
        return try PrivateDirectory(hostHome.resolvingSymlinksInPath(), create: false)
    }

    private func writeStore(
        _ store: [String: Any], _ provider: DistillAccountProvider, into directory: PrivateDirectory
    ) throws {
        guard var data = try? JSONSerialization.data(
            withJSONObject: store, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { throw DistillGuestCredentialError.refreshResponseInvalid(provider) }
        data.append(0x0A)
        try directory.writeAtomically(data, to: provider.credentialFileName)
    }

    private func post(
        _ url: URL, body: [String: Any], provider: DistillAccountProvider
    ) async throws -> (data: Data, status: Int) {
        let json = try JSONSerialization.data(withJSONObject: body)
        do {
            // Not cut by a cancelled caller (Stop while a run prepares): the
            // request spends the refresh token, so its answer must be stored.
            return try await Task { try await httpPost(url, json) }.value
        } catch {
            throw DistillGuestCredentialError.refreshFailed(provider, status: 0, code: nil)
        }
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The OAuth error code (`{"error":"x"}`, `{"error":{"code":"x"}}` or
    /// `{"code":"x"}`), kept only when it looks like a code: the body is never
    /// echoed, since a server could reflect the token back.
    static func errorCode(_ body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let code = (root["error"] as? String)
            ?? ((root["error"] as? [String: Any])?["code"] as? String)
            ?? (root["code"] as? String)
        guard let code, !code.isEmpty, code.count <= 64,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") })
        else { return nil }
        return code
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// chrono's RFC 3339 (`2026-10-06T13:20:39.039343Z`, any fraction or none).
    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Distill's `<file>.lock` (fs2 `lock_exclusive`, i.e. `flock(LOCK_EX)`),
/// waited for without blocking a thread.
private struct AuthFileLock {
    let descriptor: Int32

    static func acquire(directory: PrivateDirectory, provider: DistillAccountProvider, timeout: TimeInterval) async throws -> AuthFileLock {
        let name = "\(provider.credentialFileName).lock"
        let path = "\(directory.path)/\(name)"
        let fd = openat(directory.descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DistillGuestCredentialError.writeFailed(path: path, errno: errno) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
                close(fd)
                throw DistillGuestCredentialError.lockTimeout(provider)
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                close(fd)
                throw error
            }
        }
        return AuthFileLock(descriptor: fd)
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
