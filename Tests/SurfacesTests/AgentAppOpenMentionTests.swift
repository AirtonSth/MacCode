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

    func test_missingTopLevelPathShapedMention_opensWorkspaceRootInFiles() {
        // WHY: agents often link planned deliverables (`./plan`) before the file
        // exists. Clicking must open the Files split at the workspace root, not beep.
        XCTAssertEqual(resolve("./plan"), root.path,
                       "./plan must open Files at the workspace root when the leaf is not on disk yet")
        XCTAssertNil(resolve("plan/index.html"),
                     "multi-segment missing paths must not open the workspace root as a guess")
        XCTAssertTrue(AgentAppViewModel.isPathShapedFileMention("./plan"))
        XCTAssertTrue(AgentAppViewModel.isPathShapedFileMention("foo/bar"))
        XCTAssertFalse(AgentAppViewModel.isPathShapedFileMention("Package.swift"),
                       "bare filenames stay bare so workspace search, not root fallback, owns them")
        XCTAssertTrue(AgentAppViewModel.allowsWorkspaceRootFallback(
            forCandidate: root.appendingPathComponent("plan").path, root: root.path))
        XCTAssertFalse(AgentAppViewModel.allowsWorkspaceRootFallback(
            forCandidate: root.appendingPathComponent("plan/index.html").path, root: root.path))
    }

    func test_relativeMarkdownURL_tokenIsPathShaped() {
        // Scheme-less markdown targets must still route as file mentions.
        let url = URL(string: "./plan") ?? URL(fileURLWithPath: "./plan")
        let token = AgentAppViewModel.relativeFileMentionToken(from: url)
        XCTAssertEqual(token, "./plan",
                       "relative markdown URLs must yield the path token for Files-split open")
        XCTAssertTrue(token.map(AgentAppViewModel.isPathShapedFileMention) ?? false)
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
