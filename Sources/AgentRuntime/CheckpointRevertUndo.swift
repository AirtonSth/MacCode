import Foundation
import CoreModel

/// UX-MAC-CHECKPOINT-REVERT-UNDO: an additive, transient snapshot captured the
/// instant BEFORE `revertThreadToCheckpoint` destroys forward state, so the
/// revert can be taken back within a short toast window without corrupting the
/// user's workspace.
///
/// A revert is destructive in three places: (a) it overwrites the git WORKING
/// TREE, (b) it deletes the newer checkpoint rows, and (c) it deletes the
/// newer assistant-message rows. This struct preserves all three as forward
/// state so undo can restore them exactly. The capture is pure read + store;
/// the revert's own behavior is unchanged.
public struct CheckpointRevertUndo: Sendable {
    /// One workspace file as it existed on disk just before the revert
    /// overwrote it. `contentsBase64 == nil` means the file was ABSENT pre-revert
    /// (the revert created it, or it never existed), so undo must remove it.
    public struct CapturedFile: Sendable, Equatable {
        public let path: String
        public let contentsBase64: String?

        public init(path: String, contentsBase64: String?) {
            self.path = path
            self.contentsBase64 = contentsBase64
        }
    }

    public let threadId: AgentThreadID
    public let checkpointTurnCount: Int
    public let capturedAt: Date
    /// Pre-revert on-disk bytes for every path the revert would touch.
    public let forwardFiles: [CapturedFile]
    /// The `newer` checkpoint rows the revert deleted, captured whole.
    public let deletedCheckpoints: [AgentTurnCheckpointSummary]
    /// The assistant-message rows the revert deleted, captured whole, BEFORE delete.
    public let deletedMessages: [AgentMessage]

    public init(
        threadId: AgentThreadID,
        checkpointTurnCount: Int,
        capturedAt: Date,
        forwardFiles: [CapturedFile],
        deletedCheckpoints: [AgentTurnCheckpointSummary],
        deletedMessages: [AgentMessage]
    ) {
        self.threadId = threadId
        self.checkpointTurnCount = checkpointTurnCount
        self.capturedAt = capturedAt
        self.forwardFiles = forwardFiles
        self.deletedCheckpoints = deletedCheckpoints
        self.deletedMessages = deletedMessages
    }

    /// Pure: the exact set of workspace paths a revert touches. Mirrors
    /// `restoreWorkspace`'s affected set: the target snapshot paths UNION every
    /// newer snapshot path. Capturing exactly this set means undo writes back
    /// precisely the files the revert could have changed and nothing else.
    public static func affectedPaths(
        target: AgentTurnCheckpointSummary,
        newer: [AgentTurnCheckpointSummary]
    ) -> Set<String> {
        let targetPaths = Set(target.fileSnapshots.map(\.path))
        let newerPaths = Set(newer.flatMap { $0.fileSnapshots.map(\.path) })
        return targetPaths.union(newerPaths)
    }

    /// Pure: is an undo still allowed `window` seconds after capture? A revert
    /// must be reversible, but only briefly — after the window the snapshot is
    /// dropped and the revert is final. Mirrors ThreadDeletionUndo's seam.
    public static func isWithinUndoWindow(
        capturedAt: Date,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(capturedAt) < window
    }
}
