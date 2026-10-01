import XCTest
import Darwin
@testable import AppShell

@MainActor
final class KeybindingsFileWatcherDescriptorTests: XCTestCase {
    private func openDescriptorCount() -> Int {
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    func test_restartingWatcherDoesNotLeakDescriptors_becauseCancelMustCloseItsOwnFD() throws {
        // WHY: the cancel handler closed `self.fd`, which already pointed at the next
        // watcher's descriptor, so every reopen of Settings leaked one fd and closed the live one.
        let path = NSTemporaryDirectory() + "rc2-keybindings-" + UUID().uuidString + ".json"
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = openDescriptorCount()
        let watcher = KeybindingsFileWatcher()
        for _ in 0..<40 {
            watcher.start(path: path, onChange: {})
        }
        watcher.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(openDescriptorCount(), before, "every cancelled watcher must close exactly its own descriptor")
    }
}
