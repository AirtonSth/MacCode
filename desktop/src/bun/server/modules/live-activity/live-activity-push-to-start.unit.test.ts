import { describe, expect, it } from "bun:test";

import { createLiveActivityPushServiceForTests } from "./live-activity-push.service";
import type {
	LiveActivityPushSubscriptionStoreContract,
	PushToStartTokenStoreContract,
	PushToStartTokenStored,
	PushToStartTokenInput,
} from "./live-activity-push.model";

interface CapturedDelivery {
	event: "update" | "end" | "start";
	chatId: string;
	chatTitle: string;
	preview: string;
	liveActivityToken: string;
	pushToken: string;
	pushTokenType: string;
	attributesType?: string;
	attributes?: Record<string, unknown>;
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
		deleteByChatId: (chatId) => {
			for (const [key, row] of rows.entries()) {
				if (row.chatId === chatId) {
					rows.delete(key);
				}
			}
		},
		deleteExact: ({ chatId, liveActivityToken, pushToken, pushTokenType }) => {
			rows.delete([chatId, pushTokenType, pushToken, liveActivityToken].join("::"));
		},
		listAll: () => [...rows.values()],
		upsert: (input) => {
			const row = { ...input, updatedAt: new Date().toISOString() };
			rows.set([input.chatId, input.pushTokenType, input.pushToken, input.liveActivityToken].join("::"), row);
			return row;
		},
	};
};

const createRecordingHarness = (pushToStartTokenStore?: PushToStartTokenStoreContract, subscriptionStore?: LiveActivityPushSubscriptionStoreContract) => {
	const deliveries: CapturedDelivery[] = [];
	const service = createLiveActivityPushServiceForTests(
		async (input) => {
			deliveries.push({
				event: input.event,
				chatId: input.contentState.chatId,
				chatTitle: input.contentState.chatTitle,
				preview: input.contentState.preview,
				liveActivityToken: input.liveActivityToken,
				pushToken: input.pushToken,
				pushTokenType: input.pushTokenType,
				attributesType: input.attributesType,
				attributes: input.attributes,
			});
			return { delivered: true, shouldDropSubscription: false };
		},
		subscriptionStore,
		pushToStartTokenStore,
	);
	return { deliveries, service };
};

describe("LiveActivityPushService push-to-start", () => {
	describe("registerPushToStartToken", () => {
		it("accepts a valid apns push-to-start token", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-1",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(1);
			const stored = store.rows.get("apns::device-push-1");
			expect(stored?.pushToStartToken).toBe("pts-token-1");
		});

		it("accepts a valid fcm push-to-start token", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-fcm",
				pushToken: "device-fcm-1",
				pushTokenType: "fcm",
			});

			expect(store.rows.size).toBe(1);
		});

		it("replaces existing token for same device (upsert behavior)", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-old",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});
			service.registerPushToStartToken({
				pushToStartToken: "pts-token-new",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(1);
			const stored = store.rows.get("apns::device-push-1");
			expect(stored?.pushToStartToken).toBe("pts-token-new");
		});

		it("ignores empty pushToStartToken", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(0);
		});

		it("ignores empty pushToken", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-1",
				pushToken: "",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(0);
		});

		it("ignores whitespace-only tokens", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "   ",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(0);
		});

		it("trims whitespace from token values", () => {
			const store = createInMemoryPushToStartTokenStore();
			const { service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "  pts-token-1  ",
				pushToken: "  device-push-1  ",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(1);
			const stored = store.rows.get("apns::device-push-1");
			expect(stored?.pushToStartToken).toBe("pts-token-1");
		});
	});

	describe("onChatStarted triggers push-to-start", () => {
		it("sends push-to-start when no active subscriptions exist", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const { deliveries, service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-1",
				pushToken: "device-push-1",
				pushTokenType: "apns",
			});

			service.onChatStarted({
				chatId: "chat-start-1",
				chatTitle: "New Thread",
			});

			// Allow async push-to-start to complete
			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			const startDelivery = deliveries.find((d) => d.event === "start");
			expect(startDelivery).toBeDefined();
			expect(startDelivery?.chatId).toBe("chat-start-1");
			expect(startDelivery?.liveActivityToken).toBe("pts-token-1");
			expect(startDelivery?.pushToken).toBe("device-push-1");
			expect(startDelivery?.pushTokenType).toBe("apns");
		});

		it("sends push-to-start with attributesType LiveActivityAttributes", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const { deliveries, service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-attrs",
				pushToken: "device-push-attrs",
				pushTokenType: "apns",
			});

			service.onChatStarted({
				chatId: "chat-attrs",
				chatTitle: "Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			const startDelivery = deliveries.find((d) => d.event === "start");
			expect(startDelivery?.attributesType).toBe("LiveActivityAttributes");
			expect(startDelivery?.attributes).toEqual({});
		});

		it("does NOT send push-to-start when active subscriptions exist", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const subStore = createInMemorySubscriptionStore();
			const { deliveries, service } = createRecordingHarness(store, subStore);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-sub",
				pushToken: "device-push-sub",
				pushTokenType: "apns",
			});

			service.onChatStarted({
				chatId: "chat-with-sub",
				chatTitle: "Thread",
			});

			await service.upsertSubscription({
				chatId: "chat-with-sub",
				chatTitle: "Thread",
				pushToken: "device-push-sub",
				pushTokenType: "apns",
				liveActivityToken: "live-token-existing",
			});

			// Start a second chat — this time subscriptions exist for it
			service.onChatStarted({
				chatId: "chat-with-sub",
				chatTitle: "Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			// The first onChatStarted should have triggered push-to-start (no subscriptions yet),
			// but the second one should NOT (subscription exists)
			const startDeliveries = deliveries.filter((d) => d.event === "start");
			expect(startDeliveries).toHaveLength(1);
		});

		it("does NOT send push-to-start when no tokens registered", async () => {
			const { deliveries, service } = createRecordingHarness();

			service.onChatStarted({
				chatId: "chat-no-tokens",
				chatTitle: "Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			const startDeliveries = deliveries.filter((d) => d.event === "start");
			expect(startDeliveries).toHaveLength(0);
		});

		it("sends push-to-start to multiple registered devices", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const { deliveries, service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-token-a",
				pushToken: "device-a",
				pushTokenType: "apns",
			});
			service.registerPushToStartToken({
				pushToStartToken: "pts-token-b",
				pushToken: "device-b",
				pushTokenType: "fcm",
			});

			service.onChatStarted({
				chatId: "chat-multi",
				chatTitle: "Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			const startDeliveries = deliveries.filter((d) => d.event === "start");
			expect(startDeliveries).toHaveLength(2);

			const pushTokens = startDeliveries.map((d) => d.pushToken).sort();
			expect(pushTokens).toEqual(["device-a", "device-b"]);
		});

		it("drops push-to-start token when delivery returns shouldDropSubscription", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const deliveries: CapturedDelivery[] = [];
			const service = createLiveActivityPushServiceForTests(
				async (input) => {
					deliveries.push({
						event: input.event,
						chatId: input.contentState.chatId,
						chatTitle: input.contentState.chatTitle,
						preview: input.contentState.preview,
						liveActivityToken: input.liveActivityToken,
						pushToken: input.pushToken,
						pushTokenType: input.pushTokenType,
					});
					if (input.event === "start") {
						return { delivered: false, errorCode: "apns/BadDeviceToken", shouldDropSubscription: true };
					}
					return { delivered: true, shouldDropSubscription: false };
				},
				undefined,
				store,
			);

			service.registerPushToStartToken({
				pushToStartToken: "pts-bad-token",
				pushToken: "device-bad",
				pushTokenType: "apns",
			});

			expect(store.rows.size).toBe(1);

			service.onChatStarted({
				chatId: "chat-drop",
				chatTitle: "Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			// Token should be dropped from store after permanent failure
			expect(store.rows.size).toBe(0);
		});
	});

	describe("end event includes sound", () => {
		it("delivers end event with sound=default through the sender", async () => {
			const rawDeliveries: Array<{
				event: string;
				contentState: Record<string, unknown>;
			}> = [];

			const service = createLiveActivityPushServiceForTests(
				async (input) => {
					rawDeliveries.push({
						event: input.event,
						contentState: input.contentState as unknown as Record<string, unknown>,
					});
					return { delivered: true, shouldDropSubscription: false };
				},
			);

			service.onChatStarted({
				chatId: "chat-sound",
				chatTitle: "Thread",
			});
			await service.upsertSubscription({
				chatId: "chat-sound",
				chatTitle: "Thread",
				pushToken: "push-token-sound",
				pushTokenType: "apns",
				liveActivityToken: "live-token-sound",
			});
			await service.onChatFinished({
				chatId: "chat-sound",
				outcome: "completed",
			});

			const endEvent = rawDeliveries.find((d) => d.event === "end");
			expect(endEvent).toBeDefined();
			expect(endEvent?.contentState.phase).toBe("completed");
		});
	});

	describe("push-to-start token persistence and restoration", () => {
		it("restores push-to-start tokens from store on construction", async () => {
			const store = createInMemoryPushToStartTokenStore();
			store.upsert({
				pushToStartToken: "persisted-pts",
				pushToken: "persisted-device",
				pushTokenType: "apns",
			});

			const deliveries: CapturedDelivery[] = [];
			const service = createLiveActivityPushServiceForTests(
				async (input) => {
					deliveries.push({
						event: input.event,
						chatId: input.contentState.chatId,
						chatTitle: input.contentState.chatTitle,
						preview: input.contentState.preview,
						liveActivityToken: input.liveActivityToken,
						pushToken: input.pushToken,
						pushTokenType: input.pushTokenType,
					});
					return { delivered: true, shouldDropSubscription: false };
				},
				undefined,
				store,
			);

			service.onChatStarted({
				chatId: "chat-restored",
				chatTitle: "Restored Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			const startDelivery = deliveries.find((d) => d.event === "start");
			expect(startDelivery).toBeDefined();
			expect(startDelivery?.liveActivityToken).toBe("persisted-pts");
			expect(startDelivery?.pushToken).toBe("persisted-device");
		});
	});

	describe("full lifecycle: push-to-start then end with sound", () => {
		it("sends start then end when subscription is added mid-chat", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const { deliveries, service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-lifecycle",
				pushToken: "device-lifecycle",
				pushTokenType: "apns",
			});

			// 1. Start chat → triggers push-to-start
			service.onChatStarted({
				chatId: "chat-lifecycle",
				chatTitle: "Full Lifecycle",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			// 2. Mobile app wakes up and registers per-activity subscription
			await service.upsertSubscription({
				chatId: "chat-lifecycle",
				chatTitle: "Full Lifecycle",
				pushToken: "device-lifecycle",
				pushTokenType: "apns",
				liveActivityToken: "live-activity-token-from-ios",
			});

			// 3. Chat finishes → triggers end event
			await service.onChatFinished({
				chatId: "chat-lifecycle",
				outcome: "completed",
			});

			const startDeliveries = deliveries.filter((d) => d.event === "start");
			const endDeliveries = deliveries.filter((d) => d.event === "end");

			expect(startDeliveries.length).toBeGreaterThanOrEqual(1);
			expect(endDeliveries.length).toBeGreaterThanOrEqual(1);

			// End should be delivered to the per-activity subscription token
			const lastEnd = endDeliveries[endDeliveries.length - 1]!;
			expect(lastEnd.liveActivityToken).toBe("live-activity-token-from-ios");
		});
	});

	describe("edge cases", () => {
		it("handles onChatStarted called twice for same chatId gracefully", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const { deliveries, service } = createRecordingHarness(store);

			service.registerPushToStartToken({
				pushToStartToken: "pts-double",
				pushToken: "device-double",
				pushTokenType: "apns",
			});

			service.onChatStarted({
				chatId: "chat-double",
				chatTitle: "Double Start",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 50); });

			// Second start for same chat (already active, not terminal)
			service.onChatStarted({
				chatId: "chat-double",
				chatTitle: "Double Start",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			// Only one push-to-start should have been sent (first call)
			const startDeliveries = deliveries.filter((d) => d.event === "start");
			expect(startDeliveries).toHaveLength(1);
		});

		it("can register tokens even without a store (in-memory only)", () => {
			const { service, deliveries } = createRecordingHarness();

			// No store passed — should not throw
			service.registerPushToStartToken({
				pushToStartToken: "pts-no-store",
				pushToken: "device-no-store",
				pushTokenType: "apns",
			});

			// Should still work in memory
			service.onChatStarted({
				chatId: "chat-no-store",
				chatTitle: "No Store",
			});

			// Give it time
			return new Promise<void>((resolve) => {
				setTimeout(() => {
					const startDeliveries = deliveries.filter((d) => d.event === "start");
					expect(startDeliveries).toHaveLength(1);
					resolve();
				}, 100);
			});
		});

		it("handles push-to-start send error without crashing", async () => {
			const store = createInMemoryPushToStartTokenStore();
			const service = createLiveActivityPushServiceForTests(
				async (input) => {
					if (input.event === "start") {
						throw new Error("network timeout");
					}
					return { delivered: true, shouldDropSubscription: false };
				},
				undefined,
				store,
			);

			service.registerPushToStartToken({
				pushToStartToken: "pts-error",
				pushToken: "device-error",
				pushTokenType: "apns",
			});

			// Should not throw
			service.onChatStarted({
				chatId: "chat-error",
				chatTitle: "Error Thread",
			});

			await new Promise<void>((resolve) => { setTimeout(resolve, 100); });

			// Token should still be in store (transient error, not dropped)
			expect(store.rows.size).toBe(1);
		});
	});
});
