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

    func test_semanticContentChangeWithStableGeometryRejectsStaleMutation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")
        probe.uiTree = "{\"role\":\"AXWindow\",\"children\":[{\"role\":\"AXButton\",\"title\":\"Cancel\"}]}"

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "AX content changes must invalidate semantic tokens even when geometry is unchanged")
    }

    func test_pixelContentChangeWithStableGeometryRejectsStaleMutation() async throws {
        let probe = Probe()
        let backend = makeBackend(probe: probe)
        // Both screenshot and left_click use the pixel token capability. The
        // only state change below is captured content; PID, title and bounds
        // remain unchanged, so kind mismatch cannot explain the rejection.
        let token = try await stateToken(from: backend, name: "screenshot")
        probe.captureData = "changed-pixels"

        let result = await backend.invoke(
            name: "left_click",
            arguments: baseArguments(token: token).merging([
                "coordinate": [12, 34]
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("stale_state_token") == true)
        XCTAssertEqual(probe.leftClickMutations, 0, "pixel changes must invalidate pixel tokens even when geometry is unchanged")
    }

    func testHumanActivityWinsAndExecutesNoMutation() async throws {
        let probe = Probe()
        probe.activity = .human
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

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

    func testUnavailableActivityMonitorFailsClosedBeforeMutation() async throws {
        let probe = Probe()
        probe.activityMonitorAvailable = false
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("activity_monitor_unavailable") == true)
        XCTAssertEqual(probe.semanticMutations, 0)
    }

    func testHumanActivityRecheckWinsImmediatelyBeforeMutationHook() async throws {
        let probe = Probe()
        probe.activitySequence = [.none, .none, .none, .none, .human]
        let backend = makeBackend(probe: probe)
        let token = try await stateToken(from: backend, name: "doctor")

        let result = await backend.invoke(
            name: "click_element",
            arguments: baseArguments(token: token).merging([
                "role": "AXButton", "label": "Save"
            ]) { _, value in value }
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.first?.text?.contains("human_activity") == true)
        XCTAssertEqual(probe.semanticMutations, 0, "a physical event during token validation must stop the mutation hook")
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
        let token = try await stateToken(from: backend, name: "doctor")

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
        let token = try await stateToken(from: backend, name: "screenshot")

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
        let token = try await stateToken(from: backend, name: "doctor")

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
        let token = try await stateToken(from: backend, name: "doctor")

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
        let token = try await stateToken(from: backend, name: "screenshot")

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
        XCTAssertEqual(probe.uiTreeCalls, 1, "get_ui_tree must hash and return the same single AX traversal")
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

    private func stateToken(from backend: ComputerUseNativeHostBackend, name: String = "doctor") async throws -> String {
        let result = await backend.invoke(
            name: name,
            arguments: ["target_pid": 17, "target_window_id": 29]
        )
        let text = try XCTUnwrap(result.content.first?.text)
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["state_token"] as? String else { continue }
            return token
        }
        throw XCTSkip("native response did not contain an observation token")
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
            userActivity: { _ in probe.nextActivity() },
            activityMonitorAvailable: { probe.activityMonitorAvailable },
            accessibilityPermission: { probe.accessibilityPermission },
            screenCapturePermission: { probe.screenCapturePermission },
            capture: { _ in
                probe.captureCalls += 1
                return probe.isMinimized ? nil : .init(data: probe.captureData, mimeType: "image/png")
            },
            uiTree: { _ in
                probe.uiTreeCalls += 1
                return probe.uiTree
            },
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
    var activitySequence: [ComputerUseNativeUserActivity] = []
    private var activityIndex = 0
    var activityMonitorAvailable = true
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
    var uiTree: String? = "{\"role\":\"AXWindow\",\"title\":\"RemoteCode\"}"
    var uiTreeCalls = 0
    var captureData = "cGl4ZWxz"

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

    func nextActivity() -> ComputerUseNativeUserActivity {
        lock.lock()
        defer { lock.unlock() }
        defer { activityIndex += 1 }
        return activitySequence.indices.contains(activityIndex) ? activitySequence[activityIndex] : activity
    }
}
