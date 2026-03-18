import { describe, expect, it } from "bun:test";

import { buildLiveActivityApsPayload } from "./live-activity-push.service";

const PUSH_STALE_WINDOW_SECONDS = 180;
const PUSH_END_DISMISS_SECONDS = 30;

const defaultContentState = {
	chatId: "active-threads",
	chatTitle: "Active Threads",
	elapsedSeconds: 10,
	phase: "running" as const,
	preview: "RemoteCode is working on 1 active thread.",
	statusLine: "1 thread active",
};

describe("buildLiveActivityApsPayload", () => {
	it("serializes content-state using the native ActivityKit shape", () => {
		const payload = buildLiveActivityApsPayload({
			contentState: defaultContentState,
			event: "update",
			timestampSeconds: 1000,
		});

		expect(payload).toMatchObject({
			timestamp: 1000,
			event: "update",
			"content-state": defaultContentState,
			"stale-date": 1000 + PUSH_STALE_WINDOW_SECONDS,
		});
		expect(payload["attributes-type"]).toBeUndefined();
		expect(payload["attributes"]).toBeUndefined();
	});

	it("uses the native attributes type and deep link defaults for start events", () => {
		const payload = buildLiveActivityApsPayload({
			contentState: defaultContentState,
			event: "start",
			timestampSeconds: 2000,
		});

		expect(payload).toMatchObject({
			timestamp: 2000,
			event: "start",
			"content-state": defaultContentState,
			"attributes-type": "RemoteCodeLiveActivityAttributes",
			attributes: {
				deepLink: "remotecode-mobile://active-threads",
			},
			"stale-date": 2000 + PUSH_STALE_WINDOW_SECONDS,
		});
		expect(payload["dismissal-date"]).toBeUndefined();
		expect(payload["sound"]).toBeUndefined();
	});

	it("keeps end-event dismissal metadata without reverting to the legacy payload shape", () => {
		const payload = buildLiveActivityApsPayload({
			contentState: {
				...defaultContentState,
				elapsedSeconds: 20,
				phase: "completed",
				preview: "No active threads right now.",
				statusLine: "All threads completed",
			},
			event: "end",
			timestampSeconds: 3000,
		});

		expect(payload).toMatchObject({
			timestamp: 3000,
			event: "end",
			"content-state": {
				...defaultContentState,
				elapsedSeconds: 20,
				phase: "completed",
				preview: "No active threads right now.",
				statusLine: "All threads completed",
			},
			"dismissal-date": 3000 + PUSH_END_DISMISS_SECONDS,
			sound: "default",
		});
		expect(payload["attributes-type"]).toBeUndefined();
		expect(payload["attributes"]).toBeUndefined();
		expect(payload["stale-date"]).toBeUndefined();
	});
});
