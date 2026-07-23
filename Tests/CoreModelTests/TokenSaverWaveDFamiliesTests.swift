import XCTest
@testable import CoreModel

final class TokenSaverWaveDFamiliesTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverWaveDFamilies.defaultEnabled)
        let rt = TokenSaverWaveDRuntime()
        XCTAssertEqual(rt.admitCommand(subcommand: "test", isMutating: false), .notLive)
        XCTAssertTrue(rt.taskDoneAllowed())
        XCTAssertFalse(TokenSaverWaveDRuntime.packageManagerAutoWrapEnabled)
    }

    func test_commandsAndTerminalAndStructure() {
        let rt = TokenSaverWaveDRuntime()
        rt.live = true
        XCTAssertEqual(rt.admitCommand(subcommand: "test", isMutating: false), .admitted)
        XCTAssertEqual(rt.admitCommand(subcommand: "rm", isMutating: false), .unknownSubcommand)
        XCTAssertEqual(rt.admitCommand(subcommand: "test", isMutating: true), .mutant)
        XCTAssertFalse(rt.mayBufferLiveTerminal())
        XCTAssertEqual(rt.codeStructureView(isLatestRead: true, isPatchTarget: false), .latestReadOrPatchForcesRaw)
        XCTAssertEqual(rt.codeStructureView(isLatestRead: false, isPatchTarget: true), .latestReadOrPatchForcesRaw)
    }

    func test_graphRecipesMLXValidation() {
        let rt = TokenSaverWaveDRuntime()
        rt.live = true
        XCTAssertEqual(rt.evidenceGraph(lspStale: true, coverageOK: true), .graphDegraded)
        XCTAssertEqual(rt.validationRecipe(networked: true, mutating: false, mappingAmbiguous: false), .networkedRecipe)
        XCTAssertEqual(rt.validationRecipe(networked: false, mutating: false, mappingAmbiguous: true), .ambiguousMapping)
        XCTAssertFalse(rt.mlxMayInventShell())
        rt.recordValidationFailure()
        XCTAssertFalse(rt.taskDoneAllowed())
    }
}
