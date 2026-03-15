import { useMutation, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { ChatDTO } from "../../../shared/api/types";

export const useCreateChatMutation = () => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();

	return useMutation<ChatDTO, Error, { projectId: string; title?: string; provider?: string }>({
		mutationFn: async (input: { projectId: string; title?: string; provider?: string }) =>
			await client.createChat(input.projectId, input.title, input.provider),
		onSuccess: async (chat) => {
			await queryClient.invalidateQueries({
				queryKey: queryKeys.chats(chat.projectId),
			});
		},
	});
};
