import { expect, test } from "bun:test";

import {
	createLiveActivityPushServiceForTests,
	createLiveActivityPushServiceFromEnvironment,
} from "./live-activity-push.service";
import type { LiveActivityPushSubscriptionStoreContract } from "./live-activity-push.model";

interface CapturedDelivery {
	event: "update" | "end" | "start";
	chatTitle: string;
	preview: string;
}

const ALLOWED_TEXT_PATTERN = /^[\p{L}\p{N}\p{Zs}'.,;:!?@#%&+\-_/()]*$/u;

const createRecordingHarness = () => {
	const deliveries: CapturedDelivery[] = [];
	const service = createLiveActivityPushServiceForTests(async (input) => {
		deliveries.push({
			event: input.event,
			chatTitle: input.contentState.chatTitle,
			preview: input.contentState.preview,
		});
		return {
			delivered: true,
			shouldDropSubscription: false,
		};
	});

	return {
		deliveries,
		service,
	};
};

const findLastDeliveryByEvent = (
	deliveries: readonly CapturedDelivery[],
	event: CapturedDelivery["event"],
): CapturedDelivery | undefined => {
	for (let index = deliveries.length - 1; index >= 0; index -= 1) {
		const current = deliveries[index];
		if (current?.event === event) {
			return current;
		}
	}

	return undefined;
};

test("LiveActivityPushService aggressively sanitizes payload text and truncates preview with ellipsis", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-1",
		chatTitle: "Thread {\"payload\":true} ```json```",
	});
	service.onAssistantDelta(
		"chat-1",
		"\u001B[31m```json\n{\"tool\":\"rm -rf /\",\"args\":[\"x\"]}\n```\u001B[0m<script>alert(1)</script> [alpha|beta] key=value \\ path",
	);
	await service.upsertSubscription({
		chatId: "chat-1",
		chatTitle: "Thread",
		pushToken: "fcm-token-1",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-1",
	});
	await service.onChatFinished({
		chatId: "chat-1",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview.length).toBeLessThanOrEqual(140);
	expect(endDelivery?.preview).toMatch(ALLOWED_TEXT_PATTERN);
	expect(endDelivery?.preview).not.toContain("{");
	expect(endDelivery?.preview).not.toContain("}");
	expect(endDelivery?.preview).not.toContain("[");
	expect(endDelivery?.preview).not.toContain("]");
	expect(endDelivery?.preview).not.toContain("`");
	expect(endDelivery?.preview).not.toContain("\\");
	expect(endDelivery?.chatTitle).toMatch(ALLOWED_TEXT_PATTERN);
	expect(endDelivery?.chatTitle).not.toContain("{");
	expect(endDelivery?.chatTitle).not.toContain("}");
});

test("LiveActivityPushService keeps short previews unchanged", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-2",
		chatTitle: "Thread",
	});
	service.onAssistantDelta("chat-2", "Short preview text");
	await service.upsertSubscription({
		chatId: "chat-2",
		chatTitle: "Thread",
		pushToken: "fcm-token-2",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-2",
	});
	await service.onChatFinished({
		chatId: "chat-2",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Short preview text");
	expect(endDelivery?.preview.endsWith("...")).toBe(false);
});

test("LiveActivityPushService accumulates legacy deltas across multiple chunks", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-legacy",
		chatTitle: "Thread",
	});
	service.onAssistantDelta("chat-legacy", "Hello");
	service.onAssistantDelta("chat-legacy", " world");
	await service.upsertSubscription({
		chatId: "chat-legacy",
		chatTitle: "Thread",
		pushToken: "fcm-token-legacy",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-legacy",
	});
	await service.onChatFinished({
		chatId: "chat-legacy",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Hello world");
});

test("LiveActivityPushService keeps structured fallback text when legacy deltas arrive before structured content", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-legacy-started",
		chatTitle: "Thread",
	});
	service.onAssistantEvent("chat-legacy-started", {
		type: "item_started",
		turnId: "turn-1",
		itemId: "item-1",
		itemType: "assistant_message",
	});
	service.onAssistantDelta("chat-legacy-started", "Hello");
	service.onAssistantDelta("chat-legacy-started", " world");
	await service.upsertSubscription({
		chatId: "chat-legacy-started",
		chatTitle: "Thread",
		pushToken: "fcm-token-legacy-started",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-legacy-started",
	});
	await service.onChatFinished({
		chatId: "chat-legacy-started",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Writing response...");
});

test("LiveActivityPushService replaces event previews with the latest response text", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-4",
		chatTitle: "Thread",
	});
	service.onAssistantEvent("chat-4", {
		type: "item_completed",
		turnId: "turn-1",
		itemId: "item-1",
		summary: "Tool finished successfully",
	});
	service.onAssistantEvent("chat-4", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-2",
		target: "body",
		delta: "Hello",
	});
	service.onAssistantEvent("chat-4", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-2",
		target: "body",
		delta: " world",
	});
	await service.upsertSubscription({
		chatId: "chat-4",
		chatTitle: "Thread",
		pushToken: "fcm-token-4",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-4",
	});
	await service.onChatFinished({
		chatId: "chat-4",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Hello world");
});

test("LiveActivityPushService ignores duplicated legacy deltas once structured response events take over", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-5",
		chatTitle: "Thread",
	});
	service.onAssistantEvent("chat-5", {
		type: "item_started",
		turnId: "turn-1",
		itemId: "item-1",
		itemType: "assistant_message",
	});
	service.onAssistantEvent("chat-5", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-1",
		target: "body",
		delta: "Hello",
	});
	service.onAssistantDelta("chat-5", "Hello");
	service.onAssistantEvent("chat-5", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-1",
		target: "body",
		delta: " world",
	});
	service.onAssistantDelta("chat-5", " world");
	await service.upsertSubscription({
		chatId: "chat-5",
		chatTitle: "Thread",
		pushToken: "fcm-token-5",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-5",
	});
	await service.onChatFinished({
		chatId: "chat-5",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Hello world");
});

test("LiveActivityPushService replaces summary preview text instead of appending it", async () => {
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-summary",
		chatTitle: "Thread",
	});
	service.onAssistantEvent("chat-summary", {
		type: "item_started",
		turnId: "turn-1",
		itemId: "item-1",
		itemType: "reasoning",
	});
	service.onAssistantEvent("chat-summary", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-1",
		target: "summary",
		delta: "Thinking...",
	});
	service.onAssistantEvent("chat-summary", {
		type: "item_delta",
		turnId: "turn-1",
		itemId: "item-1",
		target: "summary",
		delta: "Planning response...",
	});
	await service.upsertSubscription({
		chatId: "chat-summary",
		chatTitle: "Thread",
		pushToken: "fcm-token-summary",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-summary",
	});
	await service.onChatFinished({
		chatId: "chat-summary",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview).toBe("Planning response...");
});

test("LiveActivityPushService stays stable with hostile mixed payloads", async () => {
	const { deliveries, service } = createRecordingHarness();
	const hostilePayload = [
		"\u0000\u0007\u001B[31m",
		"\u200B\u202E",
		"\uD800\uDFFF",
		"```ts const data={\"x\":1}; ```",
		"{\"items\":[1,2,3]} <script>alert(1)</script> |$`\\^*=[]",
		"safe words",
	].join(" ");

	service.onChatStarted({
		chatId: "chat-3",
		chatTitle: "Thread",
	});
	service.onAssistantDelta("chat-3", hostilePayload.repeat(20));
	await service.upsertSubscription({
		chatId: "chat-3",
		chatTitle: "Thread",
		pushToken: "fcm-token-3",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-3",
	});
	await service.onChatFinished({
		chatId: "chat-3",
		outcome: "completed",
	});

	const endDelivery = findLastDeliveryByEvent(deliveries, "end");

	expect(endDelivery).toBeDefined();
	expect(endDelivery?.preview.length).toBeLessThanOrEqual(140);
	expect(endDelivery?.preview).toMatch(ALLOWED_TEXT_PATTERN);
	expect(endDelivery?.preview).not.toContain("`");
	expect(endDelivery?.preview).not.toContain("{");
	expect(endDelivery?.preview).not.toContain("}");
	expect(endDelivery?.preview).not.toContain("<");
	expect(endDelivery?.preview).not.toContain(">");
	expect(endDelivery?.preview).not.toContain("\\");
});

test("LiveActivityPushService persists subscriptions and clears them after a successful end", async () => {
	const persistedRows = new Map<string, {
		chatId: string;
		chatTitle?: string;
		liveActivityToken: string;
		pushToken: string;
		pushTokenType: "apns" | "fcm";
		updatedAt: string;
	}>();
	const deleteByChatCalls: string[] = [];
	const store: LiveActivityPushSubscriptionStoreContract = {
		deleteByChatId: (chatId) => {
			deleteByChatCalls.push(chatId);
			for (const [key, row] of persistedRows.entries()) {
				if (row.chatId === chatId) {
					persistedRows.delete(key);
				}
			}
		},
		deleteExact: ({ chatId, liveActivityToken, pushToken, pushTokenType }) => {
			persistedRows.delete([chatId, pushTokenType, pushToken, liveActivityToken].join("::"));
		},
		listAll: () => [...persistedRows.values()],
		upsert: (input) => {
			const row = {
				...input,
				updatedAt: "2026-03-05T00:00:00.000Z",
			};
			persistedRows.set(
				[input.chatId, input.pushTokenType, input.pushToken, input.liveActivityToken].join("::"),
				row,
			);
			return row;
		},
	};
	const service = createLiveActivityPushServiceForTests(async () => ({
		delivered: true,
		shouldDropSubscription: false,
	}), store);

	service.onChatStarted({
		chatId: "chat-store",
		chatTitle: "Stored chat",
	});
	await service.upsertSubscription({
		chatId: "chat-store",
		chatTitle: "Stored chat",
		liveActivityToken: "activity-token-store",
		pushToken: "push-token-store",
		pushTokenType: "apns",
	});

	expect(store.listAll()).toHaveLength(1);

	await service.onChatFinished({
		chatId: "chat-store",
		outcome: "completed",
	});

	expect(deleteByChatCalls).toEqual(["chat-store"]);
	expect(store.listAll()).toEqual([]);
});

test("LiveActivityPushService immediately flushes a follow-up update when new state arrives during an in-flight send", async () => {
	let releaseFirstDelivery = () => {
		// Assigned once the first delivery starts.
	};
	const deliveryEvents: Array<"update" | "end" | "start"> = [];
	const sender = async (input: { event: "update" | "end" | "start" }) => {
		deliveryEvents.push(input.event);
		if (deliveryEvents.length === 1) {
			await new Promise<void>((resolve) => {
				releaseFirstDelivery = resolve;
			});
		}

		return {
			delivered: true,
			shouldDropSubscription: false,
		};
	};
	const service = createLiveActivityPushServiceForTests(sender);

	service.onChatStarted({
		chatId: "chat-race",
		chatTitle: "Race",
	});

	const subscriptionPromise = service.upsertSubscription({
		chatId: "chat-race",
		chatTitle: "Race",
		liveActivityToken: "activity-token-race",
		pushToken: "push-token-race",
		pushTokenType: "apns",
	});

	await Promise.resolve();
	service.onAssistantDelta("chat-race", "fresh delta while first send is still running");
	releaseFirstDelivery();
	await subscriptionPromise;
	for (let attempt = 0; attempt < 10 && deliveryEvents.length < 2; attempt += 1) {
		await new Promise<void>((resolve) => {
			setTimeout(resolve, 25);
		});
	}

	expect(deliveryEvents).toEqual(["update", "update"]);
});

test("createLiveActivityPushServiceFromEnvironment rejects subscriptions for token types unsupported by the private backend", async () => {
	const originalFetch = globalThis.fetch;
	const deliveryBodies: Array<Record<string, unknown>> = [];
	let statusRequests = 0;

	const mockedFetch = Object.assign(async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
		const url = typeof input === "string"
			? input
			: input instanceof URL
				? input.toString()
				: input.url;

		if (url.endsWith("/v1/private/push-notification/status")) {
			statusRequests += 1;
			return Response.json({
				enabled: true,
				supportedPushTokenTypes: ["fcm"],
			});
		}

		if (url.endsWith("/v1/private/push-notification/deliver")) {
			deliveryBodies.push(JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>);
			return Response.json({
				delivered: true,
				shouldDropSubscription: false,
			});
		}

		return new Response("not found", { status: 404 });
	}, {
		preconnect: originalFetch.preconnect.bind(originalFetch),
	}) as typeof fetch;
	globalThis.fetch = mockedFetch;

	try {
		const service = createLiveActivityPushServiceFromEnvironment({
			getConnectorCredentials: () => ({
				backendUrl: "https://private.example.test",
				connectorId: "connector-id",
				connectorToken: "connector-token",
			}),
			privateBackendUrl: "https://private.example.test",
		});

		service.onChatStarted({
			chatId: "chat-private-apns",
			chatTitle: "Private backend",
		});

		const supportedPushTokenTypes = await service.getSupportedPushTokenTypes();
		const subscribed = await service.upsertSubscription({
			chatId: "chat-private-apns",
			chatTitle: "Private backend",
			liveActivityToken: "live-activity-token",
			pushToken: "device-token",
			pushTokenType: "apns",
		});

		expect(supportedPushTokenTypes).toEqual(new Set(["fcm"]));
		expect(subscribed).toBe(false);
		expect(statusRequests).toBe(1);
		expect(deliveryBodies).toHaveLength(0);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test("createLiveActivityPushServiceFromEnvironment caches backend capabilities and only delivers supported token types", async () => {
	const originalFetch = globalThis.fetch;
	const deliveryBodies: Array<Record<string, unknown>> = [];
	let statusRequests = 0;

	const mockedFetch = Object.assign(async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
		const url = typeof input === "string"
			? input
			: input instanceof URL
				? input.toString()
				: input.url;

		if (url.endsWith("/v1/private/push-notification/status")) {
			statusRequests += 1;
			return Response.json({
				enabled: true,
				supportedPushTokenTypes: ["fcm"],
			});
		}

		if (url.endsWith("/v1/private/push-notification/deliver")) {
			deliveryBodies.push(JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>);
			return Response.json({
				delivered: true,
				shouldDropSubscription: false,
			});
		}

		return new Response("not found", { status: 404 });
	}, {
		preconnect: originalFetch.preconnect.bind(originalFetch),
	}) as typeof fetch;
	globalThis.fetch = mockedFetch;

	try {
		const service = createLiveActivityPushServiceFromEnvironment({
			getConnectorCredentials: () => ({
				backendUrl: "https://private.example.test",
				connectorId: "connector-id",
				connectorToken: "connector-token",
			}),
			privateBackendUrl: "https://private.example.test",
		});

		service.onChatStarted({
			chatId: "chat-private-fcm",
			chatTitle: "Private backend",
		});

		await service.registerPushToStartToken({
			pushToStartToken: "push-to-start-token",
			pushToken: "device-token-apns",
			pushTokenType: "apns",
		});

		const subscribed = await service.upsertSubscription({
			chatId: "chat-private-fcm",
			chatTitle: "Private backend",
			liveActivityToken: "live-activity-token",
			pushToken: "device-token-fcm",
			pushTokenType: "fcm",
		});
		await service.onChatFinished({
			chatId: "chat-private-fcm",
			outcome: "completed",
		});

		expect(subscribed).toBe(true);
		expect(statusRequests).toBe(1);
		expect(deliveryBodies).toHaveLength(1);
		expect(deliveryBodies[0]).toMatchObject({
			event: "update",
			pushToken: "device-token-fcm",
			pushTokenType: "fcm",
		});
	} finally {
		globalThis.fetch = originalFetch;
	}
});
