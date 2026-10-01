import XCTest
@testable import AgentRuntime

final class DistillAccountsTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var log: URL!
    private var pidFile: URL!
    private var script: URL!

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillAccountsTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        log = root.appendingPathComponent("argv.log")
        pidFile = root.appendingPathComponent("pid")
        script = root.appendingPathComponent("distill")
        let body = """
        #!/bin/sh
        echo "argv: $*" >> "$FAKE_LOG"
        echo "home: $DISTILL_HOME" >> "$FAKE_LOG"
        if [ "$FAKE_MODE" = fail ]; then
          echo "noise" >&2; echo "boom: no browser   " >&2; echo "" >&2; exit 3
        fi
        if [ "$1" = login ]; then
          echo "Signing in..." >&2
          echo "  https://example.com/auth?x=1" >&2
          echo "  https://example.com/second" >&2
          if [ "$FAKE_MODE" = hang ]; then echo $$ > "$FAKE_PID"; exec sleep 30; fi
        fi
        case "$*" in
          "login") echo '{"https://accounts.x.ai/sign-in":{"key":"k"}}' > "$DISTILL_HOME/auth.json";;
          "login --chatgpt") echo '{"tokens":{"access_token":"t"}}' > "$DISTILL_HOME/codex-auth.json";;
          "login --claude") echo '{"access_token":"t"}' > "$DISTILL_HOME/claude-auth.json";;
          "logout") rm -f "$DISTILL_HOME/auth.json";;
          "logout --chatgpt") rm -f "$DISTILL_HOME/codex-auth.json";;
          "logout --claude") rm -f "$DISTILL_HOME/claude-auth.json";;
        esac
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeAccounts(
        mode: String = "ok",
        openURL: @escaping @Sendable (URL) -> Void = { _ in },
        httpPost: @escaping DistillAccounts.HTTPPost = { _, _ in (Data(), 500) },
        callbackTimeout: TimeInterval = 300
    ) -> DistillAccounts {
        DistillAccounts(
            home: home,
            binaryPath: script.path,
            environment: [
                "PATH": "/usr/bin:/bin", "FAKE_MODE": mode,
                "FAKE_LOG": log.path, "FAKE_PID": pidFile.path,
            ],
            openURL: openURL,
            httpPost: httpPost,
            callbackTimeout: callbackTimeout)
    }

    private func logLines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func write(_ json: String, to name: String) throws {
        try json.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func connected(_ accounts: DistillAccounts) -> [DistillAccountProvider: Bool] {
        Dictionary(uniqueKeysWithValues: accounts.statuses().map { ($0.provider, $0.connected) })
    }

    // MARK: statuses

    func test_statuses_missingFilesAreDisconnectedInAllCasesOrder() {
        let statuses = makeAccounts().statuses()
        XCTAssertEqual(statuses.map(\.provider), DistillAccountProvider.allCases)
        XCTAssertTrue(statuses.allSatisfy { !$0.connected })
    }

    func test_statuses_emptyOrBlankCredentialsAreDisconnected() throws {
        try write("", to: "auth.json")
        try write(#"{"tokens":{"access_token":"  "}}"#, to: "codex-auth.json")
        try write(#"{"access_token":""}"#, to: "claude-auth.json")
        try write(#"{"key":" "}"#, to: "openrouter-auth.json")
        XCTAssertTrue(connected(makeAccounts()).values.allSatisfy { !$0 })
    }

    func test_statuses_corruptAndApiKeyOnlyGrokAreDisconnected() throws {
        try write("not json", to: "auth.json")
        XCTAssertEqual(connected(makeAccounts())[.grok], false)
        try write(#"{"xai::api_key":{"key":"xai-123"}}"#, to: "auth.json")
        XCTAssertEqual(connected(makeAccounts())[.grok], false)
    }

    func test_statuses_validFilesAreConnected() throws {
        try write(#"{"xai::api_key":{"key":"ignored"},"https://accounts.x.ai/sign-in":{"key":"k","email":"grok@example.com"}}"#, to: "auth.json")
        try write(#"{"tokens":{"access_token":"t"}}"#, to: "codex-auth.json")
        try write(#"{"access_token":"t","email":"claude@example.com"}"#, to: "claude-auth.json")
        try write(#"{"key":"sk-or"}"#, to: "openrouter-auth.json")
        let statuses = makeAccounts().statuses()
        XCTAssertTrue(statuses.allSatisfy(\.connected))
        XCTAssertEqual(statuses.first { $0.provider == .grok }?.email, "grok@example.com")
        XCTAssertEqual(statuses.first { $0.provider == .claude }?.email, "claude@example.com")
        XCTAssertNil(statuses.first { $0.provider == .chatgpt }?.email)
        XCTAssertNil(statuses.first { $0.provider == .openrouter }?.email)
    }

    // MARK: CLI login / logout

    func test_login_runsProviderArgvWithDistillHomeAndReportsFirstURL() async throws {
        let expected: [(DistillAccountProvider, String)] = [
            (.grok, "login"), (.chatgpt, "login --chatgpt"), (.claude, "login --claude"),
        ]
        for (provider, argv) in expected {
            try? FileManager.default.removeItem(at: log)
            let urls = Box<URL>()
            let accounts = makeAccounts()
            try await accounts.login(provider) { urls.add($0) }
            XCTAssertEqual(logLines(), ["argv: \(argv)", "home: \(home.path)"], "\(provider)")
            XCTAssertEqual(urls.all.map(\.absoluteString), ["https://example.com/auth?x=1"], "\(provider)")
            XCTAssertEqual(connected(accounts)[provider], true, "\(provider)")
        }
    }

    func test_logout_runsProviderArgvAndRemovesOnlyThatProvider() async throws {
        try write(#"{"https://accounts.x.ai/sign-in":{"key":"k"}}"#, to: "auth.json")
        try write(#"{"tokens":{"access_token":"t"}}"#, to: "codex-auth.json")
        try write(#"{"access_token":"t"}"#, to: "claude-auth.json")
        let accounts = makeAccounts()
        try await accounts.logout(.chatgpt)
        XCTAssertEqual(logLines(), ["argv: logout --chatgpt", "home: \(home.path)"])
        XCTAssertEqual(connected(accounts)[.chatgpt], false)
        XCTAssertEqual(connected(accounts)[.grok], true)
        XCTAssertEqual(connected(accounts)[.claude], true)
        try await accounts.logout(.claude)
        try await accounts.logout(.grok)
        XCTAssertEqual(logLines().filter { $0.hasPrefix("argv:") },
                       ["argv: logout --chatgpt", "argv: logout --claude", "argv: logout"])
        XCTAssertTrue(connected(accounts).values.allSatisfy { !$0 })
    }

    func test_login_failureUsesLastNonEmptyStderrLine() async {
        do {
            try await makeAccounts(mode: "fail").login(.claude) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .failed("boom: no browser"))
        }
    }

    func test_logout_failureUsesLastNonEmptyStderrLine() async {
        do {
            try await makeAccounts(mode: "fail").logout(.grok)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .failed("boom: no browser"))
        }
    }

    func test_login_cancellationTerminatesChildAndThrowsCancelled() async throws {
        let accounts = makeAccounts(mode: "hang")
        let task = Task { try await accounts.login(.chatgpt) { _ in } }
        let pid = try await waitForPID()
        XCTAssertEqual(kill(pid, 0), 0, "child should be running before cancel")
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .cancelled)
        }
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "child must be terminated")
    }

    private func waitForPID() async throws -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("fake child never started")
    }

    // MARK: OpenRouter

    func test_pkceChallenge_isBase64URLOfSHA256WithoutPadding() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            DistillAccounts.pkceChallenge(verifier: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let challenge = DistillAccounts.pkceChallenge(verifier: "any verifier")
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertEqual(challenge.count, 43)
    }

    private func callbackURL(from url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "callback_url" }?.value.flatMap(URL.init(string:))
    }

    func test_openRouterLogin_endToEndWritesOwnerOnlyKey() async throws {
        let opened = Box<URL>()
        let posted = Box<Data>()
        let accounts = makeAccounts(
            openURL: { url in
                opened.add(url)
                guard let callback = self.callbackURL(from: url),
                      var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                else { return }
                components.queryItems = [URLQueryItem(name: "code", value: "auth-code")]
                let target = components.url!
                Task { _ = try? await URLSession.shared.data(from: target) }
            },
            httpPost: { url, body in
                XCTAssertEqual(url.absoluteString, "https://openrouter.ai/api/v1/auth/keys")
                posted.add(body)
                return (Data(#"{"key":"sk-or-test"}"#.utf8), 200)
            })
        let reported = Box<URL>()
        try await accounts.login(.openrouter) { reported.add($0) }

        let url = try XCTUnwrap(opened.all.first)
        XCTAssertEqual(reported.all, opened.all)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "openrouter.ai")
        XCTAssertEqual(components.path, "/auth")
        func query(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        XCTAssertEqual(query("code_challenge_method"), "S256")
        XCTAssertEqual(query("key_label"), "Distill")
        let callback = try XCTUnwrap(query("callback_url"))
        XCTAssertTrue(callback.hasPrefix("http://localhost:"), callback)
        XCTAssertTrue(callback.contains("/auth/callback/"), callback)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(posted.all.first)) as? [String: String])
        XCTAssertEqual(body["code"], "auth-code")
        XCTAssertEqual(body["code_challenge_method"], "S256")
        let verifier = try XCTUnwrap(body["code_verifier"])
        XCTAssertEqual(query("code_challenge"), DistillAccounts.pkceChallenge(verifier: verifier))

        let file = home.appendingPathComponent("openrouter-auth.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String]
        XCTAssertEqual(saved, ["key": "sk-or-test"])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(connected(accounts)[.openrouter], true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path)
        XCTAssertEqual(leftovers, ["openrouter-auth.json"])
    }

    func test_openRouterLogin_declinedCallbackFailsWithoutExchangeOrFile() async throws {
        let exchanged = Box<Int>()
        let accounts = makeAccounts(
            openURL: { url in
                guard let callback = self.callbackURL(from: url),
                      var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                else { return }
                components.queryItems = [URLQueryItem(name: "error", value: "access_denied")]
                let target = components.url!
                Task { _ = try? await URLSession.shared.data(from: target) }
            },
            httpPost: { _, _ in exchanged.add(1); return (Data(), 200) })
        do {
            try await accounts.login(.openrouter) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(
                error as? DistillAccountError,
                .failed("OpenRouter authorization was declined. Please try again."))
        }
        XCTAssertTrue(exchanged.all.isEmpty)
        XCTAssertEqual(connected(accounts)[.openrouter], false)
    }

    func test_openRouterLogin_exchangeHTTPErrorFailsAndWritesNothing() async throws {
        let accounts = makeAccounts(
            openURL: { url in
                guard let callback = self.callbackURL(from: url),
                      var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                else { return }
                components.queryItems = [URLQueryItem(name: "code", value: "c")]
                let target = components.url!
                Task { _ = try? await URLSession.shared.data(from: target) }
            },
            httpPost: { _, _ in (Data(), 403) })
        do {
            try await accounts.login(.openrouter) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(
                error as? DistillAccountError,
                .failed("OpenRouter authorization failed (HTTP 403). Please try again."))
        }
        XCTAssertEqual(connected(accounts)[.openrouter], false)
    }

    func test_openRouterLogin_timesOutWhenNoCallbackArrives() async {
        let accounts = makeAccounts(callbackTimeout: 0.2)
        do {
            try await accounts.login(.openrouter) { _ in }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .timedOut)
        }
    }

    func test_openRouterLogin_cancellationThrowsCancelled() async throws {
        let started = Box<URL>()
        let accounts = makeAccounts(openURL: { started.add($0) })
        let task = Task { try await accounts.login(.openrouter) { _ in } }
        let deadline = Date().addingTimeInterval(5)
        while started.all.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(started.all.isEmpty)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? DistillAccountError, .cancelled)
        }
    }

    func test_openRouterLogout_deletesOnlyItsFileAndToleratesMissing() async throws {
        try write(#"{"key":"sk-or"}"#, to: "openrouter-auth.json")
        try write(#"{"access_token":"t"}"#, to: "claude-auth.json")
        let accounts = makeAccounts()
        try await accounts.logout(.openrouter)
        XCTAssertEqual(connected(accounts)[.openrouter], false)
        XCTAssertEqual(connected(accounts)[.claude], true)
        XCTAssertTrue(logLines().isEmpty, "OpenRouter logout must not spawn distill")
        try await accounts.logout(.openrouter)
    }
}
