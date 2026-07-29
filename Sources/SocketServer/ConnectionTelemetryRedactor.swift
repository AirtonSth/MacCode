import Foundation

public enum ConnectionTelemetryRedactor {
    public static func makeCorrelationId() -> String {
        UUID().uuidString.lowercased()
    }
}
