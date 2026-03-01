import { Elysia } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { CodexModelsService, CodexModelsServiceError } from "./codex-models.service";

export class ProviderController {
	static build(service: CodexModelsService) {
		return new ProviderController(service).build();
	}

	constructor(private readonly codexModelsService: CodexModelsService) {}

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
			});
	}
}

export const createProviderController = (service: CodexModelsService) => ProviderController.build(service);
