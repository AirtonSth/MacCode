import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useChatsQuery = (projectId: string | null) => {
	const client = useRemoteCodeClient();

	return useQuery({
		enabled: Boolean(projectId),
		queryFn: async () => await client.listChats(projectId!),
		queryKey: queryKeys.chats(projectId),
	});
};
