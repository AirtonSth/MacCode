import { Elysia, t } from "elysia";

import { parseCodexPermissionMode } from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort } from "../../../../shared/codex-model-config";
import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { WorkspaceSelectionService } from "./selection.service";

export class SelectionController {
	static build(service: WorkspaceSelectionService, workspaceEvents?: WorkspaceEventsServiceContract) {
		return new SelectionController(service, workspaceEvents).build();
	}

	constructor(
		private readonly service: WorkspaceSelectionService,
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

						const selection = await this.service.saveWorkspaceSelection({
							selectedChatId: body.selectedChatId,
							selectedProjectId: body.selectedProjectId,
							permissionMode,
							selectedModel,
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
							selectedReasoningEffort: t.Optional(t.Nullable(t.String())),
						}),
					},
				);
	}
}

export const createSelectionController = (
	service: WorkspaceSelectionService,
	workspaceEvents?: WorkspaceEventsServiceContract,
) => SelectionController.build(service, workspaceEvents);
