import XCTest
import AppKit
import SwiftUI
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

@MainActor
final class InsomniaSidebarTests: XCTestCase {
    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        var activateReasons: [String] = []
        var activateOptions: [InsomniaPowerOptions] = []
        var deactivateCount = 0
        var shouldActivate = true

        func activate(reason: String, options: InsomniaPowerOptions) -> Bool {
            activateReasons.append(reason)
            activateOptions.append(options)
            return shouldActivate
        }

        func deactivate() {
            deactivateCount += 1
        }

        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?
        var startCount = 0
        var stopCount = 0

        init(powerState: ExternalPowerState = .externalPower) {
            self.currentPowerState = powerState
        }

        func start() {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }

        @MainActor
        func send(_ state: ExternalPowerState) {
            currentPowerState = state
            onPowerStateChanged?(state)
        }
    }

    private final class DownloadProbe {
        var started = false
    }

    private func make(
        dir: String = NSTemporaryDirectory() + "RC2Insomnia-" + UUID().uuidString,
        seedSettings: AppSettings? = nil,
        power: FakeInsomniaPowerManager = FakeInsomniaPowerManager(),
        powerMonitor: ExternalPowerMonitoring = FakeExternalPowerMonitor(),
        insomniaBatteryPrompt: @escaping SidebarViewModel.InsomniaBatteryPrompt = { .keepEnabled },
        tokenSaverModelValidationProvider: SidebarViewModel.TokenSaverModelValidationProvider? = nil,
        tokenSaverModelDownloadHandler: SidebarViewModel.TokenSaverModelDownloadHandler? = nil,
        tokenSaverDownloadConfirmProvider: SidebarViewModel.TokenSaverDownloadConfirmProvider? = { _, _ in true },
        operationErrorPresenter: @escaping SidebarViewModel.OperationErrorPresenter = { _, _ in }
    ) throws -> (AppContext, AppCommandRouter, SidebarViewModel, FakeInsomniaPowerManager) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        if let seedSettings {
            SettingsStore(db: ctx.db).save(seedSettings)
        }
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            insomniaPower: power,
            powerMonitor: powerMonitor,
            insomniaBatteryPrompt: insomniaBatteryPrompt,
            tokenSaverModelValidationProvider: tokenSaverModelValidationProvider,
            tokenSaverModelDownloadHandler: tokenSaverModelDownloadHandler,
            tokenSaverDownloadConfirmProvider: tokenSaverDownloadConfirmProvider,
            operationErrorPresenter: operationErrorPresenter
        )
        return (ctx, router, vm, power)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func writeTinyTokenSaverModel(
        installer: TokenSaverModelInstaller,
        revision: String = "ui-rev-test"
    ) throws -> TokenSaverModelManifest {
        let fileURL = installer.modelStorageDirectory(revision: revision)
            .appendingPathComponent("model.safetensors")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data("mlx-ui-weights".utf8)
        try data.write(to: fileURL)
        let relativePath = [
            "Models",
            TokenSaverModelInstaller.safePathComponent(installer.approvedModel.id),
            revision,
            "model.safetensors"
        ].joined(separator: "/")
        let manifest = TokenSaverModelManifest(
            modelID: installer.approvedModel.id,
            modelURL: installer.approvedModel.url,
            revision: revision,
            runtime: installer.approvedModel.runtime,
            files: [
                TokenSaverModelFile(
                    relativePath: relativePath,
                    sha256: try TokenSaverModelInstaller.sha256Hex(url: fileURL),
                    sizeBytes: Int64(data.count)
                )
            ]
        )
        try installer.writeManifest(manifest)
        return manifest
    }

    private func writeTinyRequiredModels(installer: TokenSaverModelInstaller) throws {
        var manifests: [TokenSaverRequiredModelInstallManifest] = []
        for model in installer.requiredAuxiliaryModels {
            let fileURL = installer.encoderStorageDirectory(modelID: model.id, revision: model.revision)
                .appendingPathComponent("model.safetensors")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data("encoder-ui-\(model.id)".utf8)
            try data.write(to: fileURL)
            let relativePath = [
                "Encoders",
                TokenSaverModelInstaller.safePathComponent(model.id),
                model.revision,
                "model.safetensors"
            ].joined(separator: "/")
            manifests.append(TokenSaverRequiredModelInstallManifest(model: model, files: [
                TokenSaverModelFile(
                    relativePath: relativePath,
                    sha256: try TokenSaverModelInstaller.sha256Hex(url: fileURL),
                    sizeBytes: Int64(data.count)
                )
            ]))
        }
        try installer.writeEncoderManifest(TokenSaverRequiredModelsInstallManifest(models: manifests))
    }

    private func savePrivateSession(in ctx: AppContext, subscribed: Bool) {
        let user = PrivateAccountUser(
            daysRemaing: nil,
            daysRemaining: 30,
            email: subscribed ? "paid@example.com" : "unpaid@example.com",
            id: subscribed ? "paid-user" : "unpaid-user",
            subscribed: subscribed
        )
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: user
        ))
    }

    func test_defaultInactiveWhenUserHasNotChangedToggle() throws {
        let (ctx, _, vm, power) = try make()

        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(vm.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "a user with no saved Insomnia choice must launch macOS without asking for an admin password")
        XCTAssertTrue(power.activateReasons.isEmpty,
                      "default inactive Insomnia must not acquire macOS keep-awake assertions on launch")
    }

    func test_tokenSaverEnableRequiresSubscribedAccount() throws {
        let (ctx, _, vm, _) = try make(seedSettings: AppSettings(tokenSaverEnabled: false))

        vm.setTokenSaverEnabled(true)
        XCTAssertFalse(vm.tokenSaverEnabled,
                       "Token Saver must not enable while no paid account is loaded")

        savePrivateSession(in: ctx, subscribed: false)
        vm.reload()
        vm.setTokenSaverEnabled(true)
        XCTAssertFalse(vm.tokenSaverEnabled,
                       "unpaid accounts can see potential savings but must not enable the paid local service")
    }

    func test_tokenSaverPaidEnablePersistsAndReloads() throws {
        let dir = NSTemporaryDirectory() + "RC2TokenSaverOn-" + UUID().uuidString
        let installed: SidebarViewModel.TokenSaverModelValidationProvider = { .installed }
        let (ctx, _, vm, _) = try make(
            dir: dir,
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelValidationProvider: installed
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)

        XCTAssertTrue(vm.tokenSaverEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().tokenSaverEnabled,
                      "paid Token Saver enablement must persist so later launches can start from the verified model")

        let (reloadedCtx, _, reloaded, _) = try make(
            dir: dir,
            tokenSaverModelValidationProvider: installed
        )
        savePrivateSession(in: reloadedCtx, subscribed: true)
        reloaded.reload()
        XCTAssertTrue(reloaded.tokenSaverEnabled)
    }

    func test_tokenSaverPaidEnableOpensModelDownloadWhenManifestMissing() throws {
        let missing: SidebarViewModel.TokenSaverModelValidationProvider = {
            TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        }
        let waitingDownload: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            progress(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: 0,
                expectedBytes: 10,
                statusText: "Waiting"
            ))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let (ctx, _, vm, _) = try make(
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelValidationProvider: missing,
            tokenSaverModelDownloadHandler: waitingDownload
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)

        XCTAssertFalse(vm.tokenSaverEnabled,
                       "paid Token Saver must not persist enabled until the approved MLX model verifies")
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "clicking Enable Token Saver with a missing model must open the download modal")
        XCTAssertEqual(vm.tokenSaverModelDownloadState.phase, .preparing)
        XCTAssertEqual(vm.tokenSaverModelDownloadState.errorMessage, "manifest missing")
    }

    func test_tokenSaverPaidEnableOpensDownloadWhenEncoderBundleMissing() throws {
        let dir = NSTemporaryDirectory() + "RC2TokenSaverEncoderMissing-" + UUID().uuidString
        let installer = TokenSaverModelInstaller(appSupportDirectory: URL(fileURLWithPath: dir, isDirectory: true))
        _ = try writeTinyTokenSaverModel(installer: installer)
        let waitingDownload: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            progress(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: 0,
                expectedBytes: 10,
                statusText: "Waiting"
            ))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let (ctx, _, vm, _) = try make(
            dir: dir,
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelDownloadHandler: waitingDownload
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)

        XCTAssertFalse(vm.tokenSaverEnabled,
                       "paid Token Saver must not persist enabled with only the selected MLX LLM installed")
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "missing BERT/encoder models must open the same activation download path")
        XCTAssertEqual(vm.tokenSaverModelDownloadState.errorMessage, "encoder manifest missing")
        vm.cancelTokenSaverModelDownload()
    }

    func test_tokenSaverPaidEnableDownloadsMissingModelThenPersists() async throws {
        let dir = NSTemporaryDirectory() + "RC2TokenSaverDownload-" + UUID().uuidString
        let installer = TokenSaverModelInstaller(appSupportDirectory: URL(fileURLWithPath: dir, isDirectory: true))
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            progress(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: 4,
                expectedBytes: 14,
                statusText: "Downloading model.safetensors"
            ))
            progress(TokenSaverModelDownloadState(
                phase: .verifying,
                downloadedBytes: 14,
                expectedBytes: 14,
                statusText: "Verifying downloaded model"
            ))
            let manifest = try self.writeTinyTokenSaverModel(installer: installer)
            try self.writeTinyRequiredModels(installer: installer)
            progress(.ready)
            return manifest
        }
        let (ctx, _, vm, _) = try make(
            dir: dir,
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelValidationProvider: { installer.validateInstalledTokenSaverModels() },
            tokenSaverModelDownloadHandler: handler
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)

        let didEnable = await waitUntil { vm.tokenSaverEnabled }
        XCTAssertTrue(didEnable,
                      "paid Token Saver enablement should complete only after the clicked download writes and verifies the approved model manifest")
        XCTAssertFalse(vm.showsTokenSaverModelDownload)
        XCTAssertEqual(vm.tokenSaverModelDownloadState.phase, .ready)
        XCTAssertEqual(installer.validateInstalledTokenSaverModels(), .installed)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().tokenSaverEnabled,
                      "verified first-use model download must persist Token Saver on for future launches")
    }

    func test_tokenSaverEnableKeepsFallbackRunningWhileSelectedModelDownloads() async throws {
        // This exercises the dual-model migration UX (a smaller fallback installed while a
        // larger selected model downloads). It is active on hosts that select a model above the
        // fallback (≥16 GiB select E4B); on smaller hosts the selected model IS the fallback and
        // there is nothing to migrate to, so the path is skipped.
        guard TokenSaverApprovedModels.selected() != TokenSaverApprovedModels.fallbackModel else {
            throw XCTSkip("dual-model migration path requires the selected model to differ from the fallback (host < 16 GiB)")
        }
        let dir = NSTemporaryDirectory() + "RC2TokenSaverFallbackMigration-" + UUID().uuidString
        let fallbackInstaller = TokenSaverModelInstaller(
            appSupportDirectory: URL(fileURLWithPath: dir, isDirectory: true),
            approvedModel: TokenSaverApprovedModels.distill17B
        )
        _ = try writeTinyTokenSaverModel(installer: fallbackInstaller, revision: "fallback-ui-rev")
        try writeTinyRequiredModels(installer: fallbackInstaller)

        let probe = DownloadProbe()
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            probe.started = true
            progress(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: 0,
                expectedBytes: 10,
                statusText: "Downloading selected model"
            ))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let (ctx, _, vm, _) = try make(
            dir: dir,
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelDownloadHandler: handler
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)
        let started = await waitUntil { probe.started }

        XCTAssertTrue(started)
        XCTAssertTrue(vm.tokenSaverEnabled,
                      "a >=16 GiB Mac with an installed 1.7B fallback must keep Token Saver enabled while E4B downloads")
        XCTAssertTrue(SettingsStore(db: ctx.db).load().tokenSaverEnabled)
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "migration must still surface the selected-model download instead of silently staying on fallback")
        vm.cancelTokenSaverModelDownload()
    }

    func test_tokenSaverModelDownloadProgressFractionIsSafeForSwiftUIProgressView() throws {
        let complete = TokenSaverModelDownloadState(
            phase: .downloading,
            downloadedBytes: 24,
            expectedBytes: 12,
            statusText: "Downloading model.safetensors"
        )
        XCTAssertEqual(complete.fractionCompleted, 1,
                       "download progress must be clamped before it is passed into SwiftUI ProgressView")

        let missingTotal = TokenSaverModelDownloadState(
            phase: .preparing,
            downloadedBytes: 4,
            expectedBytes: 0,
            statusText: "Preparing model download"
        )
        XCTAssertNil(missingTotal.fractionCompleted,
                     "unknown or zero download totals must use the indeterminate progress view instead of an invalid value")
    }

    func test_tokenSaverModelDownloadCancelPausesAndDoesNotPersistEnabled() async throws {
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            progress(TokenSaverModelDownloadState(
                phase: .downloading,
                downloadedBytes: 5,
                expectedBytes: 20,
                statusText: "Downloading model.safetensors"
            ))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let (ctx, _, vm, _) = try make(
            seedSettings: AppSettings(tokenSaverEnabled: false),
            tokenSaverModelValidationProvider: {
                TokenSaverModelValidation(state: .missing, reason: "manifest missing")
            },
            tokenSaverModelDownloadHandler: handler
        )
        savePrivateSession(in: ctx, subscribed: true)
        vm.reload()

        vm.setTokenSaverEnabled(true)
        let didStartDownload = await waitUntil { vm.tokenSaverModelDownloadState.phase == .downloading }
        XCTAssertTrue(didStartDownload,
                      "download progress should become visible before a user can pause it")
        vm.cancelTokenSaverModelDownload()

        XCTAssertFalse(vm.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().tokenSaverEnabled)
        XCTAssertFalse(vm.showsTokenSaverModelDownload)
        XCTAssertEqual(vm.tokenSaverModelDownloadState.phase, .paused)
    }

    func test_tokenSaverUsageRefreshesFromProviderTokenUsageEvents() async throws {
        let (ctx, router, vm, _) = try make(seedSettings: AppSettings(tokenSaverEnabled: true))
        let workspaceDir = NSTemporaryDirectory() + "RC2TokenSaverUsageWorkspace-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "usage", cwd: workspaceDir)
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "usage",
            provider: .codex,
            model: "gpt-test"
        )
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .running,
            startedAt: Date()
        )
        try ctx.runRepo.upsert(run)

        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200)),
            thread.id,
            run.id
        )

        let refreshed = await waitUntil { vm.tokenSaverUsageSnapshot.usedTokens == 200 }
        XCTAssertTrue(refreshed,
                      "sidebar Token Saver indicator must refresh when Claude/Codex provider usage is recorded")
        // Provider token-usage events record REAL provider spend only. Savings
        // are measured at compression time and live in the DB ledger — they are
        // never synthesised here from a fixed ratio (the old behavior reported a
        // fabricated 276). usage.json must therefore show zero "saved".
        XCTAssertEqual(vm.tokenSaverUsageSnapshot.measuredSavedTokens, 0,
                       "token-usage events must not fabricate savings from an assumed compression ratio")
        XCTAssertEqual(try ctx.tokenSaverSavingsRepo.summary().totalRuns, 0,
                       "normal provider usage must not create Saved rows unless the thread is in /distill mode or prompt compression actually ran")
        XCTAssertEqual(vm.tokenSaverUsageSnapshot.eligibleRuns, 1)
    }

    func test_tokenSaverActivityRingsRenderCodexUsedProgress() throws {
        let oneThirdBluePixels = try renderedBluePixelCount(codexUsedProgress: 0.33)
        let twoThirdsBluePixels = try renderedBluePixelCount(codexUsedProgress: 0.66)

        XCTAssertGreaterThan(oneThirdBluePixels, 80,
                             "Codex used percentage has data, so the Token Saver chart must render a visible blue used arc")
        XCTAssertGreaterThan(twoThirdsBluePixels, oneThirdBluePixels + 120,
                             "Codex ring must fill from used percentage; 66% used should visibly render more blue arc than 33% used")
    }

    private func renderedBluePixelCount(codexUsedProgress: Double) throws -> Int {
        let view = SidebarRootView.TokenSaverActivityRings(values: .init(
            tokenSaverProgress: 0.2,
            claudeUsedProgress: 0.42,
            codexUsedProgress: codexUsedProgress
        ))
            .frame(width: 104, height: 104)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data)
        else {
            throw XCTSkip("Token Saver activity rings could not render into an image for visual verification")
        }

        var bluePixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.6,
                   color.blueComponent > 0.65,
                   color.blueComponent > color.redComponent + 0.28,
                   color.blueComponent > color.greenComponent + 0.12 {
                    bluePixels += 1
                }
            }
        }
        return bluePixels
    }

    func test_toggleOffPersistsAndReloadsOff() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOff-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: true))

        vm.setInsomniaEnabled(false)

        let disabled = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(disabled.insomniaEnabled, "turning Insomnia off must persist the inactive session")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "turning Insomnia off must release the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertFalse(reloaded.insomniaEnabled)
        XCTAssertTrue(reloadedPower.activateReasons.isEmpty,
                      "a saved off choice must survive relaunch and must not reacquire keep-awake")
    }

    func test_toggleOnPersistsAndReloadsOn() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOn-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaEnabled(true)

        XCTAssertTrue(vm.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "turning Insomnia on must persist the active session")
        XCTAssertEqual(power.activateReasons, ["RemoteCode Insomnia"],
                       "turning Insomnia on must acquire the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertTrue(reloaded.insomniaEnabled)
        XCTAssertEqual(reloadedPower.activateReasons, ["RemoteCode Insomnia"],
                       "a saved on choice must survive relaunch and reacquire keep-awake")
    }

    func test_appCloseDisablesInsomniaAndPreventsRelaunchReactivation() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaClose-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaEnabled(true)
        vm.disableInsomniaForAppClose()

        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "closing the macOS app must persist Insomnia off so keep-awake cannot outlive the app session")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "closing the macOS app must release all Insomnia power assertions")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertFalse(reloaded.insomniaEnabled)
        XCTAssertTrue(reloadedPower.activateReasons.isEmpty,
                      "reopening the app after a normal close must not silently restart Insomnia")
    }

    func test_unpluggingMacBookWhileInsomniaEnabledPromptsAndCanDisable() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (ctx, _, vm, power) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: {
                promptCount += 1
                return .disable
            }
        )

        vm.setInsomniaEnabled(true)
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 1,
                       "unplugging while Insomnia is active must ask before letting a keep-awake session drain battery")
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "choosing Disable Insomnia from the battery warning must persist the safer off state")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "choosing Disable Insomnia from the battery warning must release keep-awake assertions")
    }

    func test_unpluggingMacBookWhileInsomniaEnabledCanKeepSession() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (ctx, _, vm, power) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: {
                promptCount += 1
                return .keepEnabled
            }
        )

        vm.setInsomniaEnabled(true)
        let deactivateCountBeforeWarning = power.deactivateCount
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 1,
                       "unplugging while Insomnia is active must let the user intentionally keep the session on")
        XCTAssertTrue(vm.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "choosing Keep Insomnia On must not silently turn off a requested keep-awake session")
        XCTAssertEqual(power.deactivateCount, deactivateCountBeforeWarning,
                       "choosing Keep Insomnia On must not release the active keep-awake assertion")
    }

    func test_batteryNotificationWhileInsomniaOffDoesNotPrompt() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .externalPower)
        var promptCount = 0
        let (_, _, vm, _) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: {
                promptCount += 1
                return .disable
            }
        )

        monitor.send(.battery)

        XCTAssertEqual(promptCount, 0,
                       "battery warnings must not interrupt users when Insomnia is already off")
        XCTAssertFalse(vm.insomniaEnabled)
    }

    func test_launchingAlreadyOnBatteryDoesNotPromptWithoutUnplugTransition() throws {
        let monitor = FakeExternalPowerMonitor(powerState: .battery)
        var promptCount = 0
        let (_, _, vm, _) = try make(
            seedSettings: AppSettings(insomniaEnabled: false),
            powerMonitor: monitor,
            insomniaBatteryPrompt: {
                promptCount += 1
                return .disable
            }
        )

        vm.setInsomniaEnabled(true)
        monitor.send(.battery)

        XCTAssertEqual(promptCount, 0,
                       "the warning is for an unplug event, not for every refresh while already on battery")
        XCTAssertTrue(vm.insomniaEnabled)
    }

    func test_optionsPersistAndUpdateActiveSession() throws {
        let (ctx, _, vm, power) = try make(seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaAllowDisplaySleep(false)
        vm.setInsomniaAllowSystemSleepWhenDisplayClosed(true)
        vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(false)
        var settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(settings.insomniaAllowDisplaySleep)
        XCTAssertTrue(settings.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertFalse(settings.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertTrue(power.activateOptions.isEmpty,
                      "changing Insomnia options while inactive must persist preferences without starting a session")

        vm.setInsomniaEnabled(true)
        settings = SettingsStore(db: ctx.db).load()
        XCTAssertTrue(settings.insomniaEnabled)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ))

        vm.setInsomniaAllowDisplaySleep(true)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: true,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ), "adjusting options while active must immediately restart the active keep-awake assertion")
    }

    func test_powerAssertionFailurePersistsOff() throws {
        let power = FakeInsomniaPowerManager()
        power.shouldActivate = false
        let (ctx, _, vm, _) = try make(seedSettings: AppSettings(insomniaEnabled: false), power: power)

        vm.setInsomniaEnabled(true)

        let settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(settings.insomniaEnabled,
                       "if macOS refuses the keep-awake assertion, the sidebar must fail loud by returning to off state")
        XCTAssertEqual(power.activateReasons, ["RemoteCode Insomnia"])
    }
}
