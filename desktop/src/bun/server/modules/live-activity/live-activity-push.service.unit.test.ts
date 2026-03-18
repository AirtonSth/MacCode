import { afterEach, expect, test } from "bun:test";

import {
	createLiveActivityPushServiceForTests,
	createLiveActivityPushServiceFromEnvironment,
} from "./live-activity-push.service";
import type {
	LiveActivityPushStoredSubscription,
	LiveActivityPushSubscriptionStoreContract,
	PushToStartTokenStoreContract,
	PushToStartTokenStored,
} from "./live-activity-push.model";

interface CapturedDelivery {
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	event: "update" | "end" | "start";
	phase: string;
	preview: string;
	pushToken?: string;
	pushTokenType?: string;
	statusLine: string;
}

const createRecordingHarness = () => {
	const deliveries: CapturedDelivery[] = [];
	const service = createLiveActivityPushServiceForTests(async (input) => {
		deliveries.push({
			chatId: input.contentState.chatId,
			chatTitle: input.contentState.chatTitle,
			elapsedSeconds: input.contentState.elapsedSeconds,
			event: input.event,
			phase: input.contentState.phase,
			preview: input.contentState.preview,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			statusLine: input.contentState.statusLine,
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

const createInMemorySubscriptionStore = (): LiveActivityPushSubscriptionStoreContract & {
	rows: Map<string, LiveActivityPushStoredSubscription>;
} => {
	const rows = new Map<string, LiveActivityPushStoredSubscription>();
	return {
		rows,
		deleteExact: ({ liveActivityToken, pushToken, pushTokenType }) => {
			rows.delete([pushTokenType, pushToken, liveActivityToken].join("::"));
		},
		listAll: () => [...rows.values()],
		upsert: (input) => {
			const stored: LiveActivityPushStoredSubscription = {
				...input,
				updatedAt: new Date().toISOString(),
			};
			rows.set([input.pushTokenType, input.pushToken, input.liveActivityToken].join("::"), stored);
			return stored;
		},
	};
};

const createInMemoryPushToStartTokenStore = (): PushToStartTokenStoreContract & {
	rows: Map<string, PushToStartTokenStored>;
} => {
	const rows = new Map<string, PushToStartTokenStored>();
	return {
		rows,
		deleteByPushToken: (pushToken, pushTokenType) => {
			rows.delete(`${pushTokenType}::${pushToken}`);
		},
		listAll: () => [...rows.values()],
		upsert: (input) => {
			const stored: PushToStartTokenStored = {
				...input,
				updatedAt: new Date().toISOString(),
			};
			rows.set(`${input.pushTokenType}::${input.pushToken}`, stored);
			return stored;
		},
	};
};

const findLastDelivery = (
	deliveries: readonly CapturedDelivery[],
	event: CapturedDelivery["event"],
): CapturedDelivery | undefined => {
	for (let index = deliveries.length - 1; index >= 0; index -= 1) {
		const delivery = deliveries[index];
		if (delivery?.event === event) {
			return delivery;
		}
	}

	return undefined;
};

const realDateNow = Date.now;

afterEach(() => {
	Date.now = realDateNow;
});

test("LiveActivityPushService emits a global session payload for the first active chat", async () => {
	Date.now = () => 1_000;
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-1",
		chatTitle: "Thread 1",
	});
	await service.upsertSubscription({
		chatId: "chat-1",
		chatTitle: "Thread 1",
		pushToken: "fcm-token-1",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-1",
	});

	expect(findLastDelivery(deliveries, "update")).toMatchObject({
		chatId: "active-threads",
		chatTitle: "1 Active Thread",
		elapsedSeconds: 0,
		event: "update",
		phase: "running",
		statusLine: "Generating response",
	});
});

test("LiveActivityPushService keeps one timer across overlapping chats and shows global counts", async () => {
	Date.now = () => 1_000;
	const { deliveries, service } = createRecordingHarness();

	await service.upsertSubscription({
		chatId: "chat-a",
		chatTitle: "A",
		pushToken: "fcm-token-1",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-1",
	});

	service.onChatStarted({
		chatId: "chat-a",
		chatTitle: "A",
	});

	Date.now = () => 6_000;
	service.onChatStarted({
		chatId: "chat-b",
		chatTitle: "B",
	});
	await new Promise<void>((resolve) => {
		setTimeout(resolve, 25);
	});

	expect(findLastDelivery(deliveries, "update")).toMatchObject({
		chatId: "active-threads",
		chatTitle: "2 Active Threads",
		elapsedSeconds: 5,
		phase: "running",
		statusLine: "Generating response",
	});
});

test("LiveActivityPushService does not go terminal while another chat is still active", async () => {
	Date.now = () => 1_000;
	const { deliveries, service } = createRecordingHarness();

	await service.upsertSubscription({
		chatId: "chat-a",
		chatTitle: "A",
		pushToken: "fcm-token-1",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-1",
	});

	service.onChatStarted({
		chatId: "chat-a",
		chatTitle: "A",
	});
	Date.now = () => 4_000;
	service.onChatStarted({
		chatId: "chat-b",
		chatTitle: "B",
	});
	Date.now = () => 10_000;
	await service.onChatFinished({
		chatId: "chat-a",
		outcome: "completed",
	});

	expect(findLastDelivery(deliveries, "update")).toMatchObject({
		chatId: "active-threads",
		chatTitle: "1 Active Thread",
		elapsedSeconds: 9,
		phase: "running",
		statusLine: "Generating response",
	});
});

test("LiveActivityPushService emits a frozen terminal summary when the last chat finishes", async () => {
	Date.now = () => 1_000;
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-terminal",
		chatTitle: "Terminal",
	});
	await service.upsertSubscription({
		chatId: "chat-terminal",
		chatTitle: "Terminal",
		pushToken: "fcm-token-terminal",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-terminal",
	});

	Date.now = () => 12_000;
	await service.onChatFinished({
		chatId: "chat-terminal",
		outcome: "error",
	});

	expect(findLastDelivery(deliveries, "update")).toMatchObject({
		chatId: "active-threads",
		elapsedSeconds: 11,
		phase: "error",
		preview: "No active threads right now.",
		statusLine: "At least one thread ended with an error",
	});
	expect(deliveries.some((delivery) => delivery.event === "end")).toBe(false);
});

test("LiveActivityPushService resets elapsed time and outcome when a new session begins", async () => {
	Date.now = () => 1_000;
	const { deliveries, service } = createRecordingHarness();

	service.onChatStarted({
		chatId: "chat-old",
		chatTitle: "Old",
	});
	await service.upsertSubscription({
		chatId: "chat-old",
		chatTitle: "Old",
		pushToken: "fcm-token-old",
		pushTokenType: "fcm",
		liveActivityToken: "live-token-old",
	});
	Date.now = () => 7_000;
	await service.onChatFinished({
		chatId: "chat-old",
		outcome: "failed",
	});

	Date.now = () => 9_000;
	service.onChatStarted({
		chatId: "chat-new",
		chatTitle: "New",
	});
	await new Promise<void>((resolve) => {
		setTimeout(resolve, 25);
	});

	expect(findLastDelivery(deliveries, "update")).toMatchObject({
		chatId: "active-threads",
		chatTitle: "1 Active Thread",
		elapsedSeconds: 0,
		phase: "running",
		statusLine: "Generating response",
	});
});

test("LiveActivityPushService persists subscriptions after a terminal update", async () => {
	const store = createInMemorySubscriptionStore();
	const service = createLiveActivityPushServiceForTests(async () => ({
		delivered: true,
		shouldDropSubscription: false,
	}), store);

	service.onChatStarted({
		chatId: "chat-store",
		chatTitle: "Stored",
	});
	await service.upsertSubscription({
		chatId: "chat-store",
		chatTitle: "Stored",
		pushToken: "push-token-store",
		pushTokenType: "apns",
		liveActivityToken: "activity-token-store",
	});
	await service.onChatFinished({
		chatId: "chat-store",
		outcome: "completed",
	});

	expect(store.listAll()).toHaveLength(1);
	expect(store.listAll()[0]).toEqual(expect.objectContaining({
		chatId: "chat-store",
		pushToken: "push-token-store",
		pushTokenType: "apns",
		liveActivityToken: "activity-token-store",
	}));
});

test("LiveActivityPushService prunes stale persisted subscriptions for the same device and delivers only the newest token", async () => {
	const store = createInMemorySubscriptionStore();
	store.rows.set("fcm::device-token::live-token-old", {
		chatId: "chat-old",
		chatTitle: "Old",
		liveActivityToken: "live-token-old",
		pushToken: "device-token",
		pushTokenType: "fcm",
		updatedAt: "2026-03-18T16:00:00.000Z",
	});
	store.rows.set("fcm::device-token::live-token-new", {
		chatId: "chat-new",
		chatTitle: "New",
		liveActivityToken: "live-token-new",
		pushToken: "device-token",
		pushTokenType: "fcm",
		updatedAt: "2026-03-18T16:01:00.000Z",
	});
	const deliveries: CapturedDelivery[] = [];
	const restored = createLiveActivityPushServiceForTests(async (input) => {
		deliveries.push({
			chatId: input.contentState.chatId,
			chatTitle: input.contentState.chatTitle,
			elapsedSeconds: input.contentState.elapsedSeconds,
			event: input.event,
			phase: input.contentState.phase,
			preview: input.contentState.preview,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			statusLine: input.contentState.statusLine,
		});
		return {
			delivered: true,
			shouldDropSubscription: false,
		};
	}, store);

	restored.onChatStarted({
		chatId: "chat-new",
		chatTitle: "New",
	});
	await new Promise<void>((resolve) => {
		setTimeout(resolve, 25);
	});

	expect(store.listAll()).toHaveLength(1);
	expect(store.listAll()[0]).toEqual(expect.objectContaining({
		liveActivityToken: "live-token-new",
		pushToken: "device-token",
	}));
	expect(deliveries.filter((delivery) => delivery.event === "update")).toHaveLength(1);
});

test("LiveActivityPushService keeps subscriptions after permanent delivery failures", async () => {
	let deliveries = 0;
	const service = createLiveActivityPushServiceForTests(async () => {
		deliveries += 1;
		return {
			delivered: false,
			errorCode: "push/unsupported-token-type-apns",
			shouldDropSubscription: true,
		};
	});

	service.onChatStarted({
		chatId: "chat-keep",
		chatTitle: "Keep",
	});
	await service.upsertSubscription({
		chatId: "chat-keep",
		chatTitle: "Keep",
		liveActivityToken: "activity-token-keep",
		pushToken: "push-token-keep",
		pushTokenType: "apns",
	});
	await service.onChatFinished({
		chatId: "chat-keep",
		outcome: "completed",
	});
	service.onChatStarted({
		chatId: "chat-next",
		chatTitle: "Next",
	});

	await new Promise<void>((resolve) => {
		setTimeout(resolve, 25);
	});

	expect(deliveries).toBeGreaterThanOrEqual(2);
});

test("createLiveActivityPushServiceFromEnvironment rejects subscriptions whose token type is not supported by backend capabilities", async () => {
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
		expect(deliveryBodies.length).toBeGreaterThanOrEqual(1);
		expect(deliveryBodies.every((body) => body.pushTokenType === "fcm")).toBe(true);
		expect(deliveryBodies.some((body) => body.pushToken === "device-token-fcm")).toBe(true);
		expect(deliveryBodies.some((body) => body.pushToken === "device-token-apns")).toBe(false);
	} finally {
		globalThis.fetch = originalFetch;
	}
});

test("LiveActivityPushService keeps push-to-start tokens persisted when pruning unsupported types", () => {
	const subscriptionStore = createInMemorySubscriptionStore();
	const pushToStartTokenStore = createInMemoryPushToStartTokenStore();
	subscriptionStore.upsert({
		chatId: "chat-apns",
		chatTitle: "APNS chat",
		liveActivityToken: "live-apns",
		pushToken: "push-apns",
		pushTokenType: "apns",
	});
	pushToStartTokenStore.upsert({
		pushToStartToken: "pts-fcm",
		pushToken: "push-fcm",
		pushTokenType: "fcm",
	});

	const service = createLiveActivityPushServiceForTests(
		undefined,
		subscriptionStore,
		pushToStartTokenStore,
	);

	service.pruneUnsupportedPushTokenTypes(new Set(["fcm"]));

	expect(subscriptionStore.listAll()).toHaveLength(0);
	expect(pushToStartTokenStore.listAll()).toHaveLength(1);
	expect(pushToStartTokenStore.listAll()[0]?.pushTokenType).toBe("fcm");
});
