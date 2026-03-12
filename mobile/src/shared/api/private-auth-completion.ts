/* eslint-disable total-functions/no-partial-url-constructor */
import { createPrivateClient } from "@remotecode/contracts";

import type { PersistedPrivateSessionRecord } from "./private-session-store";

const PRIVATE_AUTH_COMPLETE_PATH = "/auth/complete";
const PRIVATE_AUTH_SCHEMES = new Set(["remotecode", "remotecode-mobile"]);

const toLogicalPath = (url: URL): string => {
	if (url.protocol === "https:" || url.protocol === "http:") {
		return url.pathname;
	}

	const normalizedPath = url.pathname.length > 1 ? url.pathname : "";
	if (url.host.length > 0) {
		return `/${url.host}${normalizedPath}`;
	}

	return normalizedPath || "/";
};

export const parsePrivateAuthCompletionInput = (rawUrl: string): {
	backendUrl: string;
	completionToken: string;
} => {
	const trimmedUrl = rawUrl.trim();
	if (!trimmedUrl) {
		throw new Error("invalid_private_auth_completion_url");
	}

	const parsed = (() => {
		try {
			return new URL(trimmedUrl);
		} catch {
			throw new Error("invalid_private_auth_completion_url");
		}
	})();

	const scheme = parsed.protocol.replace(/:$/u, "").toLowerCase();
	if (!PRIVATE_AUTH_SCHEMES.has(scheme) || toLogicalPath(parsed) !== PRIVATE_AUTH_COMPLETE_PATH) {
		throw new Error("invalid_private_auth_completion_url");
	}

	const completionToken = parsed.searchParams.get("completionToken")?.trim() ?? "";
	const backendUrl = parsed.searchParams.get("backendUrl")?.trim() ?? "";
	if (!completionToken || !backendUrl) {
		throw new Error("invalid_private_auth_completion_url");
	}

	return {
		backendUrl: backendUrl.replace(/\/+$/u, ""),
		completionToken,
	};
};

export const exchangePrivateAuthCompletion = async (input: {
	completion: {
		backendUrl: string;
		completionToken: string;
	};
	createClient?: typeof createPrivateClient;
}): Promise<PersistedPrivateSessionRecord> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.completion.backendUrl,
	});
	const session = await client.exchangeCompletionToken({
		completionToken: input.completion.completionToken,
	});

	return {
		backendUrl: input.completion.backendUrl,
		session,
	};
};
