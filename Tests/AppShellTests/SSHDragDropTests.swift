import XCTest
@testable import AppShell
@testable import CoreModel

// P3: SSH drag-and-drop — Finder files dropped onto the remote pane queue upload
// requests. The pure payload resolver (SSHDropPayloadResolver) is tested without
// any UI or router. The surface-level path is exercised via the testing accessor
// on SSHSurface so the queue plumbing (enqueue + count) is also covered.

// MARK: - Pure resolver tests

final class SSHDropPayloadResolverTests: XCTestCase {

    // WHY: dropping one regular file onto the remote pane must produce exactly one
    // upload request whose localPath equals the dropped URL's path and whose
    // remotePath is remotePath/filename. If neither holds, the scp call receives
    // wrong paths and the upload silently targets the wrong location.
    func testSingleFileDropProducesOneUploadRequest() {
        let url = URL(fileURLWithPath: "/Users/dev/logo.png")
        let result = SSHDropPayloadResolver.resolve(fileURLs: [url], remotePath: "/var/www")
        XCTAssertEqual(result.count, 1, "one file => one upload request")
        XCTAssertEqual(result[0].localPath, "/Users/dev/logo.png")
        XCTAssertEqual(result[0].remotePath, "/var/www/logo.png")
        XCTAssertFalse(result[0].isDirectory)
    }

    // WHY: dropping multiple files must produce one request per file in the same
    // remote directory. Fewer requests would silently skip files; a wrong count
    // means partial uploads with no user-visible error.
    func testMultipleFilesDropProducesOneRequestEach() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.txt")
        ]
        let result = SSHDropPayloadResolver.resolve(fileURLs: urls, remotePath: "/upload")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.remotePath).sorted(),
                       ["/upload/a.txt", "/upload/b.txt", "/upload/c.txt"])
    }

    // WHY: an empty drop (e.g. user accidentally drops a non-file object that
    // resolves to zero URLs) must never produce any request. Producing a phantom
    // request would kick off an scp call with an empty local path.
    func testEmptyURLsProducesNoRequests() {
        let result = SSHDropPayloadResolver.resolve(fileURLs: [], remotePath: "/srv")
        XCTAssertTrue(result.isEmpty, "empty drop => no requests")
    }

    // WHY: directories are valid drag sources from Finder. The resolver must mark
    // them as isDirectory=true so the surface can route to the recursive-scp path
    // (-r flag). If isDirectory is false for a folder, the silent scp no-op from
    // the original base helper is triggered instead.
    func testDirectoryDropIsMarkedAsDirectory() {
        // Use a path known to exist as a directory on any macOS machine.
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let result = SSHDropPayloadResolver.resolve(fileURLs: [url], remotePath: "/home/user")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isDirectory,
                      "directory URL must be flagged so recursive scp is used")
        XCTAssertEqual(result[0].remotePath, "/home/user/tmp")
    }

    // WHY: trailing slashes on the remotePath must not produce double-slash remote
    // paths like "/srv//file.txt". A malformed path causes the remote shell to
    // reject or misroute the scp call on some servers.
    func testTrailingSlashOnRemotePathNormalized() {
        let url = URL(fileURLWithPath: "/home/user/photo.jpg")
        let result = SSHDropPayloadResolver.resolve(fileURLs: [url], remotePath: "/srv/upload/")
        XCTAssertEqual(result[0].remotePath, "/srv/upload/photo.jpg",
                       "trailing slash on remotePath must not double-up in result")
    }

    // WHY: a URL whose lastPathComponent is empty (e.g. a bare "/" or "") must be
    // skipped. Including it would produce a remotePath equal to remotePath itself,
    // inadvertently targeting the directory as the destination file.
    func testURLWithEmptyLastPathComponentIsSkipped() {
        let url = URL(fileURLWithPath: "/")
        let result = SSHDropPayloadResolver.resolve(fileURLs: [url], remotePath: "/dst")
        XCTAssertTrue(result.isEmpty,
                      "URL with no filename component must not generate a request")
    }
}

// MARK: - Surface integration (queue plumbing via testing accessor)

@MainActor
final class SSHSurfaceDropIntegrationTests: XCTestCase {

    private func makeSurface() throws -> SSHSurface {
        try SSHSurface(workspaceID: WorkspaceID(), cwd: "/tmp", title: "t", router: nil)
    }

    // WHY: the surface testing accessor must enqueue one upload per valid dropped
    // file. If the count mismatches, the surface is silently losing or duplicating
    // transfer requests before any router call.
    func testFinderDropEnqueuesOneItemPerFile() throws {
        let surface = try makeSurface()
        let urls = [
            URL(fileURLWithPath: "/Users/dev/file1.txt"),
            URL(fileURLWithPath: "/Users/dev/file2.txt")
        ]
        let enqueued = surface.handleFinderDropOnRemotePaneForTesting(urls: urls)
        XCTAssertEqual(enqueued, 2,
                       "two dropped files must produce two queued transfer items")
        XCTAssertEqual(surface.queueCountForTesting, 2)
    }

    // WHY: an empty drop payload (zero URLs) must leave the queue untouched.
    // Enqueuing anything for an empty drop would be a phantom transfer.
    func testEmptyDropDoesNotEnqueueAnything() throws {
        let surface = try makeSurface()
        let enqueued = surface.handleFinderDropOnRemotePaneForTesting(urls: [])
        XCTAssertEqual(enqueued, 0)
        XCTAssertEqual(surface.queueCountForTesting, 0)
    }

    // WHY: a directory dropped on the remote pane must still produce exactly one
    // queued item (the directory transfer). If the surface rejects it or produces
    // zero items, recursive folder uploads from Finder are silently broken.
    func testDirectoryDropEnqueuesOneItem() throws {
        let surface = try makeSurface()
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let enqueued = surface.handleFinderDropOnRemotePaneForTesting(urls: [url])
        XCTAssertEqual(enqueued, 1,
                       "directory drop must produce exactly one queued transfer")
        XCTAssertEqual(surface.queueCountForTesting, 1)
    }
}
