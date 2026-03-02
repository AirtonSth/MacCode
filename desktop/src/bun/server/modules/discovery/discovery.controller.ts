import { Elysia } from "elysia";

import type { ServerMetadataServiceContract } from "../server-metadata/server-metadata.service";

export class DiscoveryController {
	static build(service: ServerMetadataServiceContract) {
		return new DiscoveryController(service).build();
	}

	constructor(private readonly service: ServerMetadataServiceContract) {}

	build() {
		return new Elysia({ name: "discovery-controller" }).get("/discovery", async () => {
			return this.service.getDiscoveryMetadata();
		});
	}
}

export const createDiscoveryController = (service: ServerMetadataServiceContract) =>
	DiscoveryController.build(service);
