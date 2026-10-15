import Foundation

/// Provider failures that are worth resuming automatically: the network or the
/// response stream dropped mid-turn. Auth, rate-limit, payment and request
/// errors are not transient in this sense and still stop the run.
public enum TransientNetworkRetry {
    /// Marker the Distill/Grok ACP clients put on network-class failures.
    public static let marker = "[retryable:network]"

    public static let prompt = """
    The previous turn was interrupted by a network error before it finished. Continue the original task from where you stopped; do not repeat work that already completed.
    """

    public static func isTransientNetworkFailure(_ errorMessage: String?) -> Bool {
        guard let errorMessage else { return false }
        return errorMessage.contains(marker)
    }
}
