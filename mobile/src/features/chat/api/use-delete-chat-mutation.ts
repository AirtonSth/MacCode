import { useMutation, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";

export const useDeleteChatMutation = (projectId: string | null) => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();

	return useMutation<{ deleted: boolean }, Error, string>({
		mutationFn: async (chatId: string) => await client.deleteChat(chatId),
		onSuccess: async () => {
			if (!projectId) {
				return;
			}

			await queryClient.invalidateQueries({
				queryKey: queryKeys.chats(projectId),
			});
		},
	});
};
