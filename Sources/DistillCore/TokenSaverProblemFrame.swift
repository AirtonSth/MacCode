import Foundation

/// Fase -2 product frame for the Token Saver agent-app series (task-01).
/// Pure gate data: incomplete owners or missing no-go freeze block later promotion paths.
/// Does not mutate provider payloads or enable compression lanes.
public enum TokenSaverProblemFrame {
    public static let schemaVersion = 1
    public static let documentPath = "docs/token-saver-problem-frame.md"
    public static let taskID = "task-01"

    /// Relative reduction MDE for API-cost cohort (paired experiment; task-05 binds stats).
    public static let apiCostMinimumUsefulImprovement: Double = 0.05

    /// Absolute eligible observations required when percentage floor is not used alone.
    public static let minimumIndependentObservations = 30

    /// Share of provider+shape cohort denominator required as absolute volume floor.
    public static let minimumEligibleTokenShareOfDenominator: Double = 0.01

    public enum OwnerRole: String, CaseIterable, Sendable {
        case decision
        case runtime
        case dataAccounting
        case securityPrivacy
        case releaseOncall

        public var displayName: String {
            switch self {
            case .decision: return "Decision owner"
            case .runtime: return "Runtime owner"
            case .dataAccounting: return "Data/accounting owner"
            case .securityPrivacy: return "Security/privacy approver"
            case .releaseOncall: return "Release/on-call/rollback owner"
            }
        }
    }

    public struct OwnerAssignment: Sendable, Equatable {
        public let role: OwnerRole
        public let name: String
        public let contact: String

        public init(role: OwnerRole, name: String, contact: String) {
            self.role = role
            self.name = name
            self.contact = contact
        }

        public var isComplete: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Sealed owners for this series. Empty name/contact fails `ownersReceiptIsComplete`.
    public static let sealedOwners: [OwnerAssignment] = [
        .init(role: .decision, name: "RemoteCode Product (Token Saver)", contact: "product@remotecode.local"),
        .init(role: .runtime, name: "Agent Runtime / Distill", contact: "runtime@remotecode.local"),
        .init(role: .dataAccounting, name: "Token Saver Ledger", contact: "accounting@remotecode.local"),
        .init(role: .securityPrivacy, name: "Security & Privacy", contact: "security@remotecode.local"),
        .init(role: .releaseOncall, name: "Release Engineering", contact: "release-oncall@remotecode.local"),
    ]

    /// Immutable no-go surface for T-012 series (plan §1).
    public static let noGoItems: [String] = [
        "cross-user hook or sidecar credential for Token Saver",
        "truncating caps for Claude/Codex without recovery handles",
        "provider HTTP proxy",
        "Python, Rust, external Headroom/Tura runtime, or new ONNX for Token Saver",
        "persistent config under ~/.claude or ~/.codex",
        "semantic response cache for mutable answers",
        "automatic AGENTS/CLAUDE learned instruction writes",
        "automatic lowering of user-selected reasoning/effort",
        "SessionLearn free-text auto-learn / auto-instructions without typed consent gate",
        "billing or headline tokens-saved from character counts alone",
    ]

    /// Keywords that must appear in the no-go freeze (AC-03).
    public static let requiredNoGoKeywords: [String] = [
        "cross-user",
        "truncat",
        "proxy",
        "Python",
        "Rust",
        "ONNX",
        "~/.claude",
        "~/.codex",
        "semantic response cache",
        "auto-learn",
        "effort",
        "character count",
    ]

    public enum StopReason: String, Sendable, Equatable {
        case incompleteOwners
        case cohortBelowFloor
        case experimentInconclusive
        case nonInferiorityFailed
        case securityOrRecoveryBreach
        case coverageIncomplete
    }

    public enum AdvanceDecision: Sendable, Equatable {
        case mayContinueMeasurement
        case stopNoChangeOrWrappersOnly(StopReason)
    }

    public static var ownersReceiptIsComplete: Bool {
        validateOwners(sealedOwners).isEmpty
    }

    /// Returns missing role raw values; empty means complete.
    public static func validateOwners(_ owners: [OwnerAssignment]) -> [OwnerRole] {
        var present: [OwnerRole: OwnerAssignment] = [:]
        for owner in owners {
            present[owner.role] = owner
        }
        return OwnerRole.allCases.filter { role in
            guard let assignment = present[role] else { return true }
            return !assignment.isComplete
        }
    }

    public static func noGoFreezeContainsRequiredKeywords(
        items: [String] = noGoItems
    ) -> [String] {
        let blob = items.joined(separator: "\n").lowercased()
        return requiredNoGoKeywords.filter { keyword in
            !blob.contains(keyword.lowercased())
        }
    }

    /// Incidence floor (stricter freeze): absolute volume required, and **both**
    /// observation count and token-share thresholds must pass.
    /// Top-ranked shapes with zero absolute eligible tokens never pass.
    public static func cohortMeetsFloor(
        eligibleObservations: Int,
        eligibleTokens: Int64,
        denominatorTokens: Int64
    ) -> Bool {
        guard eligibleTokens > 0, denominatorTokens > 0 else { return false }
        guard eligibleObservations >= minimumIndependentObservations else { return false }
        let share = Double(eligibleTokens) / Double(denominatorTokens)
        return share + 1e-15 >= minimumEligibleTokenShareOfDenominator
    }

    /// Gate used by later tasks: incomplete owners or below-floor cohort ⇒ STOP.
    public static func advanceDecision(
        owners: [OwnerAssignment] = sealedOwners,
        eligibleObservations: Int,
        eligibleTokens: Int64,
        denominatorTokens: Int64,
        experimentInconclusive: Bool = false
    ) -> AdvanceDecision {
        if !validateOwners(owners).isEmpty {
            return .stopNoChangeOrWrappersOnly(.incompleteOwners)
        }
        if experimentInconclusive {
            return .stopNoChangeOrWrappersOnly(.experimentInconclusive)
        }
        if !cohortMeetsFloor(
            eligibleObservations: eligibleObservations,
            eligibleTokens: eligibleTokens,
            denominatorTokens: denominatorTokens
        ) {
            return .stopNoChangeOrWrappersOnly(.cohortBelowFloor)
        }
        return .mayContinueMeasurement
    }

    /// Primary outcome labels (content-free; for docs/tests alignment).
    public static let primaryOutcomeSummary =
        "Avoidable provider input tokens (and paired provider rounds when trajectory experiment exists) on same-user agent-app turns"
}
