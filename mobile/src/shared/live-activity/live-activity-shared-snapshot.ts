import type { ThreadLiveActivityPhase } from "./thread-live-activity.types";

export interface LiveActivitySharedSnapshotCounts {
	activeCount: number;
	finalizingCount: number;
	runningCount: number;
}

export interface LiveActivitySharedSnapshotState {
	chatId: string;
	chatTitle: string;
	elapsedSecondsSnapshot?: number | null;
	phase: ThreadLiveActivityPhase;
	preview: string;
	startedAtMs: number;
	statusLine: string;
}

export interface LiveActivitySharedSnapshot {
	activeThreadCount: number;
	chatId: string;
	chatTitle: string;
	deepLink: string;
	elapsedSecondsSnapshot: number | null;
	finalizingThreadCount: number;
	phase: ThreadLiveActivityPhase;
	preview: string;
	runningThreadCount: number;
	schemaVersion: 1;
	startedAtMs: number;
	statusLine: string;
	updatedAtMs: number;
}

interface ToLiveActivitySharedSnapshotInput {
	counts: LiveActivitySharedSnapshotCounts;
	deepLink: string;
	nowMs?: number;
	state: LiveActivitySharedSnapshotState;
}

export const toLiveActivitySharedSnapshot = (
	input: ToLiveActivitySharedSnapshotInput,
): LiveActivitySharedSnapshot => ({
	activeThreadCount: Math.max(0, Math.floor(input.counts.activeCount)),
	chatId: input.state.chatId,
	chatTitle: input.state.chatTitle,
	deepLink: input.deepLink,
	elapsedSecondsSnapshot:
		typeof input.state.elapsedSecondsSnapshot === "number" && input.state.elapsedSecondsSnapshot >= 0
			? Math.floor(input.state.elapsedSecondsSnapshot)
			: null,
	finalizingThreadCount: Math.max(0, Math.floor(input.counts.finalizingCount)),
	phase: input.state.phase,
	preview: input.state.preview,
	runningThreadCount: Math.max(0, Math.floor(input.counts.runningCount)),
	schemaVersion: 1,
	startedAtMs: Math.floor(input.state.startedAtMs),
	statusLine: input.state.statusLine,
	updatedAtMs: Math.floor(input.nowMs ?? Date.now()),
});
