/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { showThreadCompletionDesktopNotification } from "./thread-completion-notification";

const originalNotification = globalThis.Notification;

describe("thread completion desktop notification", () => {
	beforeEach(() => {
		let permission: NotificationPermission = "default";
		const notificationMock = mock((_title: string, _options?: NotificationOptions) => undefined) as unknown as typeof Notification;
		Object.defineProperty(notificationMock, "permission", {
			get: () => permission,
		});
		Object.defineProperty(notificationMock, "requestPermission", {
			value: mock(async () => {
				permission = "granted";
				return permission;
			}),
		});
		globalThis.Notification = notificationMock;
	});

	afterEach(() => {
		globalThis.Notification = originalNotification;
	});

	test("shows a desktop notification for a completed thread", async () => {
		const shown = await showThreadCompletionDesktopNotification({
			status: "completed",
			title: "Build Thread",
		});

		expect(shown).toBe(true);
		expect((globalThis.Notification as unknown as ReturnType<typeof mock>).mock.calls[0]).toEqual([
			"Thread finished",
			{
				body: "Build Thread response is ready.",
			},
		]);
	});

	test("does not show a desktop notification when permission is denied", async () => {
		const deniedNotification = mock((_title: string, _options?: NotificationOptions) => undefined) as unknown as typeof Notification;
		Object.defineProperty(deniedNotification, "permission", {
			get: () => "denied",
		});
		Object.defineProperty(deniedNotification, "requestPermission", {
			value: mock(async () => "denied" as const),
		});
		globalThis.Notification = deniedNotification;

		const shown = await showThreadCompletionDesktopNotification({
			status: "failed",
			title: "Build Thread",
		});

		expect(shown).toBe(false);
	});
});
