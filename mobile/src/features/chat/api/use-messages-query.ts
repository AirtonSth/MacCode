import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { MessagePageDTO } from "../../../shared/api/types";
import {
	createEmptyPage,
	getPlaceholderMessagePage,
	MESSAGE_PAGE_SIZE,
} from "./message-page-utils";

const normalizeQueryPage = (page: MessagePageDTO | undefined): MessagePageDTO => page ?? createEmptyPage();

export const useMessagesQuery = (chatId: string | null, options?: { enabled?: boolean }) => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();
	const enabled = options?.enabled ?? true;
	const [pageLoadKind, setPageLoadKind] = useState<"latest" | "older" | null>(null);

	const query = useQuery<MessagePageDTO>({
		enabled: Boolean(chatId) && enabled,
		placeholderData: (previousPage) => {
			if (!chatId) {
				return createEmptyPage();
			}

			return getPlaceholderMessagePage(
				previousPage,
				queryClient.getQueryData<MessagePageDTO>(queryKeys.messages(chatId)),
			);
		},
		queryFn: async () => {
			if (!chatId) {
				return createEmptyPage();
			}

			return await client.listMessagesPage(chatId, {
				limit: MESSAGE_PAGE_SIZE,
			});
		},
		queryKey: queryKeys.messages(chatId),
	});

	const page = useMemo(
		() => normalizeQueryPage(query.data),
		[query.data],
	);

	const loadOlderMessages = useCallback(async (): Promise<void> => {
		if (!chatId || !page.hasMore || !page.nextBeforeMessageId || pageLoadKind) {
			return;
		}

		setPageLoadKind("older");
		try {
			const olderPage = await client.listMessagesPage(chatId, {
				beforeMessageId: page.nextBeforeMessageId,
				limit: MESSAGE_PAGE_SIZE,
			});
			queryClient.setQueryData<MessagePageDTO>(queryKeys.messages(chatId), olderPage);
		} finally {
			setPageLoadKind(null);
		}
	}, [chatId, client, page.hasMore, page.nextBeforeMessageId, pageLoadKind, queryClient]);

	const loadLatestMessages = useCallback(async (): Promise<void> => {
		if (!chatId || pageLoadKind) {
			return;
		}

		setPageLoadKind("latest");
		try {
			const latestPage = await client.listMessagesPage(chatId, {
				limit: MESSAGE_PAGE_SIZE,
			});
			queryClient.setQueryData<MessagePageDTO>(queryKeys.messages(chatId), latestPage);
		} finally {
			setPageLoadKind(null);
		}
	}, [chatId, client, pageLoadKind, queryClient]);

	return {
		...query,
		hasOlderMessages: page.hasMore,
		isLoadingLatestMessages: pageLoadKind === "latest",
		isLoadingOlderMessages: pageLoadKind === "older",
		loadLatestMessages,
		loadOlderMessages,
		messages: page.messages,
		page,
	};
};
