import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { ChatProvider } from "../../shared/core/server.types";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { LiveActivityPushSubscriptionInput, PushToStartTokenInput } from "../live-activity/live-activity-push.model";
import type { ChatService } from "./chat.service";

const VALID_CHAT_PROVIDERS = new Set<string>(["codex", "claude"]);

const parseChatProvider = (value: unknown): ChatProvider | null => {
	if (typeof value !== "string") {
		return null;
	}

	return VALID_CHAT_PROVIDERS.has(value) ? (value as ChatProvider) : null;
};

const LIVE_ACTIVITY_SUBSCRIPTION_LOG_PREFIX = "[live-activity-subscription]";

const toTokenPreview = (value: string): string => {
	const normalized = value.trim();
	if (normalized.length <= 12) {
		return normalized;
	}

	return `${normalized.slice(0, 6)}...${normalized.slice(-4)}`;
};

const logLiveActivitySubscription = (message: string, meta: Record<string, unknown>): void => {
	console.info(`${LIVE_ACTIVITY_SUBSCRIPTION_LOG_PREFIX} ${message}`, meta);
};

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

interface LiveActivitySubscriptionReader {
	getLiveActivityPushIsEnabled: () => boolean;
	getLiveActivityPushSupportedTokenTypes: () => Promise<ReadonlySet<"apns" | "fcm">>;
	upsertLiveActivityPushSubscription: (input: LiveActivityPushSubscriptionInput) => Promise<boolean>;
	registerPushToStartToken: (input: PushToStartTokenInput) => Promise<void>;
}

export class ChatController {
	static build(
		service: ChatService,
		workspaceEvents?: WorkspaceEventsServiceContract,
		runtimeActiveThreadReader?: RuntimeActiveThreadReader,
		liveActivitySubscriptionReader?: LiveActivitySubscriptionReader,
	) {
		return new ChatController(service, workspaceEvents, runtimeActiveThreadReader, liveActivitySubscriptionReader).build();
	}

	constructor(
		private readonly service: ChatService,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
		private readonly runtimeActiveThreadReader?: RuntimeActiveThreadReader,
		private readonly liveActivitySubscriptionReader?: LiveActivitySubscriptionReader,
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
			.post(
				"/chats/:id/live-activity/subscription",
				async ({ body, params: parameters, set }) => {
					const liveActivitySubscriptionReader = this.liveActivitySubscriptionReader;
					const legacyFcmToken = body.fcmToken?.trim() || "";
					const pushToken = body.pushToken?.trim() || legacyFcmToken;
					const pushTokenType = body.pushTokenType ?? (legacyFcmToken.length > 0 ? "fcm" : null);
					const liveActivityToken = body.liveActivityToken.trim();
					const supportedPushTokenTypes = liveActivitySubscriptionReader
						? await liveActivitySubscriptionReader.getLiveActivityPushSupportedTokenTypes()
						: new Set<"apns" | "fcm">();
					const enabled = (liveActivitySubscriptionReader?.getLiveActivityPushIsEnabled() ?? false)
						&& supportedPushTokenTypes.size > 0;
					logLiveActivitySubscription("request received", {
						chatId: parameters.id,
						enabled,
						liveActivityToken: toTokenPreview(liveActivityToken),
						pushToken: toTokenPreview(pushToken),
						pushTokenType,
						supportedPushTokenTypes: Array.from(supportedPushTokenTypes),
					});
					if (
						pushToken.length === 0
						|| liveActivityToken.length === 0
						|| (pushTokenType !== "apns" && pushTokenType !== "fcm")
					) {
						logLiveActivitySubscription("request rejected (invalid payload)", {
							chatId: parameters.id,
							enabled,
							liveActivityToken: toTokenPreview(liveActivityToken),
							pushToken: toTokenPreview(pushToken),
							pushTokenType,
						});
						set.status = 400;
						return {
							error: "invalid live activity subscription payload",
						};
					}

					const chat = await this.service.getChatById(parameters.id);
					if (!chat) {
						logLiveActivitySubscription("request rejected (chat not found)", {
							chatId: parameters.id,
							enabled,
							liveActivityToken: toTokenPreview(liveActivityToken),
							pushToken: toTokenPreview(pushToken),
							pushTokenType,
						});
						set.status = 404;
						return { error: "chat not found" };
					}

					if (!liveActivitySubscriptionReader || !enabled) {
						logLiveActivitySubscription("request completed", {
							chatId: parameters.id,
							enabled,
							liveActivityToken: toTokenPreview(liveActivityToken),
							pushToken: toTokenPreview(pushToken),
							pushTokenType,
							supportedPushTokenTypes: Array.from(supportedPushTokenTypes),
							subscribed: false,
						});
						return {
							enabled: false,
							subscribed: false,
						};
					}

					if (!supportedPushTokenTypes.has(pushTokenType)) {
						logLiveActivitySubscription("request completed (unsupported push token type)", {
							chatId: parameters.id,
							enabled,
							liveActivityToken: toTokenPreview(liveActivityToken),
							pushToken: toTokenPreview(pushToken),
							pushTokenType,
							supportedPushTokenTypes: Array.from(supportedPushTokenTypes),
							subscribed: false,
						});
						return {
							enabled: false,
							subscribed: false,
						};
					}

					const subscribed = await liveActivitySubscriptionReader.upsertLiveActivityPushSubscription({
						chatId: parameters.id,
						chatTitle: body.chatTitle?.trim() || chat.title,
						pushToken,
						pushTokenType,
						liveActivityToken,
					});
					logLiveActivitySubscription("request completed", {
						chatId: parameters.id,
						enabled,
						liveActivityToken: toTokenPreview(liveActivityToken),
						pushToken: toTokenPreview(pushToken),
						pushTokenType,
						supportedPushTokenTypes: Array.from(supportedPushTokenTypes),
						subscribed,
					});

					return {
						enabled: true,
						subscribed,
					};
				},
				{
					body: t.Object({
						chatTitle: t.Optional(t.String()),
						fcmToken: t.Optional(t.String()),
						pushToken: t.Optional(t.String()),
						pushTokenType: t.Optional(t.Union([t.Literal("apns"), t.Literal("fcm")])),
						liveActivityToken: t.String(),
					}),
				},
			)
			.post(
				"/live-activity/push-to-start-token",
				async ({ body, set }) => {
					const liveActivitySubscriptionReader = this.liveActivitySubscriptionReader;
					const pushToStartToken = body.pushToStartToken?.trim() || "";
					const pushToken = body.pushToken?.trim() || "";
					const pushTokenType = body.pushTokenType;
					const supportedPushTokenTypes = liveActivitySubscriptionReader
						? await liveActivitySubscriptionReader.getLiveActivityPushSupportedTokenTypes()
						: new Set<"apns" | "fcm">();
					const enabled = (liveActivitySubscriptionReader?.getLiveActivityPushIsEnabled() ?? false)
						&& supportedPushTokenTypes.size > 0;

					if (
						pushToStartToken.length === 0
						|| pushToken.length === 0
						|| (pushTokenType !== "apns" && pushTokenType !== "fcm")
					) {
						set.status = 400;
						return { error: "invalid push-to-start token payload" };
					}

					if (!liveActivitySubscriptionReader || !enabled) {
						return { enabled: false, registered: false };
					}

					if (!supportedPushTokenTypes.has(pushTokenType)) {
						return { enabled: false, registered: false };
					}

					await liveActivitySubscriptionReader.registerPushToStartToken({
						pushToStartToken,
						pushToken,
						pushTokenType,
					});

					logLiveActivitySubscription("push-to-start token registered", {
						enabled,
						pushToStartToken: toTokenPreview(pushToStartToken),
						pushToken: toTokenPreview(pushToken),
						pushTokenType,
					});

					return { enabled: true, registered: true };
				},
				{
					body: t.Object({
						pushToStartToken: t.String(),
						pushToken: t.String(),
						pushTokenType: t.Union([t.Literal("apns"), t.Literal("fcm")]),
					}),
				},
			)
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
					const provider = body.provider ? parseChatProvider(body.provider) : undefined;
					if (body.provider && provider === null) {
						set.status = 400;
						return { error: "invalid provider" };
					}
					const chat = await this.service.createChat(parameters.id, title, provider ?? undefined);

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
						provider: t.Optional(t.String()),
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
	liveActivitySubscriptionReader?: LiveActivitySubscriptionReader,
) =>
	ChatController.build(service, workspaceEvents, runtimeActiveThreadReader, liveActivitySubscriptionReader);
