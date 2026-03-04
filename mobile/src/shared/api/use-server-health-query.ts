import { useQuery } from "@tanstack/react-query";

import { useApiConfig } from "./api-config-provider";
import { queryKeys } from "./query-keys";
import { useRemoteCodeClient } from "./use-remotecode-client";

export const useServerHealthQuery = () => {
	const api = useRemoteCodeClient();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();

	return useQuery({
		enabled: isConfigLoaded,
		queryKey: queryKeys.serverHealth(config.baseUrl, config.token),
		queryFn: async () => await api.verifyToken(config.token, config.baseUrl),
		retry: 1,
		staleTime: 30_000,
	});
};
