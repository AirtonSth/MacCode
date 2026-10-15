import AppKit
import CoreModel
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Surfaces

/// Contract §4 gallery: at most three tiles, "+N" for the rest, fixed tile
/// height (no layout jump), honest failure, and bounded remote fetches.
final class AgentChatImageGalleryTests: XCTestCase {
    // MARK: Layout

    /// WHY: the reference design shows three tiles with "+N" on the last;
    /// N must be exactly the images the row does not show.
    func test_overflowPlan_showsThreeTilesAndCountsTheRest() {
        typealias Layout = AgentChatImageGalleryLayout
        XCTAssertEqual(Layout.plan(count: 0, expanded: false), .init(visibleCount: 0, overflowCount: 0))
        XCTAssertEqual(Layout.plan(count: 3, expanded: false), .init(visibleCount: 3, overflowCount: 0),
                       "exactly three images need no +N")
        XCTAssertEqual(Layout.plan(count: 5, expanded: false), .init(visibleCount: 3, overflowCount: 2),
                       "five images: three tiles, the third reads +2")
        XCTAssertEqual(Layout.plan(count: 5, expanded: true), .init(visibleCount: 5, overflowCount: 0),
                       "after tapping +N every image has its own tile")
    }

    func test_tileWidthShrinksAsTheRowFills() {
        let one = AgentChatImageGalleryLayout.tileMaxWidth(imageCount: 1)
        let two = AgentChatImageGalleryLayout.tileMaxWidth(imageCount: 2)
        let three = AgentChatImageGalleryLayout.tileMaxWidth(imageCount: 3)
        XCTAssertGreaterThan(one, two)
        XCTAssertGreaterThan(two, three)
        XCTAssertEqual(AgentChatImageGalleryLayout.tileHeight, 200, "fixed height: loading never moves the transcript")
    }

    // MARK: Row wiring

    /// WHY: bot screenshots were posted as attachments and the row showed only
    /// "📷 reason"; the attachment must reach the gallery.
    func test_replyRefsIncludeImageAttachments() {
        let shot = AgentAttachment(id: "a1", path: "/store/a1", displayName: "screenshot.jpg", kind: .image, mimeType: "image/jpeg")
        XCTAssertEqual(AgentChatImageGallery.refs(text: "📷 login", attachments: [shot]).map(\.ref), ["a1"])
        XCTAssertTrue(AgentChatImageGallery.refs(text: "no images here", attachments: []).isEmpty)
    }

    /// WHY: the reply row is Equatable so SwiftUI can skip it; a new
    /// attachment or the stream finishing must still repaint it.
    func test_assistantReplyEqualityTracksAttachmentsAndImageVisibility() {
        let shot = AgentAttachment(id: "a1", path: "/store/a1", kind: .image)
        let base = AgentChatAssistantReply(text: "x")
        XCTAssertNotEqual(base, AgentChatAssistantReply(text: "x", attachments: [shot]))
        XCTAssertNotEqual(base, AgentChatAssistantReply(text: "x", showsImages: false))
        XCTAssertEqual(base, AgentChatAssistantReply(text: "x"))
    }

    // MARK: Local loading

    private func writePNG(width: Int, height: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-\(UUID().uuidString).png").path
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return path
    }

    /// WHY: transcript paint must never decode full-size screenshots; the
    /// loader returns a downsampled image, caches it for the next mount, and
    /// reports a missing file as a failure instead of a blank tile.
    func test_localImageLoadsDownsampledThenServesFromCache() async throws {
        let path = try writePNG(width: 2_400, height: 1_200)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ref = AgentMessageImageRef(source: .localPath(path), ref: path, displayName: "x.png")
        let loader = AgentChatImageLoader()
        let loaded = await loader.image(for: ref)
        let image = try XCTUnwrap(loaded)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), AgentChatImageLoader.decodeMaxPixel)
        XCTAssertNotNil(AgentChatImageLoader.cachedImage(for: ref), "a remounted tile paints from cache on its first frame")

        let missing = AgentMessageImageRef(source: .localPath("/tmp/missing-\(UUID().uuidString).png"), ref: "m", displayName: "m")
        let none = await loader.image(for: missing)
        XCTAssertNil(none)
    }

    func test_fileSignatureRejectsDirectoriesAndNonImages() throws {
        XCTAssertNil(AgentChatImageLoader.fileSignature(NSTemporaryDirectory()))
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("not-image-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertNil(AgentChatImageLoader.fileSignature(text.path))
    }

    // MARK: Remote caps

    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var mime = "image/png"
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var announceLength = true

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var headers = ["Content-Type": Self.mime]
            if Self.announceLength { headers["Content-Length"] = "\(Self.body.count)" }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func pngData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: try writePNG(width: 40, height: 20)))
    }

    /// WHY: a link that is not an image (an HTML page), an error page, or a
    /// huge download must never be decoded on the user's machine.
    func test_remoteFetchAcceptsOnlyBoundedImageResponses() async throws {
        let url = URL(string: "https://example.test/a.png")!
        StubProtocol.status = 200
        StubProtocol.announceLength = true
        StubProtocol.mime = "image/png"
        StubProtocol.body = try pngData()
        let ok = await AgentChatImageLoader.fetchRemote(url, session: stubSession())
        XCTAssertEqual(ok, StubProtocol.body)

        StubProtocol.mime = "text/html"
        let html = await AgentChatImageLoader.fetchRemote(url, session: stubSession())
        XCTAssertNil(html, "non-image MIME is refused")

        StubProtocol.mime = "image/png"
        StubProtocol.status = 404
        let missing = await AgentChatImageLoader.fetchRemote(url, session: stubSession())
        XCTAssertNil(missing, "error statuses are refused")

        StubProtocol.status = 200
        StubProtocol.announceLength = false
        StubProtocol.body = Data(count: AgentChatImageLoader.maxRemoteBytes + 1)
        let huge = await AgentChatImageLoader.fetchRemote(url, session: stubSession())
        XCTAssertNil(huge, "a body over 10 MB is cut off even without Content-Length")

        XCTAssertEqual(AgentChatImageLoader.remoteTimeout, 15)
        XCTAssertEqual(AgentChatImageLoader.makeSession().configuration.timeoutIntervalForResource, 15)
    }
}
