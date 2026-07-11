import XCTest
import CoreGraphics
@testable import AppShell

@MainActor
final class PetAssetRuntimeTests: XCTestCase {
    func test_bundledManifest_matchesProductionAtlasContract() throws {
        let atlas = try PetAtlas.bundled()
        let manifest = atlas.manifest

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.dimensions.width, 1_536)
        XCTAssertEqual(manifest.dimensions.height, 3_328)
        XCTAssertEqual(manifest.grid.columns, 8)
        XCTAssertEqual(manifest.grid.rows, 16)
        XCTAssertEqual(manifest.grid.frameWidth, 192)
        XCTAssertEqual(manifest.grid.frameHeight, 208)
        XCTAssertEqual(manifest.rows.map(\.state), PetAnimationState.allCases)
        XCTAssertEqual(manifest.rows.reduce(0) { $0 + $1.frames }, 120)
        XCTAssertEqual(manifest.unusedFrameCount, 8)
    }

    func test_bundledAtlas_resolvesFullAtlasAndEveryStateRow_withoutDecodingRows() throws {
        let atlas = try PetAtlas.bundled()

        XCTAssertEqual(atlas.atlasURL.lastPathComponent, "remote-code-black-cat-atlas.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: atlas.atlasURL.path))
        for state in PetAnimationState.allCases {
            let url = try atlas.rowURL(for: state)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing row for \(state.rawValue)")
            XCTAssertEqual(url.lastPathComponent, "remote-code-black-cat-\(state.rawValue).png")
        }
        XCTAssertTrue(atlas.decodedRowStates.isEmpty,
            "resource validation must inspect image metadata, not decode the 20 MB full atlas")
    }

    func test_frameCropping_isExactAndNearestNeighbor_withBoundedRowCache() throws {
        let atlas = try PetAtlas.bundled()
        try atlas.activate(.idle, adjacent: [.coding])

        let first = try atlas.frame(state: .idle, index: 0)
        let last = try atlas.frame(state: .idle, index: 7)

        XCTAssertEqual(first.image.width, 192)
        XCTAssertEqual(first.image.height, 208)
        XCTAssertEqual(last.image.width, 192)
        XCTAssertEqual(last.image.height, 208)
        XCTAssertEqual(first.interpolationQuality, .none)
        XCTAssertEqual(atlas.decodedRowStates, Set([.idle, .coding]))

        try atlas.activate(.search, adjacent: [.idle])
        XCTAssertEqual(atlas.decodedRowStates, Set([.search, .idle]))
        XCTAssertLessThanOrEqual(atlas.decodedRowStates.count, 3,
            "runtime memory must retain only the active row and bounded adjacent rows")
    }

    func test_all120UsedFrames_decodeAndCropAcrossEveryStateRow() throws {
        let atlas = try PetAtlas.bundled()
        var croppedFrameCount = 0

        for row in atlas.manifest.rows {
            try atlas.activate(row.state)
            for index in 0..<row.frames {
                let frame = try atlas.frame(state: row.state, index: index)
                XCTAssertEqual(frame.image.width, 192)
                XCTAssertEqual(frame.image.height, 208)
                croppedFrameCount += 1
            }
            XCTAssertEqual(atlas.decodedRowStates, Set([row.state]),
                "serial validation must release the previous decoded row")
        }

        XCTAssertEqual(croppedFrameCount, 120)
    }

    func test_allFramesHaveNoSmallFragmentsFromAdjacentSourceCells() throws {
        let atlas = try PetAtlas.bundled()
        var suspiciousFragments: [String] = []

        for row in atlas.manifest.rows {
            try atlas.activate(row.state)
            for index in 0..<row.frames {
                let frame = try atlas.frame(state: row.state, index: index)
                for component in alphaComponents(in: frame.image) {
                    // The packer maps each source cell to x=26...166 with at most one pixel of motion.
                    // Small components at either horizontal limit are adjacent-cell spill, not Pet art.
                    let touchesHorizontalSourceCropEdge = component.bounds.minX <= 27
                        || component.bounds.maxX >= 164
                    if touchesHorizontalSourceCropEdge, component.pixelCount <= 64 {
                        suspiciousFragments.append(
                            "\(row.state.rawValue)[\(index)] area=\(component.pixelCount) bounds=\(component.bounds)"
                        )
                    }
                }
            }
        }

        XCTAssertTrue(suspiciousFragments.isEmpty,
            "sprite frames must not retain small alpha fragments from neighboring source cells:\n"
                + suspiciousFragments.joined(separator: "\n"))
    }

    func test_canonicalFrame_usesManifestIndex_andRejectsUnusedCell() throws {
        let atlas = try PetAtlas.bundled()
        let canonical = try atlas.canonicalFrame(for: .listening)

        XCTAssertEqual(canonical.state, .listening)
        XCTAssertEqual(canonical.index, 0)
        XCTAssertThrowsError(try atlas.frame(state: .listening, index: 6)) { error in
            XCTAssertEqual(error as? PetAtlasError, .invalidFrame(state: .listening, index: 6))
        }
    }

    func test_animationController_neverKeepsMoreThanOneTimer_andStopsForEveryPausePolicy() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)

        try controller.setState(.idle)
        XCTAssertEqual(scheduler.activeTimerCount, 1)
        try controller.setState(.coding)
        XCTAssertEqual(scheduler.activeTimerCount, 1)
        XCTAssertEqual(scheduler.maximumActiveTimerCount, 1)

        controller.setVisible(false)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
        XCTAssertEqual(controller.currentFrameIndex, 0)
        controller.setVisible(true)
        XCTAssertEqual(scheduler.activeTimerCount, 1)

        controller.setScreenLocked(true)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
        controller.setScreenLocked(false)
        XCTAssertEqual(scheduler.activeTimerCount, 1)

        controller.setAnimationsEnabled(false)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
        controller.setAnimationsEnabled(true)
        XCTAssertEqual(scheduler.activeTimerCount, 1)

        controller.setReducedMotion(true)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
        XCTAssertEqual(controller.currentFrameIndex, 0,
            "Reduced Motion must project the manifest canonical static frame")

        controller.setReducedMotion(false)
        try controller.setState(.sleeping)
        XCTAssertEqual(scheduler.activeTimerCount, 0,
            "the idle sleeping state must stay static instead of spending energy on a repeating timer")
        XCTAssertEqual(controller.currentFrameIndex, 0,
            "sleeping must project the manifest canonical static frame")
    }

    func test_loopPlayback_wraps_andKeepsSingleTimer() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)
        try controller.setState(.idle)

        for _ in 0..<8 { scheduler.fireActiveTimer() }

        XCTAssertEqual(controller.currentState, .idle)
        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertEqual(scheduler.activeTimerCount, 1)
        XCTAssertEqual(scheduler.maximumActiveTimerCount, 1)
    }

    func test_animationController_deinitInvalidatesItsOnlyTimer() throws {
        let scheduler = TestPetAnimationScheduler()
        var controller: PetAnimationController? = try PetAnimationController(
            atlas: .bundled(),
            scheduler: scheduler
        )
        try controller?.setState(.idle)
        XCTAssertEqual(scheduler.activeTimerCount, 1)

        controller = nil

        XCTAssertEqual(scheduler.activeTimerCount, 0,
            "the RunLoop must not retain a dead controller's repeating timer")
    }

    func test_oncePlayback_holdsOrTransitionsAtTerminalFrame() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)

        try controller.setState(.success)
        for _ in 0..<7 { scheduler.fireActiveTimer() }
        XCTAssertEqual(controller.currentFrameIndex, 7)
        XCTAssertEqual(scheduler.activeTimerCount, 0,
            "onceHold must stop on its final visible frame")

        try controller.setState(.failed)
        for _ in 0..<8 { scheduler.fireActiveTimer() }
        XCTAssertEqual(controller.currentState, .waiting)
        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertEqual(scheduler.activeTimerCount, 1,
            "onceThenWaiting must continue with the waiting loop")

        try controller.setState(.interrupted, derivedTerminalState: .reconnecting)
        for _ in 0..<6 { scheduler.fireActiveTimer() }
        XCTAssertEqual(controller.currentState, .reconnecting)
        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertEqual(scheduler.activeTimerCount, 1,
            "onceThenDerived must continue with the caller's derived loop")
    }
}

private struct AlphaComponent {
    let pixelCount: Int
    let bounds: CGRect
}

private func alphaComponents(in image: CGImage, threshold: UInt8 = 1) -> [AlphaComponent] {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var visited = [Bool](repeating: false, count: width * height)
    var components: [AlphaComponent] = []
    let neighbors = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),            (1, 0),
        (-1, 1),  (0, 1),   (1, 1),
    ]

    for y in 0..<height {
        for x in 0..<width {
            let start = y * width + x
            guard !visited[start], pixels[y * bytesPerRow + x * 4 + 3] >= threshold else { continue }
            visited[start] = true
            var queue = [(x, y)]
            var cursor = 0
            var minX = x
            var maxX = x
            var minY = y
            var maxY = y

            while cursor < queue.count {
                let (currentX, currentY) = queue[cursor]
                cursor += 1
                minX = min(minX, currentX)
                maxX = max(maxX, currentX)
                minY = min(minY, currentY)
                maxY = max(maxY, currentY)

                for (dx, dy) in neighbors {
                    let nextX = currentX + dx
                    let nextY = currentY + dy
                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                    let next = nextY * width + nextX
                    guard !visited[next], pixels[nextY * bytesPerRow + nextX * 4 + 3] >= threshold else { continue }
                    visited[next] = true
                    queue.append((nextX, nextY))
                }
            }

            components.append(AlphaComponent(
                pixelCount: queue.count,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            ))
        }
    }
    return components
}

private final class TestPetAnimationTimer: PetAnimationTimer {
    private(set) var isValid = true
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func invalidate() { isValid = false }
    @MainActor
    func fire() {
        guard isValid else { return }
        handler()
    }
}

@MainActor
private final class TestPetAnimationScheduler: PetAnimationScheduling {
    private var timers: [TestPetAnimationTimer] = []
    private(set) var maximumActiveTimerCount = 0

    var activeTimerCount: Int { timers.filter(\.isValid).count }

    func schedule(interval _: TimeInterval, handler: @escaping @MainActor () -> Void) -> any PetAnimationTimer {
        let timer = TestPetAnimationTimer(handler: handler)
        timers.append(timer)
        maximumActiveTimerCount = max(maximumActiveTimerCount, activeTimerCount)
        return timer
    }

    func fireActiveTimer() {
        timers.last(where: \.isValid)?.fire()
    }
}
