import XCTest
@testable import AgentRuntime

final class ProviderCLIProbeCooperativePoolTests: XCTestCase {
    func test_runCompletesWhenEveryCooperativeThreadIsBlockedInProbes() {
        let count = 2 * ProcessInfo.processInfo.activeProcessorCount
        let completed = expectation(description: "all probes complete")
        completed.expectedFulfillmentCount = count
        let lock = NSLock()
        var results: [ProviderCLIProbe.CommandResult?] = Array(repeating: nil, count: count)

        // Probes block their caller; if drains depend on a starved GCD pool, the whole app's Swift concurrency deadlocks.
        // User-initiated callers with children that outlive a scheduling quantum match the router's probe tasks;
        // with drains on DispatchQueue.global this timed out at 60 s, with dedicated drain threads it takes ~1 s.
        for index in 0..<count {
            Task.detached(priority: .userInitiated) {
                let result = ProviderCLIProbe.run(
                    binaryPath: "/bin/sh",
                    arguments: ["-c", "sleep 1; echo ok"],
                    environment: [:],
                    timeoutSeconds: 10
                )
                lock.lock()
                results[index] = result
                lock.unlock()
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 60)
        lock.lock()
        let collected = results
        lock.unlock()
        XCTAssertEqual(collected.count, count)
        for result in collected {
            XCTAssertEqual(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        }
    }

    func test_runOffCooperativePoolDoesNotConsumeCooperativeThreads() {
        let count = 2 * ProcessInfo.processInfo.activeProcessorCount
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let parked = expectation(description: "all dedicated threads return")
        parked.expectedFulfillmentCount = count
        defer { for _ in 0..<count { release.signal() } }

        for _ in 0..<count {
            Task {
                await ProviderCLIProbe.runOffCooperativePool {
                    entered.signal()
                    release.wait()
                    return true
                }
                parked.fulfill()
            }
        }
        for _ in 0..<count {
            XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        }

        let unrelated = expectation(description: "unrelated cooperative task completes")
        Task.detached(priority: .userInitiated) {
            XCTAssertEqual(42, 42)
            unrelated.fulfill()
        }
        wait(for: [unrelated], timeout: 5)
        for _ in 0..<count { release.signal() }
        wait(for: [parked], timeout: 60)
    }

    func test_runHonorsCurrentDirectory_becauseUsageProbesMustRunInTheRequestCwd() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = ProviderCLIProbe.run(
            binaryPath: "/bin/pwd",
            arguments: [],
            environment: [:],
            runAsUser: nil,
            timeoutSeconds: 10,
            currentDirectory: tmp.path
        )
        let actualPath = URL(fileURLWithPath: result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            .resolvingSymlinksInPath().path
        let expectedPath = tmp.resolvingSymlinksInPath().path
        XCTAssertEqual(actualPath, expectedPath)
    }
}
