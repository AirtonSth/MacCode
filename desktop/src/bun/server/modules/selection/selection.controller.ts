import { Elysia, t } from "elysia";

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

					const selection = await this.service.saveWorkspaceSelection(body);
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
					}),
				},
			);
	}
}

export const createSelectionController = (
	service: WorkspaceSelectionService,
	workspaceEvents?: WorkspaceEventsServiceContract,
) => SelectionController.build(service, workspaceEvents);
