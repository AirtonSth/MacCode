// TokenSaverDistillStatusFormatterTests.swift
//
// Tests for TokenSaverDistillStatusFormatter -- the pure formatter that converts
// a TokenSaverDistillStatusInput into ordered ASCII diagnostic lines for
// "distill --status" output.
//
// WHY these tests exist (Rule 8):
// - The formatter is the contract between the controller state and any
//   diagnostics consumer (CLI --status, UI panel, log output). If it silently
//   drops the sidecar URL or metrics, an operator diagnosing a hung service
//   gets an incomplete picture and wastes time. Every key field has an explicit
//   assertion.
// - The "not-running" and "blocked/failed" cases must produce sane output
//   (no dangling url/pid/metrics lines) so a diagnostics reader is not misled
//   by stale data from a previous run state.
// - ASCII-only rule: the formatter must never emit smart quotes or non-ASCII so
//   the output is safe to pipe, diff, and embed in structured logs.

import XCTest
import DistillCore
@testable import AppShell

final class TokenSaverDistillStatusFormatterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeReadyEvent(
        baseURL: String = "http://127.0.0.1:55000",
        pid: Int32 = 4242,
        runtime: String = "mlx",
        modelID: String = "rc-model-3b"
    ) -> DistillServiceReadyEvent {
        let json = """
        {
          "event": "ready",
          "base_url": "\(baseURL)",
          "host": "127.0.0.1",
          "port": 55000,
          "pid": \(pid),
          "protocol": 1,
          "runtime": "\(runtime)",
          "model_id": "\(modelID)",
          "max_concurrent_requests": 8,
          "max_queue_depth": 64
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(DistillServiceReadyEvent.self, from: json)
    }

    // `DistillServiceMetrics` has no public memberwise init across module
    // boundaries (synthesised inits are internal). Decode from JSON wire format.
    private func makeMetrics(
        active: Int = 1,
        total: Int = 10,
        success: Int = 9,
        failed: Int = 1,
        max: Int = 8
    ) -> DistillServiceMetrics {
        let json = """
        {
          "active_requests": \(active),
          "total_requests": \(total),
          "successful_requests": \(success),
          "failed_requests": \(failed),
          "fallback_requests": 0,
          "result_cache_hits": 0,
          "result_cache_misses": 0,
          "volatile_token_warnings": 0,
          "encoder_lane_invocations": 0,
          "encoder_lane_accepts": 0,
          "encoder_lane_fallbacks": 0,
          "encoder_lane_failures": 0,
          "encoder_lane_deadline_timeouts": 0,
          "pipe_hit_rate": 0,
          "max_concurrent_requests": \(max)
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(DistillServiceMetrics.self, from: json)
    }

    // MARK: - Helpers

    private func line(containing key: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix("\(key):") }
    }

    // MARK: - Running state: all fields present

    func test_running_includesURL() {
        // WHY: the sidecar URL is the primary connection point; a --status output
        // missing the URL is useless for diagnosing connectivity.
        let ready = makeReadyEvent(baseURL: "http://127.0.0.1:55000")
        let input = TokenSaverDistillStatusInput(
            status: .running(ready),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let urlLine = line(containing: "url", in: result)
        XCTAssertNotNil(urlLine, "running state must include a url: line")
        XCTAssertTrue(urlLine!.contains("http://127.0.0.1:55000"),
            "url line must contain the sidecar base URL")
    }

    func test_running_includesReadyzWhenProbed() {
        // WHY: readyz=yes vs readyz=no tells the operator whether the HTTP health
        // endpoint confirms the model is warm; without it a "running" state looks
        // the same whether the model loaded or is still warming up.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: true
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let readyLine = line(containing: "ready", in: result)
        XCTAssertNotNil(readyLine, "running+readyzOK=true must include a ready: line")
        XCTAssertTrue(readyLine!.contains("yes"),
            "readyzOK=true must produce ready: yes")
    }

    func test_running_readyzFalse() {
        // WHY: readyz=false means the HTTP probe returned non-200; the status line
        // must say "no" so the operator knows the service is up but not warm.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: false
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let readyLine = line(containing: "ready", in: result)
        XCTAssertNotNil(readyLine, "running+readyzOK=false must include a ready: line")
        XCTAssertTrue(readyLine!.contains("no"),
            "readyzOK=false must produce ready: no")
    }

    func test_running_includesMetrics() {
        // WHY: metrics (total/active/success/failed) are the core signal for
        // capacity and error-rate diagnostics. Missing them in --status output
        // would hide a sidecar that is processing but failing every request.
        let metrics = makeMetrics(active: 2, total: 20, success: 18, failed: 2, max: 8)
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: metrics,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let metricsLine = line(containing: "metrics", in: result)
        XCTAssertNotNil(metricsLine, "running+metrics must include a metrics: line")
        XCTAssertTrue(metricsLine!.contains("total=20"), "metrics line must include total count")
        XCTAssertTrue(metricsLine!.contains("active=2"), "metrics line must include active count")
        XCTAssertTrue(metricsLine!.contains("success=18"), "metrics line must include success count")
        XCTAssertTrue(metricsLine!.contains("failed=2"), "metrics line must include failed count")
        XCTAssertTrue(metricsLine!.contains("max=8"), "metrics line must include max concurrency")
    }

    func test_running_includesStoreSize() {
        // WHY: the CCR store size tells the operator how much disk the reversible-
        // content cache is consuming. Missing it leaves disk-growth issues invisible.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: 1_048_576,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let storeLine = line(containing: "store", in: result)
        XCTAssertNotNil(storeLine, "running+storeSizeBytes must include a store: line")
        XCTAssertTrue(storeLine!.contains("1048576"), "store line must contain the byte count")
        XCTAssertTrue(storeLine!.contains("bytes"), "store line must include the 'bytes' unit label")
    }

    func test_running_allFieldsPresent() {
        // WHY: the full diagnostics output must include every key in a defined order
        // so a reader can reliably scan for url/ready/metrics/store in one pass.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: makeMetrics(),
            storeSizeBytes: 2048,
            readyzOK: true
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let keys = result.map { $0.prefix(while: { $0 != ":" }) }.map(String.init)
        XCTAssertTrue(keys.contains("status"), "must include status key")
        XCTAssertTrue(keys.contains("url"), "must include url key")
        XCTAssertTrue(keys.contains("ready"), "must include ready key")
        XCTAssertTrue(keys.contains("metrics"), "must include metrics key")
        XCTAssertTrue(keys.contains("store"), "must include store key")
    }

    // MARK: - Not-running state: no url / pid / metrics

    func test_notStarted_statusLineIsNotRunning() {
        // WHY: a consumer that checks `status:` must see a stable "not-running"
        // label so it does not mistake a freshly-stopped controller for "blocked"
        // or "failed".
        let input = TokenSaverDistillStatusInput(status: .notStarted)
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let statusLine = line(containing: "status", in: result)
        XCTAssertNotNil(statusLine)
        XCTAssertTrue(statusLine!.contains("not-running"),
            "notStarted must produce status: not-running")
    }

    func test_notStarted_noURLLine() {
        // WHY: a not-running controller has no live sidecar; emitting a stale URL
        // would mislead a caller into trying to connect to a dead socket.
        let input = TokenSaverDistillStatusInput(status: .notStarted)
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "url", in: result),
            "notStarted must NOT include a url: line")
    }

    func test_notStarted_noMetricsLine() {
        // WHY: metrics from a previous run must not appear when the service is
        // stopped; stale counters would mislead diagnostics.
        let input = TokenSaverDistillStatusInput(
            status: .notStarted,
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "metrics", in: result),
            "notStarted with no metrics input must NOT produce a metrics: line")
    }

    // MARK: - Blocked state

    func test_blocked_includesReasonLine() {
        // WHY: the blocked reason is the actionable signal -- "subscription required"
        // tells the user exactly what must change. Without the reason line the
        // operator sees "blocked" with no path forward.
        let input = TokenSaverDistillStatusInput(status: .blocked("subscription required"))
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let reasonLine = line(containing: "reason", in: result)
        XCTAssertNotNil(reasonLine, "blocked must include a reason: line")
        XCTAssertTrue(reasonLine!.contains("subscription required"),
            "reason line must carry the block reason verbatim")
    }

    func test_blocked_noURLLine() {
        // WHY: blocked means the sidecar was never started; emitting a URL would
        // be misleading.
        let input = TokenSaverDistillStatusInput(status: .blocked("model download required"))
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "url", in: result),
            "blocked state must NOT include a url: line")
    }

    // MARK: - Failed state

    func test_failed_includesReasonLine() {
        // WHY: the failure reason is required to distinguish a clean stop from a
        // crash or a launch error.
        let input = TokenSaverDistillStatusInput(
            status: .failed("RemoteCodeDistillService exited; restarting")
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let reasonLine = line(containing: "reason", in: result)
        XCTAssertNotNil(reasonLine, "failed must include a reason: line")
        XCTAssertTrue(reasonLine!.contains("RemoteCodeDistillService"),
            "reason line must carry the failure reason")
    }

    func test_failed_noURLLine() {
        // WHY: a failed sidecar is not reachable; showing a URL would mislead.
        let input = TokenSaverDistillStatusInput(
            status: .failed("launch failed")
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "url", in: result),
            "failed state must NOT include a url: line")
    }

    // MARK: - Optional fields omitted when nil

    func test_running_omitsReadyzLineWhenNotProbed() {
        // WHY: if the caller did not perform a readyz probe (nil), the formatter
        // must not emit a ready: line at all -- an absent line is less confusing
        // than a stale or fabricated value.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "ready", in: result),
            "nil readyzOK must produce no ready: line")
    }

    func test_running_omitsMetricsLineWhenNil() {
        // WHY: if the caller did not fetch metrics (nil), no metrics: line must
        // appear -- an absent line avoids showing all-zero counters that look like
        // a healthy but idle service when the fetch actually failed.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "metrics", in: result),
            "nil metrics must produce no metrics: line")
    }

    func test_anyState_omitsStoreLineWhenNil() {
        // WHY: if store size is unavailable (e.g. DB not accessible), no store:
        // line must appear -- stale or zero values would hide real growth problems.
        let input = TokenSaverDistillStatusInput(
            status: .running(makeReadyEvent()),
            metrics: nil,
            storeSizeBytes: nil,
            readyzOK: nil
        )
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "store", in: result),
            "nil storeSizeBytes must produce no store: line")
    }

    // MARK: - ASCII-only output

    func test_allLines_areASCII() {
        // WHY: distill --status output is piped, diffed, and embedded in structured
        // logs. Non-ASCII or smart-quote characters break plain-text tools that
        // assume the 0-127 range. Every character in every line must be ASCII.
        let inputs: [TokenSaverDistillStatusInput] = [
            TokenSaverDistillStatusInput(status: .notStarted),
            TokenSaverDistillStatusInput(status: .blocked("subscription required")),
            TokenSaverDistillStatusInput(status: .starting),
            TokenSaverDistillStatusInput(
                status: .running(makeReadyEvent()),
                metrics: makeMetrics(),
                storeSizeBytes: 512,
                readyzOK: true
            ),
            TokenSaverDistillStatusInput(status: .failed("crash")),
        ]
        for input in inputs {
            let result = TokenSaverDistillStatusFormatter.lines(for: input)
            for line in result {
                for scalar in line.unicodeScalars {
                    XCTAssertTrue(
                        scalar.value < 128,
                        "Non-ASCII character U+\(String(scalar.value, radix: 16)) found in line: \(line)"
                    )
                }
            }
        }
    }

    // MARK: - Starting state

    func test_starting_statusLineIsStarting() {
        // WHY: a starting state is transitional; the consumer must distinguish it
        // from running (where url/metrics exist) to avoid premature connection
        // attempts to a not-yet-bound port.
        let input = TokenSaverDistillStatusInput(status: .starting)
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        let statusLine = line(containing: "status", in: result)
        XCTAssertNotNil(statusLine)
        XCTAssertTrue(statusLine!.contains("starting"),
            "starting state must produce status: starting")
    }

    func test_starting_noURLLine() {
        // WHY: during startup the port has not been bound yet; emitting a URL would
        // be premature and cause connection failures.
        let input = TokenSaverDistillStatusInput(status: .starting)
        let result = TokenSaverDistillStatusFormatter.lines(for: input)
        XCTAssertNil(line(containing: "url", in: result),
            "starting state must NOT include a url: line")
    }
}
