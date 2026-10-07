import Foundation

/// Provider failure details shared by the Distill and Grok ACP clients.
///
/// WHY: both peers answer a failed `session/prompt` with the generic JSON-RPC
/// `-32603 Internal error` and carry the provider's real failure in
/// `error.data` (`{message, http_status}`). Reading only `error.message` hid
/// every provider 400/401/404/429 behind "Internal error", and HTTP 401/429
/// never reached the auth / rate-limit taxonomy because the JSON-RPC code is
/// always -32603.
enum ACPRPCErrorPayload {
    struct Parsed: Equatable, Sendable {
        let code: Int?
        let message: String
        let detail: String?
        let httpStatus: Int?
    }

    static func parse(_ error: [String: Any], defaultMessage: String) -> Parsed {
        let message = (error["message"] as? String) ?? defaultMessage
        var detail: String?
        var httpStatus: Int?
        if let text = error["data"] as? String {
            detail = text
        } else if let data = error["data"] as? [String: Any] {
            detail = (data["message"] as? String) ?? (data["detail"] as? String) ?? (data["error"] as? String)
            httpStatus = intValue(data["http_status"]) ?? intValue(data["httpStatus"]) ?? intValue(data["status"])
        }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(
            code: intValue(error["code"]),
            message: message,
            detail: trimmedDetail?.isEmpty == false ? trimmedDetail : nil,
            httpStatus: httpStatus
        )
    }

    /// True for JSON-RPC messages that say nothing about the provider failure.
    static func isGenericMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || ["internal error", "internal_error", "internal server error", "server error",
                "unknown error", "error"].contains(normalized)
            || (normalized.hasPrefix("unknown ") && normalized.hasSuffix(" acp error"))
    }

    /// `data.message` replaces a generic RPC message; otherwise both are shown.
    static func describe(message: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        if isGenericMessage(message) { return detail }
        if message.contains(detail) { return message }
        return "\(message): \(detail)"
    }

    /// The provider failure carried by `x.ai/session/prompt_complete` (or the
    /// legacy `_x.ai/…` spelling) for `sessionId`, when that prompt stopped with
    /// `stopReason: "error"`. Nil for any other method, session, or outcome.
    static func promptCompleteFailure(method: String, payload: Any?, sessionId: String) -> String? {
        guard method == "x.ai/session/prompt_complete" || method == "_x.ai/session/prompt_complete",
              let payload = payload as? [String: Any],
              payload["sessionId"] as? String == sessionId,
              (payload["stopReason"] as? String)?.lowercased() == "error",
              let result = (payload["agentResult"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            return nil
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
