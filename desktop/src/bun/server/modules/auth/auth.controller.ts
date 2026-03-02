import { Elysia, t } from "elysia";

import type { ServerMetadataServiceContract } from "../server-metadata/server-metadata.service";

const readBearerToken = (authorizationHeader: string | null): string | null => {
	if (!authorizationHeader) {
		return null;
	}

	if (authorizationHeader.startsWith("Bearer ")) {
		return authorizationHeader.slice(7).trim();
	}

	return authorizationHeader.trim();
};

export class AuthController {
	static build(service: ServerMetadataServiceContract) {
		return new AuthController(service).build();
	}

	constructor(private readonly service: ServerMetadataServiceContract) {}

	build() {
		return new Elysia({ name: "auth-controller" }).post(
				"/auth/verify",
				async ({ body, request, set }) => {
					const bodyToken = typeof body?.token === "string" ? body.token : null;
					const headerToken = readBearerToken(request.headers.get("authorization"));
					const token = bodyToken?.trim() || headerToken;
					if (!this.service.verifyToken(token)) {
						set.status = 401;
						return { error: "unauthorized" };
					}

					const metadata = this.service.getDiscoveryMetadata();
					return {
						ok: true,
						server: {
							serverId: metadata.serverId,
							hostname: metadata.hostname,
							port: metadata.port,
							version: metadata.version,
							authMode: metadata.authMode,
							capabilitiesVersion: metadata.capabilitiesVersion,
						},
					};
				},
				{
					body: t.Optional(
						t.Object({
							clientId: t.Optional(t.String()),
							requestId: t.Optional(t.String()),
							token: t.Optional(t.String()),
						}),
					),
				},
			);
	}
}

export const createAuthController = (service: ServerMetadataServiceContract) => AuthController.build(service);
