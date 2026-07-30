import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import SocketServer
import CoreModel

final class BrowserScreenshotInlineV1Tests: XCTestCase {
    func testResponseIsStrictBoundedDownsampledJPEGWithIntegrityMetadata() throws {
        // WHY: the iPhone must receive one small, renderable payload on 3G,
        // never an unbounded source screenshot or a Mac-only path.
        let source = try makePNG(width: 2_400, height: 1_400)
        let response = try BrowserScreenshotInlineV1.makeResponse(
            sourceData: source,
            requestedMaxBytes: BrowserScreenshotInlineV1.maximumResponseBytes,
            requestedMaxPixelDimension:
                BrowserScreenshotInlineV1.maximumPixelDimension
        )

        XCTAssertEqual(
            Set(response.keys),
            Set([
                "version",
                "mime_type",
                "data_base64",
                "byte_count",
                "pixel_width",
                "pixel_height",
                "sha256",
            ])
        )
        XCTAssertNil(response["path"])
        XCTAssertEqual(response["version"]?.intValue, 1)
        XCTAssertEqual(response["mime_type"]?.stringValue, "image/jpeg")

        let encoded = try XCTUnwrap(response["data_base64"]?.stringValue)
        let jpeg = try XCTUnwrap(Data(base64Encoded: encoded))
        let byteCount = try XCTUnwrap(response["byte_count"]?.intValue)
        let width = try XCTUnwrap(response["pixel_width"]?.intValue)
        let height = try XCTUnwrap(response["pixel_height"]?.intValue)
        XCTAssertEqual(jpeg.count, byteCount)
        XCTAssertLessThanOrEqual(
            byteCount,
            BrowserScreenshotInlineV1.maximumResponseBytes
        )
        XCTAssertLessThanOrEqual(
            max(width, height),
            BrowserScreenshotInlineV1.maximumPixelDimension
        )
        XCTAssertLessThanOrEqual(
            width * height,
            BrowserScreenshotInlineV1.maximumPixelCount
        )
        XCTAssertEqual(
            response["sha256"]?.stringValue,
            SHA256.hash(data: jpeg)
                .map { String(format: "%02x", $0) }
                .joined()
        )

        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(jpeg as CFData, nil)
        )
        XCTAssertEqual(
            CGImageSourceGetType(imageSource) as String?,
            "public.jpeg"
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        )
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }

    func testLowerRequestCapsAreHonored() throws {
        // WHY: a cellular client may request a tighter window, but can never
        // expand the host's hard limits.
        let response = try BrowserScreenshotInlineV1.makeResponse(
            sourceData: makePNG(width: 1_600, height: 1_000),
            requestedMaxBytes: 48 * 1_024,
            requestedMaxPixelDimension: 640
        )

        XCTAssertLessThanOrEqual(
            try XCTUnwrap(response["byte_count"]?.intValue),
            48 * 1_024
        )
        let width = try XCTUnwrap(response["pixel_width"]?.intValue)
        let height = try XCTUnwrap(response["pixel_height"]?.intValue)
        XCTAssertLessThanOrEqual(max(width, height), 640)
        XCTAssertLessThanOrEqual(
            width * height,
            BrowserScreenshotInlineV1.maximumPixelCount
        )
    }

    func testInvalidCapsAndUnreachableByteBudgetFailClosed() throws {
        let source = try makePNG(width: 200, height: 100)
        for (bytes, pixels) in [
            (0, 100),
            (BrowserScreenshotInlineV1.maximumResponseBytes + 1, 100),
            (100, 0),
            (100, BrowserScreenshotInlineV1.maximumPixelDimension + 1),
        ] {
            XCTAssertThrowsError(
                try BrowserScreenshotInlineV1.makeResponse(
                    sourceData: source,
                    requestedMaxBytes: bytes,
                    requestedMaxPixelDimension: pixels
                )
            ) { error in
                XCTAssertEqual(
                    error as? BrowserScreenshotInlineV1Error,
                    .invalidLimits
                )
            }
        }

        XCTAssertThrowsError(
            try BrowserScreenshotInlineV1.makeResponse(
                sourceData: source,
                requestedMaxBytes: 1,
                requestedMaxPixelDimension: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? BrowserScreenshotInlineV1Error,
                .encodingFailed
            )
        }
    }

    func testMalformedAndTruncatedImagesFailClosed() throws {
        let png = try makePNG(width: 320, height: 200)
        for malformed in [
            Data("not-an-image".utf8),
            Data(png.prefix(24)),
        ] {
            XCTAssertThrowsError(
                try BrowserScreenshotInlineV1.makeResponse(
                    sourceData: malformed,
                    requestedMaxBytes:
                        BrowserScreenshotInlineV1.maximumResponseBytes,
                    requestedMaxPixelDimension:
                        BrowserScreenshotInlineV1.maximumPixelDimension
                )
            ) { error in
                XCTAssertEqual(
                    error as? BrowserScreenshotInlineV1Error,
                    .invalidSource
                )
            }
        }
    }

    func testFileReaderRejectsOversizedAndSymlinkSourcesBeforeDecode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oversized = directory.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: oversized.path,
            contents: nil
        ))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(
            atOffset: UInt64(
                BrowserScreenshotInlineV1.maximumSourceBytes + 1
            )
        )
        try handle.close()
        XCTAssertThrowsError(
            try BrowserScreenshotInlineV1.makeResponse(
                fileURL: oversized,
                requestedMaxBytes:
                    BrowserScreenshotInlineV1.maximumResponseBytes,
                requestedMaxPixelDimension:
                    BrowserScreenshotInlineV1.maximumPixelDimension
            )
        ) { error in
            XCTAssertEqual(
                error as? BrowserScreenshotInlineV1Error,
                .sourceTooLarge
            )
        }

        let real = directory.appendingPathComponent("real.png")
        try makePNG(width: 100, height: 60).write(to: real)
        let symlink = directory.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: real
        )
        XCTAssertThrowsError(
            try BrowserScreenshotInlineV1.makeResponse(
                fileURL: symlink,
                requestedMaxBytes:
                    BrowserScreenshotInlineV1.maximumResponseBytes,
                requestedMaxPixelDimension:
                    BrowserScreenshotInlineV1.maximumPixelDimension
            )
        ) { error in
            XCTAssertEqual(
                error as? BrowserScreenshotInlineV1Error,
                .invalidSource
            )
        }
    }

    @MainActor
    func testDispatcherV1ReturnsInlineContractWithoutHostPath() async throws {
        // WHY: a successful modern RPC must be directly renderable/shareable
        // on iOS and must not leak a host filesystem path as its success value.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = directory.appendingPathComponent("host-shot.png")
        try makePNG(width: 1_200, height: 800).write(to: screenshot)
        let router = BrowserScreenshotFileRouter(screenshotURL: screenshot)
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "browser.screenshot",
            params: [
                "id": .string(UUID().uuidString),
                "response_version": .number(1),
                "max_bytes": .number(
                    Double(BrowserScreenshotInlineV1.maximumResponseBytes)
                ),
                "max_pixel_dimension": .number(
                    Double(BrowserScreenshotInlineV1.maximumPixelDimension)
                ),
            ]
        ))

        XCTAssertNil(response.error)
        let object = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(object["version"]?.intValue, 1)
        XCTAssertNotNil(object["data_base64"]?.stringValue)
        XCTAssertNil(object["path"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: screenshot.path),
            "temporary source PNG must be removed after the bounded response is built"
        )
    }

    @MainActor
    func testDispatcherV1RejectsMissingCapsWithoutCapturing() async throws {
        let router = BrowserScreenshotFileRouter(
            screenshotURL: URL(fileURLWithPath: "/tmp/unused.png")
        )
        let response = await JSONRPCDispatcher(router: router).dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "browser.screenshot",
                params: [
                    "id": .string(UUID().uuidString),
                    "response_version": .number(1),
                ]
            )
        )

        XCTAssertEqual(response.error?.code, JSONRPCError.invalidParams.code)
        XCTAssertEqual(router.screenshotCallCount, 0)
    }

    @MainActor
    func testDispatcherRejectsMalformedPresentVersionWithoutLegacyPathDowngrade() async {
        // WHY: only an absent version opts into legacy path behavior. A caller
        // that presents malformed v1 negotiation must never receive a host path.
        let router = BrowserScreenshotFileRouter(
            screenshotURL: URL(fileURLWithPath: "/tmp/must-not-leak.png")
        )
        let dispatcher = JSONRPCDispatcher(router: router)
        let malformedVersions: [JSONValue] = [
            .number(1.5),
            .string("1"),
            .number(Double.greatestFiniteMagnitude),
        ]

        for (index, malformedVersion) in malformedVersions.enumerated() {
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(index + 1),
                method: "browser.screenshot",
                params: [
                    "id": .string(UUID().uuidString),
                    "response_version": malformedVersion,
                ]
            ))

            XCTAssertEqual(
                response.error?.code,
                JSONRPCError.invalidParams.code
            )
            XCTAssertNil(response.result)
        }
        XCTAssertEqual(router.screenshotCallCount, 0)
    }

    @MainActor
    func testDispatcherV1RejectsMalformedCapsWithoutIntegerTrapOrCapture() async {
        let router = BrowserScreenshotFileRouter(
            screenshotURL: URL(fileURLWithPath: "/tmp/unused.png")
        )
        let dispatcher = JSONRPCDispatcher(router: router)
        let malformedCaps: [(field: String, value: JSONValue)] = [
            ("max_bytes", .number(Double.greatestFiniteMagnitude)),
            ("max_bytes", .number(1.5)),
            ("max_pixel_dimension", .string("1280")),
        ]

        for (index, malformed) in malformedCaps.enumerated() {
            var params: [String: JSONValue] = [
                "id": .string(UUID().uuidString),
                "response_version": .number(1),
                "max_bytes": .number(
                    Double(BrowserScreenshotInlineV1.maximumResponseBytes)
                ),
                "max_pixel_dimension": .number(
                    Double(BrowserScreenshotInlineV1.maximumPixelDimension)
                ),
            ]
            params[malformed.field] = malformed.value
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(index + 1),
                method: "browser.screenshot",
                params: params
            ))

            XCTAssertEqual(
                response.error?.code,
                JSONRPCError.invalidParams.code
            )
            XCTAssertNil(response.result)
        }
        XCTAssertEqual(router.screenshotCallCount, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrowserScreenshotInlineV1Error.encodingFailed
        }
        let tile = max(8, min(width, height) / 24)
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let red = CGFloat((x * 31 + y * 17) % 255) / 255
                let green = CGFloat((x * 13 + y * 29) % 255) / 255
                let blue = CGFloat((x * 7 + y * 11) % 255) / 255
                context.setFillColor(
                    CGColor(
                        colorSpace: colorSpace,
                        components: [red, green, blue, 1]
                    )!
                )
                context.fill(CGRect(
                    x: x,
                    y: y,
                    width: min(tile, width - x),
                    height: min(tile, height - y)
                ))
            }
        }
        guard let image = context.makeImage() else {
            throw BrowserScreenshotInlineV1Error.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw BrowserScreenshotInlineV1Error.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BrowserScreenshotInlineV1Error.encodingFailed
        }
        return data as Data
    }
}

@MainActor
private final class BrowserScreenshotFileRouter: FakeRouter {
    let screenshotURL: URL
    private(set) var screenshotCallCount = 0

    init(screenshotURL: URL) {
        self.screenshotURL = screenshotURL
        super.init()
    }

    override func browserScreenshot(
        surface: SurfaceID,
        savePath: String?
    ) throws -> String {
        screenshotCallCount += 1
        return screenshotURL.path
    }
}
