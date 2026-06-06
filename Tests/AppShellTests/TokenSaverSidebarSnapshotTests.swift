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

    func test_paidTokenSaverSidebarRendersSavingsPanelOffscreen() throws {
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
