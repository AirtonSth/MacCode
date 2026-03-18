import type { ThreadLiveActivityPhase } from "./thread-live-activity.types";

export const resolveThreadLiveActivityCompactGlyph = (input: {
	phase: ThreadLiveActivityPhase;
	statusLine: string | undefined;
}): string => {
	const normalizedStatusLine = input.statusLine?.trim() ?? "";
	const numericMatch = /^(?<count>\d+)\s+thread/iu.exec(normalizedStatusLine)
		?? /^finalizing\s+(?<count>\d+)\s+thread/iu.exec(normalizedStatusLine);
	const countGlyph = numericMatch?.groups?.count ?? null;

	if (input.phase === "running" || input.phase === "finalizing") {
		return countGlyph ?? "RC";
	}

	switch (input.phase) {
		case "background": {
			return "B";
		}
		case "completed": {
			return "C";
		}
		case "error": {
			return "E";
		}
		case "failed": {
			return "F";
		}
		default: {
			return "R";
		}
	}
};
