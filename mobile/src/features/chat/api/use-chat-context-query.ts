import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ChatContextDTO } from "../../../shared/api/types";

interface UseChatContextQueryOptions {
	enabled?: boolean;
}

export const useChatContextQuery = (chatId: string | null, options?: UseChatContextQueryOptions) => {
	const client = useRemoteCodeClient();
	const enabled = options?.enabled ?? true;

	return useQuery<ChatContextDTO>({
		enabled: Boolean(chatId) && enabled,
		queryFn: async () => await client.getChatContext(chatId!),
		queryKey: queryKeys.chatContext(chatId),
	});
};
