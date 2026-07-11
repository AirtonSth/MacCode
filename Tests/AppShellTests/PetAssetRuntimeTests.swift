import XCTest
import CoreGraphics
@testable import AppShell

@MainActor
final class PetAssetRuntimeTests: XCTestCase {
    func test_bundledManifest_matchesProductionAtlasContract() throws {
        let atlas = try PetAtlas.bundled()
        let manifest = atlas.manifest

        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.dimensions.width, 1_536)
        XCTAssertEqual(manifest.dimensions.height, 6_656)
        XCTAssertEqual(manifest.grid.columns, 8)
        XCTAssertEqual(manifest.grid.rows, 32)
        XCTAssertEqual(manifest.grid.frameWidth, 192)
        XCTAssertEqual(manifest.grid.frameHeight, 208)
        XCTAssertEqual(manifest.rows.map(\.state), PetAnimationState.allCases)
        XCTAssertEqual(manifest.rows.reduce(0) { $0 + $1.frames }, 256)
        XCTAssertEqual(manifest.unusedFrameCount, 0)
        XCTAssertTrue(
            manifest.rows
                .filter { $0.state.isCompanionReaction }
                .allSatisfy { $0.mode == .onceHold },
            "companion reactions must finish all eight authored frames and wait for the reducer's exact return state"
        )
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
            "resource validation must inspect image metadata without decoding the full atlas")
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

    func test_all256AuthoredFramesDecodeAndCropAcrossEveryStateRow() throws {
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

        XCTAssertEqual(croppedFrameCount, 256)
    }

    func test_stateVisualBoundsRemoveOnlyTransparentPaddingWithoutClippingOrFrameJitter() throws {
        let atlas = try PetAtlas.bundled()
        var frameCount = 0

        for row in atlas.manifest.rows {
            var sourceUnion: CGRect?
            var displayUnion: CGRect?
            let expectedSourceBounds = row.visualBounds.rect
            let expectedDisplayBounds = CGRect(origin: .zero, size: expectedSourceBounds.size)

            for index in 0..<row.frames {
                let frame = try atlas.frame(state: row.state, index: index)
                let sourceComponents = alphaComponents(in: frame.image)
                let displayComponents = alphaComponents(in: frame.displayImage)
                let sourceBounds = try XCTUnwrap(union(of: sourceComponents))
                let displayBounds = try XCTUnwrap(union(of: displayComponents))

                XCTAssertTrue(expectedSourceBounds.contains(sourceBounds),
                    "\(row.state.rawValue)[\(index)] must not be clipped by its stable visual envelope")
                XCTAssertEqual(
                    sourceComponents.reduce(0) { $0 + $1.pixelCount },
                    displayComponents.reduce(0) { $0 + $1.pixelCount },
                    "visual trimming may remove transparent padding only"
                )
                XCTAssertEqual(frame.displayImage.width, Int(expectedSourceBounds.width))
                XCTAssertEqual(frame.displayImage.height, Int(expectedSourceBounds.height))
                sourceUnion = sourceUnion.map { $0.union(sourceBounds) } ?? sourceBounds
                displayUnion = displayUnion.map { $0.union(displayBounds) } ?? displayBounds
                frameCount += 1
            }

            XCTAssertEqual(sourceUnion, expectedSourceBounds,
                "the manifest envelope must stay tight so screen-edge placement has no hidden margin")
            XCTAssertEqual(displayUnion, expectedDisplayBounds,
                "every state must use one stable tight canvas across all of its animation frames")
        }

        XCTAssertEqual(frameCount, 256)
    }

    func test_allFramesHaveNoSmallFragmentsFromAdjacentSourceCells() throws {
        let atlas = try PetAtlas.bundled()
        var suspiciousFragments: [String] = []

        for row in atlas.manifest.rows {
            try atlas.activate(row.state)
            for index in 0..<row.frames {
                let frame = try atlas.frame(state: row.state, index: index)
                for component in alphaComponents(in: frame.image) {
                    // Atlas v2 maps each isolated source cell into x=8...184. A component
                    // reaching that outer draw boundary signals a broken source isolation;
                    // authored stars and motion marks may legitimately sit farther inward.
                    let touchesHorizontalSourceCropEdge = component.bounds.minX <= 8
                        || component.bounds.maxX >= 184
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
        XCTAssertThrowsError(try atlas.frame(state: .listening, index: 8)) { error in
            XCTAssertEqual(error as? PetAtlasError, .invalidFrame(state: .listening, index: 8))
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
        XCTAssertEqual(scheduler.activeTimerCount, 1,
            "visible sleep must animate breathing, ear twitches, tail motion, and drifting Zzz")
        XCTAssertEqual(controller.currentFrameIndex, 0,
            "sleeping begins at its first authored frame")
        scheduler.fireActiveTimer()
        XCTAssertEqual(controller.currentFrameIndex, 1,
            "the sleeping companion must visibly advance while normal animation is allowed")
    }

    func test_everyAuthoredReactionAdvancesWhenAnimationPolicyAllowsMotion() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)

        for state in PetAnimationState.allCases {
            try controller.setState(state, derivedTerminalState: .idle)
            XCTAssertEqual(scheduler.activeTimerCount, 1,
                "\(state.rawValue) must start animated instead of rendering as a static reaction")
            XCTAssertEqual(controller.currentFrameIndex, 0)
            scheduler.fireActiveTimer()
            XCTAssertEqual(controller.currentFrameIndex, 1,
                "\(state.rawValue) must contain visible authored frame progression")
        }
        XCTAssertEqual(scheduler.maximumActiveTimerCount, 1)
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
        for _ in 0..<8 { scheduler.fireActiveTimer() }
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

private func union(of components: [AlphaComponent]) -> CGRect? {
    components.reduce(nil) { result, component in
        result.map { $0.union(component.bounds) } ?? component.bounds
    }
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
