import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class DistillGuestRecoveryTests: XCTestCase {
    func testParseAcceptsOnlyAllowedClosedActionObject() throws {
        XCTAssertEqual(try DistillGuestHostDiagnosis.parse(Data(#"{"action":"stop"}"#.utf8), allowedActions: [.stop]), .stop)
        XCTAssertEqual(try DistillGuestHostDiagnosis.parse(Data(#"{"structuredOutput":{"action":"resynchronizeGuest"},"text":"","stopReason":"end_turn","structuredOutputError":null}"#.utf8), allowedActions: [.resynchronizeGuest]), .resynchronizeGuest)
        XCTAssertEqual(try DistillGuestHostDiagnosis.parse(Data(#"{"text":"{\"action\":\"stop\"}","stopReason":"normal"}"#.utf8), allowedActions: [.stop]), .stop)
    }

    func testParseRejectsMalformedExtraAndDisallowedActions() {
        for json in ["not json", #"{"action":"stop","extra":true}"#, #"{"action":"unknown"}"#, #"{"structuredOutput":{"action":"stop"},"stopReason":"cancelled"}"#, #"{"structuredOutput":{"action":"stop"},"structuredOutputError":"bad"}"#] {
            XCTAssertThrowsError(try DistillGuestHostDiagnosis.parse(Data(json.utf8), allowedActions: [.refreshGuestCatalog]))
        }
        XCTAssertThrowsError(try DistillGuestHostDiagnosis.parse(Data(#"{"action":"stop"}"#.utf8), allowedActions: [.refreshGuestCatalog]))
    }

    func testFakeProcessSeparatesStderrAndUsesIsolatedCwdAndEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnosis-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "printf 'stderr noise' >&2; printf '{\"action\":\"stop\"}'; printf '%s|%s' \"$HOME\" \"$PWD\""
        let result = try await DistillGuestHostDiagnosis.run(binary: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], cwd: root, timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).hasPrefix("{\"action\":\"stop\"}"))
        let output = String(decoding: result.stdout, as: UTF8.self)
        let workingDirectory = try XCTUnwrap(output.components(separatedBy: "|").last)
        XCTAssertEqual(URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        XCTAssertTrue(output.contains(root.path))
        XCTAssertEqual(try DistillGuestHostDiagnosis.parse(Data(#"{"action":"stop"}"#.utf8), allowedActions: [.stop]), .stop)
    }

    func testTimeoutEscalatesToKillAndWaitsForOwnedProcessExit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("pid")
        let script = "#!/bin/sh\necho $$ > '\(marker.path)'\ntrap '' TERM\nwhile :; do :; done\n"
        let binary = try fixture.executable(script)
        let start = Date()
        do {
            _ = try await DistillGuestHostDiagnosis.run(binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"], cwd: fixture.root, timeout: 0.5)
            XCTFail("Expected timeout")
        } catch DistillGuestHostDiagnosis.Failure.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        } catch { XCTFail("Unexpected failure: \(error)") }
        let pid = try fixture.waitForPID(marker)
        XCTAssertEqual(kill(pid, 0), -1, "Timed-out owned process must be gone")
    }

    func testCancellationTerminatesOwnedProcessAndWaitsForExit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("pid")
        let binary = try fixture.executable("#!/bin/sh\necho $$ > '\(marker.path)'\ntrap '' TERM\nwhile :; do :; done\n")
        let task = Task { try await DistillGuestHostDiagnosis.run(binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"], cwd: fixture.root, timeout: 10) }
        let pid = try fixture.waitForPID(marker)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(kill(pid, 0), -1, "Cancelled owned process must be gone")
    }

    func testOutputOverflowStopsOwnedProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("pid")
        let binary = try fixture.executable("#!/bin/sh\necho $$ > '\(marker.path)'\nexec /usr/bin/yes x\n")
        do {
            _ = try await DistillGuestHostDiagnosis.run(binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"], cwd: fixture.root, timeout: 5)
            XCTFail("Expected output limit")
        } catch DistillGuestHostDiagnosis.Failure.outputLimit { }
        catch { XCTFail("Unexpected failure: \(error)") }
        let pid = try fixture.waitForPID(marker)
        XCTAssertEqual(kill(pid, 0), -1, "Overflowing owned process must be gone")
    }

    func testDiagnosisFailuresRemoveSyntheticTemporaryHome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source/.distill", isDirectory: true)
        let temp = fixture.root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "auto", cwd: fixture.root.path, prompt: "SECRET TASK PROMPT")
        for script in ["#!/bin/sh\nprintf '{\\\"action\\\":\\\"stop\\\"}'\nexit 7\n", "#!/bin/sh\nprintf 'not json'\n"] {
            let binary = try fixture.executable(script)
            do {
                _ = try await DistillGuestHostDiagnosis.diagnose(DistillGuestRecoveryContext(category: .transport, availableActions: [.stop]), request: request, binary: binary.path, hostHome: fixture.root.appendingPathComponent("source"), temporaryHome: temp, timeout: 2)
                XCTFail("Expected diagnosis failure")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        }

        let marker = fixture.root.appendingPathComponent("diagnosis-pid")
        let hanging = try fixture.executable("#!/bin/sh\necho $$ > '\(marker.path)'\ntrap '' TERM\nwhile :; do :; done\n")
        let cancellationHome = fixture.root.appendingPathComponent("cancel-home", isDirectory: true)
        let task = Task {
            try await DistillGuestHostDiagnosis.diagnose(DistillGuestRecoveryContext(category: .transport, availableActions: [.stop]), request: request, binary: hanging.path, hostHome: fixture.root.appendingPathComponent("source"), temporaryHome: cancellationHome, timeout: 10)
        }
        _ = try fixture.waitForPID(marker)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancellationHome.path))
    }

    func testIsolationConfigurationAndPromptContainOnlyContext() throws {
        let context = DistillGuestRecoveryContext(category: .transport, availableActions: [.resynchronizeGuest, .stop])
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(context), encoding: .utf8))
        XCTAssertTrue(text.contains("transport"))
        XCTAssertFalse(text.contains("private-path"))
        XCTAssertTrue(DistillGuestHostDiagnosis.prompt.contains("Do not use tools."))
        XCTAssertTrue(DistillGuestHostDiagnosis.schema(allowedActions: [.stop]).contains("[\"stop\"]"))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-recovery-test-\(UUID().uuidString)", isDirectory: true)

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

        func executable(_ contents: String) throws -> URL {
            let url = root.appendingPathComponent("fake-cli-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }

        func waitForPID(_ marker: URL) throws -> Int32 {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw NSError(domain: "DistillGuestRecoveryTests", code: 1)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
