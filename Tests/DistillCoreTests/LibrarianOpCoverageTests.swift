import XCTest
@testable import DistillCore

/// Drives EVERY exposed catalog op through the shipped dispatcher against a real
/// temp workspace: no op may return an implementation-missing reason, and the
/// workspace / navigation ops must return real content from the real files.
final class LibrarianOpCoverageTests: XCTestCase {
    private var root: URL!
    private var transcriptDB: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-librarian-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFixture()
        try initGitRepo()
        transcriptDB = root.appendingPathComponent("transcript.sqlite")
        try makeTranscriptDatabase()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func writeFixture() throws {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        import Foundation

        public struct WidgetConfig {
            public let title: String
        }

        public func renderWidget(config: WidgetConfig) -> String {
            return "<widget>\\(config.title)</widget>"
        }

        public func publishWidget(config: WidgetConfig) -> String {
            let markup = renderWidget(config: config)
            return markup + "<published/>"
        }
        """.write(to: sources.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest

        final class WidgetTests: XCTestCase {
            func testRenderWidget() {
                XCTAssertEqual(renderWidget(config: WidgetConfig(title: "x")), "<widget>x</widget>")
            }
        }
        """.write(to: sources.appendingPathComponent("WidgetTests.swift"), atomically: true, encoding: .utf8)
        try """
        public func unusedHelper() -> Int { 41 }
        """.write(to: sources.appendingPathComponent("UnusedHelper.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "FixtureKit",
            targets: [.executableTarget(name: "FixtureApp", path: "Sources")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        all: build

        test:
        \tswift test

        run:
        \tswift run FixtureApp
        """.write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let github = root.appendingPathComponent(".github", isDirectory: true)
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        try "Sources/* @team-core\nSources/Widget.swift @widget-owner\n"
            .write(to: github.appendingPathComponent("CODEOWNERS"), atomically: true, encoding: .utf8)
        let json = (0..<80).map { "{\"id\": \($0), \"name\": \"widget-\($0)\", \"state\": \"ready\"}" }
        try ("[" + json.joined(separator: ",\n") + "]")
            .write(to: root.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        let report = (0..<120).map { index -> String in
            index % 17 == 0
                ? "Sources/WidgetTests.swift:\(index): error: testRenderWidget failed - expected widget \(index)"
                : "Sources/WidgetTests.swift:\(index): note: passed widget \(index)"
        }
        let reportBody = (["Test Suite 'WidgetTests' started", "Running tests…"] + report + ["Executed 120 tests, with 1 failure"])
            .joined(separator: "\n")
        try reportBody.write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let lint = (0..<120).map { "Sources/Widget.swift:\($0): warning: unused variable widget\($0)" }
        let lintBody = (["Linting FixtureKit"] + lint + ["120 problems (1 error, 119 warnings)"]).joined(separator: "\n")
        try lintBody.write(to: root.appendingPathComponent("lint.txt"), atomically: true, encoding: .utf8)
        let listing = (0..<200).map { "Sources/nested/module\($0)/File\($0).swift" }.joined(separator: "\n")
        try listing.write(to: root.appendingPathComponent("listing.txt"), atomically: true, encoding: .utf8)
    }

    private func initGitRepo() throws {
        let git = "/usr/bin/git"
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try run(["init", "-q"])
        try run(["config", "user.email", "fixture@example.com"])
        try run(["config", "user.name", "Fixture Author"])
        try run(["add", "-A"])
        try run(["commit", "-q", "-m", "fixture"])
    }

    private func makeTranscriptDatabase() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            transcriptDB.path,
            """
            CREATE TABLE agent_messages (id TEXT PRIMARY KEY, thread_id TEXT, role TEXT, content TEXT, created_at TEXT);
            INSERT INTO agent_messages VALUES ('m1','thread-fixture','user','why did authentication fail?','2026-09-18T00:00:00Z');
            INSERT INTO agent_messages VALUES ('m2','thread-fixture','assistant','the widget token expired','2026-09-18T00:01:00Z');
            """
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture transcript DB must be created")
    }

    private func environment() -> LibrarianOpEnvironment {
        var environment = LibrarianOpEnvironment.live
        environment.defaultRoot = root.path
        environment.transcript = LibrarianTranscriptSQLite(dbPath: transcriptDB.path).store
        return environment
    }

    private func dispatch(_ id: String, _ configure: (inout LibrarianRequest) -> Void = { _ in }) async -> LibrarianResult {
        let dispatcher = LibrarianDispatcher(environment: environment())
        var request = LibrarianRequest(id: id, provider: "coverage-test", threadID: "thread-fixture")
        request.root = root.path
        configure(&request)
        return await dispatcher.dispatch(request)
    }

    private func reasons(_ result: LibrarianResult) -> String {
        (result.envelope?.jsonString() ?? "") + "\n" + result.text
    }

    // MARK: - No op is a stub

    private let implementationMissingReasons = [
        "host_language_tool_required",
        "graphify_cli_not_executed",
        "fsevents_watch_is_host",
        "media_bytes_required",
        "workbook_bytes_required",
        "two_image_handles_required",
        "host_resume_evict_not_in_sidecar",
        "host_resume_args_evict_not_in_sidecar",
        "host_watch_not_local_suggested",
        "host_codemod_not_local_authored",
        "claude_posttooluse_only",
        "path_wrap_is_host_PATH",
        "vision_ocr_needs_image_bytes",
        "host_only_catalog_op"
    ]

    func test_noExposedOpReturnsAnImplementationMissingReason() async {
        let json = try! String(contentsOf: root.appendingPathComponent("data.json"), encoding: .utf8)
        let report = try! String(contentsOf: root.appendingPathComponent("report.txt"), encoding: .utf8)
        let listing = try! String(contentsOf: root.appendingPathComponent("listing.txt"), encoding: .utf8)
        var offenders: [String] = []
        for id in LibrarianCatalog.implementedIDs {
            let result = await dispatch(id) { request in
                request.input = json
                request.question = "which widget failed?"
                request.pattern = "renderWidget"
                request.symbol = "renderWidget"
                request.paths = ["Sources/Widget.swift", "Sources/WidgetTests.swift"]
                request.fileName = "Sources/Widget.swift"
                request.root = root.path
                request.command = "/usr/bin/true"
                request.payload = #"{"pattern":"widget","replacement":"widget","apply":false}"#
                request.since = "2020-01-01T00:00:00Z"
                if id == "stdout_budget_elide" { request.input = listing }
                if id == "test_crusher" || id == "test_baseline_diff" { request.input = report }
            }
            let text = reasons(result)
            for reason in implementationMissingReasons where text.contains(reason) {
                offenders.append("\(id) -> \(reason)")
            }
        }
        XCTAssertEqual(offenders, [], "no exposed op may report an implementation-missing reason")
    }

    // MARK: - Real content for the formerly stubbed / misrouted ops

    func test_navigationOpsReturnRealWorkspaceContent() async throws {
        let search = await dispatch("workspace_semantic_search") { request in
            request.question = "renderWidget widget config"
        }
        XCTAssertEqual(search.status, .ok)
        XCTAssertTrue(search.text.contains("Widget.swift"), "semantic search must rank a real workspace path: \(search.text)")

        let map = await dispatch("repo_map_budget") { request in
            request.question = "widget rendering"
            request.budgetTokens = 4_000
        }
        XCTAssertEqual(map.status, .ok)
        XCTAssertTrue(map.text.contains("Widget.swift"), "repo map must list real paths: \(map.text)")

        let rank = await dispatch("encoder_rank") { request in
            request.input = "func renderWidget()\nfunc publishWidget()\nunrelated line about flowers"
            request.question = "where is the widget published?"
            request.paths = ["Sources/Widget.swift"]
        }
        XCTAssertEqual(rank.status, .ok)
        XCTAssertTrue(rank.text.contains("encoder_rank"), rank.text)

        let lsp = await dispatch("lsp_query") { request in
            request.paths = ["Sources/Widget.swift"]
            request.symbol = "renderWidget"
            request.navigationOperation = "documentSymbol"
        }
        if lsp.status == .ok {
            XCTAssertTrue(lsp.text.contains("Widget.swift"), "lsp_query must report a real file: \(lsp.text)")
            XCTAssertTrue(lsp.text.contains(":"), "lsp_query must report a real line: \(lsp.text)")
        } else {
            // Honest capability state only: sourcekit-lsp missing/launch failure.
            XCTAssertTrue(
                lsp.text.contains("sourcekit-lsp") || lsp.text.contains("lsp"),
                "a non-ok lsp_query must state the real capability gap: \(lsp.text)"
            )
        }

        let ast = await dispatch("ast_grep_query") { request in
            request.pattern = "return $VALUE"
            request.paths = ["Sources/Widget.swift"]
        }
        XCTAssertEqual(ast.status, .ok, ast.text)
        XCTAssertTrue(ast.text.contains("Widget.swift"), "structural search must report real file:line")
        XCTAssertTrue(ast.text.contains("captures="), "structural search must capture metavariables")

        let changed = await dispatch("workspace_change_notice") { request in
            request.since = "2020-01-01T00:00:00Z"
        }
        XCTAssertEqual(changed.status, .ok)
        XCTAssertTrue(changed.text.contains("changes="), changed.text)

        let wrappers = await dispatch("path_wrappers")
        XCTAssertTrue(
            wrappers.status == .ok || wrappers.text.contains("no managed PATH wrappers"),
            "path_wrappers must report a real inventory or an honest empty state: \(wrappers.text)"
        )
    }

    func test_transcriptOpsSearchTheRealPersistedStore() async throws {
        for op in ["session_transcript_search", "history_recall_search"] {
            let result = await dispatch(op) { request in
                request.question = "authentication"
                request.scopeToThread = false
            }
            XCTAssertEqual(result.status, .ok, "\(op) must read the real transcript store: \(result.text)")
            XCTAssertTrue(result.text.contains("thread-fixture"), result.text)
            XCTAssertTrue(result.text.contains("authentication"), result.text)
        }
    }

    func test_hostOpsDoTheirAdvertisedWork() async throws {
        let evictInput = """
        {"messages":[
          {"kind":"tool_result","content":"\(String(repeating: "noise ", count: 80))"},
          {"kind":"tool_result","content":"second older result"},
          {"kind":"tool_result","content":"recent result"},
          {"kind":"tool_result","content":"newest result"}
        ]}
        """
        let evict = await dispatch("stale_tool_result_evict") { request in request.input = evictInput }
        XCTAssertEqual(evict.status, .ok, evict.text)
        XCTAssertTrue(evict.text.contains("evicted=2"), evict.text)
        XCTAssertTrue(evict.text.contains("[[rc:"), "evicted results must leave a recovery handle")

        let argsInput = """
        {"messages":[
          {"kind":"tool_args","content":"{\\"path\\":\\"a.swift\\",\\"content\\":\\"old\\"}"},
          {"kind":"tool_args","content":"middle"},
          {"kind":"tool_args","content":"recent"},
          {"kind":"tool_args","content":"newest"}
        ]}
        """
        let args = await dispatch("stale_tool_args_evict") { request in request.input = argsInput }
        XCTAssertTrue(args.text.contains("evicted=2"), args.text)

        let original = try String(contentsOf: root.appendingPathComponent("Sources/Widget.swift"), encoding: .utf8)
        let handle = LibrarianHandleStore.makeHandle(original)
        let store = LibrarianHandleStore(records: [handle: original])
        let dispatcher = LibrarianDispatcher(store: store, environment: environment())
        var stubRequest = LibrarianRequest(id: "unchanged_reread_stub", provider: "coverage-test")
        stubRequest.paths = ["Sources/Widget.swift"]
        stubRequest.handle = handle
        let stub = await dispatcher.dispatch(stubRequest)
        XCTAssertEqual(stub.status, LibrarianStatus.ok, stub.text)
        XCTAssertTrue(stub.text.contains("status=unchanged"), stub.text)

        let codemod = await dispatch("batch_codemod_apply") { request in
            request.payload = #"{"pattern":"widget-([0-9]+)","replacement":"widget_$1","apply":false}"#
            request.paths = ["data.json"]
        }
        XCTAssertEqual(codemod.status, .ok, codemod.text)
        XCTAssertTrue(codemod.text.contains("files_changed=1"), codemod.text)
        XCTAssertTrue(codemod.text.contains("revert"), codemod.text)

        let watch = await dispatch("predicate_watch") { request in
            request.command = "/bin/echo"
            request.arguments = ["widget ready"]
            request.pattern = "widget ready"
            request.watchTimeoutSeconds = 5
            request.watchIntervalSeconds = 0.2
        }
        XCTAssertEqual(watch.status, .ok, watch.text)
        XCTAssertTrue(watch.text.contains("matched"), watch.text)
    }

    func test_mediaOpsReportRealCapabilityStates() async throws {
        // Real PNG + real WAV are synthesized so OCR / ASR paths run for real.
        let png = root.appendingPathComponent("shot.png")
        try LibrarianFixtureMedia.writePNG(text: "STEP 1 BUILD", to: png)
        let pngAfter = root.appendingPathComponent("shot-after.png")
        try LibrarianFixtureMedia.writePNG(text: "STEP 2 SHIP", to: pngAfter)
        let wav = root.appendingPathComponent("note.wav")
        try LibrarianFixtureMedia.writeSilentWAV(seconds: 1, to: wav)
        let csv = root.appendingPathComponent("sheet.csv")
        try "a,b\n1,2\n".write(to: csv, atomically: true, encoding: .utf8)

        let ocr = await dispatch("screenshot_ocr") { request in request.paths = ["shot.png"] }
        XCTAssertEqual(ocr.status, .ok, ocr.text)
        XCTAssertTrue(ocr.text.contains("vision-on-device"), ocr.text)

        let diff = await dispatch("screenshot_diff_digest") { request in
            request.paths = ["shot.png", "shot-after.png"]
        }
        XCTAssertEqual(diff.status, .ok, diff.text)
        XCTAssertTrue(diff.text.contains("changed_pct="), diff.text)

        let sheet = await dispatch("spreadsheet_extract") { request in request.paths = ["sheet.csv"] }
        XCTAssertEqual(sheet.status, .ok, sheet.text)
        XCTAssertTrue(sheet.text.contains("a"), sheet.text)
        XCTAssertTrue(sheet.text.contains("1"), sheet.text)

        let audio = await dispatch("audio_transcribe_local") { request in request.paths = ["note.wav"] }
        if audio.status != .ok {
            XCTAssertTrue(
                audio.text.contains("speech_authorization=") || audio.text.contains("speech_state="),
                "ASR must report the real TCC/transcript state, never an implementation stub: \(audio.text)"
            )
        }

        let video = await dispatch("video_keyframe_ocr") { request in request.paths = ["missing.mp4"] }
        XCTAssertTrue(video.text.contains("no video at") || video.text.contains("video_decode_failed"), video.text)
    }

    // MARK: - Suggested capabilities

    func test_suggestedCapabilityOpsReturnRealContent() async throws {
        let commands = await dispatch("project_commands")
        XCTAssertEqual(commands.status, .ok, commands.text)
        XCTAssertTrue(commands.text.contains("swift test"), commands.text)
        XCTAssertTrue(commands.text.contains("make test"), commands.text)

        let branch = await dispatch("branch_files")
        XCTAssertEqual(branch.status, .ok, branch.text)
        XCTAssertTrue(branch.text.contains("branch="), branch.text)

        // Touch a file so the branch view has a real change to report.
        try "// touched\n".write(to: root.appendingPathComponent("Sources/Touched.swift"), atomically: true, encoding: .utf8)
        let touched = await dispatch("branch_files")
        XCTAssertTrue(touched.text.contains("Sources/Touched.swift"), touched.text)

        let references = await dispatch("symbol_references") { request in
            request.symbol = "renderWidget"
        }
        XCTAssertEqual(references.status, .ok, references.text)
        XCTAssertTrue(references.text.contains("Widget.swift"), references.text)
        XCTAssertTrue(references.text.contains("WidgetTests.swift"), references.text)

        let mapping = await dispatch("test_mapping") { request in
            request.paths = ["Sources/Widget.swift"]
        }
        XCTAssertEqual(mapping.status, .ok, mapping.text)
        XCTAssertTrue(mapping.text.contains("WidgetTests.swift"), mapping.text)

        let ownership = await dispatch("ownership_lookup") { request in
            request.paths = ["Sources/Widget.swift"]
        }
        XCTAssertEqual(ownership.status, .ok, ownership.text)
        XCTAssertTrue(ownership.text.contains("@widget-owner") || ownership.text.contains("@team-core"), ownership.text)
        XCTAssertTrue(ownership.text.contains("recent_authors"), ownership.text)

        let orphans = await dispatch("orphan_files")
        XCTAssertEqual(orphans.status, .ok, orphans.text)
        XCTAssertTrue(orphans.text.contains("UnusedHelper.swift"), orphans.text)
        XCTAssertFalse(orphans.text.contains("WidgetTests.swift"), "test files are never orphan candidates")

        let graph = await dispatch("call_graph") { request in request.symbol = "renderWidget" }
        XCTAssertEqual(graph.status, .ok, graph.text)
        XCTAssertTrue(graph.text.contains("WidgetTests.swift"), "call graph must name the real caller")
        XCTAssertTrue(graph.text.contains("publishWidget"), "call graph must name the real callee: \(graph.text)")
    }
}

/// Deterministic media fixtures: a real PNG drawn with CoreGraphics and a real
/// silent WAV written by hand, so the media ops run on real bytes.
enum LibrarianFixtureMedia {
    static func writePNG(text: String, to url: URL) throws {
        #if canImport(CoreGraphics)
        let width = 320
        let height = 120
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("CoreGraphics context unavailable")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        #if canImport(AppKit)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36),
            .foregroundColor: NSColor.black
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 16, y: 50)
        CTLineDraw(line, context)
        #endif
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("PNG encoding unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("PNG finalize failed")
        }
        #else
        throw XCTSkip("CoreGraphics unavailable")
        #endif
    }

    static func writeSilentWAV(seconds: Int, to url: URL) throws {
        let sampleRate = 8_000
        let frames = sampleRate * seconds
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        try data.write(to: url)
    }
}

#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
