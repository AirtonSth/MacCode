import XCTest
import Darwin
import CoreModel
@testable import Surfaces

private struct TerminalBusyPollSample {
    let callbackWallMilliseconds: Double
    let mainActorCPUMilliseconds: Double
    let observedWakeups: Int
    let checksum: Int64
}

@MainActor
private final class TerminalBusyPollArm {
    private let interval: TimeInterval
    private let duration: TimeInterval
    private let ptys: [(pid: pid_t, masterFD: Int32)]
    private var active = false
    private var callbackWallNanoseconds: UInt64 = 0
    private var mainActorCPUNanoseconds: UInt64 = 0
    private var observedWakeups = 0
    private var checksum: Int64 = 0

    init(interval: TimeInterval, duration: TimeInterval, ptys: [(pid: pid_t, masterFD: Int32)]) {
        self.interval = interval
        self.duration = duration
        self.ptys = ptys
    }

    func start() {
        active = true
        for pty in ptys {
            scheduleProbe(for: pty)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.active = false
        }
    }

    var isActive: Bool { active }

    var sample: TerminalBusyPollSample {
        TerminalBusyPollSample(
            callbackWallMilliseconds: Double(callbackWallNanoseconds) / 1_000_000,
            mainActorCPUMilliseconds: Double(mainActorCPUNanoseconds) / 1_000_000,
            observedWakeups: observedWakeups,
            checksum: checksum
        )
    }

    private func scheduleProbe(for pty: (pid: pid_t, masterFD: Int32)) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.observedWakeups += 1
            guard self.active else { return }
            let cpuStart = Self.threadCPUNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            self.checksum &+= Int64(tcgetpgrp(pty.masterFD))
            self.callbackWallNanoseconds &+= DispatchTime.now().uptimeNanoseconds - wallStart
            self.mainActorCPUNanoseconds &+= Self.threadCPUNanoseconds() - cpuStart
            self.scheduleProbe(for: pty)
        }
    }

    private static func threadCPUNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}

@MainActor
final class TerminalBusyPollingPerformanceTests: XCTestCase {
    private struct OwnedPTY {
        let pid: pid_t
        let masterFD: Int32
    }

    func test_hiddenBusyPollingBacksOffButActivityAndVisibilityKeepSpinnerLatency() {
        XCTAssertEqual(
            TerminalSurface.busyStatePollDelay(isVisible: true, activityTriggered: false),
            0.25,
            accuracy: 0.000_001,
            "a visible terminal must retain the existing 250 ms spinner cadence"
        )
        XCTAssertEqual(
            TerminalSurface.busyStatePollDelay(isVisible: false, activityTriggered: false),
            1.0,
            accuracy: 0.000_001,
            "an eventless hidden foreground job may poll slowly instead of waking the MainActor four times per second"
        )
        XCTAssertEqual(
            TerminalSurface.busyStatePollDelay(isVisible: false, activityTriggered: true),
            0.25,
            accuracy: 0.000_001,
            "input/output/reveal must restore the old 250 ms bound so the visible spinner transition does not regress"
        )
    }

    func test_activityExpeditesHiddenPollWithoutPostponingEarlierDeadline() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(
            TerminalSurface.shouldReplaceBusyStatePoll(
                scheduledAt: now.addingTimeInterval(1.0),
                requestedAt: now.addingTimeInterval(0.25)
            ),
            "completion output must pull a hidden one-second poll forward to the 250 ms activity bound"
        )
        XCTAssertFalse(
            TerminalSurface.shouldReplaceBusyStatePoll(
                scheduledAt: now.addingTimeInterval(0.10),
                requestedAt: now.addingTimeInterval(0.25)
            ),
            "later activity must never postpone a poll that will already observe the final transition sooner"
        )
        XCTAssertTrue(
            TerminalSurface.shouldReplaceBusyStatePoll(
                scheduledAt: nil,
                requestedAt: now.addingTimeInterval(0.25)
            ),
            "a stopped poll loop must restart on terminal activity"
        )
    }

    func test_repeatedHiddenActivityKeepsOnePollAndCloseCancelsQueuedCallback() throws {
        let surface = try makeDeterministicSurface()
        var closed = false
        defer {
            if !closed {
                surface.close()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
        }
        surface.didBecomeHidden()
        XCTAssertEqual(surface.sendTextStatus("sleep 5\n"), .accepted)
        try waitUntil(timeout: 1.0, message: "hidden foreground job never published busy=true") {
            surface.lastPublishedBusyStateForTesting
        }
        XCTAssertEqual(surface.busyStatePollPendingCountForTesting, 1)

        for _ in 0..<4 {
            let entriesBeforeActivity = surface.busyStatePollCallbackEntryCountForTesting
            XCTAssertEqual(surface.sendTextStatus(" "), .accepted)
            XCTAssertEqual(
                surface.busyStatePollPendingCountForTesting,
                1,
                "replacing the hidden safety poll must retain exactly one owned callback"
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.38))
            XCTAssertEqual(
                surface.busyStatePollCallbackEntryCountForTesting,
                entriesBeforeActivity + 1,
                "only the expedited callback may enter; every cancelled one-second callback must stay silent"
            )
            XCTAssertEqual(surface.busyStatePollPendingCountForTesting, 1)
        }

        let entriesBeforeSafetyPoll = surface.busyStatePollCallbackEntryCountForTesting
        RunLoop.main.run(until: Date().addingTimeInterval(1.10))
        XCTAssertEqual(
            surface.busyStatePollCallbackEntryCountForTesting,
            entriesBeforeSafetyPoll + 1,
            "after replacement activity stops, exactly one hidden safety callback may enter"
        )
        XCTAssertEqual(surface.busyStatePollPendingCountForTesting, 1)

        surface.close()
        closed = true
        XCTAssertEqual(surface.busyStatePollPendingCountForTesting, 0)
        let entriesAfterClose = surface.busyStatePollCallbackEntryCountForTesting
        RunLoop.main.run(until: Date().addingTimeInterval(1.10))
        XCTAssertEqual(
            surface.busyStatePollCallbackEntryCountForTesting,
            entriesAfterClose,
            "close must cancel the queued callback before its body enters the MainActor"
        )
    }

    func test_hiddenLivePTYPublishesBusyAndFinalIdleWithBoundedClearLatency() throws {
        let surface = try makeDeterministicSurface()
        defer {
            surface.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
        }
        surface.didBecomeHidden()
        XCTAssertEqual(surface.sendTextStatus("stty -echo\n"), .accepted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.20))

        let marker = "RC2_BUSY_CLEAR_\(UUID().uuidString)"
        XCTAssertEqual(
            surface.sendTextStatus("sleep 0.60; printf '\\n\(marker)\\n'\n"),
            .accepted
        )
        try waitUntil(timeout: 1.0, message: "hidden foreground job never published busy=true") {
            surface.lastPublishedBusyStateForTesting
        }
        try waitUntil(timeout: 1.0, message: "completion output did not reach the hidden mirror") {
            surface.readTextSnapshot().text.contains(marker)
        }
        let outputObservedAt = Date()
        try waitUntil(timeout: 2.60, message: "completion output did not clear busy after the 2 s quiet window") {
            !surface.lastPublishedBusyStateForTesting
        }
        let outputClearMilliseconds = Date().timeIntervalSince(outputObservedAt) * 1_000
        XCTAssertLessThanOrEqual(
            outputClearMilliseconds,
            2_450,
            "busy clears only after the 2 s output-quiet window (so an idle TUI is not busy) plus the 250 ms cadence and scheduler slack"
        )

        XCTAssertEqual(surface.sendTextStatus("sleep 0.40\n"), .accepted)
        try waitUntil(timeout: 1.0, message: "second hidden foreground job never published busy=true") {
            surface.lastPublishedBusyStateForTesting
        }
        let silentBusyObservedAt = Date()
        try waitUntil(timeout: 2.60, message: "eventless completion lost the final busy=false transition") {
            !surface.lastPublishedBusyStateForTesting
        }
        let silentClearMilliseconds = Date().timeIntervalSince(silentBusyObservedAt) * 1_000
        XCTAssertLessThanOrEqual(
            silentClearMilliseconds,
            2_450,
            "a hidden job with no completion output must still clear once the 2 s quiet window passes"
        )
        print("TERMINAL_BUSY_POLL_CLEAR output_triggered_ms=\(outputClearMilliseconds) silent_fallback_ms=\(silentClearMilliseconds)")
    }

    /// Same-process A/B against the production e13ab412 cadence. Both arms schedule
    /// real MainActor timer callbacks and execute a real tcgetpgrp per observed wake
    /// against the same 16 owned busy PTYs. Counts are normalized to 60 seconds.
    func test_benchmarkHiddenBusySixteenPTYs_reducesWakeupsMainActorCPUAndWall() throws {
        guard ProcessInfo.processInfo.environment["RC2_TERMINAL_BUSY_POLL_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_TERMINAL_BUSY_POLL_BENCHMARK=1 to run the terminal busy-poll A/B benchmark.")
        }

        let terminalCount = 16
        let sampleDuration: TimeInterval = 10.5
        let legacyInterval: TimeInterval = 0.25
        let adaptiveInterval = TerminalSurface.busyStatePollDelay(
            isVisible: false,
            activityTriggered: false
        )
        let warmupCount = 2
        let measuredCount = 5
        let ptys = try makeBusyPTYs(count: terminalCount)
        defer { dispose(ptys) }

        func measurePair() -> (legacy: TerminalBusyPollSample, adaptive: TerminalBusyPollSample) {
            let ownedPTYs = ptys.map { (pid: $0.pid, masterFD: $0.masterFD) }
            let legacy = TerminalBusyPollArm(
                interval: legacyInterval,
                duration: sampleDuration,
                ptys: ownedPTYs
            )
            let adaptive = TerminalBusyPollArm(
                interval: adaptiveInterval,
                duration: sampleDuration,
                ptys: ownedPTYs
            )
            legacy.start()
            adaptive.start()
            while legacy.isActive || adaptive.isActive {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return (legacy.sample, adaptive.sample)
        }

        for _ in 0..<warmupCount {
            _ = measurePair()
        }
        var legacy: [TerminalBusyPollSample] = []
        var adaptive: [TerminalBusyPollSample] = []
        for _ in 0..<measuredCount {
            let pair = measurePair()
            legacy.append(pair.legacy)
            adaptive.append(pair.adaptive)
        }

        let legacyWall = median(legacy.map(\.callbackWallMilliseconds))
        let adaptiveWall = median(adaptive.map(\.callbackWallMilliseconds))
        let legacyCPU = median(legacy.map(\.mainActorCPUMilliseconds))
        let adaptiveCPU = median(adaptive.map(\.mainActorCPUMilliseconds))
        let legacyWakeups = median(legacy.map { Double($0.observedWakeups) * 60 / sampleDuration })
        let adaptiveWakeups = median(adaptive.map { Double($0.observedWakeups) * 60 / sampleDuration })
        let wakeupReduction = improvement(before: Double(legacyWakeups), after: Double(adaptiveWakeups))
        let wallImprovement = improvement(before: legacyWall, after: adaptiveWall)
        let cpuImprovement = improvement(before: legacyCPU, after: adaptiveCPU)

        XCTAssertGreaterThan(legacyWakeups, 3_500, "the real 250 ms callbacks should stay close to 3,840 wakes per 60 seconds")
        XCTAssertLessThan(legacyWakeups, 4_000)
        XCTAssertGreaterThan(adaptiveWakeups, 800, "the real one-second callbacks should stay close to 960 wakes per 60 seconds")
        XCTAssertLessThan(adaptiveWakeups, 1_000)
        XCTAssertTrue((legacy + adaptive).allSatisfy { $0.checksum > 0 }, "every observed timer wake must execute tcgetpgrp against an owned PTY")
        print("TERMINAL_BUSY_POLL_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) terminals=\(terminalCount) sample_seconds=\(sampleDuration) callbacks=real tcgetpgrp=real")
        print("TERMINAL_BUSY_POLL_BENCHMARK legacy_wakeups_per_60s=\(legacyWakeups) adaptive_wakeups_per_60s=\(adaptiveWakeups) wakeup_reduction_percent=\(wakeupReduction)")
        print("TERMINAL_BUSY_POLL_BENCHMARK legacy_callback_wall_ms=\(legacy.map(\.callbackWallMilliseconds)) adaptive_callback_wall_ms=\(adaptive.map(\.callbackWallMilliseconds)) legacy_wall_median_ms=\(legacyWall) adaptive_wall_median_ms=\(adaptiveWall) wall_improvement_percent=\(wallImprovement)")
        print("TERMINAL_BUSY_POLL_BENCHMARK legacy_main_actor_cpu_ms=\(legacy.map(\.mainActorCPUMilliseconds)) adaptive_main_actor_cpu_ms=\(adaptive.map(\.mainActorCPUMilliseconds)) legacy_main_actor_cpu_median_ms=\(legacyCPU) adaptive_main_actor_cpu_median_ms=\(adaptiveCPU) main_actor_cpu_improvement_percent=\(cpuImprovement)")
        XCTAssertGreaterThan(wakeupReduction, 5)
        XCTAssertGreaterThan(wallImprovement, 5)
        XCTAssertGreaterThan(cpuImprovement, 5)
    }

    private func makeDeterministicSurface() throws -> TerminalSurface {
        let spawn = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sh",
            arguments: ["sh"],
            environment: [
                "HOME": NSTemporaryDirectory(),
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PS1": "",
                "PS2": "",
                "TERM": "xterm-256color",
            ]
        )
        guard spawn.pid > 0, spawn.masterFD >= 0 else {
            if spawn.masterFD >= 0 { Darwin.close(spawn.masterFD) }
            throw NSError(domain: "TerminalBusyPollingPerformanceTests.surface", code: Int(errno))
        }
        let lease = TerminalFileDescriptorLease(fd: spawn.masterFD)
        let flagsConfigured = TerminalFileDescriptorFlags.enableCloseOnExec(spawn.masterFD)
            && TerminalFileDescriptorFlags.enableNonBlocking(spawn.masterFD)
        let prepared = TerminalPreparedPTYRuntime(
            pid: spawn.pid,
            masterFD: spawn.masterFD,
            lease: lease,
            suspended: false
        )
        guard flagsConfigured else {
            _ = prepared.discard()?.wait(until: .now() + 2)
            throw NSError(domain: "TerminalBusyPollingPerformanceTests.flags", code: Int(errno))
        }
        return try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "busy polling",
            launch: .shell(cwd: NSTemporaryDirectory()),
            preparedRuntime: prepared
        )
    }

    private func makeBusyPTYs(count: Int) throws -> [OwnedPTY] {
        var result: [OwnedPTY] = []
        do {
            for index in 0..<count {
                let spawn = TerminalPTYProcessRuntime.spawn(
                    cwd: NSTemporaryDirectory(),
                    executable: "/bin/sh",
                    arguments: ["sh"],
                    environment: [
                        "HOME": NSTemporaryDirectory(),
                        "LANG": "en_US.UTF-8",
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "PS1": "",
                        "PS2": "",
                        "TERM": "xterm-256color",
                    ]
                )
                guard spawn.pid > 0, spawn.masterFD >= 0 else {
                    if spawn.masterFD >= 0 { Darwin.close(spawn.masterFD) }
                    throw NSError(domain: "TerminalBusyPollingPerformanceTests", code: Int(errno))
                }
                result.append(OwnedPTY(pid: spawn.pid, masterFD: spawn.masterFD))
                let command = Data("sleep 180 # rc2-owned-busy-poll-\(index)\n".utf8)
                let written = command.withUnsafeBytes { pointer in
                    Darwin.write(spawn.masterFD, pointer.baseAddress, command.count)
                }
                guard written == command.count else {
                    throw NSError(domain: "TerminalBusyPollingPerformanceTests.write", code: Int(errno))
                }
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if result.allSatisfy({
                    let group = tcgetpgrp($0.masterFD)
                    return group > 0 && group != $0.pid
                }) {
                    return result
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            throw NSError(domain: "TerminalBusyPollingPerformanceTests.foreground", code: 1)
        } catch {
            dispose(result)
            throw error
        }
    }

    private func dispose(_ ptys: [OwnedPTY]) {
        for pty in ptys {
            let foregroundGroup = tcgetpgrp(pty.masterFD)
            if foregroundGroup > 0, foregroundGroup != pty.pid {
                _ = Darwin.kill(-foregroundGroup, SIGHUP)
            }
            _ = Darwin.kill(pty.pid, SIGHUP)
            Darwin.close(pty.masterFD)
        }
        for pty in ptys {
            var status: Int32 = 0
            while waitpid(pty.pid, &status, 0) < 0, errno == EINTR {}
        }
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func improvement(before: Double, after: Double) -> Double {
        guard before > 0 else { return 0 }
        return 100 * (before - after) / before
    }

    private func waitUntil(
        timeout: TimeInterval,
        message: String,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(message)
        throw NSError(domain: "TerminalBusyPollingPerformanceTests.timeout", code: 1)
    }
}
