import XCTest
import CoreModel

/// Quarantine for legacy Claude adapter process tests that no longer pass.
/// Claude is not a selectable provider since 6d91b691f (Distill only; legacy
/// Claude threads are read-only), so neither `ClaudeStreamingCLIAdapter` nor
/// `ClaudeAgentSDKBridgeAdapter` starts a user turn. These tests run again
/// automatically if Claude becomes selectable, and must pass before it ships.
func skipUnlessLegacyClaudeIsSelectable() throws {
    try XCTSkipUnless(
        AgentProvider.claude.isSelectable,
        "Legacy Claude adapter quarantined: Claude is not a selectable provider (Distill only)."
    )
}
