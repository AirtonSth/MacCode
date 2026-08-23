import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Surfaces

final class AgentChatAttachmentThumbnailTests: XCTestCase {
    func test_fileKey_changesForRealSizeAndModificationInvalidations() throws {
        // WHY: reusing a path after its payload changes must not return the old chip image.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x11, count: 64), modificationOffset: 1)
        let first = try XCTUnwrap(AgentAttachmentThumbnailLoader.fileKey(forPath: fixture.imageURL.path))

        try fixture.install(Data(repeating: 0x22, count: 96), modificationOffset: 2)
        let second = try XCTUnwrap(AgentAttachmentThumbnailLoader.fileKey(forPath: fixture.imageURL.path))

        XCTAssertEqual(first.path, second.path)
        XCTAssertNotEqual(first.sizeBytes, second.sizeBytes)
        XCTAssertNotEqual(first.modificationTimeNanoseconds, second.modificationTimeNanoseconds)
        XCTAssertNotEqual(first, second)
    }

    func test_memoryCache_evictsBeforeExceedingItsStrictCostBudget() {
        // WHY: image chips can span many threads, so decoded pixels must never grow unbounded.
        var cache = AgentAttachmentThumbnailMemoryCache(costLimitBytes: 10, countLimit: 2)
        let firstKey = key(path: "/one.png", stamp: 1)
        let secondKey = key(path: "/two.png", stamp: 2)
        let thirdKey = key(path: "/three.png", stamp: 3)

        cache.insert(value(cost: 6, width: 1), for: firstKey)
        cache.insert(value(cost: 6, width: 2), for: secondKey)
        XCTAssertNil(cache.value(for: firstKey), "the older entry must leave before cost exceeds 10 bytes")
        XCTAssertNotNil(cache.value(for: secondKey))
        XCTAssertLessThanOrEqual(cache.totalCostBytes, cache.costLimitBytes)
        XCTAssertLessThanOrEqual(cache.count, cache.countLimit)

        cache.insert(value(cost: 11, width: 3), for: thirdKey)
        XCTAssertNil(cache.value(for: thirdKey), "an entry larger than the whole budget must not be retained")
        XCTAssertLessThanOrEqual(cache.totalCostBytes, cache.costLimitBytes)
        XCTAssertLessThanOrEqual(cache.count, cache.countLimit)

        var countLimited = AgentAttachmentThumbnailMemoryCache(costLimitBytes: 100, countLimit: 1)
        countLimited.insert(value(cost: 1, width: 1), for: firstKey)
        countLimited.insert(value(cost: 1, width: 2), for: secondKey)
        XCTAssertNil(countLimited.value(for: firstKey), "the older entry must leave before count exceeds one")
        XCTAssertNotNil(countLimited.value(for: secondKey))
        XCTAssertEqual(countLimited.count, 1)
    }

    func test_loader_reusesThenInvalidatesARealImageAtTheSamePath() async throws {
        // WHY: stable composer recomputes should hit memory, while a real same-path rewrite
        // must decode the replacement rather than paint stale pixels.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        let firstJPEG = try Self.makeLargeJPEG(width: 1_024, height: 1_024, variant: 1)
        let secondJPEG = try Self.makeLargeJPEG(width: 1_024, height: 1_023, variant: 2)
        let decodeProbe = ThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 256 * 1_024,
            countLimit: 8,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        try fixture.install(firstJPEG, modificationOffset: 10)
        let firstLoad = await loader.thumbnail(forPath: fixture.imageURL.path)
        let cachedLoad = await loader.thumbnail(forPath: fixture.imageURL.path)
        let first = try XCTUnwrap(firstLoad)
        let cached = try XCTUnwrap(cachedLoad)
        XCTAssertEqual(first.key, cached.key)

        try fixture.install(secondJPEG, modificationOffset: 20)
        let replacementLoad = await loader.thumbnail(forPath: fixture.imageURL.path)
        let replacement = try XCTUnwrap(replacementLoad)
        XCTAssertNotEqual(first.key, replacement.key)

        XCTAssertEqual(decodeProbe.count, 2, "one stable hit plus one real invalidation requires exactly two decodes")
        XCTAssertEqual(decodeProbe.mainThreadCount, 0, "ImageIO decode must never execute on MainActor")
        let cache = await loader.cacheSnapshot()
        XCTAssertLessThanOrEqual(cache.costBytes, 256 * 1_024)
        XCTAssertLessThanOrEqual(cache.entryCount, 8)
    }

    func test_loader_discardsAnAsyncDecodeWhenTheFileChangesMidFlight() async throws {
        // WHY: an old detached decode may complete after an attachment path is replaced.
        // The loader must observe the new signature and retry instead of publishing it.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x31, count: 64), modificationOffset: 30)
        let release = DispatchSemaphore(value: 0)
        let invocations = LockedCounter()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 128,
            countLimit: 4,
            decoder: { _, _ in
                let invocation = invocations.next()
                if invocation == 1 {
                    _ = release.wait(timeout: .now() + 5)
                }
                return AgentAttachmentDecodedThumbnail(
                    image: NSImage(size: NSSize(width: invocation, height: 1)),
                    costBytes: 16
                )
            }
        )

        let load = Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        for _ in 0..<500 where invocations.current == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStart = invocations.current > 0
        XCTAssertTrue(didStart, "the first detached decode must start")
        try fixture.install(Data(repeating: 0x42, count: 96), modificationOffset: 40)
        release.signal()

        let loaded = await load.value
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(result.image.size.width, 2, "only the retry for the current file may be published")
        XCTAssertEqual(result.key, AgentAttachmentThumbnailLoader.fileKey(forPath: fixture.imageURL.path))
        XCTAssertEqual(invocations.current, 2, "signature drift must discard once and decode the replacement")
    }

    func test_loader_preservesSVGPreviewWithABoundedOffMainRasterFallback() async throws {
        // WHY: attachment classification includes SVG, which NSImage displayed before this
        // optimization even though ImageIO cannot create an SVG thumbnail on macOS 14.
        let fixture = try ThumbnailFixture(pathExtension: "svg")
        defer { fixture.remove() }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">
          <rect width="120" height="80" fill="#d14"/>
        </svg>
        """
        try fixture.install(Data(svg.utf8), modificationOffset: 50)
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 64 * 64 * 4,
            countLimit: 1,
            maxPixel: 64
        )

        let loaded = await loader.thumbnail(forPath: fixture.imageURL.path)
        let result = try XCTUnwrap(loaded)

        XCTAssertEqual(max(result.image.size.width, result.image.size.height), 64)
        let cache = await loader.cacheSnapshot()
        XCTAssertLessThanOrEqual(cache.costBytes, 64 * 64 * 4)
        XCTAssertEqual(cache.entryCount, 1)
    }

    func test_loader_boundsDecodeFanoutAndDropsCancelledQueuedWork() async throws {
        // WHY: the chip row is eager and attachment count is not capped. A large draft
        // must not start an unbounded decode storm, and removed chips must leave the queue.
        let fixtures = try (0..<6).map { _ in try ThumbnailFixture() }
        defer { fixtures.forEach { $0.remove() } }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.install(
                Data(repeating: UInt8(index + 1), count: 64 + index),
                modificationOffset: 60 + index
            )
        }
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 256 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 2,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )
        let activeLoads = fixtures.prefix(2).map { fixture in
            Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        }

        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if decodeProbe.count == 2, snapshot.activeDecodeCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        var snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(decodeProbe.count, 2)
        XCTAssertEqual(snapshot.activeDecodeCount, 2)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0)

        let queuedLoads = fixtures.dropFirst(2).map { fixture in
            Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        }
        let loads = activeLoads + queuedLoads
        for _ in 0..<500 {
            snapshot = await loader.cacheSnapshot()
            if snapshot.waitingDecodeCount == 4 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(snapshot.waitingDecodeCount, 4)

        // The first two tasks already own both permits, so this task is deterministically queued.
        loads[5].cancel()
        for _ in 0..<500 {
            snapshot = await loader.cacheSnapshot()
            if snapshot.waitingDecodeCount == 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(snapshot.waitingDecodeCount, 3, "a removed chip must leave before a decode starts")
        decodeProbe.release(count: 5)

        var results: [AgentAttachmentThumbnailResult?] = []
        for load in loads {
            results.append(await load.value)
        }
        XCTAssertNil(results[5])
        XCTAssertTrue(results.dropLast().allSatisfy { $0 != nil })
        XCTAssertEqual(decodeProbe.count, 5, "the cancelled queued attachment must never enter the decoder")
        XCTAssertLessThanOrEqual(decodeProbe.maximumConcurrentCount, 2)
        XCTAssertEqual(decodeProbe.mainThreadCount, 0)
        snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 0)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0)
    }

    @MainActor
    func test_microbench_offMainBoundedThumbnail_beatsBodyDecodeWithRealInvalidations() async throws {
        // Same-process A/B: three real replacements of one 9 MP image path and a typing-sized
        // burst of body paints per version. Legacy opens NSImage synchronously on every paint;
        // off-main thumbnailing performs one ImageIO decode per signature, then reuses view state.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        let variants = [
            try Self.makeLargeJPEG(width: 3_072, height: 3_072, variant: 11),
            try Self.makeLargeJPEG(width: 3_072, height: 3_071, variant: 22),
            try Self.makeLargeJPEG(width: 3_072, height: 3_072, variant: 33),
        ]
        let warmup = 2
        let samples = 5
        let paintsPerVersion = 128
        let expectedDecodes = variants.count
        let expectedLegacyLoads = variants.count * paintsPerVersion
        var stamp = 100

        struct Measurement {
            let wallMilliseconds: Double
            let mainActorMilliseconds: Double
            let imageLoads: Int
            let mainThreadImageLoads: Int
            let cacheHits: Int
        }

        func legacyRun() throws -> Measurement {
            let start = DispatchTime.now().uptimeNanoseconds
            var mainActorNanoseconds: UInt64 = 0
            var checksum = 0
            for data in variants {
                stamp += 1
                try fixture.install(data, modificationOffset: stamp)
                for _ in 0..<paintsPerVersion {
                    let bodyStart = DispatchTime.now().uptimeNanoseconds
                    checksum &+= try Self.legacyBodyImageLoad(path: fixture.imageURL.path)
                    mainActorNanoseconds += DispatchTime.now().uptimeNanoseconds - bodyStart
                }
            }
            XCTAssertGreaterThan(checksum, 0)
            return Measurement(
                wallMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                mainActorMilliseconds: Double(mainActorNanoseconds) / 1_000_000,
                imageLoads: expectedLegacyLoads,
                mainThreadImageLoads: expectedLegacyLoads,
                cacheHits: 0
            )
        }

        func thumbnailRun() async throws -> Measurement {
            let decodeProbe = ThumbnailDecodeProbe()
            let loader = AgentAttachmentThumbnailLoader(
                costLimitBytes: 256 * 1_024,
                countLimit: 8,
                decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
            )
            let start = DispatchTime.now().uptimeNanoseconds
            var mainActorNanoseconds: UInt64 = 0
            var checksum = 0
            for data in variants {
                stamp += 1
                try fixture.install(data, modificationOffset: stamp)
                let firstLoad = await loader.thumbnail(forPath: fixture.imageURL.path)
                let cachedLoad = await loader.thumbnail(forPath: fixture.imageURL.path)
                let first = try XCTUnwrap(firstLoad)
                let cached = try XCTUnwrap(cachedLoad)
                XCTAssertEqual(first.key, cached.key)
                let bodyStart = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<paintsPerVersion {
                    checksum &+= Int(cached.image.size.width + cached.image.size.height)
                }
                mainActorNanoseconds += DispatchTime.now().uptimeNanoseconds - bodyStart
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            XCTAssertGreaterThan(checksum, 0)
            XCTAssertEqual(decodeProbe.count, expectedDecodes)
            XCTAssertEqual(expectedDecodes, variants.count)
            let cache = await loader.cacheSnapshot()
            XCTAssertLessThanOrEqual(cache.costBytes, 256 * 1_024)
            return Measurement(
                wallMilliseconds: elapsed,
                mainActorMilliseconds: Double(mainActorNanoseconds) / 1_000_000,
                imageLoads: decodeProbe.count,
                mainThreadImageLoads: decodeProbe.mainThreadCount,
                cacheHits: variants.count
            )
        }

        for _ in 0..<warmup {
            _ = try legacyRun()
            _ = try await thumbnailRun()
        }

        var legacy: [Measurement] = []
        var thumbnail: [Measurement] = []
        for sample in 0..<samples {
            if sample.isMultiple(of: 2) {
                legacy.append(try legacyRun())
                thumbnail.append(try await thumbnailRun())
            } else {
                thumbnail.append(try await thumbnailRun())
                legacy.append(try legacyRun())
            }
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        let legacyWallRaw = legacy.map(\.wallMilliseconds)
        let thumbnailWallRaw = thumbnail.map(\.wallMilliseconds)
        let legacyMainRaw = legacy.map(\.mainActorMilliseconds)
        let thumbnailMainRaw = thumbnail.map(\.mainActorMilliseconds)
        let legacyWallMedian = median(legacyWallRaw)
        let thumbnailWallMedian = median(thumbnailWallRaw)
        let legacyMainMedian = median(legacyMainRaw)
        let thumbnailMainMedian = median(thumbnailMainRaw)
        let wallImprovement = (legacyWallMedian - thumbnailWallMedian) / legacyWallMedian * 100
        let mainImprovement = (legacyMainMedian - thumbnailMainMedian) / legacyMainMedian * 100

        NSLog(
            "[perf-proof] attachmentChip legacy_wall_ms=%@ thumbnail_wall_ms=%@ wall_improvement_pct=%.2f legacy_main_actor_ms=%@ thumbnail_main_actor_ms=%@ main_improvement_pct=%.2f legacy_sync_loads=%d thumbnail_decodes=%d thumbnail_cache_hits=%d thumbnail_main_actor_decodes=%d raw_legacy_wall=%@ raw_thumbnail_wall=%@ raw_legacy_main=%@ raw_thumbnail_main=%@",
            String(legacyWallMedian), String(thumbnailWallMedian), wallImprovement,
            String(legacyMainMedian), String(thumbnailMainMedian), mainImprovement,
            legacy[0].imageLoads, thumbnail[0].imageLoads, thumbnail[0].cacheHits,
            thumbnail[0].mainThreadImageLoads,
            String(describing: legacyWallRaw), String(describing: thumbnailWallRaw),
            String(describing: legacyMainRaw), String(describing: thumbnailMainRaw)
        )
        XCTAssertGreaterThan(wallImprovement, 5.0, "off-main bounded thumbnails must improve median wall time by >5%")
        XCTAssertGreaterThan(mainImprovement, 5.0, "body reuse must improve MainActor time by >5%")
        XCTAssertTrue(thumbnail.allSatisfy { $0.imageLoads == expectedDecodes })
        XCTAssertTrue(thumbnail.allSatisfy { $0.mainThreadImageLoads == 0 })
        XCTAssertTrue(legacy.allSatisfy { $0.mainThreadImageLoads == expectedLegacyLoads })
    }

    private func key(path: String, stamp: Int64) -> AgentAttachmentThumbnailKey {
        AgentAttachmentThumbnailKey(path: path, modificationTimeNanoseconds: stamp, sizeBytes: stamp)
    }

    private func value(cost: Int, width: CGFloat) -> AgentAttachmentDecodedThumbnail {
        AgentAttachmentDecodedThumbnail(
            image: NSImage(size: NSSize(width: width, height: 1)),
            costBytes: cost
        )
    }

    private static func legacyBodyImageLoad(path: String) throws -> Int {
        XCTAssertTrue(Thread.isMainThread, "legacy SwiftUI body work must be measured on MainActor")
        return try autoreleasepool {
            let image = try XCTUnwrap(NSImage(contentsOfFile: path))
            return Int(image.size.width + image.size.height)
        }
    }

    private static func makeLargeJPEG(width: Int, height: Int, variant: Int) throws -> Data {
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
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ThumbnailFixture {
    let directoryURL: URL
    let imageURL: URL
    private let baseModificationTime = Date(timeIntervalSince1970: 2_000_000_000)

    init(pathExtension: String = "jpg") throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachment-thumb-\(UUID().uuidString)", isDirectory: true)
        imageURL = directoryURL.appendingPathComponent("attachment.\(pathExtension)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func install(_ data: Data, modificationOffset: Int) throws {
        try data.write(to: imageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: baseModificationTime.addingTimeInterval(TimeInterval(modificationOffset))],
            ofItemAtPath: imageURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ThumbnailDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _mainThreadCount = 0

    func decode(path: String, maxPixel: Int) -> AgentAttachmentDecodedThumbnail? {
        lock.lock()
        _count += 1
        if Thread.isMainThread { _mainThreadCount += 1 }
        lock.unlock()
        return AgentAttachmentThumbnailLoader.decodeImage(path: path, maxPixel: maxPixel)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var mainThreadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _mainThreadCount
    }
}

private final class BlockingThumbnailDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let permits = DispatchSemaphore(value: 0)
    private var _count = 0
    private var _activeCount = 0
    private var _maximumConcurrentCount = 0
    private var _mainThreadCount = 0

    func decode(path: String, maxPixel: Int) -> AgentAttachmentDecodedThumbnail? {
        lock.lock()
        _count += 1
        _activeCount += 1
        _maximumConcurrentCount = max(_maximumConcurrentCount, _activeCount)
        if Thread.isMainThread { _mainThreadCount += 1 }
        lock.unlock()
        _ = permits.wait(timeout: .now() + 5)
        lock.lock()
        _activeCount -= 1
        lock.unlock()
        return AgentAttachmentDecodedThumbnail(
            image: NSImage(size: NSSize(width: maxPixel, height: 1)),
            costBytes: max(1, maxPixel * 4)
        )
    }

    func release(count: Int) {
        for _ in 0..<count { permits.signal() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var maximumConcurrentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maximumConcurrentCount
    }

    var mainThreadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _mainThreadCount
    }
}
