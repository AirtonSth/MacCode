import { Elysia } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { MessageService } from "./message.service";

export class MessageController {
	constructor(private readonly service: MessageService) {}

	static build(service: MessageService) {
		return new MessageController(service).build();
	}

	build() {
		return new Elysia({ name: "message-controller" })
			.use(withRestAuth())
			.get("/chats/:id/messages", async ({ params: parameters, set }) => {
				const result = await this.service.listByChatId(parameters.id);

				if (!result.chatExists) {
					set.status = 404;

					return { error: "chat not found" };
				}

				return { messages: result.messages };
			});
	}
}

export const createMessageController = (service: MessageService) => MessageController.build(service);
