import XCTest
@testable import CoreModel

final class ComputerUseNativeHostBackendTests: XCTestCase {
    func test_observationResolvesExactTargetWithoutActivation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        let metadata = try XCTUnwrap(result.content.first?.text)
        XCTAssertTrue(metadata.contains("\"target_pid\":17"))
        XCTAssertTrue(metadata.contains("\"target_window_id\":29"))
        XCTAssertTrue(metadata.contains("\"state_token\":"))
        XCTAssertTrue(metadata.contains("\"capture_mode\":"))
        XCTAssertTrue(metadata.contains("\"capabilities\":"))
        XCTAssertTrue(metadata.contains("\"user_activity\":"))
        XCTAssertEqual(probe.activations, 0, "observing a target must not activate or raise its window")
    }

    func testCaptureUsesInjectedAsyncExactWindowHook() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)

        let result = await backend.invoke(
            name: "screenshot",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.last?.type, "image")
        XCTAssertEqual(probe.captureCalls, 1)
    }

    func test_staleStateTokenExecutesNoMutation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)
        probe.windowTitle = "changed by the user"

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "stale state must fail before any AX mutation")
    }

    func testHumanActivityWinsAndExecutesNoMutation() async throws {
        let probe = Probe()
        probe.activity = .human
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("human_activity") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "physical user activity has priority over semantic automation")
    }

    func testUnrelatedAndTaggedSyntheticActivityDoNotBlockTarget() {
        var now: UInt64 = 10_000
        let monitor = ComputerUseNativeActivityMonitor(
            quietWindowNanoseconds: 2_000,
            now: { now }
        )
        let target = ComputerUseNativeHostTarget(pid: 17, windowID: 29)

        monitor.record(.init(
            kind: .keyboard,
            pid: 99,
            timestampNanoseconds: now
        ))
        monitor.record(.init(
            kind: .mouse,
            pid: 99,
            windowID: 88,
            timestampNanoseconds: now
        ))
        XCTAssertEqual(monitor.activity(for: target), .none)

        monitor.record(.init(
            kind: .keyboard,
            pid: target.pid,
            timestampNanoseconds: now,
            isSynthetic: true
        ))
        monitor.record(.init(
            kind: .mouse,
            pid: target.pid,
            windowID: target.windowID,
            timestampNanoseconds: now,
            isSynthetic: true
        ))
        XCTAssertEqual(monitor.activity(for: target), .none)

        monitor.record(.init(
            kind: .keyboard,
            pid: target.pid,
            timestampNanoseconds: now
        ))
        XCTAssertEqual(monitor.activity(for: target), .human)
        now += 2_001
        XCTAssertEqual(monitor.activity(for: target), .none, "the native quiet window is exactly two seconds")
    }

    func testMissingPermissionExecutesNoMutation() async throws {
        let probe = Probe()
        probe.accessibilityPermission = false
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("permission_required") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "missing accessibility permission must fail closed")
    }

    func testMinimizedPixelTargetExecutesNoMutation() async throws {
        let probe = Probe()
        probe.isMinimized = true
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("pixel_target_not_renderable") == true)
        XCTAssertEqual(probe.pixelMutations, 0, "minimized pixels cannot be targeted without restoring the window")
    }

    func testFocusOnlyActionsExecuteNoMutation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "type",
            arguments: baseArguments(token: token).merging([
                "text": "secret"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("focus_required") == true)
        XCTAssertEqual(probe.pixelMutations, 0, "typing must not activate or focus a background target")
    }

    func testBackgroundSemanticTypingUsesTargetFocusedElement() async throws {
        let probe = Probe()
        probe.typeTextResult = true
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "type",
            arguments: baseArguments(token: token).merging([
                "text": "background text"
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.typeTextMutations, 1)
        XCTAssertEqual(probe.activations, 0)
    }

    func testLeftClickUsesExactTargetAXHookWithoutActivation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.leftClickMutations, 1)
        XCTAssertEqual(probe.activations, 0)
    }

    func testGetUITreeSerializesBoundedInjectedTargetTree() async throws {
        let probe = Probe()
        probe.uiTree = "{\"role\":\"AXWindow\",\"children\":[{\"role\":\"AXButton\",\"title\":\"Save\"}]}"
        let backend = makeBackend(probe: probe)
        let result = await backend.invoke(
            name: "get_ui_tree",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("AXButton") == true)
        XCTAssertFalse(result.content.first?.text?.contains("unavailable") == true)
    }

    func testSemanticAXActionCanMutateBackgroundTarget() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend)

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(probe.semanticMutations, 1)
        XCTAssertEqual(probe.activations, 0)
    }

    private func stateToken(from backend: ComputerUseNativeHostBackend) async throws -> String {
        let result = await backend.invoke(
            name: "doctor",
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let text = try XCTUnwrap(result.content.first?.text)
        let data = try XCTUnwrap(text.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["state_token"] as? String)
    }

    private func baseArguments(token: String) -> [String: Any] {
        [
            "target_pid": 17,
            "target_window_id": 29,
            "expected_state_token": token,
        ]
    }

    private func makeBackend(probe: Probe) -> ComputerUseNativeHostBackend {
        ComputerUseNativeHostBackend(hooks: .init(
            listWindows: { _ in [probe.window] },
            userActivity: { _ in probe.activity },
            accessibilityPermission: { probe.accessibilityPermission },
            screenCapturePermission: { probe.screenCapturePermission },
            capture: { _ in
                probe.captureCalls += 1
                return probe.isMinimized ? nil : .init(data: "cGl4ZWxz", mimeType: "image/png")
            },
            uiTree: { _ in probe.uiTree },
            semanticAction: { _, _, _ in
                probe.semanticMutations += 1
                return true
            },
            leftClick: { _, _ in
                probe.leftClickMutations += 1
                return true
            },
            typeText: { _, _ in
                probe.typeTextMutations += 1
                return probe.typeTextResult
            },
            pixelAction: { _, _, _ in
                probe.pixelMutations += 1
                return true
            },
            activate: { _ in probe.activations += 1 }
        ))
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    var windowTitle = "RemoteCode"
    var activity: ComputerUseNativeUserActivity = .none
    var accessibilityPermission = true
    var screenCapturePermission = true
    var isMinimized = false
    var semanticMutations = 0
    var leftClickMutations = 0
    var typeTextMutations = 0
    var typeTextResult = false
    var pixelMutations = 0
    var activations = 0
    var captureCalls = 0
    var uiTree: String?

    var window: ComputerUseNativeWindow {
        lock.lock(); defer { lock.unlock() }
        return ComputerUseNativeWindow(
            target: .init(pid: 17, windowID: 29),
            title: windowTitle,
            bundleIdentifier: "com.example.RemoteCode",
            isOnScreen: !isMinimized,
            isMinimized: isMinimized,
            bounds: .zero
        )
    }
}
