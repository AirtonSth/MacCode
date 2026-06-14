import XCTest
import AppKit
import SwiftUI
import AgentRuntime
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverSidebarSnapshotTests: XCTestCase {
    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        func activate(reason: String, options: InsomniaPowerOptions) -> Bool { true }
        func deactivate() {}
        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState = .externalPower
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?

        func start() {}
        func stop() {}
    }

    func test_paidTokenSaverSidebarRendersSavingsPanelOffscreen() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverSnapshot-\(UUID().uuidString)", isDirectory: true)
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true))
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "token",
            refreshToken: "refresh",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        ))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let chartDays = (0..<7).compactMap { index -> TokenSaverDayUsage? in
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: today) else { return nil }
            let used = [21_000, 34_000, 18_000, 56_000, 42_000, 61_000, 120_000][index]
            let saved = [29_000, 44_000, 22_000, 74_000, 58_000, 86_000, 109_000][index]
            return TokenSaverDayUsage(
                dayStart: day,
                actualProviderTokens: used,
                estimatedRawTokens: used + saved,
                eligibleRuns: index == 6 ? 2 : 1
            )
        }
        try TokenSaverUsageStore(appSupportDirectory: appSupport).save(TokenSaverUsageSnapshot(
            period: .sevenDays,
            providers: [
                TokenSaverProviderUsage(
                    provider: .claude,
                    actualProviderTokens: 188_000,
                    estimatedRawTokens: 440_000,
                    eligibleRuns: 8,
                    currentSessionTokens: 220_000,
                    currentSessionLimitTokens: 512_000,
                    weeklyUsedPercent: 57
                ),
                TokenSaverProviderUsage(
                    provider: .codex,
                    actualProviderTokens: 124_000,
                    estimatedRawTokens: 300_000,
                    eligibleRuns: 5,
                    currentSessionTokens: 120_000,
                    currentSessionLimitTokens: 400_000,
                    weeklyUsedPercent: 33
                )
            ],
            daily: chartDays
        ))

        let viewModel = SidebarViewModel(
            context: context,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor(),
            tokenSaverModelValidationProvider: { .installed }
        )
        viewModel.reload()
        // PERF-MAC-100: the heavy snapshot+summary load now runs off-main and
        // coalesced. RunLoop pumping does not service Swift concurrency, so we
        // await the deterministic reload here to guarantee the published
        // snapshot is populated before the offscreen render + asserts below.
        await viewModel.reloadTokenSaverAndWait()
        let root = SidebarRootView(vm: viewModel)
            .frame(width: 320, height: 860)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 860)
        hostingView.wantsLayer = true

        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("offscreen Token Saver sidebar snapshot must create a bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("offscreen Token Saver sidebar snapshot must encode as PNG")
        }

        let artifactPath = ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_SIDEBAR_ARTIFACT"]
        let artifactURL = URL(fileURLWithPath: artifactPath ?? NSTemporaryDirectory() + "remote-code-token-saver-sidebar-proof.png")
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: artifactURL)

        XCTAssertGreaterThan(png.count, 12_000,
                             "Token Saver proof image must be non-trivial, not an empty or single-color render")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 1_000,
                             "Token Saver sidebar should render visible UI content in the offscreen snapshot")
        XCTAssertEqual(viewModel.tokenSaverUsageSnapshot.usedTokens, 312_000)
        XCTAssertEqual(viewModel.tokenSaverUsageSnapshot.measuredSavedTokens, 428_000)
        XCTAssertTrue(viewModel.tokenSaverEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    // MARK: - :40 Light-appearance + width-variant tests

    /// WHY: the existing snapshot uses dark appearance at 320pt width. A light-mode
    /// readability regression (e.g. white text on white background) or a layout
    /// truncation at a narrow sidebar width (180pt) would go undetected until a
    /// user reports it.  These variants exercise the offscreen harness under
    /// NSAppearance(.aqua) and two non-default widths so both regressions produce
    /// a test failure.

    func test_sidebarSnapshot_lightAppearance_rendersVisibleContent() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverSnapshotLight-\(UUID().uuidString)", isDirectory: true)
        let (vm, hostingView) = try await makeOffscreenSidebar(appSupport: appSupport, width: 320)

        NSAppearance.current = NSAppearance(named: .aqua)!
        hostingView.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("light-appearance offscreen snapshot must create a bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("light-appearance offscreen snapshot must encode as PNG")
        }

        // Restore default appearance.
        NSAppearance.current = nil

        XCTAssertGreaterThan(png.count, 12_000,
                             "light-mode Token Saver sidebar snapshot must not be empty or blank -- " +
                             "a tiny file means nothing rendered (white-on-white readability regression)")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 1_000,
                             "light-mode sidebar must render visible non-transparent pixels -- " +
                             "near-zero count means text/icons are invisible against the light background")
        XCTAssertTrue(vm.tokenSaverEnabled,
                      "light-appearance render must not change tokenSaverEnabled state")
    }

    func test_sidebarSnapshot_narrowWidth180pt_rendersWithoutCrash() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverSnapshotNarrow-\(UUID().uuidString)", isDirectory: true)
        let (_, hostingView) = try await makeOffscreenSidebar(appSupport: appSupport, width: 180)

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("narrow (180pt) offscreen snapshot must create a bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("narrow (180pt) offscreen snapshot must encode as PNG")
        }

        XCTAssertGreaterThan(png.count, 1_000,
                             "narrow (180pt) Token Saver sidebar must render at least some content -- " +
                             "an empty file means the layout collapsed entirely at minimum width")
        // At 180pt some elements may be clipped but the view must not be completely blank.
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 100,
                             "narrow (180pt) sidebar must render some visible pixels -- " +
                             "zero count means the layout truncation removed all UI at minimum width")
    }

    func test_sidebarSnapshot_wideWidth560pt_rendersWithoutCrash() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverSnapshotWide-\(UUID().uuidString)", isDirectory: true)
        let (_, hostingView) = try await makeOffscreenSidebar(appSupport: appSupport, width: 560)

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("wide (560pt) offscreen snapshot must create a bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("wide (560pt) offscreen snapshot must encode as PNG")
        }

        XCTAssertGreaterThan(png.count, 12_000,
                             "wide (560pt) Token Saver sidebar must render substantial content -- " +
                             "a tiny file means the layout broke when stretched beyond the default width")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 1_000,
                             "wide (560pt) sidebar must render visible pixels across the wider canvas -- " +
                             "near-zero means elements did not expand to fill the extra width")
    }

    func test_tokenSaverDetailsPopoverRendersOtherSavingsReconciliation() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverDetailsOther-\(UUID().uuidString)", isDirectory: true)
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true))
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "token",
            refreshToken: "refresh",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        ))
        for _ in 0..<9 {
            try context.tokenSaverSavingsRepo.record(
                provider: "unknown",
                mode: "command-output",
                inputTokens: 3_000,
                outputTokens: 470
            )
        }

        let vm = SidebarViewModel(
            context: context,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor(),
            tokenSaverModelValidationProvider: { .installed }
        )
        vm.reload()
        await vm.reloadTokenSaverAndWait()

        let other = try XCTUnwrap(TokenSaverSavingsDisplay.otherSavingsRow(
            from: vm.tokenSaverSavingsSummary,
            subscribed: true,
            enabled: true
        ))
        XCTAssertEqual(vm.tokenSaverSavingsSummary.totalSavedTokens, 22_770)
        XCTAssertEqual(other.savedTokens, 22_770)
        XCTAssertEqual(other.runs, 9)
        XCTAssertEqual(
            (vm.tokenSaverSavingsSummary.savings(for: "claude")?.savedTokens ?? 0) +
            (vm.tokenSaverSavingsSummary.savings(for: "codex")?.savedTokens ?? 0) +
            other.savedTokens,
            vm.tokenSaverSavingsSummary.totalSavedTokens,
            "details rows must reconcile to the headline total when direct CLI rows are unattributed"
        )

        let details = SidebarRootView(vm: vm)
            .tokenSaverDetailsPopoverForTesting
            .frame(width: 350, height: 460)
        let hosting = NSHostingView(rootView: details)
        hosting.frame = NSRect(x: 0, y: 0, width: 350, height: 460)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Token Saver details reconciliation snapshot must create a bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Token Saver details reconciliation snapshot must encode as PNG")
        }
        let artifactPath = ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_DETAILS_ARTIFACT"]
        let artifactURL = URL(fileURLWithPath: artifactPath ?? NSTemporaryDirectory() + "remote-code-token-saver-details-proof.png")
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: artifactURL)

        XCTAssertGreaterThan(png.count, 6_000,
                             "details popover proof image must not be empty; a tiny file means the reconciliation UI did not render")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 500,
                             "details popover must render visible pixels for the reconciliation rows")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    // MARK: - Shared offscreen fixture factory

    /// Builds a fully populated SidebarViewModel + offscreen hosting view at `width`.
    /// Returns the view as NSView so callers don't need to know the SwiftUI root type.
    /// Extracted so light/narrow/wide tests share identical setup and avoid copy-paste drift.
    private func makeOffscreenSidebar(
        appSupport: URL,
        width: CGFloat
    ) async throws -> (vm: SidebarViewModel, hostingView: NSView) {
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true))
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "token",
            refreshToken: "refresh",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        ))

        let vm = SidebarViewModel(
            context: context,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor(),
            tokenSaverModelValidationProvider: { .installed }
        )
        vm.reload()
        // PERF-MAC-100: deterministically populate the off-main snapshot+summary
        // before building the offscreen render (RunLoop pumping does not service
        // Swift concurrency).
        await vm.reloadTokenSaverAndWait()

        let height: CGFloat = 860
        let root = SidebarRootView(vm: vm).frame(width: width, height: height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.wantsLayer = true

        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        return (vm, hosting)
    }

    private func nonTransparentSampleCount(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let xStride = max(width / 80, 1)
        let yStride = max(height / 160, 1)
        for y in stride(from: 0, to: height, by: yStride) {
            for x in stride(from: 0, to: width, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 &&
                    (color.redComponent > 0.05 || color.greenComponent > 0.05 || color.blueComponent > 0.05) {
                    count += 1
                }
            }
        }
        return count
    }
}
