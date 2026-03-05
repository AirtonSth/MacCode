import { Elysia, t } from "elysia";

import type { ServerMetadataServiceContract } from "../server-metadata/server-metadata.service";

const LOG_PREFIX = "[auth-verify]";

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
					console.log(LOG_PREFIX, "request", {
						clientId: request.headers.get("x-remotecode-client-id") ?? null,
						hasBodyToken: Boolean(bodyToken?.trim()),
						hasHeaderToken: Boolean(headerToken?.trim()),
						requestId: request.headers.get("x-remotecode-request-id") ?? null,
					});
					if (!this.service.verifyToken(token)) {
						console.log(LOG_PREFIX, "unauthorized", {
							clientId: request.headers.get("x-remotecode-client-id") ?? null,
							requestId: request.headers.get("x-remotecode-request-id") ?? null,
						});
						set.status = 401;
						return { error: "unauthorized" };
					}

					const metadata = this.service.getDiscoveryMetadata();
					console.log(LOG_PREFIX, "ok", {
						clientId: request.headers.get("x-remotecode-client-id") ?? null,
						requestId: request.headers.get("x-remotecode-request-id") ?? null,
						serverId: metadata.serverId,
					});
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
