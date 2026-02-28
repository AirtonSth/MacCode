import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { WorkspaceSelectionService } from "./selection.service";

export class SelectionController {
	static build(service: WorkspaceSelectionService) {
		return new SelectionController(service).build();
	}

	constructor(private readonly service: WorkspaceSelectionService) {}

	build() {
		return new Elysia({ name: "selection-controller" })
			.use(withRestAuth())
			.get("/selection", async () => {
				const selection = await this.service.getWorkspaceSelection();

				return selection;
			})
			.patch(
				"/selection",
				async ({ body, set }) => {
					if (body.selectedProjectId === null && body.selectedChatId !== null) {
						set.status = 400;

						return { error: "selectedChatId requires a selectedProjectId" };
					}

					const selection = await this.service.saveWorkspaceSelection(body);
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

export const createSelectionController = (service: WorkspaceSelectionService) => SelectionController.build(service);
