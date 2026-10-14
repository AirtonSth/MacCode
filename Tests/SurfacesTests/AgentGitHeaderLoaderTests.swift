import XCTest
import AgentRuntime
@testable import Surfaces

/// WHY: every same-workspace Agent App tab reloads its git header after each
/// finished run, so N tabs used to spawn N full git sets at once. Requests
/// that overlap a running load must share one trailing load, yet each must
/// still get a result read after it asked (never a load that started first).
@MainActor
final class AgentGitHeaderLoaderTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let release = DispatchSemaphore(value: 0)
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func enter() -> Int { lock.lock(); calls += 1; let n = calls; lock.unlock(); return n }
    }

    nonisolated private static func header(_ n: Int) -> AgentGitHeaderLoader.Header {
        (branch: "b\(n)", summary: GitSummary(isGitRepo: true, branch: "b\(n)", dirty: false, files: [], totalAdditions: 0, totalDeletions: 0))
    }

    private func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func test_overlappingRefreshesShareOneTrailingLoad() {
        let gate = Gate()
        let loader = AgentGitHeaderLoader(load: { _ in
            let n = gate.enter()
            gate.release.wait()
            return Self.header(n)
        })
        let owners = (0..<5).map { _ in NSObject() }
        var received: [Int: [String?]] = [:]
        loader.load(cwd: "/repo", owner: owners[0]) { received[0, default: []].append($0.branch) }
        pump { gate.count == 1 }
        for i in 1..<5 {
            loader.load(cwd: "/repo", owner: owners[i]) { received[i, default: []].append($0.branch) }
        }
        XCTAssertEqual(gate.count, 1, "no second load may start while one runs")

        gate.release.signal()
        pump { gate.count == 2 }
        gate.release.signal()
        pump { received.count == 5 }

        XCTAssertEqual(gate.count, 2, "5 overlapping refreshes cost 2 loads, not 5")
        XCTAssertEqual(received[0], ["b1"])
        for i in 1..<5 {
            XCTAssertEqual(received[i], ["b2"], "a request made during load 1 must get load 2, read after it asked")
        }
    }

    func test_ownerThatAsksAgainGetsOnlyTheNewerLoad() {
        let gate = Gate()
        let loader = AgentGitHeaderLoader(load: { _ in
            let n = gate.enter()
            gate.release.wait()
            return Self.header(n)
        })
        let owner = NSObject()
        var received: [String?] = []
        loader.load(cwd: "/repo", owner: owner) { received.append($0.branch) }
        pump { gate.count == 1 }
        loader.load(cwd: "/repo", owner: owner) { received.append($0.branch) }
        loader.load(cwd: "/repo", owner: owner) { received.append($0.branch) }
        gate.release.signal()
        pump { gate.count == 2 }
        gate.release.signal()
        pump { !received.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(received, ["b2"], "latest wins: one delivery, from the load that started after the last request")
    }

    func test_differentWorkspacesLoadIndependently() {
        let gate = Gate()
        let loader = AgentGitHeaderLoader(load: { _ in
            let n = gate.enter()
            gate.release.wait()
            return Self.header(n)
        })
        var done = 0
        loader.load(cwd: "/a", owner: NSObject()) { _ in done += 1 }
        loader.load(cwd: "/b", owner: NSObject()) { _ in done += 1 }
        pump { gate.count == 2 }
        XCTAssertEqual(gate.count, 2, "another workspace never waits behind this one")
        gate.release.signal(); gate.release.signal()
        pump { done == 2 }
        XCTAssertEqual(done, 2)
    }

    /// WHY: a load whose git probe timed out has no trustworthy header;
    /// publishing it showed "no changes" as if fresh. The tab keeps what it
    /// showed, and the workspace is not left marked busy for the next refresh.
    func test_timedOutLoadDeliversNothing_andTheNextLoadStillRuns() {
        let gate = Gate()
        let loader = AgentGitHeaderLoader(load: { _ in
            let n = gate.enter()
            return n == 1 ? nil : Self.header(n)
        })
        let owner = NSObject()
        var received: [String?] = []
        loader.load(cwd: "/repo", owner: owner) { received.append($0.branch) }
        pump { gate.count == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(received, [], "a timed-out load must not replace the header")

        loader.load(cwd: "/repo", owner: owner) { received.append($0.branch) }
        pump { !received.isEmpty }
        XCTAssertEqual(gate.count, 2)
        XCTAssertEqual(received, ["b2"])
    }
}
