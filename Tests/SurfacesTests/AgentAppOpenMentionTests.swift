import XCTest
import CoreModel
@testable import Surfaces

/// UX-MAC_AGENT-OPEN-SPLIT: a clicked mention must land on the file the agent
/// meant — resolution against the thread root, `:line` stripping, bare-filename
/// search — or refuse (nil → beep) rather than open something unrelated.
final class AgentAppOpenMentionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: root.appendingPathComponent("Sources/App/Main.swift").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("README.md").path, contents: Data("x".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func resolve(_ raw: String) -> String? {
        AgentAppViewModel.resolveFileMention(raw, root: root.path)
    }

    // MARK: resolution

    func test_relativeMention_resolvesAgainstThreadRoot() {
        XCTAssertEqual(resolve("Sources/App/Main.swift"), root.appendingPathComponent("Sources/App/Main.swift").path,
                       "agents speak in workspace-relative paths — they must open the workspace file")
    }

    func test_lineSuffix_isStrippedBeforeResolution() {
        XCTAssertEqual(resolve("Sources/App/Main.swift:42"), root.appendingPathComponent("Sources/App/Main.swift").path)
        XCTAssertEqual(resolve("Sources/App/Main.swift:42:7"), root.appendingPathComponent("Sources/App/Main.swift").path,
                       "compiler-style file:line:col refs must still open the file")
    }

    func test_absoluteMention_resolvesDirectly() {
        let absolute = root.appendingPathComponent("README.md").path
        XCTAssertEqual(resolve(absolute), absolute)
    }

    func test_bareFilename_isFoundByWorkspaceSearch() {
        XCTAssertEqual(resolve("Main.swift"), root.appendingPathComponent("Sources/App/Main.swift").path,
                       "\"look at Main.swift\" is the most common mention shape — it must resolve without a path")
    }

    func test_deletedFile_fallsBackToItsExistingParentDirectory() {
        XCTAssertEqual(resolve("Sources/App/Gone.swift"), root.appendingPathComponent("Sources/App").path,
                       "a since-deleted mention should land the user next to where it was, not dead-click")
    }

    func test_unresolvableMention_returnsNilInsteadOfGuessing() {
        XCTAssertNil(resolve("nowhere/at/all.xyz"),
                     "when nothing on disk plausibly matches, refusing beats opening the workspace root")
        XCTAssertNil(resolve(""), "an empty token must never resolve")
    }

    func test_directoryMention_resolvesToTheDirectory() {
        XCTAssertEqual(resolve("Sources/App"), root.appendingPathComponent("Sources/App").path,
                       "directory mentions open the Files panel at that directory")
    }

    // MARK: line-suffix helper

    func test_strippingLineSuffix_onlyRemovesDigitSegments() {
        XCTAssertEqual(AgentAppViewModel.strippingLineSuffix("a.swift:12"), "a.swift")
        XCTAssertEqual(AgentAppViewModel.strippingLineSuffix("a.swift:12:5"), "a.swift")
        XCTAssertEqual(AgentAppViewModel.strippingLineSuffix("a.swift"), "a.swift")
        XCTAssertEqual(AgentAppViewModel.strippingLineSuffix("weird:name:file"), "weird:name:file",
                       "non-numeric colon segments are part of the name, not a line ref")
    }

    // MARK: tool rows

    private func item(type: AssistantItemType = .tool, body: String) -> AssistantItem {
        AssistantItem(id: "i1", turnId: "t1", type: type, state: .completed, body: body, startedAtMs: 0)
    }

    func test_readToolInput_yieldsFileTarget() {
        let target = AgentTimelineItemPresentation.toolOpenTarget(for: item(body: #"{"file_path":"Sources/App/Main.swift"}"#))
        XCTAssertEqual(target, .file("Sources/App/Main.swift"),
                       "Read/Edit tool rows must offer opening the exact file the tool touched")
    }

    func test_fetchToolInput_yieldsURLTarget() {
        let target = AgentTimelineItemPresentation.toolOpenTarget(for: item(body: #"{"url":"https://example.com/doc"}"#))
        XCTAssertEqual(target, .url(URL(string: "https://example.com/doc")!))
    }

    func test_nonWebURLInToolInput_isNotOpenable() {
        XCTAssertNil(AgentTimelineItemPresentation.toolOpenTarget(for: item(body: #"{"url":"javascript:alert(1)"}"#)),
                     "only http(s) tool URLs may open the in-app browser")
    }

    func test_bashCommandInput_hasNoOpenTarget() {
        XCTAssertNil(AgentTimelineItemPresentation.toolOpenTarget(for: item(body: #"{"command":"rm -rf build"}"#)),
                     "a shell command is not a navigable file — no affordance must appear")
    }

    func test_prosaicItemTypes_neverOfferTargets() {
        XCTAssertNil(AgentTimelineItemPresentation.toolOpenTarget(for: item(type: .assistantMessage, body: #"{"file_path":"x"}"#)))
    }
}
