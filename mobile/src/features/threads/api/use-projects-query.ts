import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ProjectDTO, WorkspaceSummaryDTO } from "../../../shared/api/types";

interface UseProjectsQueryOptions {
	enabled?: boolean;
	mode?: "full" | "summary";
	staleTime?: number;
	gcTime?: number;
}

export const useProjectsQuery = (options?: UseProjectsQueryOptions) => {
	const client = useRemoteCodeClient();
	const mode = options?.mode ?? "full";
	const enabled = options?.enabled ?? true;

	return useQuery<ProjectDTO[] | WorkspaceSummaryDTO[]>({
		enabled,
		gcTime: options?.gcTime,
		queryFn: async () => (
			mode === "summary"
				? await client.listWorkspaceSummaries()
				: await client.listProjects()
		),
		queryKey: [...queryKeys.projects, mode] as const,
		staleTime: options?.staleTime,
	});
};
