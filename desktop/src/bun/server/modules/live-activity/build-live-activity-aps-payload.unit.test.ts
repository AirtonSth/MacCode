import { describe, expect, it } from "bun:test";

import { buildLiveActivityApsPayload } from "./live-activity-push.service";

const LIVE_ACTIVITY_NAME = "ThreadLiveActivity";
const PUSH_STALE_WINDOW_SECONDS = 180;
const PUSH_END_DISMISS_SECONDS = 30;

const defaultContentState = {
	chatId: "chat-1",
	chatTitle: "Thread",
	elapsedSeconds: 10,
	phase: "running" as const,
	preview: "Working on it",
	statusLine: "Generating response",
};

describe("buildLiveActivityApsPayload", () => {
	describe("common fields", () => {
		it("includes timestamp, event, and content-state for all event types", () => {
			for (const event of ["start", "update", "end"] as const) {
				const payload = buildLiveActivityApsPayload({
					contentState: defaultContentState,
					event,
					timestampSeconds: 1000,
				});

				expect(payload.timestamp).toBe(1000);
				expect(payload.event).toBe(event);
				expect(payload["content-state"]).toBeDefined();

				const cs = payload["content-state"] as Record<string, unknown>;
				expect(cs.name).toBe(LIVE_ACTIVITY_NAME);
				expect(typeof cs.props).toBe("string");
			}
		});

		it("serializes contentState as JSON string in props", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 1000,
			});

			const cs = payload["content-state"] as Record<string, unknown>;
			const parsed = JSON.parse(cs.props as string) as typeof defaultContentState;
			expect(parsed.chatId).toBe("chat-1");
			expect(parsed.chatTitle).toBe("Thread");
			expect(parsed.elapsedSeconds).toBe(10);
			expect(parsed.phase).toBe("running");
		});

		it("floors and clamps negative timestamp to 0", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: -100,
			});

			expect(payload.timestamp).toBe(0);
		});

		it("floors fractional timestamps", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 1234.99,
			});

			expect(payload.timestamp).toBe(1234);
		});

		it("uses nowMs when timestampSeconds is undefined", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				nowMs: 5_000_000,
			});

			expect(payload.timestamp).toBe(5_000);
		});

		it("uses current time when both timestampSeconds and nowMs are undefined", () => {
			const before = Math.floor(Date.now() / 1_000);
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
			});
			const after = Math.floor(Date.now() / 1_000);

			expect(payload.timestamp).toBeGreaterThanOrEqual(before);
			expect(payload.timestamp).toBeLessThanOrEqual(after);
		});

		it("uses current time when timestampSeconds is NaN", () => {
			const before = Math.floor(Date.now() / 1_000);
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: NaN,
			});
			const after = Math.floor(Date.now() / 1_000);

			expect(payload.timestamp).toBeGreaterThanOrEqual(before);
			expect(payload.timestamp).toBeLessThanOrEqual(after);
		});

		it("uses current time when timestampSeconds is Infinity", () => {
			const before = Math.floor(Date.now() / 1_000);
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: Infinity,
			});
			const after = Math.floor(Date.now() / 1_000);

			expect(payload.timestamp).toBeGreaterThanOrEqual(before);
			expect(payload.timestamp).toBeLessThanOrEqual(after);
		});
	});

	describe("start event", () => {
		it("includes attributes-type defaulting to LiveActivityAttributes", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect(payload["attributes-type"]).toBe("LiveActivityAttributes");
		});

		it("includes empty attributes by default", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect(payload["attributes"]).toEqual({});
		});

		it("forwards custom attributesType when provided", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
				attributesType: "CustomAttributes",
			});

			expect(payload["attributes-type"]).toBe("CustomAttributes");
		});

		it("forwards custom attributes object when provided", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
				attributes: { key: "value", nested: { a: 1 } },
			});

			expect(payload["attributes"]).toEqual({ key: "value", nested: { a: 1 } });
		});

		it("includes stale-date at timestamp + 180s", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect(payload["stale-date"]).toBe(1000 + PUSH_STALE_WINDOW_SECONDS);
		});

		it("does NOT include dismissal-date", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect(payload["dismissal-date"]).toBeUndefined();
		});

		it("does NOT include sound", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect(payload["sound"]).toBeUndefined();
		});
	});

	describe("update event", () => {
		it("includes stale-date at timestamp + 180s", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 2000,
			});

			expect(payload["stale-date"]).toBe(2000 + PUSH_STALE_WINDOW_SECONDS);
		});

		it("does NOT include attributes-type", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 2000,
			});

			expect(payload["attributes-type"]).toBeUndefined();
		});

		it("does NOT include attributes", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 2000,
			});

			expect(payload["attributes"]).toBeUndefined();
		});

		it("does NOT include dismissal-date", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 2000,
			});

			expect(payload["dismissal-date"]).toBeUndefined();
		});

		it("does NOT include sound", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 2000,
			});

			expect(payload["sound"]).toBeUndefined();
		});
	});

	describe("end event", () => {
		it("includes dismissal-date at timestamp + 30s", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 3000,
			});

			expect(payload["dismissal-date"]).toBe(3000 + PUSH_END_DISMISS_SECONDS);
		});

		it("includes sound set to default", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 3000,
			});

			expect(payload["sound"]).toBe("default");
		});

		it("does NOT include stale-date", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 3000,
			});

			expect(payload["stale-date"]).toBeUndefined();
		});

		it("does NOT include attributes-type", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 3000,
			});

			expect(payload["attributes-type"]).toBeUndefined();
		});

		it("does NOT include attributes", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 3000,
			});

			expect(payload["attributes"]).toBeUndefined();
		});
	});

	describe("mutual exclusivity of event-specific fields", () => {
		it("start payload has exactly: attributes-type, attributes, stale-date (no dismissal-date, no sound)", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "start",
				timestampSeconds: 1000,
			});

			expect("attributes-type" in payload).toBe(true);
			expect("attributes" in payload).toBe(true);
			expect("stale-date" in payload).toBe(true);
			expect("dismissal-date" in payload).toBe(false);
			expect("sound" in payload).toBe(false);
		});

		it("update payload has exactly: stale-date (no attributes-type, no attributes, no dismissal-date, no sound)", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "update",
				timestampSeconds: 1000,
			});

			expect("attributes-type" in payload).toBe(false);
			expect("attributes" in payload).toBe(false);
			expect("stale-date" in payload).toBe(true);
			expect("dismissal-date" in payload).toBe(false);
			expect("sound" in payload).toBe(false);
		});

		it("end payload has exactly: dismissal-date, sound (no attributes-type, no attributes, no stale-date)", () => {
			const payload = buildLiveActivityApsPayload({
				contentState: defaultContentState,
				event: "end",
				timestampSeconds: 1000,
			});

			expect("attributes-type" in payload).toBe(false);
			expect("attributes" in payload).toBe(false);
			expect("stale-date" in payload).toBe(false);
			expect("dismissal-date" in payload).toBe(true);
			expect("sound" in payload).toBe(true);
		});
	});
});
