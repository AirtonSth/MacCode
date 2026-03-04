import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { WorkspaceSelectionDTO } from "../../../shared/api/types";

interface UseWorkspaceSelectionQueryOptions {
	enabled?: boolean;
}

export const useWorkspaceSelectionQuery = (options?: UseWorkspaceSelectionQueryOptions) => {
	const client = useRemoteCodeClient();

	return useQuery<WorkspaceSelectionDTO>({
		enabled: options?.enabled ?? true,
		queryFn: async () => await client.getSelection(),
		queryKey: queryKeys.selection,
	});
};
