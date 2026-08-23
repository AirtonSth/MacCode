import XCTest
import CoreGraphics
import CryptoKit
import ImageIO
import Persistence
@testable import AppShell

@MainActor
final class PetAssetRuntimeTests: XCTestCase {
    func test_bundledManifest_matchesProductionAtlasContract() throws {
        let atlas = try PetAtlas.bundled()
        let manifest = atlas.manifest

        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.dimensions.width, 1_536)
        XCTAssertEqual(manifest.dimensions.height, 7_072)
        XCTAssertEqual(manifest.grid.columns, 8)
        XCTAssertEqual(manifest.grid.rows, 34)
        XCTAssertEqual(manifest.grid.frameWidth, 192)
        XCTAssertEqual(manifest.grid.frameHeight, 208)
        XCTAssertEqual(manifest.rows.map(\.state), PetAnimationState.allCases)
        XCTAssertEqual(manifest.rows.reduce(0) { $0 + $1.frames }, 272)
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

    func test_consolidatedAtlasContainsTheExactPackagedStateRows() throws {
        let atlas = try PetAtlas.bundled()
        let consolidated = try image(at: atlas.atlasURL)

        for row in atlas.manifest.rows {
            let topLeftRow = CGRect(
                x: 0,
                y: row.row * atlas.manifest.grid.frameHeight,
                width: atlas.manifest.dimensions.width,
                height: atlas.manifest.grid.frameHeight
            )
            let packagedRow = try image(at: atlas.rowURL(for: row.state))
            let consolidatedRow = try XCTUnwrap(consolidated.cropping(to: topLeftRow))
            XCTAssertEqual(rgbaBytes(of: consolidatedRow), rgbaBytes(of: packagedRow),
                "atlas row \(row.row) must contain the exact \(row.state.rawValue) resource")
        }
    }

    func test_bundledAtlas_resolvesThreeIndependentDefaultMicroActionRowsWithoutCursorGaze() throws {
        let atlas = try PetAtlas.bundled()
        let canonicalPixels = rgbaBytes(of: try atlas.canonicalIdleMicroActionFrame().image)

        XCTAssertEqual(PetIdleMicroAction.allCases, [.blink, .tail, .ears],
            "default idle must use believable isolated feline motion instead of cursor-driven pupils")

        for action in PetIdleMicroAction.allCases {
            let url = try atlas.idleMicroActionRowURL(for: action)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(url.lastPathComponent, "remote-code-black-cat-idle-\(action.rawValue).png")
            for index in 0..<8 {
                let frame = try atlas.idleMicroActionFrame(action: action, index: index)
                XCTAssertEqual(frame.image.width, 192)
                XCTAssertEqual(frame.image.height, 208)
                XCTAssertEqual(
                    alphaComponents(in: frame.image).reduce(0) { $0 + $1.pixelCount },
                    alphaComponents(in: frame.displayImage).reduce(0) { $0 + $1.pixelCount },
                    "idle-\(action.rawValue)[\(index)] must not clip any generated sprite pixels"
                )
                if index == 0 {
                    XCTAssertEqual(rgbaBytes(of: frame.image), canonicalPixels,
                        "every micro-action must return to the exact same neutral pose")
                }
            }
        }

        let resourceDirectory = try atlas.idleMicroActionRowURL(for: .blink).deletingLastPathComponent()
        let gazeResource = resourceDirectory.appendingPathComponent(
            "remote-code-black-cat-idle-gaze.png"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: gazeResource.path),
            "the rejected cursor-gaze sprite must not remain packaged as dead runtime behavior")
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

    func test_repeatedAnimationFrameLookup_reusesImageObjectsWithinTheBoundedRowCache() throws {
        // WHY: looped Pet states revisit the same eight frames up to 24 times per second.
        // Rebuilding identical CoreGraphics crops and AppKit bridges on every loop would
        // turn an already-bounded row cache into continuous allocation churn.
        let atlas = try PetAtlas.bundled()
        let first = try atlas.frame(state: .coding, index: 3)
        let repeated = try atlas.frame(state: .coding, index: 3)

        XCTAssertTrue(first.image === repeated.image)
        XCTAssertTrue(first.displayImage === repeated.displayImage)

        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(first)
        let firstAppKitImage = try XCTUnwrap(model.currentImage)
        model.setFrame(repeated)
        XCTAssertTrue(firstAppKitImage === model.currentImage)

        try atlas.activate(.search)
        let reloaded = try atlas.frame(state: .coding, index: 3)
        XCTAssertFalse(first.image === reloaded.image,
            "evicting the decoded row must also evict its cached frame objects")

        let blink = try atlas.idleMicroActionFrame(action: .blink, index: 2)
        let repeatedBlink = try atlas.idleMicroActionFrame(action: .blink, index: 2)
        XCTAssertTrue(blink.image === repeatedBlink.image)
        XCTAssertTrue(blink.displayImage === repeatedBlink.displayImage)
        _ = try atlas.idleMicroActionFrame(action: .tail, index: 2)
        let reloadedBlink = try atlas.idleMicroActionFrame(action: .blink, index: 2)
        XCTAssertFalse(blink.image === reloadedBlink.image,
            "switching idle micro-action rows must release the prior action's frame cache")
    }

    func test_perfProof_repeatedAnimationFrameBridge() throws {
        let atlas = try PetAtlas.bundled()
        try atlas.activate(.coding)
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let iterations = 50_000

        func measureMilliseconds() throws -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                for iteration in 0..<iterations {
                    model.setFrame(try atlas.frame(state: .coding, index: iteration % 8))
                }
            }
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }

        for _ in 0..<5 { _ = try measureMilliseconds() }
        let samples = try (0..<5).map { _ in try measureMilliseconds() }

        XCTAssertEqual(model.currentFrame?.state, .coding)
        print("[perf-proof] pet_frame_bridge iterations=\(iterations) warmup=5 n=5 wall_ms=\(samples)")
    }

    func test_all272AuthoredFramesDecodeAndCropAcrossEveryStateRow() throws {
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

        XCTAssertEqual(croppedFrameCount, 272)
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

        XCTAssertEqual(frameCount, 272)
    }

    func test_allFramesHaveNoSmallFragmentsFromAdjacentSourceCells() throws {
        let atlas = try PetAtlas.bundled()
        var suspiciousFragments: [String] = []

        for row in atlas.manifest.rows {
            try atlas.activate(row.state)
            for index in 0..<row.frames {
                let frame = try atlas.frame(state: row.state, index: index)
                for component in alphaComponents(in: frame.image) {
                    // Atlas v3 maps each isolated source cell into x=8...184 and y=16...192. A component
                    // reaching that outer draw boundary signals a broken source isolation;
                    // authored stars and motion marks may legitimately sit farther inward.
                    let touchesSourceCropEdge = component.bounds.minX <= 8
                        || component.bounds.maxX >= 184
                        || component.bounds.minY <= 16
                        || component.bounds.maxY >= 192
                    if touchesSourceCropEdge, component.pixelCount <= 64 {
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

    func test_visibleDefaultIdleAndApprovedSleepRemainPixelIdentical() throws {
        let atlas = try PetAtlas.bundled()
        let expectedHashes: [(URL, String)] = [
            (try atlas.rowURL(for: .sleeping), "9cba2cad77585413a6237b124192499483e9e8dafc365fdd8ebe2a9c0f86661c"),
            (try atlas.idleMicroActionRowURL(for: .blink), "fecb0fe377edc94dab5676c5cb998f4efa8c70da75e567b6501bd77b4c9805a7"),
            (try atlas.idleMicroActionRowURL(for: .tail), "686db50ce7e7970c7099913fc6c81d5fd12131d9c3e8f267a5dcc0d1b1b3f0bd"),
            (try atlas.idleMicroActionRowURL(for: .ears), "85e99ed8f30ce9ef07a3414cb50f1a10868cb7a823c26c2826c7bb1c3880ac12"),
        ]

        for (url, expected) in expectedHashes {
            let digest = SHA256.hash(data: Data(rgbaBytes(of: try image(at: url))))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, expected,
                "already-approved default idle and sleep pixels must not drift during the broad polish pass")
        }
    }

    func test_everyVisibleCatKeepsTheDefaultFurPaletteAndHeadScale() throws {
        let atlas = try PetAtlas.bundled()
        let defaultFrame = try atlas.canonicalIdleMicroActionFrame().image
        let referenceFur = try XCTUnwrap(darkFurMedianRGB(in: defaultFrame))
        let referenceHeadScale = try XCTUnwrap(headEnvelopeScale(in: defaultFrame))
        let referenceFurQuantiles = try XCTUnwrap(furPaletteQuantiles(in: defaultFrame))

        for state in PetAnimationState.allCases where state != .sleeping {
            let row = try XCTUnwrap(atlas.manifest.row(for: state))
            let frames = try (0..<row.frames).map { try atlas.frame(state: state, index: $0).image }
            let readableHeadScales = frames.compactMap(headEnvelopeScale(in:))
            let medianHeadScale = try XCTUnwrap(median(readableHeadScales.map { Double($0) }),
                "\(state.rawValue) needs at least one readable two-eye pose for scale validation")
            let headScale = CGFloat(medianHeadScale)
            XCTAssertEqual(
                headScale,
                referenceHeadScale,
                accuracy: referenceHeadScale * 0.10,
                "\(state.rawValue) must keep the same head scale as visible default idle"
            )
            let minimumReadableFrames = state == .idleGroom ? 1 : 2
            XCTAssertGreaterThanOrEqual(
                readableHeadScales.count,
                minimumReadableFrames,
                "\(state.rawValue) needs enough readable face frames for its authored eye story"
            )
            for scale in readableHeadScales {
                XCTAssertEqual(
                    scale,
                    headScale,
                    accuracy: headScale * 0.25,
                    "\(state.rawValue) must not change physical head scale between authored frames"
                )
            }

            for (index, frame) in frames.enumerated() {
                let fur = try XCTUnwrap(darkFurMedianRGB(in: frame))
                let furQuantiles = try XCTUnwrap(furPaletteQuantiles(in: frame))
                for channel in 0..<3 {
                    XCTAssertEqual(fur[channel], referenceFur[channel], accuracy: 3,
                        "\(state.rawValue)[\(index)] must use the same black-fur palette as default")
                    for quantile in 0..<3 {
                        XCTAssertEqual(
                            furQuantiles[channel][quantile],
                            referenceFurQuantiles[channel][quantile],
                            accuracy: quantile == 1 ? 4 : 8,
                            "\(state.rawValue)[\(index)] must preserve shadows, base fur, and highlights"
                        )
                    }
                }
            }
        }
    }

    func test_allAnimationsKeepTheCatPresentAndSpatiallyContinuous() throws {
        let atlas = try PetAtlas.bundled()
        let plantedStates: Set<PetAnimationState> = [
            .listening, .thinking, .coding, .editing, .terminal,
            .approval, .search, .gitReview, .reconnecting,
            .question, .waiting, .purring, .comfort, .pickedUp,
        ]

        for state in PetAnimationState.allCases where state != .sleeping {
            let row = try XCTUnwrap(atlas.manifest.row(for: state))
            let cats = try (0..<row.frames).map {
                let frame = try atlas.frame(state: state, index: $0).image
                return try XCTUnwrap(
                    darkFurComponent(in: frame),
                    "\(state.rawValue) must contain one connected cat"
                )
            }
            var transitions = (1..<cats.count).map { ($0 - 1, $0) }
            if row.mode == .loop || state.isExtendedCompanionReaction {
                transitions.append((cats.count - 1, 0))
            }
            for (previousIndex, currentIndex) in transitions {
                let overlapFloor = plantedStates.contains(state) ? 0.50 : 0.25
                XCTAssertGreaterThanOrEqual(
                    boundingBoxOverlapRatio(cats[previousIndex], cats[currentIndex]),
                    overlapFloor,
                    "\(state.rawValue)[\(previousIndex)→\(currentIndex)] must preserve a spatially continuous cat"
                )

            }
        }
    }

    func test_reconnectingKeepsOneStableCatAndUsesNoDetachedEyeLikeRing() throws {
        let atlas = try PetAtlas.bundled()
        let frames = try (0..<8).map { try atlas.frame(state: .reconnecting, index: $0).image }
        let referenceCat = try XCTUnwrap(darkFurComponent(in: frames[0]))
        let referenceEyes = try XCTUnwrap(goldEyePair(in: frames[0]))
        var bilateralBlinkCount = 0

        for (index, frame) in frames.enumerated() {
            let visibleGoldEyeComponents = goldEyeComponents(in: frame)
            XCTAssertNotEqual(visibleGoldEyeComponents.count, 1,
                "reconnecting[\(index)] cannot blink one eye while the other appears to spin")
            let cat = try XCTUnwrap(darkFurComponent(in: frame))
            XCTAssertLessThanOrEqual(relativeChange(referenceCat.pixelCount, cat.pixelCount), 0.04)
            XCTAssertLessThanOrEqual(relativeChange(referenceCat.bounds.width, cat.bounds.width), 0.04)
            XCTAssertLessThanOrEqual(relativeChange(referenceCat.bounds.height, cat.bounds.height), 0.04)
            XCTAssertLessThanOrEqual(hypot(
                referenceCat.bounds.midX - cat.bounds.midX,
                referenceCat.bounds.midY - cat.bounds.midY
            ), 2, "reconnecting[\(index)] must keep the cat planted while only status marks advance")

            if let eyes = goldEyePair(in: frame) {
                XCTAssertLessThanOrEqual(distance(referenceEyes.firstCenter, eyes.firstCenter), 2,
                    "reconnecting[\(index)] left eye cannot spin or jump")
                XCTAssertLessThanOrEqual(distance(referenceEyes.secondCenter, eyes.secondCenter), 2,
                    "reconnecting[\(index)] right eye cannot spin or jump")
            } else {
                bilateralBlinkCount += 1
            }
            let detachedEyeLikeComponents = alphaComponents(in: frame).filter {
                (180...500).contains($0.pixelCount)
                    && (14...30).contains(Int($0.bounds.width))
                    && (14...30).contains(Int($0.bounds.height))
            }
            XCTAssertTrue(detachedEyeLikeComponents.isEmpty,
                "reconnecting[\(index)] must not render a detached annulus that resembles a loose eye")
        }
        XCTAssertLessThanOrEqual(bilateralBlinkCount, 1,
            "reconnecting may contain at most one bilateral blink; the status loop cannot flicker")
    }

    func test_eatingHasNoNeutralGrayBlockInsideTheCatMouth() throws {
        let atlas = try PetAtlas.bundled()
        for index in 0..<8 {
            let frame = try atlas.frame(state: .eating, index: index).image
            let grayBlocks = neutralGrayComponents(
                in: frame,
                rect: try XCTUnwrap(mouthRegion(in: frame))
            ).filter { $0.pixelCount >= 6 && $0.bounds.width >= 3 && $0.bounds.height >= 2 }
            XCTAssertTrue(grayBlocks.isEmpty,
                "eating[\(index)] must use fur/nose/tongue colors without a gray mouth block")
        }
    }

    func test_yawnAndStretchAreSemanticallyDistinctSingleReactions() throws {
        let atlas = try PetAtlas.bundled()
        let yawnFrames = try (0..<8).map { try atlas.frame(state: .idleYawn, index: $0).image }
        let stretchFrames = try (0..<8).map { try atlas.frame(state: .idleStretch, index: $0).image }

        XCTAssertNotEqual(yawnFrames.flatMap(rgbaBytes(of:)), stretchFrames.flatMap(rgbaBytes(of:)))
        let yawnMouthPixels = try yawnFrames.map {
            pinkPixelCount(in: $0, rect: try XCTUnwrap(mouthRegion(in: $0)))
        }
        let stretchMouthPixels = try stretchFrames.map {
            pinkPixelCount(in: $0, rect: try XCTUnwrap(mouthRegion(in: $0)))
        }
        let peak = try XCTUnwrap(yawnMouthPixels.enumerated().max(by: { $0.element < $1.element }))
        XCTAssertTrue((2...5).contains(peak.offset), "the yawn must open in the middle of the sequence")
        XCTAssertGreaterThanOrEqual(peak.element, 40, "the yawn needs a visibly open mouth")
        let closedMouthBudget = max(15, peak.element / 4)
        XCTAssertLessThanOrEqual(yawnMouthPixels.first ?? .max, closedMouthBudget)
        XCTAssertLessThanOrEqual(yawnMouthPixels.last ?? .max, closedMouthBudget,
            "onceHold must finish neutral instead of freezing an open mouth for up to 12 seconds")
        XCTAssertGreaterThanOrEqual(
            peak.element,
            (stretchMouthPixels.max() ?? .max) * 2,
            "the yawn needs a distinct open-mouth peak; stretch only contains normal nose/ear pink"
        )
        XCTAssertTrue(yawnFrames.allSatisfy {
            guard let cat = darkFurComponent(in: $0) else { return false }
            return cat.bounds.width / cat.bounds.height < 1.2
        }, "yawning stays seated and must not contain the long foreleg stretch")
        XCTAssertGreaterThanOrEqual(stretchFrames.filter {
            guard let cat = darkFurComponent(in: $0) else { return false }
            return cat.bounds.width / cat.bounds.height > 1.25
        }.count, 2, "stretching needs visibly extended body frames and no seated yawn substitution")
    }

    func test_waitingThinksBeforeYawning_withoutRestoringTheHourglass() throws {
        // WHY: waiting can persist behind the unread badge, so its loop must communicate patience
        // without freezing on the rejected hourglass or opening the yawn immediately.
        let atlas = try PetAtlas.bundled()
        let frames = try (0..<8).map { try atlas.frame(state: .waiting, index: $0).image }
        let mouthPixels = try frames.map {
            pinkPixelCount(in: $0, rect: try XCTUnwrap(mouthRegion(in: $0)))
        }
        let peak = try XCTUnwrap(mouthPixels.enumerated().max(by: { $0.element < $1.element }))

        XCTAssertTrue((5...6).contains(peak.offset),
            "waiting must think first and yawn only after the pause")
        XCTAssertGreaterThanOrEqual(peak.element, 40, "waiting needs one readable seated yawn")
        XCTAssertLessThanOrEqual(mouthPixels[7], max(20, peak.element / 2),
            "the waiting loop must settle neutral after the yawn")

        for (index, frame) in frames.enumerated() {
            let cat = try XCTUnwrap(darkFurComponent(in: frame))
            let protectedCatBounds = cat.bounds.insetBy(dx: -8, dy: -8)
            let pixels = rgbaBytes(of: frame)
            let detachedHourglassPixels = (0..<(frame.width * frame.height)).filter { pixel in
                let x = pixel % frame.width
                let y = pixel / frame.width
                guard !protectedCatBounds.contains(CGPoint(x: x, y: y)) else { return false }
                let offset = pixel * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                return pixels[offset + 3] >= 64
                    && red > 140
                    && green > 80
                    && blue < 120
                    && red - blue > 50
            }.count
            XCTAssertEqual(detachedHourglassPixels, 0,
                "waiting[\(index)] must not restore the detached gold hourglass")
        }
    }

    func test_butterflyFramesContainExactlyOneCatSizedFurComponent() throws {
        // WHY: a neighboring source cell once leaked into this row and rendered a second cat.
        let atlas = try PetAtlas.bundled()
        for index in 0..<8 {
            let frame = try atlas.frame(state: .idleButterfly, index: index).image
            let pixels = rgbaBytes(of: frame)
            let cats = matchingComponents(width: frame.width, height: frame.height) { pixel in
                let offset = pixel * 4
                let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
                return pixels[offset + 3] >= 16
                    && (channels.max() ?? 255) < 80
                    && (channels.max() ?? 0) - (channels.min() ?? 0) < 28
            }.filter { $0.pixelCount >= 500 }

            XCTAssertEqual(cats.count, 1,
                "idleButterfly[\(index)] must contain exactly one cat, never a duplicate or ghost")
        }
    }

    func test_boxReactionShowsAirborneEntryOcclusionAndReturn() throws {
        // WHY: replacing the original jump with a crawl made the box interaction read incorrectly.
        let atlas = try PetAtlas.bundled()
        let cats = try (0..<8).map {
            try XCTUnwrap(darkFurComponent(in: atlas.frame(state: .idleBox, index: $0).image))
        }

        XCTAssertLessThan(cats[2].bounds.minY, cats[0].bounds.minY - 20,
            "idleBox must include a clearly airborne jump frame")
        XCTAssertGreaterThan(cats[3].bounds.midY, cats[2].bounds.midY + 10,
            "the airborne cat must descend into the box instead of teleporting")
        XCTAssertLessThan(cats[4].bounds.height, cats[0].bounds.height * 0.95,
            "the box must occlude the cat while it peeks from inside")
        XCTAssertGreaterThanOrEqual(boundingBoxOverlapRatio(cats[7], cats[0]), 0.5,
            "idleBox must return to the original seated pose after hopping out")
    }

    func test_pickedUpHangsFromAStableInvisibleScruffWithoutAPropLine() throws {
        let atlas = try PetAtlas.bundled()
        let frames = try (0..<8).map { try atlas.frame(state: .pickedUp, index: $0).image }
        let cats = try frames.map { try XCTUnwrap(darkFurComponent(in: $0)) }
        let readableHeads = frames.compactMap(headEnvelope(in:))
        let referenceHead = try XCTUnwrap(readableHeads.first)
        let referenceScruff = CGPoint(x: referenceHead.bounds.midX, y: referenceHead.bounds.minY)
        let visualBounds = try XCTUnwrap(atlas.manifest.row(for: .pickedUp)).visualBounds.rect
        let runtimeScruff = CGPoint(
            x: visualBounds.minX + PetScruffAnchor.normalized.x * visualBounds.width,
            y: visualBounds.minY + (1 - PetScruffAnchor.normalized.y) * visualBounds.height
        )

        XCTAssertGreaterThanOrEqual(readableHeads.count, 3)
        XCTAssertTrue(referenceHead.bounds.insetBy(dx: -3, dy: -3).contains(runtimeScruff),
            "the runtime cursor anchor must land on the authored head, never the body or transparent padding")
        XCTAssertEqual(runtimeScruff.x, referenceHead.bounds.midX, accuracy: 8,
            "the runtime cursor anchor must stay centered on the authored scruff")
        for cat in cats {
            XCTAssertGreaterThan(cat.bounds.height, cat.bounds.width * 1.15,
                "pickedUp must hang vertically instead of showing the default seated body")
        }
        for head in readableHeads {
            let scruff = CGPoint(x: head.bounds.midX, y: head.bounds.minY)
            XCTAssertLessThanOrEqual(distance(referenceScruff, scruff), 3,
                "pickedUp head/scruff must stay under the pointer while the body sways")
        }
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(alphaComponents(in: frame).filter { $0.pixelCount >= 4 }.count, 1,
                "pickedUp[\(index)] must contain only the cat; detached holder props are forbidden")
            XCTAssertLessThan(thinHeadBoundaryRun(in: frame), 6,
                "pickedUp[\(index)] must not draw a line, rope, hand, or cursor above the scruff")
        }
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

    func test_everyNonIdleAuthoredReactionAdvancesWhenAnimationPolicyAllowsMotion() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)

        for state in PetAnimationState.allCases where state != .idle {
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

    func test_idlePlaybackRunsOneNaturalMicroActionAtATime() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(
            atlas: .bundled(),
            scheduler: scheduler,
            idleActionProvider: { .blink },
            idleRestDelayProvider: { 4 }
        )
        try controller.setState(.idle)

        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 4)

        scheduler.fireActiveTimer()
        XCTAssertEqual(controller.currentFrameIndex, 1,
            "a blink must begin without also moving the tail or ears")
        XCTAssertEqual(controller.currentIdleMicroAction, .blink)
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 1.0 / 24.0, accuracy: 0.001,
            "a feline blink should close and reopen in roughly 167 milliseconds")

        for _ in 0..<3 { scheduler.fireActiveTimer() }

        XCTAssertEqual(controller.currentFrameIndex, 0)
        XCTAssertNil(controller.currentIdleMicroAction)
        XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 4)
        XCTAssertEqual(scheduler.maximumActiveTimerCount, 1,
            "independent micro-actions must preserve one-timer ownership")
    }

    func test_defaultMicroActionWeightsPreserveBlinkAndMakeTailAndEarsNoticeable() {
        XCTAssertEqual(PetIdleMicroAction.restDelayRange, 6...10,
            "the approved blink distribution must remain unchanged")
        let actions = (0..<100).map(PetIdleMicroAction.select)
        XCTAssertEqual(actions.filter { $0 == .blink }.count, 65)
        XCTAssertEqual(actions.filter { $0 == .tail }.count, 20)
        XCTAssertEqual(actions.filter { $0 == .ears }.count, 15)
        XCTAssertEqual(PetIdleMicroAction.select(-1), .blink)
        XCTAssertEqual(PetIdleMicroAction.select(0), .blink)
        XCTAssertEqual(PetIdleMicroAction.select(64), .blink)
        XCTAssertEqual(PetIdleMicroAction.select(65), .tail)
        XCTAssertEqual(PetIdleMicroAction.select(84), .tail)
        XCTAssertEqual(PetIdleMicroAction.select(85), .ears)
        XCTAssertEqual(PetIdleMicroAction.select(99), .ears)
        XCTAssertEqual(PetIdleMicroAction.select(100), .ears)
    }

    func test_defaultTailAndEarMicroActionsPlayTheirNaturalSequenceThenRest() throws {
        let cases: [(PetIdleMicroAction, [Int], TimeInterval)] = [
            (.tail, [1, 2, 3, 2, 1, 0], 1.0 / 5.0),
            (.ears, [1, 2, 3, 4, 5, 6, 7, 0], 1.0 / 12.0),
        ]

        for (action, sequence, frameInterval) in cases {
            let scheduler = TestPetAnimationScheduler()
            let controller = try PetAnimationController(
                atlas: .bundled(),
                scheduler: scheduler,
                idleActionProvider: { action },
                idleRestDelayProvider: { 4 }
            )
            try controller.setState(.idle)

            scheduler.fireActiveTimer()
            XCTAssertEqual(controller.currentIdleMicroAction, action)
            XCTAssertEqual(controller.currentFrameIndex, sequence[0])
            XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), frameInterval, accuracy: 0.001)
            for frame in sequence.dropFirst() {
                scheduler.fireActiveTimer()
                XCTAssertEqual(controller.currentFrameIndex, frame)
            }

            XCTAssertNil(controller.currentIdleMicroAction)
            XCTAssertEqual(try XCTUnwrap(scheduler.lastInterval), 4)
            XCTAssertEqual(scheduler.maximumActiveTimerCount, 1)
        }
    }

    func test_everyPlaybackRateMatchesThePhysicalActionInsteadOfOneUniformSpeed() throws {
        let manifest = try PetAtlas.bundled().manifest
        let expected: [PetAnimationState: Int] = [
            .idle: 4,
            .listening: 3,
            .thinking: 3,
            .coding: 4,
            .editing: 4,
            .terminal: 4,
            .search: 3,
            .gitReview: 3,
            .success: 7,
            .approval: 3,
            .question: 3,
            .waiting: 2,
            .failed: 7,
            .interrupted: 7,
            .reconnecting: 3,
            .sleeping: 3,
            .idleBall: 3,
            .idleScratch: 4,
            .idleGroom: 3,
            .idleStretch: 2,
            .idleBox: 2,
            .idleButterfly: 4,
            .eating: 3,
            .drinking: 3,
            .purring: 3,
            .playing: 4,
            .comfort: 3,
            .workingMouse: 4,
            .workingBug: 4,
            .workingEngineer: 3,
            .notificationPounce: 7,
            .celebrateTreat: 7,
            .idleYawn: 2,
            .pickedUp: 3,
        ]
        let loops: Set<PetAnimationState> = [
            .idle, .listening, .thinking, .coding, .editing, .terminal,
            .search, .gitReview, .approval, .question, .waiting,
            .reconnecting, .sleeping, .pickedUp,
        ]
        let onceThenWaiting: Set<PetAnimationState> = [.failed]
        let onceThenDerived: Set<PetAnimationState> = [.interrupted]

        XCTAssertEqual(Set(expected.keys), Set(PetAnimationState.allCases),
            "a new animation must not silently inherit an uncanny default FPS")
        for (state, fps) in expected {
            let row = try XCTUnwrap(manifest.row(for: state))
            XCTAssertEqual(row.fps, fps,
                "\(state.rawValue) must not replay whole-body poses at tongue- or paw-level speed")
            let expectedMode: PetAtlasManifest.PlaybackMode
            if loops.contains(state) {
                expectedMode = .loop
            } else if onceThenWaiting.contains(state) {
                expectedMode = .onceThenWaiting
            } else if onceThenDerived.contains(state) {
                expectedMode = .onceThenDerived
            } else {
                expectedMode = .onceHold
            }
            XCTAssertEqual(row.mode, expectedMode,
                "\(state.rawValue) must not freeze or loop under the wrong playback contract")
        }
        let sleeping = try XCTUnwrap(manifest.row(for: .sleeping))
        XCTAssertEqual(sleeping.fps, 3,
            "the already-approved sleeping animation must retain its cadence")
        XCTAssertEqual(sleeping.frames, 8,
            "the already-approved sleeping animation must retain all authored frames")
        XCTAssertEqual(sleeping.mode, .loop,
            "the already-approved sleeping animation must keep looping")
        XCTAssertEqual(try XCTUnwrap(manifest.row(for: .pickedUp)).mode, .loop,
            "direct manipulation needs a subtle held-body loop until mouse-up")
        XCTAssertEqual(try XCTUnwrap(manifest.row(for: .idleYawn)).mode, .onceHold,
            "a cat must yawn once, not repeat the full yawn throughout the random cue")
        XCTAssertEqual(try XCTUnwrap(manifest.row(for: .idleStretch)).mode, .onceHold,
            "a cat must stretch once, not mechanically repeat the full stretch")
    }

    func test_extendedCompanionReactionLoopsUntilReducerReturnsIt() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(atlas: .bundled(), scheduler: scheduler)

        let extendedStates: [PetAnimationState] = [
            .idleBall, .idleScratch, .idleGroom,
            .idleBox, .idleButterfly, .eating, .drinking,
            .purring, .playing, .comfort, .workingMouse,
            .workingBug, .workingEngineer,
        ]
        XCTAssertEqual(
            Set(PetAnimationState.allCases.filter(\.isExtendedCompanionReaction)),
            Set(extendedStates),
            "the explicit extended-reaction contract must not silently drop a state"
        )

        for state in extendedStates {
            try controller.setState(state)
            for _ in 0..<8 { scheduler.fireActiveTimer() }
            XCTAssertEqual(controller.currentFrameIndex, 0,
                "\(state.rawValue) must restart its authored story while the transient owns the Pet")
            XCTAssertEqual(scheduler.activeTimerCount, 1,
                "\(state.rawValue) must keep animating throughout its 6–12 second transient")
        }

        for state in [PetAnimationState.notificationPounce, .celebrateTreat] {
            try controller.setState(state)
            for _ in 0..<7 { scheduler.fireActiveTimer() }
            XCTAssertEqual(controller.currentFrameIndex, 7)
            XCTAssertEqual(scheduler.activeTimerCount, 0,
                "short \(state.rawValue) feedback must remain a one-shot")
        }
    }

    func test_extendedReactionsExpireOnANeutralLoopSeamWithinSixToTwelveSeconds() throws {
        let atlas = try PetAtlas.bundled()
        let controller = try PetAnimationController(
            atlas: atlas,
            scheduler: TestPetAnimationScheduler()
        )
        let requestedDurations: [Int64] = [6_000, 9_000, 12_000]

        for state in PetAnimationState.allCases where state.isExtendedCompanionReaction {
            let row = try XCTUnwrap(atlas.manifest.row(for: state))
            let frameMilliseconds = 1_000.0 / Double(row.fps)
            let cycleMilliseconds = frameMilliseconds * Double(row.frames)
            for requested in requestedDurations {
                let aligned = controller.loopSafeDurationMilliseconds(
                    for: state,
                    requested: requested
                )
                XCTAssertTrue(PetCompanionDirector.extendedReactionDurationRange.contains(aligned),
                    "\(state.rawValue) must remain inside the requested 6–12-second ownership window")
                let openingCycles = (Double(aligned) - frameMilliseconds / 2) / cycleMilliseconds
                let terminalCycles = (Double(aligned) + frameMilliseconds / 2) / cycleMilliseconds
                let seamError = min(
                    abs(openingCycles - openingCycles.rounded()),
                    abs(terminalCycles - terminalCycles.rounded())
                )
                XCTAssertLessThanOrEqual(seamError, 0.01,
                    "\(state.rawValue) must return on its loop seam, never mid-lick or mid-pounce")
            }
        }
        XCTAssertEqual(
            controller.loopSafeDurationMilliseconds(for: .idleYawn, requested: 9_000),
            9_000,
            "one-shot reactions already settle on their neutral terminal frame"
        )
    }

    func test_loopPlayback_wraps_andKeepsSingleTimer() throws {
        let scheduler = TestPetAnimationScheduler()
        let controller = try PetAnimationController(
            atlas: .bundled(),
            scheduler: scheduler,
            idleActionProvider: { .blink },
            idleRestDelayProvider: { 4 }
        )
        try controller.setState(.idle)

        for _ in 0..<4 { scheduler.fireActiveTimer() }

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

private struct EyePair {
    let first: AlphaComponent
    let second: AlphaComponent

    var firstCenter: CGPoint { CGPoint(x: first.bounds.midX, y: first.bounds.midY) }
    var secondCenter: CGPoint { CGPoint(x: second.bounds.midX, y: second.bounds.midY) }
}

private func image(at url: URL) throws -> CGImage {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func rgbaBytes(of image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
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

private func rgbaBytes(in rect: CGRect, of image: CGImage) -> [UInt8] {
    let pixels = rgbaBytes(of: image)
    let minX = max(0, Int(rect.minX.rounded(.down)))
    let maxX = min(image.width, Int(rect.maxX.rounded(.up)))
    let minY = max(0, Int(rect.minY.rounded(.down)))
    let maxY = min(image.height, Int(rect.maxY.rounded(.up)))
    guard minX < maxX, minY < maxY else { return [] }

    var result: [UInt8] = []
    result.reserveCapacity((maxX - minX) * (maxY - minY) * 4)
    for y in minY..<maxY {
        let start = (y * image.width + minX) * 4
        let end = (y * image.width + maxX) * 4
        result.append(contentsOf: pixels[start..<end])
    }
    return result
}

private func largestOpaqueComponentPixelIndices(in image: CGImage) -> [Int] {
    let pixels = rgbaBytes(of: image)
    return largestMatchingComponentPixelIndices(width: image.width, height: image.height) { index in
        pixels[index * 4 + 3] >= 16
    }
}

private func darkFurComponent(in image: CGImage) -> AlphaComponent? {
    let pixels = rgbaBytes(of: image)
    let indices = largestMatchingComponentPixelIndices(width: image.width, height: image.height) { index in
        let offset = index * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        return pixels[offset + 3] >= 16
            && (channels.max() ?? 255) < 80
            && (channels.max() ?? 0) - (channels.min() ?? 0) < 28
    }
    guard !indices.isEmpty else { return nil }
    let xs = indices.map { $0 % image.width }
    let ys = indices.map { $0 / image.width }
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
        return nil
    }
    return AlphaComponent(
        pixelCount: indices.count,
        bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    )
}

private func darkFurMedianRGB(in image: CGImage) -> [Double]? {
    let pixels = rgbaBytes(of: image)
    let indices = largestMatchingComponentPixelIndices(width: image.width, height: image.height) { index in
        let offset = index * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        return pixels[offset + 3] >= 16
            && (channels.max() ?? 255) < 80
            && (channels.max() ?? 0) - (channels.min() ?? 0) < 28
    }
    guard !indices.isEmpty else { return nil }
    return (0..<3).compactMap { channel in
        median(indices.map { Double(pixels[$0 * 4 + channel]) })
    }
}

private func furPaletteQuantiles(in image: CGImage) -> [[Double]]? {
    let pixels = rgbaBytes(of: image)
    let indices = largestMatchingComponentPixelIndices(width: image.width, height: image.height) { index in
        let offset = index * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        return pixels[offset + 3] >= 16
            && (channels.max() ?? 255) < 128
            && (channels.max() ?? 0) - (channels.min() ?? 0) < 32
    }
    guard indices.count >= 100 else { return nil }
    return (0..<3).map { channel in
        let values = indices.map { Double(pixels[$0 * 4 + channel]) }.sorted()
        return [0.25, 0.5, 0.75].map { quantile($0, in: values) }
    }
}

private func headEnvelope(in image: CGImage) -> AlphaComponent? {
    guard let eyes = goldEyePair(in: image), let cat = darkFurComponent(in: image) else { return nil }
    let pixels = rgbaBytes(of: image)
    let midpoint = eyeMidpoint(eyes)
    let bodyIsBelow = cat.bounds.midY >= midpoint.y
    let requestedROI = CGRect(
        x: midpoint.x - 60,
        y: midpoint.y - (bodyIsBelow ? 50 : 22),
        width: 120,
        height: 72
    )
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let roi = requestedROI.intersection(cat.bounds).intersection(imageBounds)
    guard !roi.isNull, !roi.isEmpty else { return nil }

    let head = matchingComponents(width: image.width, height: image.height) { index in
        let x = index % image.width
        let y = index / image.width
        guard roi.contains(CGPoint(x: x, y: y)) else { return false }
        let offset = index * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        return pixels[offset + 3] >= 16
            && (channels.max() ?? 255) < 80
            && (channels.max() ?? 0) - (channels.min() ?? 0) < 28
    }
    .filter { $0.pixelCount >= 100 }
    .max { $0.pixelCount < $1.pixelCount }
    return head
}

private func headEnvelopeScale(in image: CGImage) -> CGFloat? {
    guard let head = headEnvelope(in: image) else { return nil }
    return sqrt(head.bounds.width * head.bounds.height)
}

private func goldEyeComponents(in image: CGImage) -> [AlphaComponent] {
    let pixels = rgbaBytes(of: image)
    guard let dark = darkFurComponent(in: image) else { return [] }
    return matchingComponents(width: image.width, height: image.height) { index in
        let offset = index * 4
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        return pixels[offset + 3] >= 64 && r > 145 && g > 95 && b < 125 && r - b > 60 && g - b > 35
    }.filter {
        (5...220).contains($0.pixelCount)
            && $0.bounds.width <= 24
            && $0.bounds.height <= 24
            && dark.bounds.insetBy(dx: -8, dy: -8).contains(
                CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)
            )
            && darkPixelCount(in: $0.bounds.insetBy(dx: -5, dy: -5), image: image) >= 12
    }
}

private func darkPixelCount(in rect: CGRect, image: CGImage) -> Int {
    let pixels = rgbaBytes(of: image)
    let minX = max(0, Int(rect.minX.rounded(.down)))
    let maxX = min(image.width, Int(rect.maxX.rounded(.up)))
    let minY = max(0, Int(rect.minY.rounded(.down)))
    let maxY = min(image.height, Int(rect.maxY.rounded(.up)))
    return (minY..<maxY).reduce(into: 0) { count, y in
        for x in minX..<maxX {
            let offset = (y * image.width + x) * 4
            let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
            if pixels[offset + 3] >= 16,
               (channels.max() ?? 255) < 128,
               (channels.max() ?? 0) - (channels.min() ?? 0) < 32 {
                count += 1
            }
        }
    }
}

private func goldEyePair(in image: CGImage) -> EyePair? {
    let gold = goldEyeComponents(in: image)
    let pixels = rgbaBytes(of: image)
    let noseCandidates = matchingComponents(width: image.width, height: image.height) { index in
        let offset = index * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        return pixels[offset + 3] >= 32
            && red >= 55
            && red - green >= 10
            && red - blue >= 3
    }.filter {
        (1...80).contains($0.pixelCount)
            && $0.bounds.width <= 18
            && $0.bounds.height <= 18
    }
    let cat = darkFurComponent(in: image)
    var best: (score: CGFloat, first: AlphaComponent, second: AlphaComponent)?
    for firstIndex in gold.indices {
        for secondIndex in gold.indices where secondIndex > firstIndex {
            let first = gold[firstIndex]
            let second = gold[secondIndex]
            let dx = abs(first.bounds.midX - second.bounds.midX)
            let dy = abs(first.bounds.midY - second.bounds.midY)
            guard (18...50).contains(dx), dy <= 12 else { continue }
            let leftEye = first.bounds.midX <= second.bounds.midX ? first : second
            let rightEye = first.bounds.midX <= second.bounds.midX ? second : first
            let midpointX = (leftEye.bounds.midX + rightEye.bounds.midX) / 2
            let midpointY = (leftEye.bounds.midY + rightEye.bounds.midY) / 2
            let bodyDirection: CGFloat = (cat?.bounds.midY ?? midpointY + 1) >= midpointY ? 1 : -1
            guard noseCandidates.contains(where: {
                let bodyDelta = ($0.bounds.midY - midpointY) * bodyDirection
                let leftDistance = $0.bounds.midX - leftEye.bounds.midX
                let rightDistance = rightEye.bounds.midX - $0.bounds.midX
                let minimumDistance = min(leftDistance, rightDistance)
                let maximumDistance = max(leftDistance, rightDistance)
                return leftDistance > 0
                    && rightDistance > 0
                    && maximumDistance <= 30
                    && maximumDistance / minimumDistance <= 2
                    && abs($0.bounds.midX - midpointX) <= 14
                    && (3...25).contains(bodyDelta)
            }) else { continue }
            let score = CGFloat(first.pixelCount + second.pixelCount) - dy * 4
            if best == nil || score > best!.score {
                best = (score, first, second)
            }
        }
    }
    guard let best else { return nil }
    return best.first.bounds.midX <= best.second.bounds.midX
        ? EyePair(first: best.first, second: best.second)
        : EyePair(first: best.second, second: best.first)
}

private func mouthRegion(in image: CGImage) -> CGRect? {
    guard let cat = darkFurComponent(in: image) else { return nil }
    let eyes = goldEyePair(in: image)
    let ears = pinkEarPair(in: image)
    let centerX = eyes.map {
        ($0.first.bounds.midX + $0.second.bounds.midX) / 2
    } ?? ears.map {
        ($0.first.bounds.midX + $0.second.bounds.midX) / 2
    } ?? cat.bounds.midX
    let centerY: CGFloat
    if let eyes {
        let eyeY = (eyes.first.bounds.midY + eyes.second.bounds.midY) / 2
        centerY = eyeY + (cat.bounds.midY >= eyeY ? 14 : -14)
    } else if let ears {
        let earY = (ears.first.bounds.midY + ears.second.bounds.midY) / 2
        centerY = earY + (cat.bounds.midY - earY) * 0.9
    } else {
        centerY = cat.bounds.midY
    }
    return CGRect(x: centerX - 20, y: centerY - 12, width: 40, height: 24)
}

private func neutralGrayComponents(in image: CGImage, rect: CGRect) -> [AlphaComponent] {
    let pixels = rgbaBytes(of: image)
    return matchingComponents(width: image.width, height: image.height) { index in
        let x = index % image.width
        let y = index / image.width
        guard rect.contains(CGPoint(x: x, y: y)) else { return false }
        let offset = index * 4
        let channels = [Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])]
        return pixels[offset + 3] >= 16
            && (70...230).contains(channels.max() ?? 0)
            && (channels.max() ?? 0) - (channels.min() ?? 0) <= 12
    }
}

private func pinkEarPair(in image: CGImage) -> EyePair? {
    let pixels = rgbaBytes(of: image)
    guard let cat = darkFurComponent(in: image),
          let eyes = goldEyePair(in: image) else { return nil }
    let eyeMidY = (eyes.first.bounds.midY + eyes.second.bounds.midY) / 2
    let eyeSeparation = abs(eyes.first.bounds.midX - eyes.second.bounds.midX)
    let bodyDirection: CGFloat = cat.bounds.midY >= eyeMidY ? 1 : -1
    let components = matchingComponents(width: image.width, height: image.height) { index in
        let offset = index * 4
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let redBlue = red - blue
        return pixels[offset + 3] >= 32
            && red >= 55
            && red - green >= 8
            && (3...90).contains(redBlue)
            && abs(green - blue) <= 55
    }.filter {
        (5...400).contains($0.pixelCount)
            && $0.bounds.width <= 30
            && $0.bounds.height <= 35
            && cat.bounds.insetBy(dx: -6, dy: -6).contains(
                CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)
            )
            && ($0.bounds.midY - eyeMidY) * bodyDirection <= -4
    }

    var best: (score: CGFloat, first: AlphaComponent, second: AlphaComponent)?
    for firstIndex in components.indices {
        for secondIndex in components.indices where secondIndex > firstIndex {
            let first = components[firstIndex]
            let second = components[secondIndex]
            let dx = abs(first.bounds.midX - second.bounds.midX)
            let dy = abs(first.bounds.midY - second.bounds.midY)
            guard (20...80).contains(dx), dy <= 20,
                  (0.95...1.95).contains(dx / eyeSeparation) else { continue }
            let score = dx * 2 + CGFloat(first.pixelCount + second.pixelCount) / 10 - dy * 3
            if best == nil || score > best!.score { best = (score, first, second) }
        }
    }
    guard let best else { return nil }
    return best.first.bounds.midX <= best.second.bounds.midX
        ? EyePair(first: best.first, second: best.second)
        : EyePair(first: best.second, second: best.first)
}

private func pinkPixelCount(in image: CGImage, rect: CGRect) -> Int {
    let pixels = rgbaBytes(of: image)
    let minX = max(0, Int(rect.minX.rounded(.down)))
    let maxX = min(image.width, Int(rect.maxX.rounded(.up)))
    let minY = max(0, Int(rect.minY.rounded(.down)))
    let maxY = min(image.height, Int(rect.maxY.rounded(.up)))
    return (minY..<maxY).reduce(into: 0) { count, y in
        for x in minX..<maxX {
            let offset = (y * image.width + x) * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if pixels[offset + 3] >= 32, red >= 90, red - green >= 25, red - blue >= 15 {
                count += 1
            }
        }
    }
}

private func thinHeadBoundaryRun(in image: CGImage) -> Int {
    let indices = largestOpaqueComponentPixelIndices(in: image)
    guard !indices.isEmpty, let eyes = goldEyePair(in: image) else { return .max }
    let occupied = Set(indices)
    let ys = indices.map { $0 / image.width }
    guard let minY = ys.min(), let maxY = ys.max() else { return .max }
    let eyeY = Int(((eyes.first.bounds.midY + eyes.second.bounds.midY) / 2).rounded())
    let scan: [Int] = CGFloat(eyeY) < CGFloat(minY + maxY) / 2
        ? Array(minY...eyeY)
        : Array((eyeY...maxY).reversed())
    var run = 0
    for y in scan {
        let xs = (0..<image.width).filter { occupied.contains(y * image.width + $0) }
        guard let first = xs.first, let last = xs.last else { continue }
        if last - first + 1 <= 4 {
            run += 1
        } else {
            break
        }
    }
    return run
}

private func normalizedCenterDistance(_ lhs: AlphaComponent, _ rhs: AlphaComponent) -> Double {
    let displacement = hypot(lhs.bounds.midX - rhs.bounds.midX, lhs.bounds.midY - rhs.bounds.midY)
    let scale = [lhs.bounds.width, lhs.bounds.height, rhs.bounds.width, rhs.bounds.height].max() ?? 0
    return scale > 0 ? Double(displacement / scale) : 0
}

private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private func eyeMidpoint(_ eyes: EyePair) -> CGPoint {
    CGPoint(
        x: (eyes.first.bounds.midX + eyes.second.bounds.midX) / 2,
        y: (eyes.first.bounds.midY + eyes.second.bounds.midY) / 2
    )
}

private func boundingBoxOverlapRatio(_ lhs: AlphaComponent, _ rhs: AlphaComponent) -> Double {
    let intersection = lhs.bounds.intersection(rhs.bounds)
    guard !intersection.isNull, !intersection.isEmpty else { return 0 }
    let overlapArea = intersection.width * intersection.height
    let smallerArea = min(
        lhs.bounds.width * lhs.bounds.height,
        rhs.bounds.width * rhs.bounds.height
    )
    return smallerArea > 0 ? Double(overlapArea / smallerArea) : 0
}

private func quantile(_ probability: Double, in sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let index = Int((Double(sorted.count - 1) * probability).rounded())
    return sorted[index]
}

private func matchingComponents(
    width: Int,
    height: Int,
    matches: (Int) -> Bool
) -> [AlphaComponent] {
    connectedPixelComponents(width: width, height: height, matches: matches).map { indices in
        let xs = indices.map { $0 % width }
        let ys = indices.map { $0 / width }
        return AlphaComponent(
            pixelCount: indices.count,
            bounds: CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0) + 1,
                height: (ys.max() ?? 0) - (ys.min() ?? 0) + 1
            )
        )
    }
}

private func largestMatchingComponentPixelIndices(
    width: Int,
    height: Int,
    matches: (Int) -> Bool
) -> [Int] {
    connectedPixelComponents(width: width, height: height, matches: matches)
        .max(by: { $0.count < $1.count }) ?? []
}

private func connectedPixelComponents(
    width: Int,
    height: Int,
    matches: (Int) -> Bool
) -> [[Int]] {
    var visited = [Bool](repeating: false, count: width * height)
    var result: [[Int]] = []
    let neighbors = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),            (1, 0),
        (-1, 1),  (0, 1),  (1, 1),
    ]

    for start in 0..<(width * height) where !visited[start] && matches(start) {
        visited[start] = true
        var queue = [start]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let x = current % width
            let y = current / width
            for (dx, dy) in neighbors {
                let nextX = x + dx
                let nextY = y + dy
                guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                let next = nextY * width + nextX
                guard !visited[next], matches(next) else { continue }
                visited[next] = true
                queue.append(next)
            }
        }
        result.append(queue)
    }
    return result
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let midpoint = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
        : sorted[midpoint]
}

private func relativeChange(_ lhs: Int, _ rhs: Int) -> Double {
    relativeChange(Double(lhs), Double(rhs))
}

private func relativeChange(_ lhs: CGFloat, _ rhs: CGFloat) -> Double {
    relativeChange(Double(lhs), Double(rhs))
}

private func relativeChange(_ lhs: Double, _ rhs: Double) -> Double {
    guard max(lhs, rhs) > 0 else { return 0 }
    return abs(lhs - rhs) / max(lhs, rhs)
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
    private(set) var scheduledIntervals: [TimeInterval] = []

    var activeTimerCount: Int { timers.filter(\.isValid).count }
    var lastInterval: TimeInterval? { scheduledIntervals.last }

    func schedule(interval: TimeInterval, handler: @escaping @MainActor () -> Void) -> any PetAnimationTimer {
        let timer = TestPetAnimationTimer(handler: handler)
        timers.append(timer)
        scheduledIntervals.append(interval)
        maximumActiveTimerCount = max(maximumActiveTimerCount, activeTimerCount)
        return timer
    }

    func fireActiveTimer() {
        timers.last(where: \.isValid)?.fire()
    }
}
