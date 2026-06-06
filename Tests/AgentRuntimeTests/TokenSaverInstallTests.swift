import XCTest
import CoreModel
@testable import AgentRuntime

final class TokenSaverInstallTests: XCTestCase {
    private final class URLProtocolStub: URLProtocol {
        typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
        static var handler: Handler?
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()

            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (status, headers, data) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        static func withHandler<T>(
            _ handler: @escaping Handler,
            run: () async throws -> T
        ) async rethrows -> T {
            lock.lock()
            Self.handler = handler
            lock.unlock()
            defer {
                lock.lock()
                Self.handler = nil
                lock.unlock()
            }
            return try await run()
        }
    }

    private final class DownloadTestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _phases: [TokenSaverModelDownloadPhase] = []
        private var _rangeHeaders: [String?] = []

        func appendPhase(_ phase: TokenSaverModelDownloadPhase) {
            lock.lock()
            _phases.append(phase)
            lock.unlock()
        }

        func appendRangeHeader(_ header: String?) {
            lock.lock()
            _rangeHeaders.append(header)
            lock.unlock()
        }

        var phases: [TokenSaverModelDownloadPhase] {
            lock.lock()
            defer { lock.unlock() }
            return _phases
        }

        var rangeHeaders: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return _rangeHeaders
        }
    }

    private final class MutableDate: @unchecked Sendable {
        var value: Date

        init(_ value: Date) {
            self.value = value
        }
    }

    private func tempDir(_ name: String = "TokenSaverInstall") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    func test_agentSkillInstallerWritesClaudeAndCodexSkillsOnlyUnderAppSupport() throws {
        let appSupport = tempDir()
        let installer = AgentSkillInstaller(appSupportDirectory: appSupport)
        let date = Date(timeIntervalSince1970: 1_783_000_000)

        let codex = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a", installedAt: date)
        let claude = try installer.installDistillSkill(for: .claude, sourceRevision: "rev-a", installedAt: date)

        XCTAssertEqual(codex.action, .installed)
        XCTAssertEqual(claude.action, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("AgentSkills/codex/distill/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("AgentSkills/claude/distill/SKILL.md").path))
        XCTAssertTrue(codex.manifest.installPath.hasPrefix(appSupport.path),
                      "managed skills must stay scoped to RemoteCode app support instead of provider global config")
        XCTAssertTrue(claude.manifest.installPath.hasPrefix(appSupport.path))
        XCTAssertEqual(codex.manifest.sourceURL, AgentSkillInstaller.distillSourceURL)
        XCTAssertEqual(claude.manifest.sourceRevision, "rev-a")

        let codexText = try String(contentsOf: URL(fileURLWithPath: codex.manifest.installPath))
        XCTAssertTrue(codexText.contains("/distill"))
        XCTAssertTrue(codexText.contains("S=state"))
        XCTAssertFalse(codex.manifest.installPath.contains(".codex"))
        XCTAssertFalse(claude.manifest.installPath.contains(".claude"))
    }

    func test_agentSkillInstallerIsIdempotentForSameRevisionAndChecksum() throws {
        let appSupport = tempDir()
        let installer = AgentSkillInstaller(appSupportDirectory: appSupport)

        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        let second = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")

        XCTAssertEqual(second.action, .skipped,
                       "relaunch should not rewrite managed skill files when version and checksum are unchanged")
    }

    func test_modelInstallerRequiresApprovedManifestAndChecksums() throws {
        let appSupport = tempDir()
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)

        XCTAssertEqual(installer.validateInstalledModel().state, .missing)

        let modelFile = installer.distillDirectory.appendingPathComponent("weights.bin")
        try FileManager.default.createDirectory(at: installer.distillDirectory, withIntermediateDirectories: true)
        try Data("mlx-weights".utf8).write(to: modelFile)
        let checksum = try TokenSaverModelInstaller.sha256Hex(url: modelFile)
        let manifest = TokenSaverModelManifest(
            revision: "commit-sha",
            files: [TokenSaverModelFile(relativePath: "weights.bin", sha256: checksum, sizeBytes: 11)]
        )
        try installer.writeManifest(manifest)

        XCTAssertEqual(installer.validateInstalledModel(), .installed,
                       "Token Saver must not start the sidecar until the approved MLX model manifest and file checksum pass")

        try Data("tampered".utf8).write(to: modelFile)
        XCTAssertEqual(installer.validateInstalledModel().state, .incomplete)
    }

    func test_modelDownloaderFetchesHuggingFaceSnapshotAndResumesPartialFiles() async throws {
        let appSupport = tempDir()
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
        let revision = "rev-test"
        let storedModel = installer.distillDirectory
            .appendingPathComponent("Models")
            .appendingPathComponent("samuelfaj__distill-1.7B-4bit-MLX")
            .appendingPathComponent(revision)
            .appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(at: storedModel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("part1".utf8).write(to: storedModel.appendingPathExtension("partial"))

        let api = """
        {"id":"samuelfaj/distill-1.7B-4bit-MLX","sha":"\(revision)","siblings":[
          {"rfilename":".gitattributes"},
          {"rfilename":"config.json"},
          {"rfilename":"model.safetensors"}
        ]}
        """
        let recorder = DownloadTestRecorder()

        let manifest = try await URLProtocolStub.withHandler({ request in
            let path = request.url?.path ?? ""
            if path.contains("/api/models/") {
                return (200, ["Content-Length": "\(api.utf8.count)"], Data(api.utf8))
            }
            if path.hasSuffix("/config.json") {
                return (200, ["Content-Length": "11"], Data(#"{"ok":true}"#.utf8))
            }
            if path.hasSuffix("/model.safetensors") {
                recorder.appendRangeHeader(request.value(forHTTPHeaderField: "Range"))
                return (206, ["Content-Length": "5"], Data("part2".utf8))
            }
            return (404, [:], Data())
        }, run: {
            try await TokenSaverModelDownloader(
                installer: installer,
                session: stubbedSession()
            ).downloadApprovedModel { state in
                recorder.appendPhase(state.phase)
            }
        })

        XCTAssertEqual(manifest.revision, revision)
        XCTAssertEqual(manifest.files.count, 2,
                       "hidden Hugging Face metadata files should not become required local MLX model files")
        XCTAssertEqual(installer.validateInstalledModel(), .installed)
        XCTAssertEqual(try String(contentsOf: storedModel), "part1part2")
        XCTAssertEqual(recorder.rangeHeaders, ["bytes=5-"],
                       "partial model data must resume with an HTTP Range request instead of restarting from zero")
        XCTAssertTrue(recorder.phases.contains(.downloading))
        XCTAssertTrue(recorder.phases.contains(.verifying))
        XCTAssertTrue(recorder.phases.contains(.ready))
    }

    func test_usageStorePersistsCountersWithoutRawText() throws {
        let appSupport = tempDir()
        let store = TokenSaverUsageStore(appSupportDirectory: appSupport)
        let snapshot = TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(provider: .claude, actualProviderTokens: 400, estimatedRawTokens: 1_000, eligibleRuns: 2),
            TokenSaverProviderUsage(provider: .codex, actualProviderTokens: 250, estimatedRawTokens: 700, eligibleRuns: 1)
        ])

        try store.save(snapshot)
        let reloaded = store.load()

        XCTAssertEqual(reloaded.usedTokens, 650)
        XCTAssertEqual(reloaded.measuredSavedTokens, 1_050)
        XCTAssertEqual(reloaded.eligibleRuns, 3)
        XCTAssertEqual(TokenSaverUsageStore.estimatePotentialSavings(usedTokens: 1_000, compressionRatio: 0.4), 600)
    }

    func test_usageStoreAggregatesProviderTokenEventsWithoutRawText() throws {
        let appSupport = tempDir()
        let store = TokenSaverUsageStore(appSupportDirectory: appSupport)

        _ = try store.record(provider: .claude, actualProviderTokens: 420, estimatedRawTokens: 1_000)
        let updated = try store.record(provider: .claude, actualProviderTokens: 80, estimatedRawTokens: 120)

        let claude = try XCTUnwrap(updated.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.actualProviderTokens, 500)
        XCTAssertEqual(claude.estimatedRawTokens, 1_120)
        XCTAssertEqual(claude.eligibleRuns, 2)
        XCTAssertEqual(updated.measuredSavedTokens, 620)
    }

    func test_usageStorePersistsCurrentSessionLimitTelemetryWithoutRawText() throws {
        let appSupport = tempDir()
        let store = TokenSaverUsageStore(appSupportDirectory: appSupport)

        _ = try store.record(
            provider: .codex,
            actualProviderTokens: 740,
            estimatedRawTokens: 1_100,
            currentSessionTokens: 740,
            currentSessionLimitTokens: 1_000
        )
        let updated = try store.record(
            provider: .codex,
            actualProviderTokens: 20,
            estimatedRawTokens: 40,
            currentSessionTokens: 120,
            currentSessionLimitTokens: 1_000
        )

        let codex = try XCTUnwrap(updated.providers.first { $0.provider == .codex })
        XCTAssertEqual(codex.currentSessionTokens, 740,
                       "Token Saver rings must preserve the highest current-session pressure so the UI can switch at 70%")
        XCTAssertEqual(codex.currentSessionLimitTokens, 1_000)
        XCTAssertEqual(store.load().providers.first { $0.provider == .codex }?.currentSessionLimitTokens, 1_000)
    }

    func test_usageStorePersistsWeeklyAccountLimitPercentagesWithoutRawText() throws {
        let appSupport = tempDir()
        let store = TokenSaverUsageStore(appSupportDirectory: appSupport)

        _ = try store.record(provider: .claude, actualProviderTokens: 400, estimatedRawTokens: 1_000)
        let updated = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 57,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_783_036_800)
        )

        let claude = try XCTUnwrap(updated.providers.first { $0.provider == .claude })
        XCTAssertEqual(claude.actualProviderTokens, 400,
                       "account usage refresh must not double-count prompt tokens")
        XCTAssertEqual(claude.weeklyUsedPercent, 57)
        XCTAssertEqual(claude.weeklyRemainingPercent, 43)
        XCTAssertEqual(claude.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(store.load().providers.first { $0.provider == .claude }?.weeklyUsedPercent, 57)
    }

    func test_usageStoreRecordsSevenDayChartBucketsWithoutRawText() throws {
        let appSupport = tempDir()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let clock = MutableDate(Date(timeIntervalSince1970: 1_783_036_800))
        let store = TokenSaverUsageStore(
            appSupportDirectory: appSupport,
            calendar: calendar,
            now: { clock.value }
        )

        _ = try store.record(provider: .claude, actualProviderTokens: 100, estimatedRawTokens: 250)
        _ = try store.record(provider: .codex, actualProviderTokens: 40, estimatedRawTokens: 100)
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        let updated = try store.record(provider: .claude, actualProviderTokens: 80, estimatedRawTokens: 200)

        XCTAssertEqual(updated.daily.count, 2,
                       "the active sidebar chart needs real daily buckets for the last 7 days, not a text-only aggregate")
        XCTAssertEqual(updated.daily[0].actualProviderTokens, 140)
        XCTAssertEqual(updated.daily[0].measuredSavedTokens, 210)
        XCTAssertEqual(updated.daily[1].actualProviderTokens, 80)
        XCTAssertEqual(updated.daily[1].measuredSavedTokens, 120)
        XCTAssertEqual(store.load().daily, updated.daily)
    }
}
