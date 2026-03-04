import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { ProjectService } from "./project.service";

export class ProjectController {
	static build(service: ProjectService, workspaceEvents?: WorkspaceEventsServiceContract) {
		return new ProjectController(service, workspaceEvents).build();
	}

constructor(
		private readonly service: ProjectService,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
	) {}

	

	build() {
		return new Elysia({ name: "project-controller" })
			.use(withRestAuth())
			.get("/projects/workspaces", async () => {
				const workspaces = await this.service.listWorkspaceSummaries();

				return { workspaces };
			})
			.get("/projects", async () => {
				const projects = await this.service.listProjects();

				return { projects };
			})
			.post(
				"/projects",
				async ({ body, request, set }) => {
					const result = await this.service.createProject(body);

					if ("type" in result) {
						set.status = 400;

						return { error: "path must be an existing absolute directory" };
					}

					if (!result.created) {
						set.status = 200;
					}

					if (result.created) {
						set.status = 201;
					}

					const metadata = readMutationRequestMetadata(request);
					this.workspaceEvents?.append({
						type: result.created ? "project_created" : "project_updated",
						payload: {
							project: result.project,
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					return {
						created: result.created,
						project: result.project,
					};
				},
				{
					body: t.Object({
						name: t.Optional(t.String()),
						path: t.String(),
					}),
				},
			)
			.patch(
				"/projects/:id",
				async ({ body, params: parameters, request, set }) => {
					const project = await this.service.setFavorite(parameters.id, body.isFavorite);

					if (!project) {
						set.status = 404;

						return { error: "project not found" };
					}

					const metadata = readMutationRequestMetadata(request);
					this.workspaceEvents?.append({
						type: "project_updated",
						payload: {
							project,
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					return { project };
				},
				{
					body: t.Object({
						isFavorite: t.Boolean(),
					}),
				},
			)
			.delete("/projects/:id", async ({ params: parameters, request, set }) => {
				const deleted = await this.service.deleteProject(parameters.id);

				if (!deleted) {
					set.status = 404;

					return { error: "project not found" };
				}

				const metadata = readMutationRequestMetadata(request);
				this.workspaceEvents?.append({
					type: "project_deleted",
					payload: {
						projectId: parameters.id,
					},
					originClientId: metadata.clientId,
					requestId: metadata.requestId,
				});

				return { deleted: true };
			});
	}
}

export const createProjectController = (service: ProjectService, workspaceEvents?: WorkspaceEventsServiceContract) =>
	ProjectController.build(service, workspaceEvents);
