import XCTest
import Darwin
@testable import Surfaces

final class TerminalInputBackpressurePerformanceTests: XCTestCase {
    private struct Sample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let writeSyscalls: Int
        let wouldBlockWrites: Int
        let waitWakeups: Int
        let payloadDigest: UInt64
        let outputDigest: UInt64
        let fifoExact: Bool
    }

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var writes = 0
        private var blocked = 0
        private var waits = 0

        func recordWrite(_ result: TerminalWriteResult) {
            lock.lock()
            writes += 1
            if result == .wouldBlock { blocked += 1 }
            lock.unlock()
        }

        func recordWait() {
            lock.lock(); waits += 1; lock.unlock()
        }

        var snapshot: (writes: Int, blocked: Int, waits: Int) {
            lock.lock(); defer { lock.unlock() }
            return (writes, blocked, waits)
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: UnsafeRawBufferPointer, count: Int) {
            lock.lock()
            data.append(contentsOf: bytes.bindMemory(to: UInt8.self).prefix(count))
            lock.unlock()
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    private struct OwnedPTY: Sendable {
        let pid: pid_t
        let masterFD: Int32
        let lease: TerminalFileDescriptorLease
    }

    /// Same-process paired A/B through the production TerminalInputPump against
    /// an owned, raw PTY whose suspended `cat` child makes the master genuinely
    /// return EAGAIN. Each child resumes after the same 200 ms pressure window.
    func test_benchmarkRealPTYBackpressure_readinessReducesWakeupsAndCPUWithoutLatencyOrFIFORegression() throws {
        guard ProcessInfo.processInfo.environment["RC2_TERMINAL_INPUT_BACKPRESSURE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_TERMINAL_INPUT_BACKPRESSURE_BENCHMARK=1 to run the real PTY input A/B benchmark.")
        }

        let warmupCount = 2
        let measuredCount = 5
        let resumeDelayMicros: useconds_t = 200_000
        var payload = Data()
        payload.reserveCapacity(256 * 1024)
        for index in 0..<(256 * 1024) {
            payload.append(UInt8((index &* 31 &+ 17) % 251))
        }

        for iteration in 0..<warmupCount {
            if iteration.isMultiple(of: 2) {
                _ = try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: false)
                _ = try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: true)
            } else {
                _ = try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: true)
                _ = try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: false)
            }
        }

        var legacy: [Sample] = []
        var readiness: [Sample] = []
        for iteration in 0..<measuredCount {
            if iteration.isMultiple(of: 2) {
                legacy.append(try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: false))
                readiness.append(try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: true))
            } else {
                readiness.append(try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: true))
                legacy.append(try measure(payload: payload, resumeDelayMicros: resumeDelayMicros, useReadiness: false))
            }
        }

        XCTAssertTrue((legacy + readiness).allSatisfy(\.fifoExact),
            "both arms must recover the exact accepted byte sequence through the real PTY")
        XCTAssertTrue((legacy + readiness).allSatisfy { $0.payloadDigest == $0.outputDigest },
            "payload and recovered output hashes must match in every measured iteration")
        XCTAssertTrue((legacy + readiness).allSatisfy { $0.wouldBlockWrites > 0 },
            "the fixture must reach genuine production EAGAIN backpressure")

        let legacyWall = median(legacy.map(\.wallMilliseconds))
        let readinessWall = median(readiness.map(\.wallMilliseconds))
        let legacyCPU = median(legacy.map(\.cpuMilliseconds))
        let readinessCPU = median(readiness.map(\.cpuMilliseconds))
        let legacyWrites = median(legacy.map { Double($0.writeSyscalls) })
        let readinessWrites = median(readiness.map { Double($0.writeSyscalls) })
        let legacyWakeups = median(legacy.map { Double($0.wouldBlockWrites) })
        let readinessWakeups = median(readiness.map { Double($0.waitWakeups) })

        let cpuImprovement = improvement(before: legacyCPU, after: readinessCPU)
        let writeImprovement = improvement(before: legacyWrites, after: readinessWrites)
        let wakeupImprovement = improvement(before: legacyWakeups, after: readinessWakeups)
        let wallImprovement = improvement(before: legacyWall, after: readinessWall)

        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) payload_bytes=\(payload.count) resume_delay_us=\(resumeDelayMicros) PTY=real EAGAIN=real FIFO=exact hash=FNV1a64")
        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK legacy_wall_ms=\(legacy.map(\.wallMilliseconds)) readiness_wall_ms=\(readiness.map(\.wallMilliseconds)) legacy_wall_median_ms=\(legacyWall) readiness_wall_median_ms=\(readinessWall) wall_improvement_percent=\(wallImprovement)")
        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK legacy_cpu_ms=\(legacy.map(\.cpuMilliseconds)) readiness_cpu_ms=\(readiness.map(\.cpuMilliseconds)) legacy_cpu_median_ms=\(legacyCPU) readiness_cpu_median_ms=\(readinessCPU) cpu_improvement_percent=\(cpuImprovement)")
        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK legacy_write_syscalls=\(legacy.map(\.writeSyscalls)) readiness_write_syscalls=\(readiness.map(\.writeSyscalls)) write_syscall_improvement_percent=\(writeImprovement)")
        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK legacy_sleep_wakeups=\(legacy.map(\.wouldBlockWrites)) readiness_poll_wakeups=\(readiness.map(\.waitWakeups)) wakeup_improvement_percent=\(wakeupImprovement)")
        print("TERMINAL_INPUT_BACKPRESSURE_BENCHMARK digest=\(legacy.first?.payloadDigest ?? 0)")

        XCTAssertGreaterThan(cpuImprovement, 5)
        XCTAssertGreaterThan(writeImprovement, 5)
        XCTAssertGreaterThan(wakeupImprovement, 5)
        XCTAssertLessThanOrEqual(readinessWall, legacyWall * 1.05,
            "kernel readiness must not regress the fixed-resume delivery latency by more than the 5% noise threshold")
    }

    private func measure(
        payload: Data,
        resumeDelayMicros: useconds_t,
        useReadiness: Bool
    ) throws -> Sample {
        let pty = try makeSuspendedRawCatPTY()
        let counters = Counters()
        let output = DataBox()
        let readerFinished = DispatchSemaphore(value: 0)
        let readerQueue = DispatchQueue(label: "rc2.terminal.input-benchmark.reader", qos: .userInitiated)
        var pump: TerminalInputPump?

        defer {
            pump?.stop()
            pty.lease.close()
            _ = Darwin.kill(pty.pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(pty.pid, &status, 0) < 0, errno == EINTR {}
        }

        readerQueue.async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while output.value.count < payload.count,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                var descriptor = pollfd(fd: pty.masterFD, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 50)
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else { continue }
                let count = Darwin.read(pty.masterFD, &buffer, buffer.count)
                if count > 0 {
                    buffer.withUnsafeBytes { output.append($0, count: count) }
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            readerFinished.signal()
        }

        let waiter: TerminalInputPump.WriteReadinessWaiter?
        if useReadiness {
            waiter = { timeoutMicros in
                pty.lease.waitForWritable(
                    timeoutMicros: timeoutMicros,
                    onPoll: { counters.recordWait() }
                )
            }
        } else {
            waiter = nil
        }
        pump = TerminalInputPump(
            retryDelay: 2_000,
            maxWouldBlockWaitMicros: 5_000_000,
            waitForWriteReadiness: waiter,
            writer: { data, offset in
                let result = pty.lease.write(data, offset: offset)
                counters.recordWrite(result)
                return result
            }
        )

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .microseconds(Int(resumeDelayMicros))
        ) {
            _ = Darwin.kill(pty.pid, SIGCONT)
        }

        let cpuStarted = processCPUMicroseconds()
        let wallStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(pump?.enqueue(payload), .accepted)
        pump?.drain()
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 5), .success,
            "the resumed cat child must echo the complete payload")
        let wallEnded = DispatchTime.now().uptimeNanoseconds
        let cpuEnded = processCPUMicroseconds()

        let recovered = output.value
        let count = counters.snapshot
        return Sample(
            wallMilliseconds: Double(wallEnded - wallStarted) / 1_000_000,
            cpuMilliseconds: Double(cpuEnded - cpuStarted) / 1_000,
            writeSyscalls: count.writes,
            wouldBlockWrites: count.blocked,
            waitWakeups: count.waits,
            payloadDigest: fnv1a64(payload),
            outputDigest: fnv1a64(recovered),
            fifoExact: recovered == payload
        )
    }

    private func makeSuspendedRawCatPTY() throws -> OwnedPTY {
        let spawn = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/cat",
            arguments: ["cat"],
            environment: ["PATH": "/usr/bin:/bin"],
            suspendedBeforeExec: true
        )
        guard spawn.pid > 0, spawn.masterFD >= 0 else {
            if spawn.masterFD >= 0 { Darwin.close(spawn.masterFD) }
            throw NSError(domain: "TerminalInputBackpressurePerformanceTests.spawn", code: Int(errno))
        }

        let lease = TerminalFileDescriptorLease(fd: spawn.masterFD)
        do {
            guard TerminalPTYProcessRuntime.ownsStoppedChild(pid: spawn.pid) else {
                throw NSError(domain: "TerminalInputBackpressurePerformanceTests.ownership", code: 1)
            }
            var attributes = termios()
            guard tcgetattr(spawn.masterFD, &attributes) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            cfmakeraw(&attributes)
            guard tcsetattr(spawn.masterFD, TCSANOW, &attributes) == 0,
                  TerminalFileDescriptorFlags.enableCloseOnExec(spawn.masterFD),
                  TerminalFileDescriptorFlags.enableNonBlocking(spawn.masterFD) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return OwnedPTY(pid: spawn.pid, masterFD: spawn.masterFD, lease: lease)
        } catch {
            lease.close()
            _ = Darwin.kill(spawn.pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(spawn.pid, &status, 0) < 0, errno == EINTR {}
            throw error
        }
    }

    private func processCPUMicroseconds() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000 + UInt64(usage.ru_utime.tv_usec)
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000 + UInt64(usage.ru_stime.tv_usec)
        return user + system
    }

    private func fnv1a64(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func improvement(before: Double, after: Double) -> Double {
        guard before > 0 else { return 0 }
        return 100 * (before - after) / before
    }
}
