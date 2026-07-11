import Foundation
import CoreGraphics
import ImageIO

enum PetAtlasError: Error, Equatable {
    case missingResource(String)
    case invalidManifest(String)
    case invalidImage(String)
    case invalidFrame(state: PetAnimationState, index: Int)
}

struct PetAtlasManifest: Decodable, Equatable {
    struct Dimensions: Decodable, Equatable {
        let height: Int
        let width: Int
    }

    struct Grid: Decodable, Equatable {
        let columns: Int
        let frameHeight: Int
        let frameWidth: Int
        let origin: String
        let rows: Int
    }

    enum PlaybackMode: String, Decodable, Equatable {
        case loop
        case onceHold
        case onceThenWaiting
        case onceThenDerived
    }

    struct Row: Decodable, Equatable {
        struct VisualBounds: Decodable, Equatable {
            let height: Int
            let width: Int
            let x: Int
            let y: Int

            var rect: CGRect {
                CGRect(x: x, y: y, width: width, height: height)
            }
        }

        let canonicalFrame: Int
        let fps: Int
        let frames: Int
        let mode: PlaybackMode
        let row: Int
        let state: PetAnimationState
        let visualBounds: VisualBounds
    }

    let atlas: String
    let dimensions: Dimensions
    let fallbackState: PetAnimationState
    let grid: Grid
    let name: String
    let rows: [Row]
    let schemaVersion: Int

    var unusedFrameCount: Int {
        grid.columns * grid.rows - rows.reduce(0) { $0 + $1.frames }
    }

    func row(for state: PetAnimationState) -> Row? {
        rows.first { $0.state == state }
    }

    func validated() throws -> PetAtlasManifest {
        guard schemaVersion == 1 else {
            throw PetAtlasError.invalidManifest("schemaVersion must be 1")
        }
        guard dimensions == Dimensions(height: 3_328, width: 1_536) else {
            throw PetAtlasError.invalidManifest("atlas dimensions must be 1536x3328")
        }
        guard grid == Grid(columns: 8, frameHeight: 208, frameWidth: 192, origin: "top-left", rows: 16) else {
            throw PetAtlasError.invalidManifest("grid must be 8x16 with 192x208 top-left frames")
        }
        guard grid.columns * grid.frameWidth == dimensions.width,
              grid.rows * grid.frameHeight == dimensions.height else {
            throw PetAtlasError.invalidManifest("grid does not exactly cover atlas")
        }
        guard fallbackState == .idle else {
            throw PetAtlasError.invalidManifest("fallbackState must be idle")
        }
        guard rows.map(\.state) == PetAnimationState.allCases,
              rows.map(\.row) == Array(0..<grid.rows) else {
            throw PetAtlasError.invalidManifest("rows must match the stable 16-state atlas order")
        }
        for row in rows {
            let visualBounds = row.visualBounds.rect
            let frameBounds = CGRect(
                x: 0,
                y: 0,
                width: grid.frameWidth,
                height: grid.frameHeight
            )
            guard (1...grid.columns).contains(row.frames),
                  row.frames > row.canonicalFrame,
                  row.canonicalFrame >= 0,
                  row.fps > 0,
                  visualBounds.width > 0,
                  visualBounds.height > 0,
                  frameBounds.contains(visualBounds) else {
                throw PetAtlasError.invalidManifest("invalid playback metadata for \(row.state.rawValue)")
            }
        }
        guard rows.reduce(0, { $0 + $1.frames }) == 120, unusedFrameCount == 8 else {
            throw PetAtlasError.invalidManifest("atlas must contain 120 used and 8 unused frames")
        }
        return self
    }
}

struct PetAtlasFrame {
    let state: PetAnimationState
    let index: Int
    let image: CGImage
    let displayImage: CGImage
    let interpolationQuality: CGInterpolationQuality = .none

    /// Rendering entry point for AppKit/SwiftUI bridges. Pixel art must never be
    /// filtered when scaled to the configured pet size.
    func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.interpolationQuality = interpolationQuality
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

/// Bundle-backed atlas runtime. The full atlas is resolved and metadata-checked,
/// but never decoded. Runtime frames come from per-state row PNGs so decoded image
/// memory stays bounded to the active row plus at most two adjacent rows.
@MainActor
final class PetAtlas {
    let manifest: PetAtlasManifest
    let atlasURL: URL

    private let rowURLs: [PetAnimationState: URL]
    private var rowImages: [PetAnimationState: CGImage] = [:]

    var decodedRowStates: Set<PetAnimationState> { Set(rowImages.keys) }

    static func bundled() throws -> PetAtlas {
        let name = "remote-code-black-cat-atlas-v1"
        guard let manifestURL = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Pet")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw PetAtlasError.missingResource("\(name).json")
        }
        return try PetAtlas(manifestURL: manifestURL)
    }

    init(manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        self.manifest = try JSONDecoder().decode(PetAtlasManifest.self, from: data).validated()

        let directory = manifestURL.deletingLastPathComponent()
        let atlasURL = directory.appendingPathComponent(manifest.atlas)
        guard FileManager.default.fileExists(atPath: atlasURL.path) else {
            throw PetAtlasError.missingResource(manifest.atlas)
        }
        try Self.validateImageMetadata(
            at: atlasURL,
            width: manifest.dimensions.width,
            height: manifest.dimensions.height
        )
        self.atlasURL = atlasURL

        var rows: [PetAnimationState: URL] = [:]
        for state in PetAnimationState.allCases {
            let filename = "remote-code-black-cat-\(state.rawValue).png"
            let url = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PetAtlasError.missingResource(filename)
            }
            try Self.validateImageMetadata(
                at: url,
                width: manifest.dimensions.width,
                height: manifest.grid.frameHeight
            )
            rows[state] = url
        }
        self.rowURLs = rows
    }

    func rowURL(for state: PetAnimationState) throws -> URL {
        guard let url = rowURLs[state] else {
            throw PetAtlasError.missingResource("remote-code-black-cat-\(state.rawValue).png")
        }
        return url
    }

    func activate(_ state: PetAnimationState, adjacent: [PetAnimationState] = []) throws {
        var desired: [PetAnimationState] = [state]
        for candidate in adjacent where !desired.contains(candidate) && desired.count < 3 {
            desired.append(candidate)
        }
        let desiredSet = Set(desired)
        rowImages = rowImages.filter { desiredSet.contains($0.key) }
        for candidate in desired where rowImages[candidate] == nil {
            rowImages[candidate] = try decodeRow(candidate)
        }
    }

    func frame(state: PetAnimationState, index: Int) throws -> PetAtlasFrame {
        guard let row = manifest.row(for: state), (0..<row.frames).contains(index) else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        if rowImages[state] == nil {
            try activate(state)
        }
        guard let rowImage = rowImages[state] else {
            throw PetAtlasError.invalidImage("row did not decode for \(state.rawValue)")
        }
        let rect = CGRect(
            x: index * manifest.grid.frameWidth,
            y: 0,
            width: manifest.grid.frameWidth,
            height: manifest.grid.frameHeight
        )
        guard let image = rowImage.cropping(to: rect),
              image.width == manifest.grid.frameWidth,
              image.height == manifest.grid.frameHeight else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        let visualBounds = row.visualBounds.rect
        guard let displayImage = image.cropping(to: visualBounds),
              displayImage.width == Int(visualBounds.width),
              displayImage.height == Int(visualBounds.height) else {
            throw PetAtlasError.invalidFrame(state: state, index: index)
        }
        return PetAtlasFrame(
            state: state,
            index: index,
            image: image,
            displayImage: displayImage
        )
    }

    func canonicalFrame(for state: PetAnimationState) throws -> PetAtlasFrame {
        guard let row = manifest.row(for: state) else {
            throw PetAtlasError.invalidManifest("missing row for \(state.rawValue)")
        }
        return try frame(state: state, index: row.canonicalFrame)
    }

    private func decodeRow(_ state: PetAnimationState) throws -> CGImage {
        let url = try rowURL(for: state)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width == manifest.dimensions.width,
              image.height == manifest.grid.frameHeight,
              image.alphaInfo != .none,
              image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast else {
            throw PetAtlasError.invalidImage(url.lastPathComponent)
        }
        return image
    }

    private static func validateImageMetadata(at url: URL, width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (raw[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (raw[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth == width,
              pixelHeight == height else {
            throw PetAtlasError.invalidImage(url.lastPathComponent)
        }
    }
}
