import XCTest
import AppKit
@testable import AppShell

/// Covers the shipped completion engine, the AppKit completion/ghost path and
/// the Distill inline-completion boundary. The engine drives the real editor
/// popup; these tests call the same functions `CodeEditorTextView` calls.
final class FilesEditorIntelligenceTests: XCTestCase {
    private func caret(at text: String) -> Int { (text as NSString).length }

    // MARK: Word completion engine

    func test_swiftPrefixOffersLanguageKeyword() {
        let text = "let total = 1\nfun"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "swift")
        XCTAssertEqual(items.first?.insertText, "func",
            "typing `fun` in Swift must offer `func` from the language dictionary")
        XCTAssertTrue(items.contains { $0.kind == .keyword })
    }

    func test_typescriptPrefixOffersLanguageKeyword() {
        let text = "const x = 1;\nfun"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "typescript")
        XCTAssertEqual(items.first?.insertText, "function",
            "the same prefix in TypeScript must offer the language-appropriate keyword, not Swift's")
    }

    func test_longerPrefixNarrowsTheList() {
        let short = FileCompletionEngine.completions(in: "p", caret: 1, language: "swift")
        let long = FileCompletionEngine.completions(in: "pri", caret: 3, language: "swift")
        XCTAssertGreaterThan(short.count, long.count,
            "a longer typed prefix must narrow the suggestion list")
        XCTAssertEqual(long.map(\.insertText), ["private", "print"],
            "`pri` must narrow to the two Swift matches, in source order")
    }

    func test_documentSymbolsAppearInCompletions() {
        let text = "let totalCount = 1\nprint(total"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "swift")
        XCTAssertTrue(items.contains { $0.insertText == "totalCount" },
            "identifiers already in the document are valid local completions")
    }

    func test_emptyPrefixReturnsNoCompletions() {
        XCTAssertTrue(FileCompletionEngine.completions(in: "let x = ", caret: 8, language: "swift").isEmpty,
            "whitespace caret must not pop the completion list")
    }

    func test_applyReplacesOnlyTheTypedPrefix() {
        let item = FileCompletionItem("print", kind: .function)
        let result = FileCompletionEngine.apply(item, to: "let x = pri", replacing: NSRange(location: 8, length: 3))
        XCTAssertEqual(result.text, "let x = print")
        XCTAssertEqual(result.caret, 13)
    }

    // MARK: AppKit editor path

    @MainActor
    func test_completionListIsServedByTheRealEditorTextView() {
        let textView = CodeEditorTextView()
        textView.string = "fun"
        textView.language = "swift"
        textView.completionItemsForPrefix = { text, caret in
            FileCompletionEngine.completions(in: text, caret: caret, language: "swift")
        }
        var index = 0
        let words = textView.completions(
            forPartialWordRange: NSRange(location: 0, length: 3),
            indexOfSelectedItem: &index
        ) ?? []
        XCTAssertEqual(words.first, "func",
            "the native completion popup must be fed by the same language engine")
    }

    @MainActor
    func test_ghostCompletionDoesNotChangeDocumentUntilAccepted() {
        let textView = CodeEditorTextView()
        textView.string = "let x = "
        textView.showGhost("42", at: (textView.string as NSString).length)
        XCTAssertEqual(textView.string, "let x = ",
            "AI completion is painted as ghost text and must not mutate the document")
        XCTAssertTrue(textView.hasGhost)

        textView.acceptGhost()
        XCTAssertEqual(textView.string, "let x = 42",
            "Tab acceptance inserts the ghost text at the caret")
        XCTAssertFalse(textView.hasGhost)
    }

    @MainActor
    func test_acceptingGhostIsASingleUndoableEdit() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.allowsUndo = true
        window.contentView = textView
        textView.string = "let x = "
        textView.showGhost("42", at: (textView.string as NSString).length)
        textView.acceptGhost()
        XCTAssertEqual(textView.string, "let x = 42")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "let x = ",
            "one undo must remove the accepted completion as a single edit")
    }

    // MARK: Inline completion request/provider boundary

    func test_requestCarriesPathLanguageAndSurroundingContext() {
        let text = "let value = compute(\nnext"
        let caret = (text as NSString).range(of: "compute(").upperBound
        let request = InlineCompletionRequest(path: "/w/Sources/App.swift", language: "swift", text: text, caret: caret)
        XCTAssertEqual(request.path, "/w/Sources/App.swift")
        XCTAssertEqual(request.language, "swift")
        XCTAssertTrue(request.prefix.hasSuffix("compute("),
            "the request must carry the prefix immediately before the caret")
        XCTAssertTrue(request.suffix.hasPrefix("\nnext"),
            "the request must carry the suffix immediately after the caret")
        let prompt = request.prompt
        XCTAssertTrue(prompt.contains("App.swift"))
        XCTAssertTrue(prompt.contains("swift"))
        XCTAssertTrue(prompt.contains("<cursor/>"))
    }

    func test_providerReturnsSanitizedCompletionAndRecordsPrompt() async throws {
        let recorder = PromptRecorder()
        let provider = DistillInlineCompletionProvider { prompt in
            await recorder.record(prompt)
            return "```swift\n42\n```"
        }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        let completion = try await provider.complete(request)
        XCTAssertEqual(completion, "42",
            "markdown fences from the model must be stripped before ghost text is shown")
        let prompts = await recorder.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("let x = "))
    }

    func test_providerRejectsCompletionThatOnlyRepeatsTheSuffix() {
        XCTAssertNil(DistillInlineCompletionProvider.sanitize("next()", prefix: "x.", suffix: "next()"),
            "a completion duplicating existing following text must be dropped")
    }

    func test_providerTimeoutSurfacesAsErrorAndLeavesCallerAbleToContinue() async {
        let provider = DistillInlineCompletionProvider(timeout: 0.05) { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return "too late"
        }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        do {
            _ = try await provider.complete(request)
            XCTFail("a slow provider must time out instead of blocking the editor")
        } catch {
            XCTAssertEqual(error as? InlineCompletionError, .timedOut)
        }
    }

    func test_providerErrorPropagatesWithoutMutatingAnything() async {
        let provider = DistillInlineCompletionProvider { _ in throw InlineCompletionError.unavailable }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        do {
            _ = try await provider.complete(request)
            XCTFail("provider failure must surface")
        } catch {
            XCTAssertEqual(error as? InlineCompletionError, .unavailable)
        }
    }
}

private actor PromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}
