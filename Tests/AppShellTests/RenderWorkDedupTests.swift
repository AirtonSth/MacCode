import XCTest
import AppKit
import SwiftUI
import CoreModel
@testable import AppShell

/// SwiftUI work repeated on every publish with no visible change.
@MainActor
final class RenderWorkDedupTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Bots roster identity ink

    /// WHY: the roster observes the whole BotsViewModel, so while a desk thread
    /// streams every visible row asks for its ink ~30x/s. Each miss builds a full
    /// blobatar figure; the ink never changes for the same inputs, so 10 roster
    /// passes over 20 bots must build 20 figures, not 200, and return the same ink.
    func test_rosterIdentityInkIsBuiltOncePerBot() {
        let run = UUID().uuidString
        let hues = ["pink", "coral", "amber", "green", "teal", "sky", "indigo", "violet"]
        let bots = (0..<20).map { i in
            (name: "Ink \(run) \(i)", handle: "ink-\(i)",
             spec: BotBlobatarSpec(hue: .named(hues[i % hues.count])))
        }
        let before = BotsChrome.identityHexComputeCountForTesting
        for _ in 0..<10 {
            for bot in bots {
                XCTAssertEqual(
                    BotsChrome.identityHex(name: bot.name, handle: bot.handle, symbol: bot.spec.token),
                    BotBlobatar.figure(name: bot.name, spec: bot.spec, handle: bot.handle).palette.head,
                    "cached ink must equal the painted avatar head"
                )
            }
        }
        XCTAssertEqual(BotsChrome.identityHexComputeCountForTesting - before, 20)

        // A rename is a new identity, not a stale hit.
        let renamed = BotsChrome.identityHex(name: "Renamed \(run)", handle: "ink-0", symbol: bots[0].spec.token)
        XCTAssertEqual(renamed, BotBlobatar.figure(name: "Renamed \(run)", spec: bots[0].spec, handle: "ink-0").palette.head)
        XCTAssertEqual(BotsChrome.identityHexComputeCountForTesting - before, 21)
    }

    // MARK: - Scheduled Tasks shell host sizing

    /// WHY: the shell host is pinned to all four edges, so AppKit only needs the
    /// SwiftUI minimum. Default sizing options also re-ran intrinsic and max-size
    /// passes on every publish (the 1 Hz active-run refresh included).
    func test_scheduledTasksShellHostOnlyAsksForMinimumSize() throws {
        let shell = try source("Sources/AppShell/MainWindowController.swift")
        let start = try XCTUnwrap(shell.range(of: "private func installScheduledTasksContent()"))
        let rest = shell[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(String(shell[start.lowerBound..<end]).contains("host.sizingOptions = [.minSize]"))
    }

    /// WHY: `[.minSize]` must keep the 980x680 floor the root declares (the
    /// default options enforced it through the intrinsic size, which equals it),
    /// so the main window still cannot shrink the Scheduled Tasks screen.
    func test_scheduledTasksMinSizeOptionKeepsTheLayoutFloor() throws {
        let dir = NSTemporaryDirectory() + "RC2SchedSizing-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = ScheduledTasksViewModel(context: ctx, router: router, loadImmediately: false)

        func mountedFittingSize(_ options: NSHostingSizingOptions) -> NSSize {
            let host = NSHostingView(rootView: ScheduledTasksRootView(vm: vm))
            host.sizingOptions = options
            host.translatesAutoresizingMaskIntoConstraints = false
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 820),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView()
            window.contentView = content
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            window.contentView = nil
            window.close()
            return size
        }

        let standard = mountedFittingSize(.standardBounds)
        let minOnly = mountedFittingSize([.minSize])
        XCTAssertEqual(standard, NSSize(width: 980, height: 680), "precondition: the old floor")
        XCTAssertEqual(minOnly, standard, "dropping intrinsic/max passes must not move the floor")
    }
}
