import XCTest
import CoreModel

final class BotComputerWorkspaceMountSpecTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/tmp/rc-app-support-ws")
    private let token = String(repeating: "a", count: 32)

    private func options(
        _ botID: BotID,
        workspaces: [String],
        registered: Set<String>? = nil,
        userHome: String = "/Users/tester"
    ) throws -> BotComputerContainerCreateOptions {
        try BotComputerGuestSpec.containerCreateOptions(
            botID: botID,
            guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID).path,
            appSupport: support,
            viewerToken: token,
            workspaces: workspaces,
            registeredWorkspaces: registered,
            userHome: userHome
        )
    }

    func test_bindsMountWorkspaceAtTheSamePathAfterGuestHome() throws {
        // WHY: the agent's absolute paths must resolve identically on the Mac and in the VM.
        let botID = BotID()
        let result = try options(botID, workspaces: ["/Users/tester/code/app"], registered: ["/Users/tester/code/app"])
        XCTAssertEqual(result.binds.count, 2)
        XCTAssertTrue(result.binds[0].hasSuffix(":\(BotComputerGuestSpec.guestUserHome)"))
        XCTAssertEqual(result.binds[1], "/Users/tester/code/app:/Users/tester/code/app")
    }

    func test_invalidWorkspacePathsAreRejected() {
        // WHY: mounting home, a parent of home or "/" would expose the whole Mac to the guest.
        let botID = BotID()
        let bad = [
            "relative/path", "/Users/tester/../other", "/Users/tester/./x", "/Users/tester/x/", "/",
            "/Users/tester", "/Users", "",
        ]
        for path in bad {
            XCTAssertThrowsError(try options(botID, workspaces: [path]), path) { error in
                XCTAssertEqual(error as? BotComputerGuestError, .invalidWorkspacePath(path))
            }
        }
        XCTAssertThrowsError(
            try options(botID, workspaces: ["/Users/tester/other"], registered: ["/Users/tester/code"])
        )
    }

    func test_labelIsStableOrderIndependentAndAlwaysSet() throws {
        // WHY: the label decides whether the container must be recreated.
        let a = BotComputerGuestSpec.workspacesLabel(["/b", "/a"])
        XCTAssertEqual(a, BotComputerGuestSpec.workspacesLabel(["/a", "/b"]))
        XCTAssertNotEqual(a, BotComputerGuestSpec.workspacesLabel(["/a"]))
        XCTAssertEqual(
            BotComputerGuestSpec.workspacesLabel([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        let empty = try options(BotID(), workspaces: [])
        XCTAssertEqual(empty.labels[BotComputerGuestSpec.workspacesLabelKey], BotComputerGuestSpec.workspacesLabel([]))
    }
}

extension BotComputerWorkspaceMountSpecTests {
    func test_symlinkResolvingToHomeIsRejected() throws {
        // WHY: Docker follows symlinks at bind time, so a link to the home dir would mount the whole home.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-symlink-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("innocent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeHome)
        XCTAssertThrowsError(
            try BotComputerGuestSpec.assertWorkspaceMountPath(link.path, userHome: fakeHome.path)
        ) { XCTAssertEqual($0 as? BotComputerGuestError, .invalidWorkspacePath(link.path)) }
        let inside = fakeHome.appendingPathComponent("a")
        let nestedLink = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: inside)
        XCTAssertThrowsError(
            try BotComputerGuestSpec.assertWorkspaceMountPath(nestedLink.path, userHome: fakeHome.path),
            "any symlink resolving elsewhere is refused"
        )
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNoThrow(try BotComputerGuestSpec.assertWorkspaceMountPath(plain.path, userHome: fakeHome.path))
    }
}
