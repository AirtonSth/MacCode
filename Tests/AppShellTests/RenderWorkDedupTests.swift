import XCTest
import CoreModel
@testable import AppShell

/// SwiftUI work repeated on every publish with no visible change.
@MainActor
final class RenderWorkDedupTests: XCTestCase {
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
}
