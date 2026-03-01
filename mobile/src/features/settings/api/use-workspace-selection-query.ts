import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useWorkspaceSelectionQuery = () => {
	const client = useRemoteCodeClient();

	return useQuery({
		queryFn: async () => await client.getSelection(),
		queryKey: queryKeys.selection,
	});
};
