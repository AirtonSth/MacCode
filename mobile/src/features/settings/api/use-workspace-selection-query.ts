import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { WorkspaceSelectionDTO } from "../../../shared/api/types";

export const useWorkspaceSelectionQuery = () => {
	const client = useRemoteCodeClient();

	return useQuery<WorkspaceSelectionDTO>({
		queryFn: async () => await client.getSelection(),
		queryKey: queryKeys.selection,
	});
};
