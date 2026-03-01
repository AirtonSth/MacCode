import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useProjectsQuery = () => {
	const client = useRemoteCodeClient();

	return useQuery({
		queryFn: async () => await client.listProjects(),
		queryKey: queryKeys.projects,
	});
};
