import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { ChatServiceContract } from "../chat/chat.service";
import type { MessageServiceContract } from "../message/message.service";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import { normalizeSelectionPreferences } from "./selection-preferences";
import type { WorkspaceSelectionService } from "./selection.service";

const normalizeProviderThreadId = (value: string | null | undefined): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
};

const isPlaceholderThreadTitle = (value: string | null | undefined): boolean => {
	if (typeof value !== "string") {
		return false;
	}

	const normalized = value.trim().toLowerCase();
	return normalized === "new thread" || normalized === "new chat";
};

const shouldLockProviderSelection = (input: {
	hasStreamingText: boolean;
	hasStreamingTurn: boolean;
	messageCount: number;
	providerThreadId: string | null;
	threadTitle: string | null;
	turnCount: number;
}): boolean => {
	return Boolean(
		normalizeProviderThreadId(input.providerThreadId)
		|| input.messageCount > 0
		|| input.turnCount > 0
		|| input.hasStreamingText
		|| input.hasStreamingTurn
		|| (
			typeof input.threadTitle === "string"
			&& input.threadTitle.trim().length > 0
			&& !isPlaceholderThreadTitle(input.threadTitle)
		)
	);
};

export class SelectionController {
	static build(
		service: WorkspaceSelectionService,
		chatService: ChatServiceContract,
		messageService: MessageServiceContract,
		workspaceEvents?: WorkspaceEventsServiceContract,
	) {
		return new SelectionController(service, chatService, messageService, workspaceEvents).build();
	}

	constructor(
		private readonly service: WorkspaceSelectionService,
		private readonly chatService: ChatServiceContract,
		private readonly messageService: MessageServiceContract,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
	) {}

	build() {
		return new Elysia({ name: "selection-controller" })
			.use(withRestAuth())
			.get("/selection", async () => {
				const selection = await this.service.getWorkspaceSelection();

				return selection;
			})
			.patch(
				"/selection",
				async ({ body, request, set }) => {
					if (body.selectedProjectId === null && body.selectedChatId !== null) {
						set.status = 400;

						return { error: "selectedChatId requires a selectedProjectId" };
					}

					const current = await this.service.getWorkspaceSelection();

					const selectedChat =
						body.selectedChatId === null
							? null
							: await this.chatService.getChatById(body.selectedChatId);
					const selectedChatMessages =
						body.selectedChatId === null
							? null
							: await this.messageService.listByChatId(body.selectedChatId);
					const lockedChatProvider =
						selectedChat
						&& shouldLockProviderSelection({
							hasStreamingText: selectedChat.isActive,
							hasStreamingTurn: selectedChat.isActive,
							messageCount: selectedChatMessages?.messages.length ?? 0,
							providerThreadId: selectedChat.providerThreadId ?? null,
							threadTitle: selectedChat.title,
							turnCount: selectedChatMessages?.turns.length ?? 0,
						})
							? selectedChat.provider
							: null;

					const normalizedPreferences = normalizeSelectionPreferences({
						current,
						lockedProvider: lockedChatProvider,
						payload: body,
					});
					if (!normalizedPreferences.ok) {
						set.status = 400;

						return { error: normalizedPreferences.error };
					}
					if (
						lockedChatProvider
						&& body.selectedProvider !== undefined
						&& body.selectedProvider !== null
						&& body.selectedProvider !== lockedChatProvider
					) {
						set.status = 400;

						return { error: "cannot change provider after thread creation" };
					}

					const {
						permissionMode,
						selectedModel,
						selectedProvider,
						selectedReasoningEffort,
					} = normalizedPreferences.value;

					const selection = await this.service.saveWorkspaceSelection({
						selectedChatId: body.selectedChatId,
						selectedProjectId: body.selectedProjectId,
						permissionMode,
						selectedModel,
						selectedProvider,
						selectedReasoningEffort,
					});
					const metadata = readMutationRequestMetadata(request);

					this.workspaceEvents?.append({
						type: "selection_updated",
						payload: {
							selection,
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					return selection;
				},
				{
					body: t.Object({
						selectedChatId: t.Nullable(t.String()),
						selectedProjectId: t.Nullable(t.String()),
						permissionMode: t.Optional(t.String()),
						selectedModel: t.Optional(t.Nullable(t.String())),
						selectedProvider: t.Optional(t.Nullable(t.String())),
						selectedReasoningEffort: t.Optional(t.Nullable(t.String())),
					}),
				},
			);
	}
}

export const createSelectionController = (
	service: WorkspaceSelectionService,
	chatService: ChatServiceContract,
	messageService: MessageServiceContract,
	workspaceEvents?: WorkspaceEventsServiceContract,
) => SelectionController.build(service, chatService, messageService, workspaceEvents);
