import { useMutation, useQueryClient } from "@tanstack/react-query";

import { queryKeys } from "@/shared/api/query-keys";
import { useRemoteCodeClient } from "@/shared/api/use-remotecode-client";
import type { WorkspaceSelectionDTO } from "@/shared/api/types";

export const useUpdateWorkspaceSelectionMutation = () => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();

	return useMutation({
		mutationFn: async (selection: WorkspaceSelectionDTO) =>
			await client.updateSelection(selection),
		onSuccess: (selection) => {
			queryClient.setQueryData(queryKeys.selection, selection);
		},
	});
};
