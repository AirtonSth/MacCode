import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { FsServiceContract } from "./fs.service";

export class FsController {
	static build(service: FsServiceContract) {
		return new FsController(service).build();
	}

	constructor(private readonly service: FsServiceContract) {}

	build() {
		return new Elysia({ name: "fs-controller" })
			.use(withRestAuth())
			.get("/fs/roots", async () => {
				return {
					roots: this.service.listRoots(),
				};
			})
			.get(
				"/fs/list",
				async ({ query, set }) => {
					const listed = this.service.listPath(query.path);
					if ("type" in listed) {
						switch (listed.type) {
							case "invalid_path":
							case "not_directory":
								set.status = 400;
								break;
							case "not_found":
							default:
								set.status = 404;
								break;
						}

						return { error: listed.type };
					}

					return listed;
				},
				{
					query: t.Object({
						path: t.String(),
					}),
				},
			);
	}
}

export const createFsController = (service: FsServiceContract) => FsController.build(service);
