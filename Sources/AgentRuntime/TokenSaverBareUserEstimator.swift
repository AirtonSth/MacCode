import Foundation

/// Counterfactual savings vs a **bare agent user** who does not use RemoteCode:
/// no Token Saver pipes/dialect, no Graphify query-first, no model auto orchestration.
///
/// Product definition: the headline Token Saver number is this total — measured
/// tool-output ledger plus attributed estimates for platform techniques. Figures
/// are local diagnostic estimates, not billed provider savings.
public struct TokenSaverBareUserBreakdown: Sendable, Equatable {
    /// Exact ledger compressions (tool-output / SR1 rows, etc.).
    public let measuredToolOutput: Int
    /// Distill language / sparse dialect vs a verbose default agent.
    public let estimatedDialect: Int
    /// Graphify query-first vs broad Read/grep of the tree.
    public let estimatedGraphify: Int
    /// Model auto / orchestration vs always-max-model, more-retry bare use
    /// (token-equivalent value, not a billed unit conversion).
    public let estimatedOrchestration: Int

    public init(
        measuredToolOutput: Int,
        estimatedDialect: Int,
        estimatedGraphify: Int,
        estimatedOrchestration: Int
    ) {
        self.measuredToolOutput = max(0, measuredToolOutput)
        self.estimatedDialect = max(0, estimatedDialect)
        self.estimatedGraphify = max(0, estimatedGraphify)
        self.estimatedOrchestration = max(0, estimatedOrchestration)
    }

    /// Primary Token Saver display total: all RemoteCode economies vs bare agent.
    public var totalEstimatedVsBareUser: Int {
        measuredToolOutput + estimatedDialect + estimatedGraphify + estimatedOrchestration
    }

    public var attributedOnly: Int {
        estimatedDialect + estimatedGraphify + estimatedOrchestration
    }

    public static let empty = TokenSaverBareUserBreakdown(
        measuredToolOutput: 0,
        estimatedDialect: 0,
        estimatedGraphify: 0,
        estimatedOrchestration: 0
    )
}

/// Pure estimator. Factors are product policy v1 and intentionally conservative
/// enough to sell the platform stack without claiming measured provider billing.
public enum TokenSaverBareUserEstimator {
    /// Bare-agent answers are ~3× more verbose than distill dialect (same factor
    /// family as `TokenSaverSR1SavingsEstimator.defaultAgentVerbosityFactor`).
    public static let dialectVerbosityMultiplier: Double = 3

    /// Share of provider tokens treated as model **output** (coding agents are
    /// input-heavy; dialect only attacks output).
    public static let outputShareOfUsage: Double = 0.22

    /// Share treated as **input** (context, tools, files).
    public static let inputShareOfUsage: Double = 0.78

    /// When Graphify runtime is active, fraction of input tokens a bare user
    /// would still burn exploring the tree (Reads/greps) that query-first avoids.
    public static let graphifyInputAvoidanceRate: Double = 0.18

    /// When RemoteCode orchestration/auto is in play, token-equivalent of fewer
    /// wrong-model retries / over-long max-model turns vs a bare always-max user.
    public static let orchestrationAvoidanceRate: Double = 0.08

    /// Build the bare-user counterfactual for a usage window.
    ///
    /// - Parameters:
    ///   - measuredToolOutputSaved: Ledger sum for the window (command-output, etc.).
    ///   - actualProviderTokens: Real provider usage in the same window.
    ///   - tokenSaverEnabled: Dialect + pipe stack active.
    ///   - graphifyActive: Token Saver ∧ Graphify preference (runtime gate).
    ///   - orchestrationActive: Model auto / RemoteCode routing available (true
    ///     when Token Saver product path is on for agent-app turns).
    public static func estimate(
        measuredToolOutputSaved: Int,
        actualProviderTokens: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool,
        orchestrationActive: Bool
    ) -> TokenSaverBareUserBreakdown {
        guard tokenSaverEnabled else {
            return TokenSaverBareUserBreakdown(
                measuredToolOutput: max(0, measuredToolOutputSaved),
                estimatedDialect: 0,
                estimatedGraphify: 0,
                estimatedOrchestration: 0
            )
        }

        let used = max(0, actualProviderTokens)
        let measured = max(0, measuredToolOutputSaved)

        // Bare output ≈ dialectVerbosityMultiplier × actual output.
        // Saved ≈ actual_output × (multiplier − 1).
        let outputTokens = Double(used) * clamped(outputShareOfUsage)
        let dialectFactor = max(1.0, dialectVerbosityMultiplier)
        let dialect = Int((outputTokens * (dialectFactor - 1.0)).rounded())

        let inputTokens = Double(used) * clamped(inputShareOfUsage)
        let graphify: Int
        if graphifyActive {
            graphify = Int((inputTokens * clamped(graphifyInputAvoidanceRate)).rounded())
        } else {
            graphify = 0
        }

        let orchestration: Int
        if orchestrationActive {
            orchestration = Int((Double(used) * clamped(orchestrationAvoidanceRate)).rounded())
        } else {
            orchestration = 0
        }

        return TokenSaverBareUserBreakdown(
            measuredToolOutput: measured,
            estimatedDialect: max(0, dialect),
            estimatedGraphify: max(0, graphify),
            estimatedOrchestration: max(0, orchestration)
        )
    }

    private static func clamped(_ rate: Double) -> Double {
        min(max(rate, 0), 0.95)
    }
}
