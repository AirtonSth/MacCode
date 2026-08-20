import Foundation

public struct LibrarianProbeRecord: Sendable, Equatable, Codable {
    public let id: String
    public let safety: String
    public let runtime: String
    public let usesLLM: Bool
    public let status: String
    public let mark: String
    public let savedTokens: Int
    public let delivered: Bool
    public let paidText: String
    public let envelopeJSON: String
    public let latencyMs: Int
    public let model: String
    public let generateCalled: Bool
}

public enum LibrarianProbe {
    public static func fixture(for id: String, store: LibrarianHandleStore) -> LibrarianRequest {
        let fn = LibrarianCatalog.function(id: id)
        let sample = sampleText(for: id)
        let handle = store.put(sample, handle: "rcv1.probe.\(id)")
        return LibrarianRequest(
            id: id,
            input: sample,
            question: "what failed?",
            handle: handle,
            handles: [handle],
            provider: "grok",
            threadID: "probe",
            admitted: true,
            retrieveAvailable: true,
            graphifyEnabled: fn?.id == "graphify_query" || fn?.id == "graph_ask",
            command: id == "distill_exact_rg" ? "rg foo" : nil,
            startLine: 1,
            endLine: 4,
            pattern: "ERROR",
            claim: "payment failed"
        )
    }

    public static func run(
        id: String,
        dispatcher: LibrarianDispatcher,
        model: String = ""
    ) async -> LibrarianProbeRecord {
        let instrumented = dispatcher.generate as? LibrarianInstrumentedGenerate
        let before = instrumented?.callCount ?? 0
        let request = fixture(for: id, store: dispatcher.store)
        let result = await dispatcher.dispatch(request)
        let fn = LibrarianCatalog.function(id: id)
        let called = (instrumented?.callCount ?? 0) > before
        let latency = called ? (instrumented?.lastLatencyMs ?? 0) : 0
        return LibrarianProbeRecord(
            id: id,
            safety: fn?.safety.rawValue ?? "unknown",
            runtime: fn?.runtime.rawValue ?? "none",
            usesLLM: fn?.usesLLM ?? false,
            status: result.status.rawValue,
            mark: mark(for: fn, result: result),
            savedTokens: result.analytics.savedTokens,
            delivered: result.analytics.delivered,
            paidText: result.text,
            envelopeJSON: result.envelope?.jsonString() ?? "",
            latencyMs: latency,
            model: model,
            generateCalled: called
        )
    }

    /// Generate IDs are implementado only when the wired generate path returned ok.
    /// Host-tool misses that the handler actually reports as unavailable count as proven.
    public static func mark(for fn: LibrarianFunction?, result: LibrarianResult) -> String {
        let safety = fn?.safety ?? .forbidden
        if safety == .forbidden {
            return (result.status == .refused || result.status == .unavailable) ? "bloqueado" : "pendente"
        }
        if fn?.usesLLM == true, fn?.mcp != "none" {
            let generated = result.analytics.record?.routeStage == .llmMLX
            return (result.status == .ok && generated) ? "implementado" : "pendente"
        }
        if result.status == .ok || result.status == .unavailable {
            return "implementado"
        }
        return "pendente"
    }

    public static func runAll(
        dispatcher: LibrarianDispatcher,
        model: String = ""
    ) async -> [LibrarianProbeRecord] {
        if let generate = dispatcher.generate, !(generate is LibrarianInstrumentedGenerate) {
            dispatcher.generate = LibrarianInstrumentedGenerate(generate)
        }
        var rows: [LibrarianProbeRecord] = []
        for id in LibrarianCatalog.ids {
            rows.append(await run(id: id, dispatcher: dispatcher, model: model))
        }
        return rows
    }

    public static func summary(_ rows: [LibrarianProbeRecord]) -> String {
        var byStatus: [String: Int] = [:]
        var byRuntime: [String: Int] = [:]
        var generate = 0
        var nonGenerate = 0
        for row in rows {
            byStatus[row.status, default: 0] += 1
            byRuntime[row.runtime, default: 0] += 1
            if row.generateCalled { generate += 1 } else { nonGenerate += 1 }
        }
        let statusLine = byStatus.keys.sorted().map { "\($0)=\(byStatus[$0] ?? 0)" }.joined(separator: " ")
        let runtimeLine = byRuntime.keys.sorted().map { "\($0)=\(byRuntime[$0] ?? 0)" }.joined(separator: " ")
        return """
        n=\(rows.count) unique=\(Set(rows.map(\.id)).count)
        status \(statusLine)
        runtime \(runtimeLine)
        generate_called=\(generate) generate_not_called=\(nonGenerate)
        """
    }

    private static func sampleText(for id: String) -> String {
        switch id {
        case "json_crusher", "toon_codec", "json_shape", "linear_issue_digest":
            return #"{"title":"Fix billing","labels":["bug"],"items":[{"id":1,"name":"a"},{"id":2,"name":"a"},{"id":3,"name":"a"},{"id":4,"name":"a"},{"id":5,"name":"a"}]}"#
        case "log_crusher":
            return Array(repeating: "INFO retry loop", count: 8).joined(separator: "\n")
        case "stack_crusher":
            return "Traceback (most recent call last):\n  File \"a.py\", line 1, in <module>\n  File \"a.py\", line 1, in <module>\n  File \"a.py\", line 1, in <module>\n  File \"a.py\", line 1, in <module>\n  File \"a.py\", line 1, in <module>\nError: boom\n"
        case "test_crusher", "test_verdict", "test_baseline_diff":
            return "test_billing.py::test_pay FAILED\ntest_billing.py::test_pay FAILED\n===== 1 failed, 3 passed =====\n"
        case "diff_crusher":
            return "diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1,3 +1,4 @@\n line\n+added\n"
        case "html_crusher":
            return "<html><script>" + String(repeating: "x", count: 200) + "</script><p>ok</p></html>"
        case "source_skeleton":
            return "func foo() {\n    let x = 1\n    let y = 2\n    let z = 3\n    return x + y + z\n}\n"
        case "lockfile_crusher":
            return (0..<60).map { "    \"pkg\($0)\": { \"version\": \"1.0.\($0)\" }" }.joined(separator: "\n")
        case "progress_bar_crusher":
            return "downloading 1%\rdownloading 50%\rdownloading 100%\ndone\n"
        case "ansi_escape_strip":
            return "\u{001B}[31mERROR\u{001B}[0m payment failed\n"
        case "secret_redact_view", "secret_presence_flag", "extract_secret_values":
            return "api_key=sk_live_abcdefghijklmnopqrstuvwxyz\nOK"
        default:
            return """
            ERROR payment failed at Sources/Billing.swift:12
            FAIL test_pay
            warning: unused
            \(String(repeating: "debug noise line\n", count: 30))
            """
        }
    }
}
