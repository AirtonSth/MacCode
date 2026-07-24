import XCTest
import CoreModel
@testable import AgentRuntime

/// Guards the single source of truth for the distill dialect's semantic prefixes.
///
/// WHY this test exists: the seven characters were previously hand-copied into
/// three modules plus two duplicated alias regexes. Those copies are live
/// behaviour gates — they decide whether provider text is buffered, routed to
/// humanization, and badged before a human reads it — so an uneven edit fails
/// silently in one of two directions: a retired prefix keeps being recognized, or
/// a live prefix stops being recognized and raw compressed text reaches the chat
/// UI untranslated. A behavioural test alone cannot catch that, because each
/// module's own tests pass against its own stale copy. So this file asserts both
/// the behaviour AND the structural absence of new copies.
///
/// KNOWN GAP, deliberately not asserted here: `SR1ResponseDetector.isDictionaryLine`
/// and its DistillCore counterpart still spell out the seven prefix *names*
/// (`s=state` … `p=proof`) as separate literals. That is a second duplication of
/// the same vocabulary, but collapsing it requires adding a prefix-to-name map and
/// changing dictionary-line detection, which is out of scope for a de-duplication
/// change. Recorded so the next person does not mistake this test for full coverage.
final class DistillSemanticPrefixParityTests: XCTestCase {

    // MARK: - The vocabulary itself

    func test_sharedConstant_pinsTheSevenPrefixes() {
        // WHY pinned as a literal here: this is the one place the vocabulary is
        // allowed to be written down twice, so a change to the dialect has to be a
        // deliberate edit to a test that says why, not a silent constant bump.
        XCTAssertEqual(DistillSemanticPrefixes.characters, "SCDRONP",
                       "S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof")
        XCTAssertEqual(DistillSemanticPrefixes.set.count, 7,
                       "seven distinct prefixes; a duplicate character would silently shrink the set")
    }

    func test_aliasPattern_preservesHistoricalCharacterClass() {
        // The historical class omits lowercase `s`. Preserved on purpose: widening it
        // would newly reject values like `s=state`. If this assertion is ever changed,
        // it must ship with a test proving the new rejection behaviour is wanted.
        XCTAssertEqual(DistillSemanticPrefixes.aliasDeclarationPattern,
                       #"\b[ScdronpSCDRONP]\s*=\s*[A-Za-z-]+"#,
                       "de-duplication must not change which alias declarations are rejected")
    }

    // MARK: - Behaviour: the detector recognizes exactly the shared set

    func test_detector_recognizesEverySharedPrefix() {
        for prefix in DistillSemanticPrefixes.characters {
            let parsed = SR1ResponseDetector.parseSemanticLine("\(prefix): payload text")
            XCTAssertEqual(parsed?.prefix, prefix,
                           "prefix \(prefix) is in the shared set, so the detector must recognize it")
        }
    }

    func test_detector_recognizesLowercaseFormOfEverySharedPrefix() {
        for prefix in DistillSemanticPrefixes.characters.lowercased() {
            let parsed = SR1ResponseDetector.parseSemanticLine("\(prefix): payload text")
            XCTAssertNotNil(parsed,
                            "models emit lowercase prefixes too; \(prefix) must still parse")
        }
    }

    func test_detector_rejectsLettersOutsideSharedSet() {
        let outsiders = "ABEFGHIJKLMQTUVWXYZ"
        for letter in outsiders {
            XCTAssertNil(SR1ResponseDetector.parseSemanticLine("\(letter): payload text"),
                         "\(letter) is not a semantic prefix; treating it as one would hold ordinary prose")
        }
    }

    // MARK: - Structure: no module may re-declare the vocabulary

    func test_noSourceFileOutsideCoreModelRedeclaresTheVocabulary() throws {
        let sources = try Self.sourcesDirectory()
        let canonicalPath = "CoreModel/DistillSemanticPrefixes.swift"

        // Each pattern is a literal copy that previously existed and desynced.
        let forbidden = [
            #"Set("SCDRONP")"#,
            #""SCDRONP".contains"#,
            "[ScdronpSCDRONP]"
        ]

        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            guard relative != canonicalPath else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for pattern in forbidden where contents.contains(pattern) {
                violations.append("\(relative): \(pattern)")
            }
        }

        XCTAssertTrue(violations.isEmpty,
                      """
                      The semantic prefix vocabulary was re-declared outside CoreModel. \
                      Import CoreModel and use DistillSemanticPrefixes instead — a second copy \
                      desyncs detection from generation and leaks raw dialect into the chat UI. \
                      Offenders: \(violations.joined(separator: ", "))
                      """)
    }

    private static func sourcesDirectory() throws -> URL {
        // .../macos-app/Tests/AgentRuntimeTests/<this file>
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Sources directory not reachable from #filePath (\(sources.path))")
        }
        return sources
    }
}
