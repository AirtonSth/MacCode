import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { ProjectService } from "./project.service";

export class ProjectController {
	static build(service: ProjectService) {
		return new ProjectController(service).build();
	}

constructor(private readonly service: ProjectService) {}

	

	build() {
		return new Elysia({ name: "project-controller" })
			.use(withRestAuth())
			.get("/projects", async () => {
				const projects = await this.service.listProjects();

				return { projects };
			})
			.post(
				"/projects",
				async ({ body, set }) => {
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
				async ({ body, params: parameters, set }) => {
					const project = await this.service.setFavorite(parameters.id, body.isFavorite);

					if (!project) {
						set.status = 404;

						return { error: "project not found" };
					}

					return { project };
				},
				{
					body: t.Object({
						isFavorite: t.Boolean(),
					}),
				},
			)
			.delete("/projects/:id", async ({ params: parameters, set }) => {
				const deleted = await this.service.deleteProject(parameters.id);

				if (!deleted) {
					set.status = 404;

					return { error: "project not found" };
				}

				return { deleted: true };
			});
	}
}

export const createProjectController = (service: ProjectService) => ProjectController.build(service);
