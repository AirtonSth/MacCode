export type ThreadLiveActivityPhase =
	| "running"
	| "finalizing"
	| "background"
	| "completed"
	| "failed"
	| "error";

export interface ThreadLiveActivityProps {
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	phase: ThreadLiveActivityPhase;
	preview: string;
	statusLine: string;
}
