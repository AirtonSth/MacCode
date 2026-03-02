import { useQuery } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { MessageDTO } from "../../../shared/api/types";

export const useMessagesQuery = (chatId: string | null) => {
	const client = useRemoteCodeClient();

	return useQuery<MessageDTO[]>({
		enabled: Boolean(chatId),
		queryFn: async () => await client.listMessages(chatId!),
		queryKey: queryKeys.messages(chatId),
	});
};
