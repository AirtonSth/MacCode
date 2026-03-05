import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { ChatService } from "./chat.service";

interface RuntimeActiveThreadReader {
	listRunningChatIds: () => string[];
	stopRunningChat: (input: {
		chatId: string;
		clientId?: string;
		requestId?: string;
	}) => Promise<{
		chat: Awaited<ReturnType<ChatService["getChatById"]>>;
		state: "not_found" | "not_running" | "stale_cleared" | "stopping";
	}>;
}

export class ChatController {
	static build(
		service: ChatService,
		workspaceEvents?: WorkspaceEventsServiceContract,
		runtimeActiveThreadReader?: RuntimeActiveThreadReader,
	) {
		return new ChatController(service, workspaceEvents, runtimeActiveThreadReader).build();
	}

constructor(
		private readonly service: ChatService,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
		private readonly runtimeActiveThreadReader?: RuntimeActiveThreadReader,
	) {}

	

	build() {
		return new Elysia({ name: "chat-controller" })
			.use(withRestAuth())
			.get("/threads/active", async () => {
				const threads = await this.service.listActiveThreads();
				return { threads };
			})
			.get("/threads/active/runtime", async () => {
				const runtimeChatIds = this.runtimeActiveThreadReader?.listRunningChatIds() ?? [];
				const threads = await this.service.listActiveThreadsByIds(runtimeChatIds);
				return { threads };
			})
			.post("/chats/:id/stop", async ({ params: parameters, request, set }) => {
				if (!this.runtimeActiveThreadReader) {
					set.status = 503;
					return { error: "runtime controller unavailable" };
				}

				const metadata = readMutationRequestMetadata(request);
				const result = await this.runtimeActiveThreadReader.stopRunningChat({
					chatId: parameters.id,
					clientId: metadata.clientId ?? undefined,
					requestId: metadata.requestId ?? undefined,
				});

				if (result.state === "not_found") {
					set.status = 404;
					return { error: "chat not found" };
				}

				return {
					chat: result.chat,
					state: result.state,
					stopped: result.state === "stale_cleared" || result.state === "stopping",
				};
			})
			.get("/projects/:id/threads", async ({ params: parameters, set }) => {
				const threads = await this.service.listThreadSummariesByProjectId(parameters.id);

				if (!threads) {
					set.status = 404;

					return { error: "project not found" };
				}

				return { threads };
			})
			.get("/projects/:id/chats", async ({ params: parameters, set }) => {
				const chats = await this.service.listByProjectId(parameters.id);

				if (!chats) {
					set.status = 404;

					return { error: "project not found" };
				}

				return { chats };
			})
			.post(
				"/projects/:id/chats",
				async ({ body, params: parameters, request, set }) => {
					const title = body.title?.trim() || "New chat";
					const chat = await this.service.createChat(parameters.id, title);

					if (!chat) {
						set.status = 404;

						return { error: "project not found" };
					}

					const metadata = readMutationRequestMetadata(request);
					this.workspaceEvents?.append({
						type: "chat_created",
						payload: {
							chat,
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					set.status = 201;

				return { chat };
			},
				{
					body: t.Object({
						title: t.Optional(t.String()),
					}),
				},
			)
			.get("/chats/:id/context", async ({ params: parameters, set }) => {
				const context = await this.service.getChatContext(parameters.id);

				if (!context) {
					set.status = 404;
					return { error: "chat not found" };
				}

				return context;
			})
			.delete("/chats/:id", async ({ params: parameters, request, set }) => {
				const deleted = await this.service.deleteChat(parameters.id);

				if (!deleted) {
					set.status = 404;

					return { error: "chat not found" };
				}

				const metadata = readMutationRequestMetadata(request);
				this.workspaceEvents?.append({
					type: "chat_deleted",
					payload: {
						chatId: parameters.id,
					},
					originClientId: metadata.clientId,
					requestId: metadata.requestId,
				});

				return { deleted: true };
			});
	}
}

export const createChatController = (
	service: ChatService,
	workspaceEvents?: WorkspaceEventsServiceContract,
	runtimeActiveThreadReader?: RuntimeActiveThreadReader,
) =>
	ChatController.build(service, workspaceEvents, runtimeActiveThreadReader);
