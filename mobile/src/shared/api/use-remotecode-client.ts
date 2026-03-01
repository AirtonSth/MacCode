import { useMemo } from "react";

import { useApiConfig } from "./api-config-provider";
import { createRemoteCodeClient } from "./remotecode-client";

export const useRemoteCodeClient = () => {
	const { config } = useApiConfig();

	return useMemo(
		() => createRemoteCodeClient(config),
		[config],
	);
};
