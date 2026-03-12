import { Elysia } from "elysia";

import { serverConfig } from "../../config";

const DEFAULT_SERVER_TOKEN = "remotecode.io-token";
const LEGACY_LOCAL_TOKEN = "local-dev-token";

const setCorsHeaders = (request: Request, headers: Record<string, string | number>) => {
	const origin = request.headers.get("origin");

	headers["access-control-allow-origin"] = origin || "*";
	headers["access-control-allow-methods"] = "GET,POST,PATCH,DELETE,OPTIONS";
	headers["access-control-allow-headers"] =
		"authorization,content-type,x-remotecode-client-id,x-remotecode-request-id";
	headers["access-control-max-age"] = "86400";
};

const isTokenAuthorized = (token: string | null | undefined): boolean => {
	const normalized = token?.trim();
	if (!normalized) {
		return false;
	}

	const isPrimary = normalized === serverConfig.token;
	const isLegacyFallback = normalized === LEGACY_LOCAL_TOKEN && serverConfig.token === DEFAULT_SERVER_TOKEN;

	return isPrimary || isLegacyFallback;
};

export const AuthService = {
	isAuthorized(request: Request): boolean {
		const token = AuthService.isWebSocketRoute(request)
			? AuthService.resolveWsToken(request)
			: AuthService.readHeaderToken(request);

		return isTokenAuthorized(token);
	},

	isWebSocketRoute(request: Request): boolean {
		try {
			return new URL(request.url).pathname.includes("/v1/ws");
		} catch {
			return request.url.includes("/v1/ws");
		}
	},

	readPathname(request: Request): string {
		try {
			return new URL(request.url).pathname;
		} catch {
			return request.url.split("?")[0] ?? request.url;
		}
	},

	isPublicRestRoute(request: Request): boolean {
		const pathname = AuthService.readPathname(request);
		return pathname === "/v1/discovery" || pathname === "/v1/private-account/browser-return";
	},

	readHeaderToken(request: Request): string | null {
		const rawToken = request.headers.get("authorization");

		if (!rawToken) {
			return null;
		}

		if (rawToken.startsWith("Bearer ")) {
			return rawToken.slice(7).trim();
		}

		return rawToken.trim();
	},

	readQueryToken(request: Request): string | null {
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
	},

	resolveWsToken(request: Request): string | null {
		return AuthService.readHeaderToken(request) ?? AuthService.readQueryToken(request);
	},

	withRestAuth() {
		return new Elysia().onRequest(({ request, set }) => {
			setCorsHeaders(request, set.headers);

			if (request.method === "OPTIONS") {
				set.status = 204;

				return "";
			}

			if (AuthService.isPublicRestRoute(request)) {
				return;
			}

			const token = AuthService.isWebSocketRoute(request)
				? AuthService.resolveWsToken(request)
				: AuthService.readHeaderToken(request);

			if (!isTokenAuthorized(token)) {
				set.status = 401;
				set.headers["content-type"] = "application/json";

				return {
					code: "unauthorized",
					error: "You are not authorized to access this desktop server.",
				};
			}
		});
	},
};

export const {readHeaderToken} = AuthService;
export const {readQueryToken} = AuthService;
export const {isWebSocketRoute} = AuthService;
export const {resolveWsToken} = AuthService;
export const {isAuthorized} = AuthService;
export const {withRestAuth} = AuthService;
export const isValidToken = isTokenAuthorized;
