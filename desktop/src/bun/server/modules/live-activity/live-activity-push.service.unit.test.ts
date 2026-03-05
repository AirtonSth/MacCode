import { expect, test } from "bun:test";

import { buildLiveActivityApnsHeaders, createLiveActivityPushServiceForTests } from "./live-activity-push.service";
import type { LiveActivityPushSubscriptionStoreContract } from "./live-activity-push.model";

interface CapturedDelivery {
	event: "update" | "end";
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
	expect(endDelivery?.preview.length).toBeLessThanOrEqual(30);
	expect(endDelivery?.preview.endsWith("...")).toBe(true);
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
	expect(endDelivery?.preview.length).toBeLessThanOrEqual(30);
	expect(endDelivery?.preview).toMatch(ALLOWED_TEXT_PATTERN);
	expect(endDelivery?.preview).not.toContain("`");
	expect(endDelivery?.preview).not.toContain("{");
	expect(endDelivery?.preview).not.toContain("}");
	expect(endDelivery?.preview).not.toContain("<");
	expect(endDelivery?.preview).not.toContain(">");
	expect(endDelivery?.preview).not.toContain("\\");
});

test("buildLiveActivityApnsHeaders uses low priority for updates and high priority for end", () => {
	const updateHeaders = buildLiveActivityApnsHeaders({
		event: "update",
		expirationSeconds: 123,
		topic: "com.example.app.push-type.liveactivity",
	});
	const endHeaders = buildLiveActivityApnsHeaders({
		event: "end",
		expirationSeconds: 456,
		topic: "com.example.app.push-type.liveactivity",
	});

	expect(updateHeaders["apns-priority"]).toBe("5");
	expect(endHeaders["apns-priority"]).toBe("10");
	expect(updateHeaders["apns-push-type"]).toBe("liveactivity");
	expect(updateHeaders["apns-topic"]).toBe("com.example.app.push-type.liveactivity");
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
	const deliveryEvents: Array<"update" | "end"> = [];
	const sender = async (input: { event: "update" | "end" }) => {
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
