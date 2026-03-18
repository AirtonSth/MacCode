/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import { toLiveActivitySharedSnapshot } from "./live-activity-shared-snapshot";

describe("live activity shared snapshot", () => {
	test("serializes the global session payload used by widget and watch", () => {
		const snapshot = toLiveActivitySharedSnapshot({
			counts: {
				activeCount: 2,
				finalizingCount: 1,
				runningCount: 1,
			},
			deepLink: "remotecode-mobile://active-threads",
			nowMs: 50_000,
			state: {
				chatId: "active-threads",
				chatTitle: "Active Threads",
				elapsedSecondsSnapshot: null,
				phase: "running",
				preview: "RemoteCode is working on 2 active threads.",
				startedAtMs: 10_000,
				statusLine: "2 threads active",
			},
		});

		expect(snapshot).toEqual({
			activeThreadCount: 2,
			chatId: "active-threads",
			chatTitle: "Active Threads",
			deepLink: "remotecode-mobile://active-threads",
			elapsedSecondsSnapshot: null,
			finalizingThreadCount: 1,
			phase: "running",
			preview: "RemoteCode is working on 2 active threads.",
			runningThreadCount: 1,
			schemaVersion: 1,
			startedAtMs: 10_000,
			statusLine: "2 threads active",
			updatedAtMs: 50_000,
		});
	});

	test("normalizes missing elapsed snapshots for active sessions", () => {
		const snapshot = toLiveActivitySharedSnapshot({
			counts: {
				activeCount: 0,
				finalizingCount: 0,
				runningCount: 0,
			},
			deepLink: "remotecode-mobile://active-threads",
			nowMs: 1,
			state: {
				chatId: "active-threads",
				chatTitle: "Active Threads",
				phase: "completed",
				preview: "No active threads right now.",
				startedAtMs: 100,
				statusLine: "All threads completed",
			},
		});

		expect(snapshot.elapsedSecondsSnapshot).toBeNull();
	});
});
