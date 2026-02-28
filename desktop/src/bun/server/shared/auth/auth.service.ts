import { Elysia } from "elysia";

import { serverConfig } from "../../config";

export class AuthService {
	static readHeaderToken(request: Request): string | null {
		const rawToken = request.headers.get("authorization");

		if (!rawToken) {
			return null;
		}

		if (rawToken.startsWith("Bearer ")) {
			return rawToken.slice(7).trim();
		}

		return rawToken.trim();
	}

	static readQueryToken(request: Request): string | null {
		const queryStart = request.url.indexOf("?");

		if (queryStart === -1) {
			return null;
		}

		const queryString = request.url.slice(queryStart + 1);

		try {
			const searchParameters = new URLSearchParams(queryString);

			return searchParameters.get("token")?.trim() ?? null;
		} catch {
			return null;
		}
	}

	static isWebSocketRoute(request: Request): boolean {
		try {
			return new URL(request.url).pathname.includes("/v1/ws");
		} catch {
			return request.url.includes("/v1/ws");
		}
	}

	static resolveWsToken(request: Request): string | null {
		return AuthService.readHeaderToken(request) ?? AuthService.readQueryToken(request);
	}

	static isAuthorized(request: Request): boolean {
		const token = AuthService.isWebSocketRoute(request)
			? AuthService.resolveWsToken(request)
			: AuthService.readHeaderToken(request);

		return Boolean(token && token === serverConfig.token);
	}

	static withRestAuth() {
		return new Elysia().onRequest(({ request, set }) => {
			const token = AuthService.isWebSocketRoute(request)
				? AuthService.resolveWsToken(request)
				: AuthService.readHeaderToken(request);

			if (!token || token !== serverConfig.token) {
				set.status = 401;
				set.headers["content-type"] = "application/json";

				return { error: "unauthorized" };
			}
		});
	}
}

export const readHeaderToken = AuthService.readHeaderToken;
export const readQueryToken = AuthService.readQueryToken;
export const isWebSocketRoute = AuthService.isWebSocketRoute;
export const resolveWsToken = AuthService.resolveWsToken;
export const isAuthorized = AuthService.isAuthorized;
export const withRestAuth = AuthService.withRestAuth;
