import { expect, test } from "bun:test";

import type { ChatDTO, ChatStatus } from "../../types";
import type { ProjectRepository } from "../project/project.repository";
import type { ChatRepository } from "./chat.repository";
import { ChatService } from "./chat.service";

const createChat = (overrides: Partial<ChatDTO> = {}): ChatDTO => ({
	diffAdded: 0,
	diffRemoved: 0,
	id: "chat-id",
	isActive: false,
	projectId: "project-id",
	provider: "fake",
	status: "pending",
	title: "Chat",
	updatedAt: new Date().toISOString(),
	...overrides,
});

test("ChatService.createChat returns null when project does not exist", async () => {
	const service = new ChatService(
		{ createChat: () => createChat(), findChatById: () => null, getChatsByProjectId: () => [] } as unknown as ChatRepository,
		{ findProjectById: () => null } as unknown as ProjectRepository,
	);

	const result = await service.createChat("missing-project", "Hello");

	expect(result).toBeNull();
});

test("ChatService.listByProjectId returns results only for an existing project", async () => {
	const service = new ChatService(
		{ findChatById: () => null, getChatsByProjectId: () => [] } as unknown as ChatRepository,
		{
			findProjectById: (id: string) =>
				id === "existing-project"
					? { createdAt: "", id: "existing-project", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }
					: null,
		} as unknown as ProjectRepository,
	);

	const found = await service.listByProjectId("existing-project");
	const missing = await service.listByProjectId("missing-project");

	expect(found).toEqual([]);
	expect(missing).toBeNull();
});

test("ChatService.updateChat merges existing state", async () => {
	const chat = createChat({ diffAdded: 2, diffRemoved: 1, status: "running" });

	let capturedUpdate: {
		diffAdded?: number;
		diffRemoved?: number;
		isActive?: boolean;
		status?: ChatStatus;
	} | undefined;

	const service = new ChatService(
		{
			findChatById: () => chat,
			getChatsByProjectId: () => [chat],

			updateChat: (_chatId: string, value: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved" | "isActive">>) => {
				capturedUpdate = {
					diffAdded: value.diffAdded,
					diffRemoved: value.diffRemoved,
					isActive: value.isActive,
					status: value.status,
				};

				return {
					...chat,
					...value,
				};
			},
		} as unknown as ChatRepository,
		{ findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }) } as unknown as ProjectRepository,
	);

	const updatedChat = await service.updateChat(chat.id, {
		status: "completed",
	});

	expect(capturedUpdate).toEqual({
		diffAdded: 2,
		diffRemoved: 1,
		isActive: false,
		status: "completed" as ChatStatus,
	});
	expect(updatedChat).toEqual(
		expect.objectContaining({
			diffAdded: 2,
			diffRemoved: 1,
			status: "completed",
		}),
	);
});
