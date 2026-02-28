import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { ChatService } from "./chat.service";

export const createChatController = (service: ChatService) =>
	new Elysia({ name: "chat-controller" })
		.use(withRestAuth())
		.get("/projects/:id/chats", async ({ params: parameters, set }) => {
			const chats = await service.listByProjectId(parameters.id);

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
				const chat = await service.createChat(parameters.id, title);

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
		);
