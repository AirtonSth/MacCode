import { useMutation, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useCreateChatMutation = () => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();

	return useMutation({
		mutationFn: async (input: { projectId: string; title?: string }) =>
			await client.createChat(input.projectId, input.title),
		onSuccess: async (chat) => {
			await queryClient.invalidateQueries({
				queryKey: queryKeys.chats(chat.projectId),
			});
		},
	});
};
