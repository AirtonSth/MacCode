import { Elysia } from "elysia";

import { serverConfig } from "../../config";

const readHeaderToken = (request: Request): string | null => {
	const {headers} = request;
	const rawToken = headers.get("authorization");

	if (!rawToken) {
		return null;
	}

	if (rawToken.startsWith("Bearer ")) {
		return rawToken.slice(7).trim();
	}

	return rawToken.trim();
};

const readQueryToken = (request: Request): string | null => {
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
};

const isWebSocketRoute = (request: Request): boolean => {
	try {
		return new URL(request.url).pathname.includes("/v1/ws");
	} catch {
		return request.url.includes("/v1/ws");
	}
};

export const isAuthorized = (request: Request): boolean => {
	const token = isWebSocketRoute(request) ? resolveWsToken(request) : readHeaderToken(request);

	return Boolean(token && token === serverConfig.token);
};

export const resolveWsToken = (request: Request): string | null => readHeaderToken(request) ?? readQueryToken(request);

export const withRestAuth = () =>
	new Elysia().onRequest(({ request, set }) => {
		const token = isWebSocketRoute(request) ? resolveWsToken(request) : readHeaderToken(request);

		if (!token || token !== serverConfig.token) {
			set.status = 401;
			set.headers["content-type"] = "application/json";

			return { error: "unauthorized" };
		}
	});
