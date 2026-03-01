import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { GitError } from "./git.model";
import type { GitService } from "./git.service";

export class GitController {
	private static isGitError(value: unknown): value is GitError {
		return (
			typeof value === "object" &&
			value !== null &&
			"type" in value &&
			typeof (value as { type?: unknown }).type === "string"
		);
	}

	static build(service: GitService) {
		return new GitController(service).build();
	}

	constructor(private readonly service: GitService) {}

	private static errorStatusCode(error: GitError): number {
		switch (error.type) {
			case "project_not_found":
				return 404;
			case "not_git_repository":
			case "validation_error":
				return 400;
			case "command_failed":
			default:
				return 500;
		}
	}

	private static errorMessage(error: GitError): string {
		switch (error.type) {
			case "project_not_found":
				return "project not found";
			case "not_git_repository":
				return "project is not a git repository";
			case "validation_error":
				return error.message;
			case "command_failed":
			default:
				return error.message;
		}
	}

	build() {
		return new Elysia({ name: "git-controller" })
			.use(withRestAuth())
			.get("/projects/:id/git/status", async ({ params: parameters, set }) => {
				const result = await this.service.getStatus(parameters.id);
				if (GitController.isGitError(result)) {
					set.status = GitController.errorStatusCode(result);
					return { error: GitController.errorMessage(result) };
				}

				return result;
			})
			.get("/projects/:id/git/branches", async ({ params: parameters, set }) => {
				const result = await this.service.listBranches(parameters.id);
				if (GitController.isGitError(result)) {
					set.status = GitController.errorStatusCode(result);
					return { error: GitController.errorMessage(result) };
				}

				return result;
			})
			.post(
				"/projects/:id/git/branches/checkout",
				async ({ body, params: parameters, set }) => {
					const result = await this.service.checkoutBranch(parameters.id, body);
					if (GitController.isGitError(result)) {
						set.status = GitController.errorStatusCode(result);
						return { error: GitController.errorMessage(result) };
					}

					return {
						branch: result,
						switched: true,
					};
				},
				{
					body: t.Object({
						branch: t.String(),
					}),
				},
			)
			.post(
				"/projects/:id/git/branches/create",
				async ({ body, params: parameters, set }) => {
					const result = await this.service.createBranch(parameters.id, {
						name: body.name.trim(),
					});
					if (GitController.isGitError(result)) {
						set.status = GitController.errorStatusCode(result);
						return { error: GitController.errorMessage(result) };
					}

					return {
						branch: result,
						created: true,
					};
				},
				{
					body: t.Object({
						name: t.String(),
					}),
				},
			)
			.post(
				"/projects/:id/git/commit",
				async ({ body, params: parameters, set }) => {
					const result = await this.service.commit(parameters.id, {
						message: body.message ?? "",
						includeUnstaged: body.includeUnstaged ?? false,
						push: body.push ?? false,
					});
					if (GitController.isGitError(result)) {
						set.status = GitController.errorStatusCode(result);
						return { error: GitController.errorMessage(result) };
					}

					return { commit: result };
				},
				{
					body: t.Object({
						message: t.Optional(t.String()),
						includeUnstaged: t.Optional(t.Boolean()),
						push: t.Optional(t.Boolean()),
					}),
				},
			);
		}
	}

export const createGitController = (service: GitService) => GitController.build(service);
