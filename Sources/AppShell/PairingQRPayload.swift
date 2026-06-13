import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Pure helpers for building and rendering the QR-code pairing payload.
///
/// WHY: The 6-digit pairing code alone is not enough for zero-tap pairing —
/// the phone also needs the host IP, port, and server_id to open the TCP
/// connection. Encoding all four fields into a URL that the iOS scanner parses
/// eliminates manual IP entry, the dominant first-run failure mode.
///
/// Security note: the payload embeds only the short-lived pairing *code* (the
/// same short secret the user types today) plus connection coordinates. It does
/// NOT embed any long-lived token or credential; once the code is redeemed or
/// expires the QR is useless.
///
/// The seam is extracted as nonisolated statics so tests can call it from any
/// context without spinning MainActor and without touching any UI or I/O.
public enum PairingQRPayload {

    // MARK: - Payload string

    /// Builds the compact URL-encoded pairing payload.
    ///
    /// Format (contract pin for the iOS scanner agent):
    ///   `remotecode://pair?code=<CODE>&host=<HOST>&port=<PORT>&server_id=<SERVER_ID>`
    ///
    /// - Parameters:
    ///   - code:     The short-lived pairing code (6 alphanumeric chars).
    ///   - host:     The Mac's reachable LAN hostname or IP address.
    ///   - port:     The HTTP listener port (always 18217 in production).
    ///   - serverId: The stable server identity persisted in settings ("server_id").
    /// - Returns: The URL string to encode into the QR code.
    ///
    /// WHY pure/nonisolated: tests verify the exact string without any AppKit or
    /// CoreImage involvement; the iOS scanner contract is pinned to this exact
    /// output so any format change is immediately caught.
    public static nonisolated func buildPayload(
        code: String,
        host: String,
        port: UInt16,
        serverId: String
    ) -> String {
        // Percent-encode each component so unusual hostnames or IDs are safe.
        // URLComponents handles the encoding; we only need the query-item values.
        var comps = URLComponents()
        comps.scheme = "remotecode"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "server_id", value: serverId)
        ]
        // Fall back to a minimal hand-built string if URLComponents cannot
        // produce a URL (degenerate inputs). In practice this cannot happen
        // with the inputs we feed it, but the guard keeps the return non-optional.
        return comps.string ?? "remotecode://pair?code=\(code)&host=\(host)&port=\(port)&server_id=\(serverId)"
    }

    // MARK: - QR image

    /// Produces a CoreImage QR representation of `payload`.
    ///
    /// Uses `CIFilter.qrCodeGenerator()` (system-provided, no third-party
    /// dependency). Error-correction level Q (≈25 % recovery capacity) gives
    /// enough redundancy for a small display without making the QR too dense.
    ///
    /// - Parameter payload: The string returned by `buildPayload(code:host:port:serverId:)`.
    /// - Returns: A `CIImage` if CoreImage could generate the QR; nil otherwise
    ///            (degenerate empty payload — never happens in production).
    ///
    /// WHY CoreImage: zero external dependencies; available on macOS 10.15+
    /// (well within our macOS 14 deployment target).
    public static nonisolated func qrCIImage(payload: String) -> CIImage? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "Q"
        return filter.outputImage
    }
}
