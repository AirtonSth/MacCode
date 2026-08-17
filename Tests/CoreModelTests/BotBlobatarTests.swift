import XCTest
@testable import CoreModel

final class BotBlobatarTests: XCTestCase {
    func test_sameNameAndSpecIsDeterministic_becauseAnAvatarMustStayTheSameCreature() {
        // WHY: A roster of the same bot must not flicker. blobatar's
        // contract is same name + spec => same figure.
        let spec = BotBlobatarSpec(shape: .cloud, expression: .idle, background: .none, hue: .named("coral"))
        let a = BotBlobatar.figure(name: "Piper", spec: spec)
        let b = BotBlobatar.figure(name: "Piper", spec: spec)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.resolvedShape, .cloud)
        let other = BotBlobatar.figure(name: "Scout", spec: spec)
        XCTAssertNotEqual(a.body.cx, other.body.cx)
    }

    func test_tokenRoundTripsStudioChoices_becauseSaveMustKeepWhatThePickerWrote() {
        // WHY: Studio writes one avatarSymbol string. Reload must restore
        // shape, expression, background, and hue.
        let spec = BotBlobatarSpec(shape: .sun, expression: .mad, background: .squircle, hue: .named("indigo"))
        XCTAssertEqual(BotBlobatarSpec.parse(spec.token), spec)
        XCTAssertEqual(BotBlobatarSpec.parse("SUN")?.shape, .sun)
        XCTAssertNil(BotBlobatarSpec.parse("blobatar:v1:orb:idle:none:auto"))
    }

    func test_autoShapeUsesTheName_becauseAutoIsTheHashedCreature() {
        // WHY: Auto is not a seventh silhouette. Two names must be able
        // to resolve to different shapes.
        let spec = BotBlobatarSpec.default
        let shapes = (0..<40).map { BotBlobatar.figure(name: "seed-\($0)", spec: spec).resolvedShape }
        XCTAssertGreaterThan(Set(shapes).count, 1)
    }

    func test_motionSampleIsDeterministic_becauseAReplayMustMatchTheLiveFace() {
        // WHY: TimelineView re-samples time. The same instant has to
        // draw the same breathe/blink or the face flickers.
        let a = BotBlobatarMotion.sample(name: "Piper", time: 12.4, expression: .idle, amplitude: 1)
        let b = BotBlobatarMotion.sample(name: "Piper", time: 12.4, expression: .idle, amplitude: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, BotBlobatarMotion.still)
    }

    func test_motionPhaseDiffersByName_becauseARosterMustNotBreatheInUnison() {
        // WHY: Seeded phase is what makes a grid a crowd instead of a
        // drill team. Two names at the same clock must not match.
        let a = BotBlobatarMotion.sample(name: "Piper", time: 8, expression: .idle, amplitude: 1)
        let b = BotBlobatarMotion.sample(name: "Scout", time: 8, expression: .idle, amplitude: 1)
        XCTAssertNotEqual(a.bobY, b.bobY)
    }

    func test_zeroAmplitudeIsStill_becauseReducedMotionAndFrozenTilesMustNotWiggle() {
        // WHY: Picker tiles and prefers-reduced-motion gate on amplitude 0.
        // A leftover sine would animate the editor grid.
        XCTAssertEqual(
            BotBlobatarMotion.sample(name: "Piper", time: 3, expression: .mad, amplitude: 0),
            .still
        )
    }
}
