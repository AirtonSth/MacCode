import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useMessagesQuery = (chatId: string | null) => {
	const client = useRemoteCodeClient();

	return useQuery({
		enabled: Boolean(chatId),
		queryFn: async () => await client.listMessages(chatId!),
		queryKey: queryKeys.messages(chatId),
	});
};
