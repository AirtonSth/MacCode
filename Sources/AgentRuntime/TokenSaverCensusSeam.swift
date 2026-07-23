import CoreModel
import Foundation

/// AgentRuntime census observation seam (task-03).
/// Lives here so Claude/Codex/Grok adapters can record opportunity metrics without
/// importing DistillCore/MLX. Types come from CoreModel only.
///
/// **Invariant:** every public method that accepts provider-visible bytes returns
/// those same bytes unchanged (fail-open, shadow-only).
public enum TokenSaverCensusSeam {
    /// Process-wide store. Defaults to an in-memory store so production always
    /// records shadow observations; tests may replace or clear it.
    public static var sharedStore: TokenSaverCensusStore? {
        get { lock.lock(); defer { lock.unlock() }; return _store }
        set { lock.lock(); defer { lock.unlock() }; _store = newValue }
    }

    private static let lock = NSLock()
    private static var _store: TokenSaverCensusStore? = TokenSaverCensusStore()

    /// Observe a provider-visible line/envelope without mutating it.
    @discardableResult
    public static func observeProviderVisiblePayload(
        _ payload: Data,
        binding: TokenSaverBindingID,
        control: TokenSaverCensusControl = .noChange,
        parserMatched: Bool = true,
        streamKind: TokenSaverCensusStreamKind = .streaming,
        toolKind: TokenSaverCensusToolKind = .unknown,
        isSameUser: Bool
    ) -> Data {
        guard let store = sharedStore else {
            return TokenSaverCensusStore.providerVisiblePayloadUnchanged(payload)
        }
        let observation = TokenSaverCensusObservation(
            binding: binding,
            control: control,
            eligibleTokens: Int64(payload.count),
            parserMatched: parserMatched,
            streamKind: streamKind,
            toolKind: toolKind,
            isSameUser: isSameUser
        )
        return store.observeWithoutMutatingProviderPayload(
            observation: observation,
            providerVisiblePayload: payload
        )
    }

    /// Convenience builder for adapter call sites with frozen dimension defaults.
    public static func defaultBinding(
        trigger: String,
        provider: String,
        providerAdapterVersion: String,
        toolShape: String
    ) -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: trigger,
            provider: provider,
            providerAdapterVersion: providerAdapterVersion,
            toolShape: toolShape,
            model: "unknown",
            cachePolicy: "default",
            triggerPolicyClassifierRecipeIndexVersion: "unset",
            billingCohort: "same-user-agent",
            hardwareTier: "unknown",
            consentVersion: "exact-v1"
        )
    }
}
