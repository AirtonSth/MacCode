import XCTest
@testable import DistillCore

final class TokenSaverProblemFrameTests: XCTestCase {
    func test_sealedOwners_coverAllFiveRolesAndAreComplete() {
        XCTAssertEqual(
            TokenSaverProblemFrame.sealedOwners.map(\.role).sorted(by: { $0.rawValue < $1.rawValue }),
            TokenSaverProblemFrame.OwnerRole.allCases.sorted(by: { $0.rawValue < $1.rawValue })
        )
        XCTAssertTrue(
            TokenSaverProblemFrame.ownersReceiptIsComplete,
            "task-01 requires a complete owners receipt before task-03+"
        )
        XCTAssertTrue(TokenSaverProblemFrame.validateOwners(TokenSaverProblemFrame.sealedOwners).isEmpty)
    }

    func test_emptyOwnerField_blocksAdvance() {
        var incomplete = TokenSaverProblemFrame.sealedOwners
        incomplete[0] = .init(role: .decision, name: "", contact: "x@example.com")
        XCTAssertEqual(
            TokenSaverProblemFrame.validateOwners(incomplete),
            [.decision]
        )
        let decision = TokenSaverProblemFrame.advanceDecision(
            owners: incomplete,
            eligibleObservations: 100,
            eligibleTokens: 1_000_000,
            denominatorTokens: 1_000_000
        )
        XCTAssertEqual(decision, .stopNoChangeOrWrappersOnly(.incompleteOwners))
    }

    func test_missingOwnerRole_blocksAdvance() {
        let withoutRelease = TokenSaverProblemFrame.sealedOwners.filter { $0.role != .releaseOncall }
        XCTAssertEqual(TokenSaverProblemFrame.validateOwners(withoutRelease), [.releaseOncall])
    }

    func test_noGoList_includesPlanSectionOneSurfaces() {
        let missing = TokenSaverProblemFrame.noGoFreezeContainsRequiredKeywords()
        XCTAssertTrue(
            missing.isEmpty,
            "no-go freeze missing required keywords: \(missing.joined(separator: ", "))"
        )
        XCTAssertGreaterThanOrEqual(TokenSaverProblemFrame.noGoItems.count, 8)
    }

    func test_cohortBelowFloor_stopNoChangeOrWrappersOnly() {
        let decision = TokenSaverProblemFrame.advanceDecision(
            eligibleObservations: 5,
            eligibleTokens: 10,
            denominatorTokens: 1_000_000
        )
        XCTAssertEqual(decision, .stopNoChangeOrWrappersOnly(.cohortBelowFloor))
    }

    func test_cohortFloor_requiresAbsoluteVolumeAndBothThresholds() {
        // Zero absolute tokens never pass (top-rank without volume).
        XCTAssertFalse(
            TokenSaverProblemFrame.cohortMeetsFloor(
                eligibleObservations: 100,
                eligibleTokens: 0,
                denominatorTokens: 1_000_000
            )
        )
        // Observations only (missing share) does not pass under AND freeze.
        XCTAssertFalse(
            TokenSaverProblemFrame.cohortMeetsFloor(
                eligibleObservations: 30,
                eligibleTokens: 100,
                denominatorTokens: 1_000_000
            )
        )
        // Share only (missing observation floor) does not pass.
        XCTAssertFalse(
            TokenSaverProblemFrame.cohortMeetsFloor(
                eligibleObservations: 29,
                eligibleTokens: 10_000,
                denominatorTokens: 1_000_000
            )
        )
        // Exactly 30 observations and exactly 1% share with volume > 0 passes.
        XCTAssertTrue(
            TokenSaverProblemFrame.cohortMeetsFloor(
                eligibleObservations: 30,
                eligibleTokens: 10_000,
                denominatorTokens: 1_000_000
            )
        )
        // Just below 1% fails.
        XCTAssertFalse(
            TokenSaverProblemFrame.cohortMeetsFloor(
                eligibleObservations: 30,
                eligibleTokens: 9_999,
                denominatorTokens: 1_000_000
            )
        )
        let decision = TokenSaverProblemFrame.advanceDecision(
            eligibleObservations: 30,
            eligibleTokens: 10_000,
            denominatorTokens: 1_000_000
        )
        XCTAssertEqual(decision, .mayContinueMeasurement)
    }

    func test_experimentInconclusive_isStop() {
        let decision = TokenSaverProblemFrame.advanceDecision(
            eligibleObservations: 100,
            eligibleTokens: 1_000_000,
            denominatorTokens: 1_000_000,
            experimentInconclusive: true
        )
        XCTAssertEqual(decision, .stopNoChangeOrWrappersOnly(.experimentInconclusive))
    }

    func test_problemFrameDocument_existsWithRequiredSections() throws {
        let docURL = try locateProblemFrameDocument()
        let text = try String(contentsOf: docURL, encoding: .utf8)
        for needle in [
            "Primary outcome",
            "Incidence minimum",
            "Owners receipt",
            "No-go freeze",
            "STOP rule",
            "cross-user",
            "proxy",
            "ONNX",
            "~/.claude",
            "semantic response cache",
            "no-change",
            "wrappers",
        ] {
            XCTAssertTrue(text.contains(needle), "problem frame missing \(needle)")
        }
    }

    func test_schemaAndTaskIdentity() {
        XCTAssertEqual(TokenSaverProblemFrame.schemaVersion, 1)
        XCTAssertEqual(TokenSaverProblemFrame.taskID, "task-01")
        XCTAssertFalse(TokenSaverProblemFrame.primaryOutcomeSummary.isEmpty)
    }

    private func locateProblemFrameDocument() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("docs/token-saver-problem-frame.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        XCTFail("docs/token-saver-problem-frame.md not found from \(#filePath)")
        throw CocoaError(.fileNoSuchFile)
    }
}
