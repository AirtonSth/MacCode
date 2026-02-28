import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { ChatService } from "./chat.service";

export class ChatController {
	static build(service: ChatService) {
		return new ChatController(service).build();
	}

constructor(private readonly service: ChatService) {}

	

	build() {
		return new Elysia({ name: "chat-controller" })
			.use(withRestAuth())
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
				async ({ body, params: parameters, set }) => {
					const title = body.title?.trim() || "Novo chat";
					const chat = await this.service.createChat(parameters.id, title);

					if (!chat) {
						set.status = 404;

						return { error: "project not found" };
					}

					set.status = 201;

					return { chat };
				},
				{
					body: t.Object({
						title: t.Optional(t.String()),
					}),
				},
			)
			.delete("/chats/:id", async ({ params: parameters, set }) => {
				const deleted = await this.service.deleteChat(parameters.id);

				if (!deleted) {
					set.status = 404;

					return { error: "chat not found" };
				}

				return { deleted: true };
			});
	}
}

export const createChatController = (service: ChatService) => ChatController.build(service);
