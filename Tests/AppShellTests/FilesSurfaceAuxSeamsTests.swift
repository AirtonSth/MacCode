import AppKit
import ImageIO
import XCTest
@testable import AppShell

final class FilesSurfaceAuxSeamsTests: XCTestCase {
    func test_resolveSubmittedFilesPath_matrix() {
        // WHY: the path field accepts root paths, absolute workspace paths, slash-wrapped
        // relative paths, and blanks. The VM must receive only workspace-relative paths.
        XCTAssertEqual(resolveSubmittedFilesPath(raw: "/workspace", root: "/workspace"), "",
            "submitting the workspace root should navigate to the Files root")
        XCTAssertEqual(resolveSubmittedFilesPath(raw: "/workspace/src", root: "/workspace"), "src",
            "absolute paths under the workspace root should become relative paths")
        XCTAssertEqual(resolveSubmittedFilesPath(raw: " /docs/guide/ ", root: "/workspace"), "docs/guide",
            "relative paths should trim whitespace and leading/trailing slashes")
        XCTAssertNil(resolveSubmittedFilesPath(raw: "   ", root: "/workspace"),
            "blank path submission should not navigate")
    }

    func test_visibleFileEntries_hidesDotfilesUnlessShownAndStillAppliesNameFilter() {
        // WHY: .git/.DS_Store clutter should stay hidden by default, but the name filter must still
        // narrow visible rows when hidden files are enabled.
        let entries = [
            FilterableFileEntry(name: ".env", isDirectory: false),
            FilterableFileEntry(name: "README.md", isDirectory: false),
            FilterableFileEntry(name: "Sources", isDirectory: true)
        ]

        let hiddenOff = visibleFileEntries(entries, showHidden: false, query: "", isHidden: { $0.name.hasPrefix(".") })
        let hiddenOnFiltered = visibleFileEntries(entries, showHidden: true, query: "env", isHidden: { $0.name.hasPrefix(".") })

        XCTAssertEqual(hiddenOff.map(\.name), ["README.md", "Sources"],
            "hidden rows must be excluded while showHidden is off")
        XCTAssertEqual(hiddenOnFiltered.map(\.name), [".env"],
            "showHidden on should expose dotfiles and still honor the name filter")
    }

    func test_shouldGateLargeMedia_thresholdAndLoadAnyway() {
        // WHY: media previews above 64MB should not decode until the user explicitly opts in, and
        // the exact threshold boundary must not show the guard.
        XCTAssertFalse(shouldGateLargeMedia(size: LargeMediaGuardThreshold, loadAnyway: false),
            "size equal to the threshold should render directly")
        XCTAssertTrue(shouldGateLargeMedia(size: LargeMediaGuardThreshold + 1, loadAnyway: false),
            "size above the threshold should show the guard before loading")
        XCTAssertFalse(shouldGateLargeMedia(size: LargeMediaGuardThreshold + 1, loadAnyway: true),
            "Load Anyway must bypass the guard for the current file")
    }

    func test_filesImageThumbnail_capsDecodedPixelsAt2048() throws {
        // WHY: Files preview used 4096² (~64 MiB RGBA) with immediate ImageIO
        // cache. Agent App opens Files in a split; cap must match File Preview.
        XCTAssertEqual(FilesImageThumbnailMaxPixelSize, 2048)
        let url = try Self.writeSolidPNG(width: 3000, height: 2200)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try XCTUnwrap(decodeFilesImageThumbnail(url: url))
        guard let cg = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Files thumbnail must vend a CGImage")
            return
        }
        XCTAssertLessThanOrEqual(cg.width, 2048)
        XCTAssertLessThanOrEqual(cg.height, 2048)
        XCTAssertLessThanOrEqual(cg.bytesPerRow * cg.height, 2048 * 2048 * 4)
        NSLog(
            "[perf-proof] filesSurface thumb source=3000x2200 decoded=%dx%d bytes=%d before_budget=%d after_budget=%d",
            cg.width, cg.height, cg.bytesPerRow * cg.height,
            4096 * 4096 * 4, 2048 * 2048 * 4
        )
    }

    private static func writeSolidPNG(width: Int, height: Int) throws -> URL {
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
            throw NSError(domain: "FilesSurfaceAuxSeamsTests", code: 1)
        }
        context.setFillColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "FilesSurfaceAuxSeamsTests", code: 2)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-files-thumb-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "FilesSurfaceAuxSeamsTests", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "FilesSurfaceAuxSeamsTests", code: 4)
        }
        return url
    }

    func test_binaryMetadataRows_includePathMimeAndByteSize() {
        // WHY: non-editable files use these rows as their only in-app inspection surface before
        // Reveal/Open Externally. Missing path/MIME/size makes binary diagnostics weak.
        let rows = binaryMetadataRows(relativePath: "build/app.bin", mime: "application/octet-stream", size: 42)

        XCTAssertEqual(rows, [
            BinaryMetadataRow(label: "Path", value: "build/app.bin"),
            BinaryMetadataRow(label: "MIME", value: "application/octet-stream"),
            BinaryMetadataRow(label: "Size", value: "42 bytes")
        ])
    }
}
