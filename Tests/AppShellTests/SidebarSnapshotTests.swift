import XCTest
import AppKit
import SwiftUI
import AgentRuntime
import Persistence
@testable import AppShell

@MainActor
final class SidebarSnapshotTests: XCTestCase {
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

    func test_sidebarSnapshot_lightAppearance_rendersVisibleContent() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2SidebarSnapshotLight-\(UUID().uuidString)", isDirectory: true)
        let (_, hostingView) = try await makeOffscreenSidebar(appSupport: appSupport, width: 320)

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
                             "light-mode sidebar snapshot must not be empty or blank -- " +
                             "a tiny file means nothing rendered (white-on-white readability regression)")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 1_000,
                             "light-mode sidebar must render visible non-transparent pixels -- " +
                             "near-zero count means text/icons are invisible against the light background")
    }

    func test_sidebarSnapshot_narrowWidth180pt_rendersWithoutCrash() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2SidebarSnapshotNarrow-\(UUID().uuidString)", isDirectory: true)
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
                             "narrow (180pt) sidebar must render at least some content -- " +
                             "an empty file means the layout collapsed entirely at minimum width")
        // At 180pt some elements may be clipped but the view must not be completely blank.
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 100,
                             "narrow (180pt) sidebar must render some visible pixels -- " +
                             "zero count means the layout truncation removed all UI at minimum width")
    }

    func test_sidebarSnapshot_wideWidth560pt_rendersWithoutCrash() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2SidebarSnapshotWide-\(UUID().uuidString)", isDirectory: true)
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
                             "wide (560pt) sidebar must render substantial content -- " +
                             "a tiny file means the layout broke when stretched beyond the default width")
        XCTAssertGreaterThan(nonTransparentSampleCount(in: bitmap), 1_000,
                             "wide (560pt) sidebar must render visible pixels across the wider canvas -- " +
                             "near-zero means elements did not expand to fill the extra width")
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
            powerMonitor: FakeExternalPowerMonitor()
        )
        vm.reload()
        // Deterministically populate the off-main account-usage snapshot before
        // building the offscreen render (RunLoop pumping does not service
        // Swift concurrency).
        await vm.reloadAccountUsageAndWait()

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
