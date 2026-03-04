import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ChatDTO, ThreadSummaryDTO } from "../../../shared/api/types";

interface UseChatsQueryOptions {
	enabled?: boolean;
	mode?: "full" | "summary";
}

export const useChatsQuery = (projectId: string | null, options?: UseChatsQueryOptions) => {
	const client = useRemoteCodeClient();
	const mode = options?.mode ?? "full";
	const enabled = options?.enabled ?? true;

	return useQuery<ChatDTO[] | ThreadSummaryDTO[]>({
		enabled: Boolean(projectId) && enabled,
		queryFn: async () => (
			mode === "summary"
				? await client.listThreadSummaries(projectId!)
				: await client.listChats(projectId!)
		),
		queryKey: [...queryKeys.chats(projectId), mode] as const,
	});
};
