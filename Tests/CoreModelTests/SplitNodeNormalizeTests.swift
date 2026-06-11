import XCTest
@testable import CoreModel

/// WHY: SplitNode.normalize is the single function that maps raw ratio arrays
/// (from resize events, split operations, and decode) into the normalized form
/// [0..1] that sums to exactly 1.0.  Downstream geometry math assumes this
/// invariant; an un-normalized ratio array causes panes to overlap or leave
/// gaps that cannot be resolved at layout time.
///
/// SplitNode.init also calls normalize when ratios are supplied but
/// mismatched - these tests pin BOTH the static helper and the init fallback
/// so regressions in either path fail immediately instead of silently
/// corrupting the split layout.
///
/// SplitNode.normalize is public; no production change needed.
final class SplitNodeNormalizeTests: XCTestCase {

    // MARK: - Static helper: SplitNode.normalize

    // WHY: equal weights must produce exactly equal fractions summing to 1.0.
    func test_normalize_equalWeights_twoElements() {
        let result = SplitNode.normalize([1.0, 1.0])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(result[1], 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-12,
            "two equal weights must sum to exactly 1.0 after normalization")
    }

    func test_normalize_unequalWeights_threeElements_sumsToOne() {
        let result = SplitNode.normalize([1.0, 2.0, 3.0])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 1.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(result[1], 2.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(result[2], 3.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-12,
            "arbitrary positive weights must normalize so the sum is 1.0; " +
            "a non-unit sum means the geometry engine cannot correctly map ratios to frame sizes")
    }

    // WHY: already-normalized input must be returned unchanged (idempotent).
    func test_normalize_alreadyNormalized_returnsSameValues() {
        let input = [0.3, 0.4, 0.3]
        let result = SplitNode.normalize(input)
        XCTAssertEqual(result.count, 3)
        for (got, expected) in zip(result, input) {
            XCTAssertEqual(got, expected, accuracy: 1e-10,
                "already-normalized values must survive a second normalization unchanged " +
                "(idempotent contract)")
        }
    }

    // WHY: a single-element array is always [1.0] - the sole child owns 100 % of the space.
    func test_normalize_singleElement_isOne() {
        let result = SplitNode.normalize([42.0])
        XCTAssertEqual(result, [1.0],
            "a single ratio must normalize to [1.0]; a value < 1.0 would leave dead space in the layout")
    }

    // WHY: all-zeros input has no finite normalization target; must produce equal fractions
    // rather than divide-by-zero or NaN so the layout can recover gracefully.
    func test_normalize_allZeros_fallsBackToEqualFractions() {
        let result = SplitNode.normalize([0.0, 0.0, 0.0])
        XCTAssertEqual(result.count, 3)
        for v in result {
            XCTAssertEqual(v, 1.0 / 3.0, accuracy: 1e-12,
                "all-zero input must fall back to equal fractions; " +
                "any NaN or zero would make the pane invisible and unrecoverable")
        }
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-12,
            "equal-fallback ratios must also sum to 1.0")
    }

    // WHY: large values must not overflow; normalization must produce the same
    // fractions as the equivalent small-value input.
    func test_normalize_largeValues_scalesCorrectly() {
        let result = SplitNode.normalize([1_000_000.0, 3_000_000.0])
        XCTAssertEqual(result[0], 0.25, accuracy: 1e-10,
            "large equal-ratio values must normalize to the same fractions as their unit equivalents")
        XCTAssertEqual(result[1], 0.75, accuracy: 1e-10)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-12)
    }

    // MARK: - SplitNode.init: ratio/child count matching

    // WHY: when ratios.count == children.count the constructor must use
    // the normalized version of the supplied ratios, not a fresh equal split.
    func test_init_matchingRatios_normalizesSupplied() {
        let pane0 = LayoutNode.pane(PaneNode())
        let pane1 = LayoutNode.pane(PaneNode())
        let sn = SplitNode(orientation: .horizontal, children: [pane0, pane1], ratios: [1.0, 3.0])
        XCTAssertEqual(sn.ratios[0], 0.25, accuracy: 1e-10,
            "supplied ratio 1.0 / (1.0+3.0) must normalize to 0.25; " +
            "using the raw 1.0 value instead would cause a 4x pane-size error")
        XCTAssertEqual(sn.ratios[1], 0.75, accuracy: 1e-10)
        XCTAssertEqual(sn.ratios.reduce(0, +), 1.0, accuracy: 1e-12,
            "init-normalized ratios must sum to 1.0")
    }

    // WHY: when ratios.count != children.count the constructor must fall back to
    // equal fractions - a mismatched ratio array would crash the geometry engine
    // that indexes ratios by child index.
    func test_init_mismatchedRatioCount_fallsBackToEqualSplit() {
        let pane0 = LayoutNode.pane(PaneNode())
        let pane1 = LayoutNode.pane(PaneNode())
        let pane2 = LayoutNode.pane(PaneNode())
        // 3 children, 2 ratios  -  mismatch
        let sn = SplitNode(orientation: .vertical,
                           children: [pane0, pane1, pane2],
                           ratios: [0.6, 0.4])
        XCTAssertEqual(sn.ratios.count, 3,
            "ratios.count must equal children.count after fallback; " +
            "an out-of-bounds index access on ratios would crash the geometry engine")
        for r in sn.ratios {
            XCTAssertEqual(r, 1.0 / 3.0, accuracy: 1e-10,
                "mismatched ratios must fall back to equal fractions, not use the truncated supplied ratios")
        }
        XCTAssertEqual(sn.ratios.reduce(0, +), 1.0, accuracy: 1e-12)
    }

    // WHY: nil ratios must produce equal fractions (default case for every new split).
    func test_init_nilRatios_equalSplit() {
        let pane0 = LayoutNode.pane(PaneNode())
        let pane1 = LayoutNode.pane(PaneNode())
        let sn = SplitNode(orientation: .horizontal, children: [pane0, pane1], ratios: nil)
        XCTAssertEqual(sn.ratios, [0.5, 0.5],
            "nil ratios must default to equal split; any other value would skew the initial pane sizes")
    }

    // MARK: - Sum invariant after round-trip encode/decode

    // WHY: SplitNode.ratios is Codable. If the JSON encoder/decoder
    // introduces floating-point rounding the sum could drift from 1.0,
    // breaking the geometry engine on the next launch. Pinning this
    // ensures a decoded split is still layout-safe without re-normalization.
    func test_roundTrip_ratiosSumToOne() throws {
        let pane0 = LayoutNode.pane(PaneNode())
        let pane1 = LayoutNode.pane(PaneNode())
        let original = SplitNode(orientation: .horizontal,
                                 children: [pane0, pane1],
                                 ratios: [0.333, 0.667])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)

        XCTAssertEqual(decoded.ratios.reduce(0, +), 1.0, accuracy: 1e-9,
            "decoded SplitNode ratios must still sum to 1.0; " +
            "JSON floating-point rounding must not push the sum off enough to break layout")
    }
}
