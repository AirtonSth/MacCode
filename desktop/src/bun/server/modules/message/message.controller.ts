import { Elysia } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { MessageService } from "./message.service";

export class MessageController {
	static build(service: MessageService) {
		return new MessageController(service).build();
	}

	constructor(private readonly service: MessageService) {}

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
			})
			.get("/chats/:id/stream-events", async ({ params: parameters, query, set }) => {
				const afterIdRaw = query.afterId;
				const limitRaw = query.limit;
				const afterId = typeof afterIdRaw === "string"
					? Number.parseInt(afterIdRaw, 10)
					: typeof afterIdRaw === "number"
						? afterIdRaw
						: 0;
				const limit = typeof limitRaw === "string"
					? Number.parseInt(limitRaw, 10)
					: typeof limitRaw === "number"
						? limitRaw
						: 500;
				const boundedLimit = Number.isFinite(limit) && limit > 0
					? Math.min(Math.floor(limit), 2000)
					: 500;
				const result = await this.service.listStreamEventsByChatId(parameters.id, {
					afterId: Number.isFinite(afterId) && afterId > 0 ? afterId : 0,
					limit: boundedLimit,
				});

				if (!result.chatExists) {
					set.status = 404;
					return { error: "chat not found" };
				}

				return {
					events: result.events,
					hasMore: result.hasMore,
					nextAfterId: result.nextAfterId,
				};
			});
	}
}

export const createMessageController = (service: MessageService) => MessageController.build(service);
