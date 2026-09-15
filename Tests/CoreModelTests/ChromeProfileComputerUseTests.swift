import Darwin
import XCTest
@testable import CoreModel

final class ChromeProfileComputerUseTests: XCTestCase {
    func testInstallerUsesPackagedResourcesAndOnlyRegistersItsOwnExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-chrome-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("RemoteCode.app/Contents")
        let resources = contents.appendingPathComponent("Resources/RemoteCode_CoreModel.bundle/ChromeComputerUse")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CoreModel/Resources/ChromeComputerUse")
        for name in ["manifest.json", "background.js"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        let home = root.appendingPathComponent("test-user")
        let executable = contents.appendingPathComponent("MacOS/RemoteCodeDistillService").path
        let installed = try ChromeProfileConnection.install(executable: executable, homeDirectory: home)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent("manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["name"] as? String, "RemoteCode Computer Use")
        let native = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(ChromeProfileConnection.hostName).json")
        let registration = try JSONSerialization.jsonObject(with: Data(contentsOf: native)) as! [String: Any]
        XCTAssertEqual(registration["allowed_origins"] as? [String], ["chrome-extension://\(ChromeProfileConnection.extensionID)/"])
        let wrapper = try String(contentsOfFile: XCTUnwrap(registration["path"] as? String))
        XCTAssertTrue(wrapper.contains(executable))
        XCTAssertTrue(wrapper.contains(ChromeProfileConnection.hostArgument))
    }

    func testBrowserToolsReachProfileBackendWithIndependentSessionIdentity() async throws {
        let recorder = Requests()
        let first = ChromeProfileComputerUseBackend { try recorder.send($0) }
        let second = ChromeProfileComputerUseBackend { try recorder.send($0) }
        let server = ManagedComputerUseMCP(backend: ComputerUseQueuedPassthroughBackend(), browserBackend: first)
        let line = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_open","arguments":{"url":"https://example.test"}}}"#)
        XCTAssertTrue(try XCTUnwrap(line).contains("current_chrome_profile"))
        _ = await first.invoke(name: "browser_snapshot", arguments: [:])
        _ = await second.invoke(name: "browser_open", arguments: ["url": "https://example.test"])
        XCTAssertEqual(recorder.items.count, 3)
        XCTAssertEqual(recorder.items[0]["session"] as? String, recorder.items[1]["session"] as? String)
        XCTAssertNotEqual(recorder.items[0]["session"] as? String, recorder.items[2]["session"] as? String)
        XCTAssertEqual(recorder.items[0]["operation"] as? String, "browser_open")
        let arguments = try XCTUnwrap(recorder.items[0]["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["url"] as? String, "https://example.test")
        let failure = ChromeProfileComputerUseBackend { _ in ["ok": false, "error": "human_activity"] }
        let result = await failure.invoke(name: "browser_act", arguments: ["action": "click", "ref": "old"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("human_activity") == true)
    }

    func testNativeFramingRoundTripsUnicodeAndRejectsOversizedFrames() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { Darwin.close($0) } }
        let deadline = Date().addingTimeInterval(2)
        try ChromeProfileConnection.writeFrame(["id": "one", "text": "Olá 👋"], fd: fds[0], until: deadline)
        let read = try ChromeProfileConnection.readFrame(fd: fds[1], until: deadline)
        XCTAssertEqual(read["text"] as? String, "Olá 👋")
        var oversized = UInt32(ChromeProfileConnection.maximumFrameBytes + 1).littleEndian
        _ = withUnsafeBytes(of: &oversized) { Darwin.write(fds[0], $0.baseAddress, 4) }
        XCTAssertThrowsError(try ChromeProfileConnection.readFrame(fd: fds[1], until: deadline))
        XCTAssertThrowsError(try ChromeProfileConnection.runHost(origin: "chrome-extension://unrelated/"))
    }
}

private final class Requests: @unchecked Sendable {
    let lock = NSLock()
    var items: [[String: Any]] = []
    func send(_ item: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
        return ["ok": true, "mode": "current_chrome_profile"]
    }
}
