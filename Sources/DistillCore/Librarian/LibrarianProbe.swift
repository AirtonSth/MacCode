import Foundation

public struct LibrarianProbeRecord: Sendable, Equatable, Codable {
    public let id: String
    public let safety: String
    public let status: String
    public let mark: String
    public let savedTokens: Int
    public let delivered: Bool
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

    public static func run(id: String, dispatcher: LibrarianDispatcher) async -> LibrarianProbeRecord {
        let request = fixture(for: id, store: dispatcher.store)
        let result = await dispatcher.dispatch(request)
        let safety = LibrarianCatalog.function(id: id)?.safety.rawValue ?? "unknown"
        let mark: String
        if safety == "forbidden" {
            mark = (result.status == .refused || result.status == .unavailable) ? "bloqueado" : "pendente"
        } else if result.status == .ok || result.status == .lowConfidence || result.status == .unavailable {
            mark = "implementado"
        } else if result.status == .refused, safety == "forbidden" {
            mark = "bloqueado"
        } else {
            mark = "pendente"
        }
        return LibrarianProbeRecord(
            id: id,
            safety: safety,
            status: result.status.rawValue,
            mark: mark,
            savedTokens: result.analytics.savedTokens,
            delivered: result.analytics.delivered
        )
    }

    public static func runAll(dispatcher: LibrarianDispatcher) async -> [LibrarianProbeRecord] {
        var rows: [LibrarianProbeRecord] = []
        for id in LibrarianCatalog.ids {
            rows.append(await run(id: id, dispatcher: dispatcher))
        }
        return rows
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
