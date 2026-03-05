import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ActiveThreadSummaryDTO } from "../../../shared/api/types";

export const useActiveThreadsQuery = (enabled = true) => {
	const client = useRemoteCodeClient();

	return useQuery<ActiveThreadSummaryDTO[]>({
		enabled,
		queryFn: async () => await client.listActiveThreads(),
		queryKey: queryKeys.activeThreads,
		refetchInterval: 2_500,
		staleTime: 1_000,
	});
};
