import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

/// Real `distill` `/loop` end to end through `DistillACPAdapter`. Costs a few cents and takes ~3 min.
/// Run with `RC_LIVE_DISTILL_LOOP=1 swift test --filter DistillLoopLiveTests`.
final class DistillLoopLiveTests: ProviderProcessTestCase {
    func test_realLoopCreatesIteratesWakesAndStops_becauseAdapterMustSurviveRealProviderShapes() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DISTILL_LOOP"] == "1" else {
            throw XCTSkip("set RC_LIVE_DISTILL_LOOP=1 to run the live Distill /loop test")
        }
        let binary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/distill/bin/distill").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary), "no distill at \(binary)")

        let token = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distill-live-loop-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let threadId = AgentThreadID()
        let adapter = DistillACPAdapter(binaryNameOverride: binary)
        let state = LiveState()
        adapter.onLoopsChanged = { _, loops in state.recordLoops(loops) }
        adapter.onProviderInitiatedTurn = { _, promptId, label in state.recordWake(promptId, label) }
        defer {
            adapter.stopAll()
            try? FileManager.default.removeItem(at: root)
        }

        let started = Date()
        func stamp(_ what: String) { print("LIVE-LOOP +\(Int(Date().timeIntervalSince(started)))s \(what)") }

        func request(_ prompt: String, attach: String? = nil) -> AgentRunRequest {
            var r = AgentRunRequest(
                threadId: threadId, provider: .distill, model: "claude/claude-haiku-5-5",
                cwd: root.path, prompt: prompt, permissionMode: .fullAccess
            )
            r.attachToProviderPromptId = attach
            return r
        }

        // 1. Create the loop.
        let first = LiveEvents()
        _ = try await adapter.startSession(request("/loop 1m reply with the single word PING")) { first.append($0) }
        let firstFinish = try await first.waitForFinish(timeout: 120)
        stamp("first run finished status=\(firstFinish.status) text=\(first.assistantText.debugDescription)")
        XCTAssertEqual(firstFinish.status, .completed)
        XCTAssertEqual(first.finishedCount, 1)

        // 2. Loop state becomes active with at least one iteration.
        let loop = try await state.waitForLoop(timeout: 90) {
            $0.state == .active && $0.iterations >= 1 && $0.humanSchedule.contains("minute")
        }
        stamp("loop active iterations=\(loop.iterations) schedule=\(loop.humanSchedule) task=\(loop.taskID)")

        // 3. Wake turn announced; adopt it.
        let wake = try await state.waitForWake(timeout: 120)
        stamp("wake announced promptId=\(wake.promptId) label=\(wake.label)")
        let second = LiveEvents()
        _ = try await adapter.sendTurn(request("", attach: wake.promptId)) { second.append($0) }
        let wakeFinish = try await second.waitForFinish(timeout: 120)
        stamp("wake run finished status=\(wakeFinish.status) text=\(second.assistantText.debugDescription)")
        print("LIVE-LOOP wake assistant text: \(second.assistantText)")
        XCTAssertEqual(wakeFinish.status, .completed)
        XCTAssertEqual(second.finishedCount, 1, "adopted wake run finishes exactly once")
        XCTAssertFalse(second.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // 4. Stop the loop.
        let taskId = try XCTUnwrap(adapter.loops(threadId: threadId).first?.taskID ?? loop.taskID)
        let deleted = try await adapter.stopLoop(threadId: threadId, taskId: taskId)
        XCTAssertTrue(deleted)
        try await state.waitForLoopsEmpty(timeout: 20)
        stamp("loop removed")
        XCTAssertTrue(adapter.loops(threadId: threadId).isEmpty)

        // 5. Stop the session; no distill left for this cwd.
        try? adapter.stopSession(threadId: threadId)
        adapter.stopAll()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let leftovers = Self.processesUsing(token: token)
        stamp("leftover processes: \(leftovers.isEmpty ? "none" : leftovers.joined(separator: " | "))")
        XCTAssertTrue(leftovers.isEmpty, "leftover distill for temp cwd: \(leftovers)")
    }

    /// Processes whose argv or cwd mention the temp directory token.
    private static func processesUsing(token: String) -> [String] {
        func run(_ path: String, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        var hits = run("/bin/ps", ["-axo", "pid,args"]).split(separator: "\n")
            .map(String.init).filter { $0.contains(token) }
        // lsof prints "p<pid>" then "n<cwd>" for each process.
        var pid = ""
        for line in run("/usr/sbin/lsof", ["-d", "cwd", "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            else if line.hasPrefix("n"), line.contains(token) { hits.append("cwd pid \(pid)") }
        }
        return hits
    }
}

private enum LiveError: Error { case timedOut(String) }

private final class LiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[DistillLoopState]] = []
    private var wakes: [(promptId: String, label: String)] = []

    func recordLoops(_ loops: [DistillLoopState]) { lock.lock(); snapshots.append(loops); lock.unlock() }
    func recordWake(_ id: String, _ label: String) { lock.lock(); wakes.append((id, label)); lock.unlock() }

    private func poll<T>(_ what: String, timeout: TimeInterval, _ probe: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LiveError.timedOut(what)
    }

    func waitForLoop(timeout: TimeInterval, where match: @escaping (DistillLoopState) -> Bool) async throws -> DistillLoopState {
        try await poll("loop state", timeout: timeout) {
            lock.lock(); defer { lock.unlock() }
            return snapshots.flatMap { $0 }.first(where: match)
        }
    }

    func waitForWake(timeout: TimeInterval) async throws -> (promptId: String, label: String) {
        try await poll("provider-initiated turn", timeout: timeout) {
            lock.lock(); defer { lock.unlock() }
            return wakes.first
        }
    }

    func waitForLoopsEmpty(timeout: TimeInterval) async throws {
        try await poll("loops empty", timeout: timeout) {
            lock.lock(); defer { lock.unlock() }
            return snapshots.last?.isEmpty == true ? true : nil
        }
    }
}

private final class LiveEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunEvent] = []

    func append(_ event: AgentRunEvent) { lock.lock(); values.append(event); lock.unlock() }

    var assistantText: String {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.itemDelta(_, let body, _, _)) = event else { return nil }
            return body
        }.joined()
    }

    var finishedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.filter { if case .finished = $0 { return true } else { return false } }.count
    }

    func waitForFinish(timeout: TimeInterval) async throws -> (status: AgentRunStatus, message: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let hit = values.compactMap { event -> (AgentRunStatus, String?)? in
                guard case .finished(let status, let message, _) = event else { return nil }
                return (status, message)
            }.first
            lock.unlock()
            if let hit { return hit }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LiveError.timedOut("finished")
    }
}
