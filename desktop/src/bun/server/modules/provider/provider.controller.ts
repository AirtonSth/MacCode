import { Elysia } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { CodexModelsService, CodexModelsServiceError } from "./codex-models.service";
import { ClaudeModelsService } from "./claude-models.service";

export class ProviderController {
	static build(codexModelsService: CodexModelsService, claudeModelsService: ClaudeModelsService) {
		return new ProviderController(codexModelsService, claudeModelsService).build();
	}

	constructor(
		private readonly codexModelsService: CodexModelsService,
		private readonly claudeModelsService: ClaudeModelsService,
	) {}

	build() {
		return new Elysia({ name: "provider-controller" })
			.use(withRestAuth())
			.get("/providers/codex/models", async ({ set }) => {
				try {
					const catalog = await this.codexModelsService.getModelsCatalog();

					return {
						models: catalog.models,
						nextCursor: catalog.nextCursor,
					};
				} catch (error) {
					if (error instanceof CodexModelsServiceError) {
						set.status = error.statusCode;
						return { error: error.message };
					}

					set.status = 503;
					return { error: "failed to load codex models" };
				}
			})
			.get("/providers/claude/models", async () => {
				const catalog = await this.claudeModelsService.getModelsCatalog();

				return {
					models: catalog.models,
					nextCursor: catalog.nextCursor,
				};
			});
	}
}

export const createProviderController = (
	codexModelsService: CodexModelsService,
	claudeModelsService: ClaudeModelsService,
) => ProviderController.build(codexModelsService, claudeModelsService);
