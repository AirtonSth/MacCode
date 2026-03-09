import { useQuery } from "@tanstack/react-query";

import { createPrivateClient, PrivateApiError } from "@remotecode/contracts";

import { useApiConfig } from "./api-config-provider";
import type { ActiveConnectionTarget } from "./api-config-store";
import { usePrivateSession } from "./private-session-provider";
import { queryKeys } from "./query-keys";
import { useRemoteCodeClient } from "./use-remotecode-client";

export const fetchPrivateTargetHealth = async (input: {
	createClient?: typeof createPrivateClient;
	refreshPrivateAccessToken?: () => Promise<string | null>;
	target: Extract<ActiveConnectionTarget, { kind: "private" }>;
}) => {
	const createClient = (accessToken: string) => (input.createClient ?? createPrivateClient)({
		baseUrl: input.target.backendUrl,
		getAccessToken: () => accessToken,
	});

	try {
		const privateClient = createClient(input.target.accessToken);
		const [me, connectors] = await Promise.all([
			privateClient.me(),
			privateClient.listConnectors(),
		]);
		const connector = connectors.connectors.find((item) => item.id === input.target.connectorId);
		if (!connector || connector.status !== "online") {
			throw new Error("private_connector_unavailable");
		}

		return {
			connector,
			ok: true,
			user: me.user,
		};
	} catch (error) {
		if (!(error instanceof PrivateApiError) || error.status !== 401 || !input.refreshPrivateAccessToken) {
			throw error;
		}

		const refreshedToken = await input.refreshPrivateAccessToken();
		if (!refreshedToken) {
			throw error;
		}

		const privateClient = createClient(refreshedToken);
		const [me, connectors] = await Promise.all([
			privateClient.me(),
			privateClient.listConnectors(),
		]);
		const connector = connectors.connectors.find((item) => item.id === input.target.connectorId);
		if (!connector || connector.status !== "online") {
			throw new Error("private_connector_unavailable");
		}

		return {
			connector,
			ok: true,
			user: me.user,
		};
	}
};

export const useServerHealthQuery = () => {
	const api = useRemoteCodeClient();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const { isLoaded: isPrivateSessionLoaded, refreshSession } = usePrivateSession();
	const activeTarget = config.activeTarget;

	return useQuery({
		enabled: isConfigLoaded && isPrivateSessionLoaded,
		queryKey: queryKeys.serverHealth(
			activeTarget.kind === "local" ? activeTarget.baseUrl : activeTarget.backendUrl,
			activeTarget.kind === "local" ? activeTarget.token : `${activeTarget.accessToken}:${activeTarget.connectorId}`,
		),
		queryFn: async () => {
			if (activeTarget.kind === "private") {
				return await fetchPrivateTargetHealth({
					refreshPrivateAccessToken: async () => {
						const session = await refreshSession();
						return session?.accessToken ?? null;
					},
					target: activeTarget,
				});
			}

			return await api.verifyToken(activeTarget.token, activeTarget.baseUrl);
		},
		retry: 1,
		staleTime: 30_000,
	});
};
