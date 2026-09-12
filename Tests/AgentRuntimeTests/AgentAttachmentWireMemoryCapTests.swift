import CoreGraphics
import Foundation
import ImageIO
import XCTest
import CoreModel
@testable import AgentRuntime

/// Memory caps for Agent App attach: Claude/Grok must not load unbounded
/// `Data` + base64. Original files stay on disk; the wire payload is a 2048px
/// ImageIO downsample under 5 MiB, and Grok text files are a 512 KiB prefix.
final class AgentAttachmentWireMemoryCapTests: XCTestCase {
    func test_smallPNG_passesThroughExactBytes() throws {
        // WHY: tiny already-capped images must not be re-encoded; existing
        // Claude stdin shape (media_type + exact base64) stays intact.
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let pngData = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let png = tmp.url.appendingPathComponent("dot.png")
        try pngData.write(to: png)

        let payload = try AgentAttachmentWireImage.encode(path: png.path, mimeType: "image/png")
        XCTAssertFalse(payload.downsampled)
        XCTAssertEqual(payload.mediaType, "image/png")
        XCTAssertEqual(payload.data, pngData)
        XCTAssertEqual(payload.originalByteCount, pngData.count)

        let block = try ClaudeStreamingCLIAdapter.attachmentContentBlock(
            AgentAttachment(path: png.path, displayName: "dot.png", kind: .image, mimeType: "image/png")
        )
        let source = try XCTUnwrap(block["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, pngData.base64EncodedString())
        XCTAssertEqual(try Data(contentsOf: png), pngData, "original must remain on disk")
    }

    func test_largeJPEG_downsamplesUnderFiveMiBAndKeepsOriginalOnDisk() throws {
        // WHY: unbounded Data(contentsOf:)+base64 was the ranked residual;
        // a 3072px photo must shrink on the wire while the file is untouched.
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let original = try Self.makeLargeJPEG(width: 3_072, height: 3_072, variant: 11, quality: 0.95)
        let url = tmp.url.appendingPathComponent("photo.jpg")
        try original.write(to: url)
        let originalOnDisk = try Data(contentsOf: url)

        let beforeBytes = originalOnDisk.count
        XCTAssertGreaterThan(beforeBytes, 0)

        let payload = try AgentAttachmentWireImage.encode(path: url.path, mimeType: "image/jpeg")
        XCTAssertTrue(payload.downsampled, "3072px source must take the ImageIO 2048px path")
        XCTAssertEqual(payload.mediaType, "image/jpeg")
        XCTAssertEqual(payload.originalByteCount, beforeBytes)
        XCTAssertLessThanOrEqual(payload.data.count, AgentAttachmentWireImage.maxEncodedBytes)
        XCTAssertLessThan(
            payload.data.count,
            beforeBytes,
            "encoded wire bytes must be smaller than the original on-disk JPEG"
        )
        XCTAssertEqual(try Data(contentsOf: url), originalOnDisk, "original must remain on disk")

        let block = try ClaudeStreamingCLIAdapter.attachmentContentBlock(
            AgentAttachment(path: url.path, displayName: "photo.jpg", kind: .image, mimeType: "image/jpeg")
        )
        let source = try XCTUnwrap(block["source"] as? [String: Any])
        let base64 = try XCTUnwrap(source["data"] as? String)
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(decoded.count, payload.data.count)
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")

        let beforeWire = (beforeBytes * 4 + 2) / 3
        let afterWire = base64.utf8.count
        let percent = Double(beforeBytes - payload.data.count) / Double(beforeBytes) * 100
        NSLog(
            "[memperf] claude-image before_file=%d after_encoded=%d after_wire_b64=%d before_wire_b64=%d saved_file_pct=%.1f downsampled=%d",
            beforeBytes, payload.data.count, afterWire, beforeWire, percent, payload.downsampled ? 1 : 0
        )
        XCTAssertLessThan(afterWire, beforeWire)
    }

    func test_encode_failsClosedWhenStillOverInjectedCap() throws {
        // WHY: if 2048px JPEG still exceeds the hard cap, refuse the attach
        // rather than shipping an oversized base64 blob.
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let jpeg = try Self.makeLargeJPEG(width: 256, height: 256, variant: 4, quality: 0.9)
        let url = tmp.url.appendingPathComponent("still-large.jpg")
        try jpeg.write(to: url)

        XCTAssertThrowsError(
            try AgentAttachmentWireImage.encode(
                path: url.path,
                mimeType: "image/jpeg",
                maxPixel: 256,
                maxEncodedBytes: 32
            )
        ) { error in
            guard let encodeError = error as? AgentAttachmentWireImage.EncodeError,
                  case .exceedsCap(let original, let encoded, let cap, let maxPixel) = encodeError else {
                return XCTFail("expected exceedsCap, got \(error)")
            }
            XCTAssertEqual(original, jpeg.count)
            XCTAssertGreaterThan(encoded, 32)
            XCTAssertEqual(cap, 32)
            XCTAssertEqual(maxPixel, 256)
            XCTAssertTrue(encodeError.description.contains("wire cap"))
            XCTAssertTrue(encodeError.description.contains("Original file kept on disk"))
        }

        XCTAssertThrowsError(
            try ClaudeStreamingCLIAdapter.attachmentContentBlock(
                AgentAttachment(path: url.path, kind: .image, mimeType: "image/jpeg"),
                maxPixel: 256,
                maxEncodedBytes: 32
            )
        ) { error in
            guard case AgentProviderAdapterError.unsupported(let message) = error else {
                return XCTFail("expected unsupported, got \(error)")
            }
            XCTAssertTrue(message.contains("wire cap"))
        }
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
    }

    func test_undecodableOversizeImage_failsClosedWithoutPassThrough() throws {
        // WHY: a 6 MiB non-image labeled as PNG must not Data(contentsOf:) the
        // whole blob just because ImageIO cannot thumbnail it.
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let junk = Data(repeating: 0x41, count: AgentAttachmentWireImage.maxEncodedBytes + 64)
        let url = tmp.url.appendingPathComponent("fake.png")
        try junk.write(to: url)

        XCTAssertThrowsError(
            try AgentAttachmentWireImage.encode(path: url.path, mimeType: "image/png")
        ) { error in
            guard let encodeError = error as? AgentAttachmentWireImage.EncodeError,
                  case .unreadable = encodeError else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertTrue(encodeError.description.contains("original kept on disk"))
        }
        XCTAssertEqual(try Data(contentsOf: url).count, junk.count)
    }

    func test_grokImage_usesTheSameDownsampleCap() throws {
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let original = try Self.makeLargeJPEG(width: 3_072, height: 3_072, variant: 22, quality: 0.95)
        let url = tmp.url.appendingPathComponent("shot.jpg")
        try original.write(to: url)

        let blocks = try GrokACPClient.promptBlocks(
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .grok,
                model: "grok-4.5",
                cwd: tmp.url.path,
                prompt: "inspect",
                attachments: [AgentAttachment(path: url.path, kind: .image, mimeType: "image/jpeg")]
            ),
            capabilities: .init(
                protocolVersion: 1,
                loadSession: true,
                embeddedContext: true,
                image: false,
                agentVersion: "0.2.103"
            )
        )
        let imageBlock = try XCTUnwrap(blocks.last)
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/jpeg")
        let base64 = try XCTUnwrap(imageBlock["data"] as? String)
        let encoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertLessThanOrEqual(encoded.count, AgentAttachmentWireImage.maxEncodedBytes)
        XCTAssertLessThan(encoded.count, original.count)
        XCTAssertEqual(try Data(contentsOf: url), original)

        let percent = Double(original.count - encoded.count) / Double(original.count) * 100
        NSLog(
            "[memperf] grok-image before_file=%d after_encoded=%d saved_file_pct=%.1f",
            original.count, encoded.count, percent
        )
    }

    func test_grokTextFile_readsFileHandlePrefixAndKeepsPath() throws {
        // WHY: mappedIfSafe used to bring the whole file into the prompt JSON.
        // 512 KiB prefix + truncation marker keeps the path while bounding RAM.
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let body = String(repeating: "abcdefghijklmnopqrstuvwxyz\n", count: 40_000)
        XCTAssertGreaterThan(body.utf8.count, GrokACPClient.embeddedFilePrefixBytes)
        let url = tmp.url.appendingPathComponent("notes.txt")
        try Data(body.utf8).write(to: url)
        let originalCount = try Data(contentsOf: url).count

        let prefix = try GrokACPClient.embeddedUTF8FilePrefix(
            path: url.path,
            displayName: "notes.txt"
        )
        XCTAssertTrue(prefix.truncated)
        XCTAssertEqual(prefix.originalByteCount, originalCount)
        XCTAssertEqual(prefix.path, url.path)
        XCTAssertEqual(prefix.text.utf8.count, GrokACPClient.embeddedFilePrefixBytes)
        XCTAssertTrue(prefix.wireText.contains(url.path))
        XCTAssertTrue(prefix.wireText.contains("truncated"))
        XCTAssertTrue(prefix.wireText.hasPrefix(prefix.text))
        XCTAssertLessThan(prefix.wireText.utf8.count, originalCount)
        XCTAssertEqual(try Data(contentsOf: url).count, originalCount)

        let blocks = try GrokACPClient.promptBlocks(
            for: AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .grok,
                model: "grok-4.5",
                cwd: tmp.url.path,
                prompt: "read this",
                attachments: [AgentAttachment(path: url.path, kind: .file, mimeType: "text/plain")]
            ),
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        let resource = try XCTUnwrap(blocks.last?["resource"] as? [String: Any])
        let text = try XCTUnwrap(resource["text"] as? String)
        XCTAssertEqual(text, prefix.wireText)
        XCTAssertEqual(resource["uri"] as? String, url.absoluteString)
        XCTAssertTrue(text.contains(url.path), "path must stay present after truncation")

        let percent = Double(originalCount - prefix.text.utf8.count) / Double(originalCount) * 100
        NSLog(
            "[memperf] grok-file before=%d after_prefix=%d after_wire=%d saved_pct=%.1f",
            originalCount, prefix.text.utf8.count, prefix.wireText.utf8.count, percent
        )
    }

    func test_grokTextFile_smallFileIsNotTruncated() throws {
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("note.txt")
        try Data("known-sha-input".utf8).write(to: url)
        let prefix = try GrokACPClient.embeddedUTF8FilePrefix(path: url.path, displayName: "note.txt")
        XCTAssertFalse(prefix.truncated)
        XCTAssertEqual(prefix.text, "known-sha-input")
        XCTAssertEqual(prefix.wireText, "known-sha-input")
    }

    func test_grokTextFile_dropsSplitUTF8TailRatherThanFailing() throws {
        let tmp = try ScratchDir()
        defer { tmp.remove() }
        var data = Data(repeating: 0x61, count: GrokACPClient.embeddedFilePrefixBytes - 1)
        data.append(contentsOf: [0xC3, 0xA9]) // é split across the 512 KiB boundary
        data.append(contentsOf: Array(repeating: 0x62, count: 64))
        let url = tmp.url.appendingPathComponent("utf8.txt")
        try data.write(to: url)

        let prefix = try GrokACPClient.embeddedUTF8FilePrefix(path: url.path, displayName: "utf8.txt")
        XCTAssertTrue(prefix.truncated)
        XCTAssertEqual(prefix.text, String(repeating: "a", count: GrokACPClient.embeddedFilePrefixBytes - 1))
        XCTAssertTrue(prefix.wireText.contains(url.path))
    }

    private static func makeLargeJPEG(width: Int, height: Int, variant: Int, quality: Double) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        let stripeHeight = max(1, height / 32)
        for stripe in 0..<32 {
            let seed = CGFloat((variant &+ stripe * 17) % 255) / 255
            context.setFillColor(
                red: seed,
                green: 1 - seed,
                blue: CGFloat((variant * 3 + stripe * 7) % 255) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: stripe * stripeHeight, width: width, height: stripeHeight + 1))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ScratchDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-attach-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
