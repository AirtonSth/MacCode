import XCTest
@testable import Surfaces

/// Tests for BrowserWaitForJS.mutationObserverScript — a pure JS-builder helper.
///
/// WHY these tests matter:
///   - The helper is the performance seam: replacing 50 ms asyncAfter polling
///     with a MutationObserver means the page notifies Swift the instant the
///     element appears (O(1)) instead of firing up to deadline/50 ms timer
///     callbacks per concurrent wait.
///   - If the JS snippet is structurally broken (wrong escaping, missing
///     MutationObserver/setTimeout calls, or the selector is dropped) the
///     waitFor contract silently degrades back to a timeout for every call.
///   - These tests are pure (no WebKit, no MainActor) so they are fast,
///     deterministic, and runnable on any platform.
final class BrowserWaitForJSTests: XCTestCase {

    // MARK: - Selector embedding

    func test_script_containsSelectorLiteral_plainSelector() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: "#submit-btn", timeoutMs: 5000)
        XCTAssertTrue(js.contains("#submit-btn"),
                      "The generated JS must embed the CSS selector so the MutationObserver targets the right element")
    }

    func test_script_containsSelectorLiteral_complexSelector() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: "div.modal > button[data-role='ok']", timeoutMs: 3000)
        XCTAssertTrue(js.contains("div.modal > button[data-role=\\'ok\\']") ||
                      js.contains("div.modal > button[data-role='ok']"),
                      "Selector with single quotes must appear in the JS without breaking the template literal")
    }

    // MARK: - Backtick escaping

    func test_script_escapsesBacktickInSelector_selectorEmbeddedSafely() {
        // A selector containing a backtick would break a JS template literal
        // if unescaped; the helper must escape it.
        let js = BrowserWaitForJS.mutationObserverScript(selector: "div[attr=`x`]", timeoutMs: 1000)
        XCTAssertFalse(js.contains("=`x`"),
                       "Unescaped backtick inside template literal breaks the JS expression; helper must escape it")
        XCTAssertTrue(js.contains("\\`x\\`"),
                      "Backtick must be escaped as \\` inside the template literal")
    }

    func test_script_escapesBackslashInSelector_doubleEscaped() {
        // A selector like `div[attr="a\\b"]` must survive template-literal embedding.
        let js = BrowserWaitForJS.mutationObserverScript(selector: "div\\special", timeoutMs: 500)
        XCTAssertTrue(js.contains("div\\\\special"),
                      "Backslash in selector must be doubled so the JS string value preserves one backslash")
    }

    // MARK: - Structural contracts

    func test_script_containsMutationObserver_observerSetup() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".foo", timeoutMs: 2000)
        XCTAssertTrue(js.contains("MutationObserver"),
                      "Script must create a MutationObserver — its presence is the performance contract (O(1) wait)")
    }

    func test_script_containsSetTimeout_deadlineContract() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".foo", timeoutMs: 2000)
        XCTAssertTrue(js.contains("setTimeout"),
                      "Script must set a deadline timeout so waitFor can return {ok:false,error:timeout} when the element never appears")
    }

    func test_script_containsTimeoutMs_valueEmbedded() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".foo", timeoutMs: 7500)
        XCTAssertTrue(js.contains("7500"),
                      "The caller-supplied timeoutMs must be forwarded to setTimeout so the JS deadline matches the Swift deadline")
    }

    func test_script_containsPromise_asyncResolution() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".bar", timeoutMs: 1000)
        XCTAssertTrue(js.contains("Promise"),
                      "Script must return a Promise so WKWebView can resolve it asynchronously rather than synchronously blocking")
    }

    func test_presenceCheckScript_usesSynchronousBooleanQuery() {
        let js = BrowserWaitForJS.presenceCheckScript(selector: "#ready")

        XCTAssertTrue(js.contains("Boolean(document.querySelector"),
                      "BrowserSurface.waitFor polls a synchronous selector check so it survives page navigations between attempts")
        XCTAssertTrue(js.contains("#ready"))
    }

    func test_boolValue_acceptsNSNumberBridgeFromWebKit() {
        XCTAssertTrue(BrowserWaitForJS.boolValue(NSNumber(value: true)),
                      "WKWebView can bridge JavaScript booleans as NSNumber; treating that as timeout breaks browser.wait for present elements")
        XCTAssertFalse(BrowserWaitForJS.boolValue(NSNumber(value: false)))
    }

    func test_script_containsObserveSubtree_detectsDeepInsertion() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".baz", timeoutMs: 1000)
        XCTAssertTrue(js.contains("subtree:true") || js.contains("subtree: true"),
                      "Observer must watch the full subtree; elements inserted deep in the DOM would be missed otherwise")
    }

    func test_script_containsEarlyExitIfAlreadyPresent_doesNotBlockWhenElementExists() {
        let js = BrowserWaitForJS.mutationObserverScript(selector: ".exists", timeoutMs: 1000)
        // The early-exit `document.querySelector(...)` check before the observer is set up
        // must appear in the script so synchronously-present elements resolve instantly.
        let queryCount = js.components(separatedBy: "querySelector").count - 1
        XCTAssertGreaterThanOrEqual(queryCount, 2,
                      "Script must check querySelector before and inside the observer to handle elements already in the DOM")
    }

    // MARK: - Idempotence

    func test_script_isIdempotent_sameSelectorYieldsSameScript() {
        let a = BrowserWaitForJS.mutationObserverScript(selector: "#my-id", timeoutMs: 3000)
        let b = BrowserWaitForJS.mutationObserverScript(selector: "#my-id", timeoutMs: 3000)
        XCTAssertEqual(a, b,
                       "Pure helper must return identical output for identical inputs — no hidden state")
    }
}
