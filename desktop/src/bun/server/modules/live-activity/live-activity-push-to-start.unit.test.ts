import { describe, expect, it } from "bun:test";

import { createLiveActivityPushServiceForTests } from "./live-activity-push.service";
import type {
	LiveActivityPushSubscriptionStoreContract,
	PushToStartTokenInput,
	PushToStartTokenStoreContract,
	PushToStartTokenStored,
} from "./live-activity-push.model";

interface CapturedDelivery {
	attributes?: Record<string, unknown>;
	attributesType?: string;
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	event: "update" | "end" | "start";
	liveActivityToken: string;
	phase: string;
	preview: string;
	pushToken: string;
	pushTokenType: string;
	statusLine: string;
}

const createInMemoryPushToStartTokenStore = (): PushToStartTokenStoreContract & { rows: Map<string, PushToStartTokenStored> } => {
	const rows = new Map<string, PushToStartTokenStored>();
	return {
		rows,
		listAll: () => [...rows.values()],
		upsert: (input: PushToStartTokenInput) => {
			const key = `${input.pushTokenType}::${input.pushToken}`;
			const stored: PushToStartTokenStored = {
				...input,
				updatedAt: new Date().toISOString(),
			};
			rows.set(key, stored);
			return stored;
		},
		deleteByPushToken: (pushToken: string, pushTokenType: string) => {
			rows.delete(`${pushTokenType}::${pushToken}`);
		},
	};
};

const createInMemorySubscriptionStore = (): LiveActivityPushSubscriptionStoreContract => {
	const rows = new Map<string, {
		chatId: string;
		chatTitle?: string;
		liveActivityToken: string;
		pushToken: string;
		pushTokenType: "apns" | "fcm";
		updatedAt: string;
	}>();
	return {
		deleteExact: ({ liveActivityToken, pushToken, pushTokenType }) => {
			rows.delete([pushTokenType, pushToken, liveActivityToken].join("::"));
		},
		listAll: () => [...rows.values()],
		upsert: (input) => {
			const row = { ...input, updatedAt: new Date().toISOString() };
			rows.set([input.pushTokenType, input.pushToken, input.liveActivityToken].join("::"), row);
			return row;
		},
	};
};

const createRecordingHarness = (
	pushToStartTokenStore?: PushToStartTokenStoreContract,
	subscriptionStore?: LiveActivityPushSubscriptionStoreContract,
	sender?: (input: CapturedDelivery) => Promise<{ delivered: boolean; shouldDropSubscription: boolean; errorCode?: string }>,
) => {
	const deliveries: CapturedDelivery[] = [];
	const service = createLiveActivityPushServiceForTests(
		async (input) => {
			const delivery: CapturedDelivery = {
				attributes: input.attributes,
				attributesType: input.attributesType,
				chatId: input.contentState.chatId,
				chatTitle: input.contentState.chatTitle,
				elapsedSeconds: input.contentState.elapsedSeconds,
				event: input.event,
				liveActivityToken: input.liveActivityToken,
				phase: input.contentState.phase,
				preview: input.contentState.preview,
				pushToken: input.pushToken,
				pushTokenType: input.pushTokenType,
				statusLine: input.contentState.statusLine,
			};
			deliveries.push(delivery);
			if (sender) {
				return await sender(delivery);
			}
			return { delivered: true, shouldDropSubscription: false };
		},
		subscriptionStore,
		pushToStartTokenStore,
	);
	return { deliveries, service };
};

describe("LiveActivityPushService push-to-start", () => {
	it("stores valid push-to-start tokens", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { service } = createRecordingHarness(store);

		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-1",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		expect(store.rows.size).toBe(1);
		expect(store.rows.get("apns::device-push-1")).toEqual(expect.objectContaining({
			pushToStartToken: "pts-token-1",
		}));
	});

	it("sends a single global push-to-start payload when a session begins without subscriptions", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { deliveries, service } = createRecordingHarness(store);

		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-1",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		service.onChatStarted({
			chatId: "chat-start-1",
			chatTitle: "New Thread",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

		const startDeliveries = deliveries.filter((delivery) => delivery.event === "start");
		expect(startDeliveries).toHaveLength(1);
		expect(startDeliveries[0]).toMatchObject({
			attributes: {
				deepLink: "remotecode-mobile://active-threads",
			},
			attributesType: "RemoteCodeLiveActivityAttributes",
			chatId: "active-threads",
			chatTitle: "1 Active Thread",
			phase: "running",
			pushToken: "device-push-1",
			pushTokenType: "apns",
			statusLine: "Generating response",
		});
	});

	it("does not send a duplicate push-to-start once the same device has an active subscription", async () => {
		const pushStore = createInMemoryPushToStartTokenStore();
		const subStore = createInMemorySubscriptionStore();
		const { deliveries, service } = createRecordingHarness(pushStore, subStore);

		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-sub",
			pushToken: "device-push-sub",
			pushTokenType: "apns",
		});

		service.onChatStarted({
			chatId: "chat-with-sub",
			chatTitle: "Thread",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 25); });
		await service.upsertSubscription({
			chatId: "chat-with-sub",
			chatTitle: "Thread",
			liveActivityToken: "live-token-existing",
			pushToken: "device-push-sub",
			pushTokenType: "apns",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 25); });

		const startDeliveries = deliveries.filter((delivery) => delivery.event === "start");
		expect(startDeliveries).toHaveLength(1);
	});

	it("sends one push-to-start per uncovered device", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { deliveries, service } = createRecordingHarness(store);

		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-a",
			pushToken: "device-a",
			pushTokenType: "apns",
		});
		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-b",
			pushToken: "device-b",
			pushTokenType: "fcm",
		});

		service.onChatStarted({
			chatId: "chat-multi",
			chatTitle: "Thread",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

		const startDeliveries = deliveries.filter((delivery) => delivery.event === "start");
		expect(startDeliveries).toHaveLength(2);
		expect(startDeliveries.every((delivery) => delivery.chatId === "active-threads")).toBe(true);
	});

	it("bootstraps a newly registered device while a session is already active", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { deliveries, service } = createRecordingHarness(store);

		service.onChatStarted({
			chatId: "chat-active",
			chatTitle: "Active",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 25); });

		await service.registerPushToStartToken({
			pushToStartToken: "pts-token-late",
			pushToken: "device-late",
			pushTokenType: "apns",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

		const startDeliveries = deliveries.filter((delivery) => delivery.event === "start");
		expect(startDeliveries).toHaveLength(1);
		expect(startDeliveries[0]).toMatchObject({
			chatId: "active-threads",
			pushToken: "device-late",
		});
	});

	it("does not send push-to-start after the session has already finished", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { deliveries, service } = createRecordingHarness(store);

		service.onChatStarted({
			chatId: "chat-finished",
			chatTitle: "Finished",
		});
		await service.upsertSubscription({
			chatId: "chat-finished",
			chatTitle: "Finished",
			liveActivityToken: "live-token-finished",
			pushToken: "device-finished",
			pushTokenType: "fcm",
		});
		await service.onChatFinished({
			chatId: "chat-finished",
			outcome: "completed",
		});

		await service.registerPushToStartToken({
			pushToStartToken: "pts-terminal",
			pushToken: "device-terminal",
			pushTokenType: "apns",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

		expect(deliveries.filter((delivery) => delivery.event === "start")).toHaveLength(0);
	});

	it("keeps push-to-start tokens even when a start delivery fails permanently", async () => {
		const store = createInMemoryPushToStartTokenStore();
		const { deliveries, service } = createRecordingHarness(
			store,
			undefined,
			async (input) => {
				if (input.event === "start") {
					return {
						delivered: false,
						errorCode: "apns/BadDeviceToken",
						shouldDropSubscription: true,
					};
				}

				return {
					delivered: true,
					shouldDropSubscription: false,
				};
			},
		);

		await service.registerPushToStartToken({
			pushToStartToken: "pts-bad-token",
			pushToken: "device-bad",
			pushTokenType: "apns",
		});

		service.onChatStarted({
			chatId: "chat-drop",
			chatTitle: "Thread",
		});
		await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

		expect(deliveries.filter((delivery) => delivery.event === "start")).toHaveLength(1);
		expect(store.rows.size).toBe(1);
		expect(store.rows.get("apns::device-bad")).toEqual(expect.objectContaining({
			pushToStartToken: "pts-bad-token",
		}));
	});
});
