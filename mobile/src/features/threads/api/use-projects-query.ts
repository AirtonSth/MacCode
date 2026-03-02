import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ProjectDTO } from "../../../shared/api/types";

export const useProjectsQuery = () => {
	const client = useRemoteCodeClient();

	return useQuery<ProjectDTO[]>({
		queryFn: async () => await client.listProjects(),
		queryKey: queryKeys.projects,
	});
};
