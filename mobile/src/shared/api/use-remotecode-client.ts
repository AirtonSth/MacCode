import { useMemo } from "react";

import { useApiConfig } from "./api-config-provider";
import { usePrivateSession } from "./private-session-provider";
import { createRemoteCodeClient } from "./remotecode-client";

export const useRemoteCodeClient = () => {
	const { config } = useApiConfig();
	const { refreshSession } = usePrivateSession();

	return useMemo(
		() => createRemoteCodeClient(config, {
			refreshPrivateAccessToken: async () => {
				const session = await refreshSession();
				return session?.accessToken ?? null;
			},
		}),
		[config, refreshSession],
	);
};
