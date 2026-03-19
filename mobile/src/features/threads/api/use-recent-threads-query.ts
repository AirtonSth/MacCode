import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { RecentThreadSummaryDTO } from "../../../shared/api/types";

export const useRecentThreadsQuery = (enabled = true) => {
	const client = useRemoteCodeClient();

	return useQuery<RecentThreadSummaryDTO[]>({
		enabled,
		queryFn: async () => await client.listRecentThreads(),
		queryKey: queryKeys.recentThreads,
		refetchInterval: 5_000,
		staleTime: 2_000,
	});
};
