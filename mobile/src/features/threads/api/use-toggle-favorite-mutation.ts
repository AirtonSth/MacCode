import { useMutation, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";

export const useToggleFavoriteMutation = () => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();

	return useMutation({
		mutationFn: async (input: { isFavorite: boolean; projectId: string }) =>
			await client.toggleFavorite(input.projectId, input.isFavorite),
		onSuccess: async () => {
			await queryClient.invalidateQueries({
				queryKey: queryKeys.projects,
			});
		},
	});
};
