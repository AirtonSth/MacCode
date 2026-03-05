import { expect, test } from "bun:test";

import { createLiveActivityPushServiceForTests } from "./live-activity-push.service";

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
		fcmToken: "fcm-token-1",
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
		fcmToken: "fcm-token-2",
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
		fcmToken: "fcm-token-3",
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
