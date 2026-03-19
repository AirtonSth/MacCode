import { Elysia, t } from "elysia";

import { parseCodexPermissionMode } from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort } from "../../../../shared/codex-model-config";
import type { ChatProvider } from "../../shared/core/server.types";
import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { ChatServiceContract } from "../chat/chat.service";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { WorkspaceSelectionService } from "./selection.service";

const VALID_PROVIDERS = new Set<string>(["codex", "claude"]);

const parseSelectedProvider = (value: unknown): ChatProvider | null => {
	if (value === null || value === undefined) {
		return null;
	}

	if (typeof value !== "string") {
		return null;
	}

	return VALID_PROVIDERS.has(value) ? (value as ChatProvider) : null;
};

export class SelectionController {
	static build(
		service: WorkspaceSelectionService,
		chatService: ChatServiceContract,
		workspaceEvents?: WorkspaceEventsServiceContract,
	) {
		return new SelectionController(service, chatService, workspaceEvents).build();
	}

	constructor(
		private readonly service: WorkspaceSelectionService,
		private readonly chatService: ChatServiceContract,
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
						const permissionMode =
							body.permissionMode === undefined
								? current.permissionMode
								: parseCodexPermissionMode(body.permissionMode);
						if (permissionMode === null) {
							set.status = 400;

							return { error: "invalid permissionMode" };
						}

						const selectedModel =
							body.selectedModel === undefined
								? current.selectedModel
								: typeof body.selectedModel === "string" && body.selectedModel.trim().length > 0
									? body.selectedModel.trim()
									: null;

						const selectedReasoningEffort =
							body.selectedReasoningEffort === undefined
								? current.selectedReasoningEffort
								: body.selectedReasoningEffort === null || body.selectedReasoningEffort === ""
									? null
									: parseCodexReasoningEffort(body.selectedReasoningEffort);
						if (selectedReasoningEffort === null && body.selectedReasoningEffort !== undefined && body.selectedReasoningEffort !== null && body.selectedReasoningEffort !== "") {
							set.status = 400;

							return { error: "invalid selectedReasoningEffort" };
						}

						const selectedProvider =
							body.selectedProvider === undefined
								? current.selectedProvider
								: body.selectedProvider === null
									? null
									: parseSelectedProvider(body.selectedProvider);
						if (body.selectedProvider !== undefined && body.selectedProvider !== null && selectedProvider === null) {
							set.status = 400;

							return { error: "invalid selectedProvider" };
						}

						const selectedChat =
							body.selectedChatId === null
								? null
								: await this.chatService.getChatById(body.selectedChatId);
						const lockedChatProvider =
							selectedChat?.provider === "codex" || selectedChat?.provider === "claude"
								? selectedChat.provider
								: null;
						if (
							lockedChatProvider
							&& body.selectedProvider !== undefined
							&& selectedProvider !== null
							&& selectedProvider !== lockedChatProvider
						) {
							set.status = 400;

							return { error: "cannot change provider after thread creation" };
						}

						const selection = await this.service.saveWorkspaceSelection({
							selectedChatId: body.selectedChatId,
							selectedProjectId: body.selectedProjectId,
							permissionMode,
							selectedModel,
							selectedProvider: lockedChatProvider ?? selectedProvider ?? null,
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
	workspaceEvents?: WorkspaceEventsServiceContract,
) => SelectionController.build(service, chatService, workspaceEvents);
