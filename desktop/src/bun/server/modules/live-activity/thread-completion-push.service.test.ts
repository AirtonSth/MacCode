/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import { ThreadCompletionPushService } from "./thread-completion-push.service";

describe("ThreadCompletionPushService", () => {
	test("sends a push alert when a subscribed thread completes", async () => {
		const deliveries: Array<{ body: string; title: string }> = [];
		const service = new ThreadCompletionPushService(async (input) => {
			deliveries.push({
				body: input.body,
				title: input.title,
			});
			return {
				delivered: true,
				shouldDropSubscription: false,
			};
		});

		await service.upsertSubscription({
			chatId: "chat-1",
			chatTitle: "Build Thread",
			enabled: true,
			pushToken: "device-token",
			pushTokenType: "fcm",
		});
		await service.onChatFinished({
			chatId: "chat-1",
			chatTitle: "Build Thread",
			outcome: "completed",
		});

		expect(deliveries).toEqual([{
			body: "Build Thread response is ready.",
			title: "Thread finished",
		}]);
	});

	test("removes a subscription when the sender marks it as permanently invalid", async () => {
		const rows = new Map<string, {
			chatId: string;
			pushToken: string;
			pushTokenType: "apns" | "fcm";
			updatedAt: string;
			chatTitle?: string;
		}>();
		const store = {
			deleteExact: (input: { chatId: string; pushToken: string; pushTokenType: "apns" | "fcm" }) => {
				rows.delete(`${input.chatId}::${input.pushTokenType}::${input.pushToken}`);
			},
			listAll: () => [...rows.values()],
			upsert: (input: { chatId: string; pushToken: string; pushTokenType: "apns" | "fcm"; chatTitle?: string }) => {
				const stored = {
					...input,
					updatedAt: new Date().toISOString(),
				};
				rows.set(`${input.chatId}::${input.pushTokenType}::${input.pushToken}`, stored);
				return stored;
			},
		};
		const service = new ThreadCompletionPushService(async () => ({
			delivered: false,
			errorCode: "messaging/registration-token-not-registered",
			shouldDropSubscription: true,
		}), store);

		await service.upsertSubscription({
			chatId: "chat-1",
			enabled: true,
			pushToken: "device-token",
			pushTokenType: "fcm",
		});
		await service.onChatFinished({
			chatId: "chat-1",
			outcome: "failed",
		});

		expect(rows.size).toBe(0);
	});
});
