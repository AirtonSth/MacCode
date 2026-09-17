import AppKit
import Darwin
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

    func test_appKitSVGFallback_sizeGate_skipsAboveTwoMiB() {
        // WHY: NSImage(contentsOf:) on a large SVG expands XML into an unbounded
        // bitmap. The gate is a pure size check so the skip does not depend on
        // AppKit actually parsing the payload.
        let limit = AgentAttachmentThumbnailLoader.maxAppKitSVGFallbackBytes
        XCTAssertEqual(limit, 2 * 1_024 * 1_024)
        XCTAssertTrue(AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(fileSizeBytes: limit))
        XCTAssertTrue(AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(fileSizeBytes: 1))
        XCTAssertFalse(AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(fileSizeBytes: limit + 1))
        XCTAssertFalse(AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(fileSizeBytes: 0))
        XCTAssertFalse(AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(fileSizeBytes: -1))
    }

    func test_decodeImage_skipsOversizedSVGFallback_andKeepsImageIO() throws {
        // WHY: ImageIO remains the path for raster files of any size; only the
        // AppKit SVG fallback is size-capped. A >2 MiB SVG must not call
        // NSImage(contentsOf:), which we prove by decode returning nil.
        let svgFixture = try ThumbnailFixture(pathExtension: "svg")
        defer { svgFixture.remove() }
        let overLimit = Int(AgentAttachmentThumbnailLoader.maxAppKitSVGFallbackBytes) + 64
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"></svg><!--"
        svg += String(repeating: "x", count: overLimit)
        svg += "-->"
        let svgData = Data(svg.utf8)
        try svgFixture.install(svgData, modificationOffset: 1)
        XCTAssertGreaterThan(svgData.count, Int(AgentAttachmentThumbnailLoader.maxAppKitSVGFallbackBytes))
        XCTAssertFalse(
            AgentAttachmentThumbnailLoader.allowsAppKitImageFallback(path: svgFixture.imageURL.path)
        )
        XCTAssertNil(
            AgentAttachmentThumbnailLoader.decodeImage(path: svgFixture.imageURL.path, maxPixel: 64),
            "oversized SVG must skip NSImage(contentsOf:) and return nil"
        )

        let jpegFixture = try ThumbnailFixture()
        defer { jpegFixture.remove() }
        let jpeg = try Self.makeLargeJPEG(width: 2_048, height: 2_048, variant: 9)
        try jpegFixture.install(jpeg, modificationOffset: 2)
        let jpegSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: jpegFixture.imageURL.path)[.size] as? NSNumber)?.int64Value
        )
        NSLog(
            "[memperf] thumbnail-svg-skip svg_bytes=%d jpeg_bytes=%d jpeg_over_2mib=%d",
            svgData.count, jpegSize, jpegSize > AgentAttachmentThumbnailLoader.maxAppKitSVGFallbackBytes ? 1 : 0
        )
        let decoded = try XCTUnwrap(
            AgentAttachmentThumbnailLoader.decodeImage(path: jpegFixture.imageURL.path, maxPixel: 64)
        )
        XCTAssertLessThanOrEqual(Int(decoded.image.size.width), 64)
        XCTAssertLessThanOrEqual(Int(decoded.image.size.height), 64)
        XCTAssertGreaterThan(decoded.costBytes, 0)
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

    func test_loader_cachesComposerAndTranscriptSizesIndependently() async throws {
        // WHY: the composer uses a 64 px chip while transcript citations need a
        // larger preview. Sharing the bounded loader must not return the chip-sized
        // bitmap for the transcript or repeatedly evict the other presentation.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(
            Self.makeLargeJPEG(width: 1_024, height: 768, variant: 44),
            modificationOffset: 24
        )
        let decodeProbe = ThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        let chipResult = await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 64)
        let transcriptResult = await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        let chipHitResult = await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 64)
        let transcriptHitResult = await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        let chip = try XCTUnwrap(chipResult)
        let transcript = try XCTUnwrap(transcriptResult)
        let chipHit = try XCTUnwrap(chipHitResult)
        let transcriptHit = try XCTUnwrap(transcriptHitResult)

        XCTAssertEqual(chip.image.size, chipHit.image.size)
        XCTAssertEqual(transcript.image.size, transcriptHit.image.size)
        XCTAssertNotEqual(chip.key, transcript.key)
        XCTAssertEqual(chip.key.maxPixel, 64)
        XCTAssertEqual(transcript.key.maxPixel, 280)
        XCTAssertEqual(decodeProbe.count, 2,
            "each requested presentation size must decode once and then hit the same hard-bounded cache")
        let cache = await loader.cacheSnapshot()
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertLessThanOrEqual(cache.costBytes, 512 * 1_024)
    }

    func test_transcriptPolicyUsesOnlyDisplaySizedDecodes() async throws {
        // WHY: the production transcript path must call the shared bounded loader
        // at the strip/featured pixel budgets instead of restoring its own decode.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x5A, count: 64), modificationOffset: 25)
        let requestedPixels = LockedIntRecorder()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 128,
            countLimit: 4,
            decoder: { _, maxPixel in
                requestedPixels.append(maxPixel)
                return AgentAttachmentDecodedThumbnail(
                    image: NSImage(size: NSSize(width: maxPixel, height: 1)),
                    costBytes: 4
                )
            }
        )

        let strip = await loader.transcriptThumbnail(
            forPath: fixture.imageURL.path,
            featured: false
        )
        let featured = await loader.transcriptThumbnail(
            forPath: fixture.imageURL.path,
            featured: true
        )

        XCTAssertEqual(try XCTUnwrap(strip).key.maxPixel, 280)
        XCTAssertEqual(try XCTUnwrap(featured).key.maxPixel, 640)
        XCTAssertEqual(try XCTUnwrap(strip).image.size.width, 280)
        XCTAssertEqual(try XCTUnwrap(featured).image.size.width, 640)
        XCTAssertEqual(requestedPixels.values, [280, 640])
        let cache = await loader.cacheSnapshot()
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertLessThanOrEqual(cache.costBytes, 128)
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
        // WHY: attachment count is not capped. A large draft must not start an
        // unbounded stat/decode storm, and removed chips must leave the queue.
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

    func test_loader_coalescesConcurrentRequestsForTheSameTranscriptImage() async throws {
        // WHY: the same citation can be mounted in a collapsed strip and an
        // expanded row simultaneously. Shared admission alone still allows both
        // callers to spend CPU decoding identical pixels.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x6B, count: 96), modificationOffset: 88)
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 2,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        let first = Task {
            await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 where decodeProbe.count == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let second = Task {
            await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if snapshot.inFlightConsumerCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let coalescedSnapshot = await loader.cacheSnapshot()
        let decodeCountBeforeRelease = decodeProbe.count
        decodeProbe.release(count: 2)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(coalescedSnapshot.activeDecodeCount, 1,
            "one coalesced physical decode must own exactly one permit")
        XCTAssertEqual(decodeCountBeforeRelease, 1,
            "concurrent callers for one file signature and size must share one decode")
        XCTAssertEqual(firstResult?.key, secondResult?.key)
        XCTAssertEqual(firstResult?.image.size, secondResult?.image.size)
        XCTAssertEqual(decodeProbe.count, 1)
    }

    func test_cancellingACoalescedCallerDoesNotRetainASecondDecodePermit() async throws {
        // WHY: admission belongs to the one physical decode, not to every caller
        // awaiting it. Cancelling A while B survives must leave capacity for an
        // unrelated C without releasing or cancelling B's shared decode.
        let fixtures = try (0..<2).map { _ in try ThumbnailFixture() }
        defer { fixtures.forEach { $0.remove() } }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.install(
                Data(repeating: UInt8(0x78 + index), count: 96 + index),
                modificationOffset: 188 + index
            )
        }
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 2,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        let callerA = Task {
            await loader.thumbnail(forPath: fixtures[0].imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 where decodeProbe.count == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let callerB = Task {
            await loader.thumbnail(forPath: fixtures[0].imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if snapshot.inFlightConsumerCount == 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        var snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.inFlightDecodeCount, 1)
        XCTAssertEqual(snapshot.inFlightConsumerCount, 2)
        XCTAssertEqual(snapshot.activeDecodeCount, 1,
            "two callers sharing one physical decode must retain only one permit")
        XCTAssertEqual(decodeProbe.count, 1)

        callerA.cancel()
        for _ in 0..<500 {
            snapshot = await loader.cacheSnapshot()
            if snapshot.inFlightConsumerCount == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(snapshot.inFlightConsumerCount, 1,
            "cancelling A must preserve B as the shared decode's sole consumer")

        let callerC = Task {
            await loader.thumbnail(forPath: fixtures[1].imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 where decodeProbe.count < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let callerCEnteredBeforeBWasReleased = decodeProbe.count == 2
        snapshot = await loader.cacheSnapshot()

        // Cleanup happens before assertions so a red run cannot strand either decoder.
        decodeProbe.release(count: 3)
        let resultA = await callerA.value
        let resultB = await callerB.value
        let resultC = await callerC.value

        XCTAssertTrue(callerCEnteredBeforeBWasReleased,
            "C must enter while B's shared physical decode is still blocked")
        XCTAssertEqual(snapshot.activeDecodeCount, 2,
            "B and C are the only two physical decodes that may own permits")
        XCTAssertEqual(snapshot.waitingDecodeCount, 0,
            "C must enter directly instead of consuming one of the eight waiter slots")
        XCTAssertEqual(snapshot.inFlightDecodeCount, 2)
        XCTAssertNil(resultA)
        XCTAssertNotNil(resultB, "cancelling A must not cancel survivor B")
        XCTAssertNotNil(resultC)
        XCTAssertLessThanOrEqual(decodeProbe.maximumConcurrentCount, 2)
        let finalSnapshot = await loader.cacheSnapshot()
        XCTAssertEqual(finalSnapshot.activeDecodeCount, 0)
        XCTAssertEqual(finalSnapshot.waitingDecodeCount, 0)
        XCTAssertEqual(finalSnapshot.inFlightDecodeCount, 0)
    }

    func test_cancellingOneCoalescedCallerDoesNotCancelTheSharedDecode() async throws {
        // WHY: SwiftUI can unmount one presentation of an attachment while a
        // second presentation still needs the same pixels. Cancellation of the
        // first waiter must not discard the shared work needed by the survivor.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x6C, count: 96), modificationOffset: 89)
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 2,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        let cancelled = Task {
            await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 where decodeProbe.count == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let survivor = Task {
            await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if snapshot.inFlightConsumerCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let coalescedSnapshot = await loader.cacheSnapshot()
        XCTAssertEqual(coalescedSnapshot.activeDecodeCount, 1,
            "the shared physical decode, not its two consumers, owns admission")
        XCTAssertEqual(coalescedSnapshot.inFlightDecodeCount, 1)
        XCTAssertEqual(coalescedSnapshot.inFlightConsumerCount, 2,
            "the cancellation scenario must first establish two consumers of one decode")

        cancelled.cancel()
        let decodeCountBeforeRelease = decodeProbe.count
        decodeProbe.release(count: 2)
        let cancelledResult = await cancelled.value
        let survivorResult = await survivor.value

        XCTAssertNil(cancelledResult)
        XCTAssertNotNil(survivorResult)
        XCTAssertEqual(decodeCountBeforeRelease, 1)
        XCTAssertEqual(decodeProbe.count, 1)
    }

    func test_cancellingTheLastConsumerCancelsTheSharedDecode() async throws {
        // WHY: an unmounted transcript row must not leave its sole detached
        // ImageIO job consuming a decode permit after nobody can use the result.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(Data(repeating: 0x6D, count: 96), modificationOffset: 90)
        let decodeProbe = CancellationAwareThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 1,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )

        let load = Task {
            await loader.thumbnail(forPath: fixture.imageURL.path, maxPixel: 280)
        }
        for _ in 0..<500 where decodeProbe.count == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(decodeProbe.count, 1)

        load.cancel()
        for _ in 0..<500 where decodeProbe.cancellationCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        decodeProbe.release()

        let cancelledResult = await load.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(decodeProbe.cancellationCount, 1,
            "the detached decode must receive cancellation when its final consumer leaves")
        let snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 0)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0)
    }

    func test_transcriptRetriesSaturationWithoutUnboundedAdmissionOrRemount() async throws {
        // WHY: transcript history can eagerly mount more than ten images. A
        // temporary full gate may delay a preview, but must not permanently turn
        // a valid image into "Preview unavailable" while the row remains mounted.
        let fixtures = try (0..<2).map { _ in try ThumbnailFixture() }
        defer { fixtures.forEach { $0.remove() } }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.install(
                Data(repeating: UInt8(0x70 + index), count: 96 + index),
                modificationOffset: 91 + index
            )
        }
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let retryProbe = ThumbnailRetrySleeperProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 512 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 1,
            maxWaitingDecodes: 0,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) },
            retrySleeper: { _ in await retryProbe.sleep() }
        )

        let activeLoad = Task {
            await loader.thumbnail(forPath: fixtures[0].imageURL.path, maxPixel: 64)
        }
        for _ in 0..<500 where decodeProbe.count == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(decodeProbe.count, 1)

        let transcriptLoad = Task {
            await loader.transcriptThumbnail(
                forPath: fixtures[1].imageURL.path,
                featured: false
            )
        }
        await retryProbe.waitUntilSleeping()

        var snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 1)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0,
            "saturation retry must not enlarge the loader continuation bound")

        decodeProbe.release(count: 1)
        let activeResult = await activeLoad.value
        XCTAssertNotNil(activeResult)
        await retryProbe.resume()
        for _ in 0..<500 where decodeProbe.count < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        decodeProbe.release(count: 1)

        let transcriptResult = await transcriptLoad.value
        let transcript = try XCTUnwrap(transcriptResult)
        XCTAssertEqual(transcript.key.maxPixel, 280)
        XCTAssertEqual(decodeProbe.count, 2)
        snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 0)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0)
    }

    func test_loader_rejectsDecorativeThumbnailWorkBeyondItsHardAdmissionBound() async throws {
        // WHY: LazyHStack bounds the current composer caller, but the loader is a
        // shared authority and must remain bounded even if another caller submits
        // an arbitrary batch. Saturation may keep the harmless photo placeholder;
        // it must not retain N file stats, decodes, or continuations.
        let fixtures = try (0..<20).map { _ in try ThumbnailFixture() }
        defer { fixtures.forEach { $0.remove() } }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.install(
                Data(repeating: UInt8(index + 1), count: 64 + index),
                modificationOffset: 200 + index
            )
        }
        let decodeProbe = BlockingThumbnailDecodeProbe()
        let loader = AgentAttachmentThumbnailLoader(
            costLimitBytes: 256 * 1_024,
            countLimit: 8,
            maxConcurrentDecodes: 2,
            maxWaitingDecodes: 2,
            decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
        )
        let activeLoads = fixtures.prefix(2).map { fixture in
            Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        }

        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if snapshot.activeDecodeCount == 2, decodeProbe.count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let queuedLoads = fixtures.dropFirst(2).prefix(2).map { fixture in
            Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        }
        for _ in 0..<500 {
            let snapshot = await loader.cacheSnapshot()
            if snapshot.waitingDecodeCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let overflowLoads = fixtures.dropFirst(4).map { fixture in
            Task { await loader.thumbnail(forPath: fixture.imageURL.path) }
        }
        var overflowResults: [AgentAttachmentThumbnailResult?] = []
        for load in overflowLoads { overflowResults.append(await load.value) }

        var snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 2)
        XCTAssertEqual(snapshot.waitingDecodeCount, 2)
        XCTAssertEqual(decodeProbe.count, 2,
            "only admitted requests may reach decode while the gate is saturated")
        XCTAssertTrue(overflowResults.allSatisfy { $0 == nil },
            "overflow requests must fail to the decorative placeholder without being retained")

        decodeProbe.release(count: 4)
        var results: [AgentAttachmentThumbnailResult?] = []
        for load in activeLoads + queuedLoads { results.append(await load.value) }
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(decodeProbe.count, 4)
        XCTAssertLessThanOrEqual(decodeProbe.maximumConcurrentCount, 2)
        snapshot = await loader.cacheSnapshot()
        XCTAssertEqual(snapshot.activeDecodeCount, 0)
        XCTAssertEqual(snapshot.waitingDecodeCount, 0)
    }

    func test_microbench_transcriptRemountsReuseTheBoundedThumbnailCache() async throws {
        // Same-process A/B for the production gap: transcript rows used to run a
        // detached ImageIO decode on every SwiftUI remount. The candidate runs the
        // identical decoder once and serves later mounts from the existing cache.
        let fixture = try ThumbnailFixture()
        defer { fixture.remove() }
        try fixture.install(
            Self.makeLargeJPEG(width: 2_048, height: 2_047, variant: 77),
            modificationOffset: 177
        )
        let path = fixture.imageURL.path
        let maxPixel = 280
        let mounts = 12
        let warmup = 2
        let samples = 5

        struct Measurement {
            let wallMilliseconds: Double
            let cpuMilliseconds: Double
            let decodes: Int
            let imageSize: NSSize
        }

        func cpuMilliseconds() -> Double {
            Double(clock()) / Double(CLOCKS_PER_SEC) * 1_000
        }

        func legacyRun() async throws -> Measurement {
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = cpuMilliseconds()
            var imageSize = NSSize.zero
            for _ in 0..<mounts {
                let decoded = await Task.detached(priority: .utility) {
                    AgentAttachmentThumbnailLoader.decodeImage(path: path, maxPixel: maxPixel)
                }.value
                imageSize = try XCTUnwrap(decoded).image.size
            }
            return Measurement(
                wallMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000,
                cpuMilliseconds: cpuMilliseconds() - cpuStart,
                decodes: mounts,
                imageSize: imageSize
            )
        }

        func cachedRun() async throws -> Measurement {
            let decodeProbe = ThumbnailDecodeProbe()
            let loader = AgentAttachmentThumbnailLoader(
                costLimitBytes: AgentAttachmentThumbnailLoader.defaultCostLimitBytes,
                countLimit: AgentAttachmentThumbnailLoader.defaultCountLimit,
                decoder: { path, maxPixel in decodeProbe.decode(path: path, maxPixel: maxPixel) }
            )
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = cpuMilliseconds()
            var imageSize = NSSize.zero
            for _ in 0..<mounts {
                let result = await loader.thumbnail(forPath: path, maxPixel: maxPixel)
                imageSize = try XCTUnwrap(result).image.size
            }
            let snapshot = await loader.cacheSnapshot()
            XCTAssertLessThanOrEqual(snapshot.costBytes, AgentAttachmentThumbnailLoader.defaultCostLimitBytes)
            XCTAssertLessThanOrEqual(snapshot.entryCount, AgentAttachmentThumbnailLoader.defaultCountLimit)
            return Measurement(
                wallMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000,
                cpuMilliseconds: cpuMilliseconds() - cpuStart,
                decodes: decodeProbe.count,
                imageSize: imageSize
            )
        }

        for _ in 0..<warmup {
            _ = try await legacyRun()
            _ = try await cachedRun()
        }

        var legacy: [Measurement] = []
        var cached: [Measurement] = []
        for sample in 0..<samples {
            if sample.isMultiple(of: 2) {
                legacy.append(try await legacyRun())
                cached.append(try await cachedRun())
            } else {
                cached.append(try await cachedRun())
                legacy.append(try await legacyRun())
            }
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        let legacyWall = legacy.map(\.wallMilliseconds)
        let cachedWall = cached.map(\.wallMilliseconds)
        let legacyCPU = legacy.map(\.cpuMilliseconds)
        let cachedCPU = cached.map(\.cpuMilliseconds)
        let wallImprovement = (median(legacyWall) - median(cachedWall)) / median(legacyWall) * 100
        let cpuImprovement = (median(legacyCPU) - median(cachedCPU)) / median(legacyCPU) * 100

        NSLog(
            "[perf-proof] transcriptThumbnail mounts=%d legacy_decodes=%d cached_decodes=%d wall_improvement_pct=%.2f cpu_improvement_pct=%.2f raw_legacy_wall=%@ raw_cached_wall=%@ raw_legacy_cpu=%@ raw_cached_cpu=%@",
            mounts, mounts, cached[0].decodes, wallImprovement, cpuImprovement,
            String(describing: legacyWall), String(describing: cachedWall),
            String(describing: legacyCPU), String(describing: cachedCPU)
        )
        XCTAssertGreaterThan(wallImprovement, 5.0)
        XCTAssertGreaterThan(cpuImprovement, 5.0)
        XCTAssertTrue(cached.allSatisfy { $0.decodes == 1 })
        XCTAssertTrue(legacy.allSatisfy { $0.decodes == mounts })
        XCTAssertTrue(zip(legacy, cached).allSatisfy { pair in
            pair.0.imageSize == pair.1.imageSize
        },
            "cache reuse must return the exact same decoded thumbnail dimensions")
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

private final class LockedIntRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
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

private final class CancellationAwareThumbnailDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let permit = DispatchSemaphore(value: 0)
    private var _count = 0
    private var _cancellationCount = 0

    func decode(path: String, maxPixel: Int) -> AgentAttachmentDecodedThumbnail? {
        lock.lock()
        _count += 1
        lock.unlock()
        while permit.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
            guard Task.isCancelled else { continue }
            lock.lock()
            _cancellationCount += 1
            lock.unlock()
            return nil
        }
        return AgentAttachmentDecodedThumbnail(
            image: NSImage(size: NSSize(width: maxPixel, height: 1)),
            costBytes: max(1, maxPixel * 4)
        )
    }

    func release() {
        permit.signal()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _cancellationCount
    }
}

private actor ThumbnailRetrySleeperProbe {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Bool, Never>?

    func sleep() async -> Bool {
        return await withCheckedContinuation { continuation in
            sleepContinuation = continuation
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSleeping() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        sleepContinuation?.resume(returning: true)
        sleepContinuation = nil
    }
}
