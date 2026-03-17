/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import { resolveTrackedLiveActivityChats } from "./live-activity-tracking";

describe("resolveTrackedLiveActivityChats", () => {
	test("tracks all active threads and deduplicates the selected running chat", () => {
		expect(resolveTrackedLiveActivityChats({
			activeThreads: [
				{
					id: "chat-a",
					projectId: "project-1",
					projectName: "Workspace",
					title: "Thread A",
					updatedAt: "2026-03-17T10:00:00.000Z",
				},
				{
					id: "chat-b",
					projectId: "project-2",
					projectName: "Workspace 2",
					title: "Thread B",
					updatedAt: "2026-03-17T10:01:00.000Z",
				},
			],
			selectedChat: {
				id: "chat-b",
				isActive: true,
				status: "running",
				title: "Thread B (selected)",
			},
			selectedChatId: "chat-b",
		})).toEqual([
			{
				chatId: "chat-a",
				chatTitle: "Thread A",
			},
			{
				chatId: "chat-b",
				chatTitle: "Thread B (selected)",
			},
		]);
	});

	test("tracks the selected running chat even before active threads refresh", () => {
		expect(resolveTrackedLiveActivityChats({
			activeThreads: [],
			selectedChat: {
				id: "chat-selected",
				isActive: true,
				status: "running",
				title: "Selected chat",
			},
			selectedChatId: "chat-selected",
		})).toEqual([
			{
				chatId: "chat-selected",
				chatTitle: "Selected chat",
			},
		]);
	});

	test("does not track a selected chat that already finished", () => {
		expect(resolveTrackedLiveActivityChats({
			activeThreads: [],
			selectedChat: {
				id: "chat-done",
				isActive: false,
				status: "completed",
				title: "Done",
			},
			selectedChatId: "chat-done",
		})).toEqual([]);
	});
});
