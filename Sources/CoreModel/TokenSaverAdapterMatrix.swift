import Foundation

/// Adapter matrix + CLI/SDK merge + cross-user admission policy (task-08).
public enum TokenSaverAdapterMatrix {
    public static let schemaVersion = 1
    public static let taskID = "task-08"

    public enum ToolSurface: String, Sendable, Equatable {
        case claudeBuiltin = "claude_builtin"
        case claudeMCP = "claude_mcp"
        case codexMCP = "codex_mcp"
        case grokWrapper = "grok_wrapper"
        case unknown
    }

    public enum MergeMode: String, Sendable, Equatable {
        case cliSettingsOnly
        case sdkHooksOnly
        case mixedIllegal
    }

    public enum LaneState: String, Sendable, Equatable {
        case off
        case shadow
        case active
    }

    public struct ToolShapeBinding: Sendable, Equatable {
        public let surface: ToolSurface
        public let replacementField: String
        public let lane: LaneState

        public init(surface: ToolSurface, replacementField: String, lane: LaneState) {
            self.surface = surface
            self.replacementField = replacementField
            self.lane = surface == .unknown ? .off : lane
        }
    }

    public static func mergeMode(cliSettingsOverlay: Bool, sdkHooks: Bool) -> MergeMode? {
        switch (cliSettingsOverlay, sdkHooks) {
        case (true, false): return .cliSettingsOnly
        case (false, true): return .sdkHooksOnly
        case (true, true): return .mixedIllegal
        default: return nil // no adapter path configured
        }
    }

    public static func laneAfterMerge(_ mode: MergeMode?) -> LaneState {
        guard let mode else { return .off }
        return mode == .mixedIllegal ? .off : .shadow
    }

    /// Settings files must remain byte-untouched by RemoteCode overlay.
    public static func settingsUntouched(before: Data, after: Data) -> Bool {
        before == after
    }

    public static func replacementField(for surface: ToolSurface, proposed: String) -> String? {
        switch surface {
        case .claudeBuiltin:
            return proposed == "content" ? proposed : nil
        case .claudeMCP, .codexMCP:
            return proposed == "mcp_content" ? proposed : nil
        case .grokWrapper:
            return proposed == "wrapper_stdout" ? proposed : nil
        case .unknown:
            return nil
        }
    }

    public enum CrossUserTurn: String, Sendable, CaseIterable {
        case initial, followUp, autoContinuation, recovery, finalResponse
    }

    public static func tokenSaverCallbacksAllowed(isSameUser: Bool, turn: CrossUserTurn) -> Bool {
        isSameUser
    }

    public static func codexHookActive(hasProvenMCPContract: Bool) -> Bool {
        hasProvenMCPContract
    }

    public struct CollisionReceipt: Sendable, Equatable {
        public let reason: String
        public let replacementPerformed: Bool
        public init(reason: String) {
            self.reason = reason
            self.replacementPerformed = false
        }
    }

    public static func collision(reason: String) -> CollisionReceipt {
        CollisionReceipt(reason: reason)
    }
}
