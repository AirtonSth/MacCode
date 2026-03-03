import { useInfiniteQuery, type InfiniteData } from "@tanstack/react-query";
import { useCallback, useMemo } from "react";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { MessageDTO, MessagePageDTO } from "../../../shared/api/types";

export const MESSAGE_PAGE_SIZE = 5;

const createEmptyPage = (): MessagePageDTO => ({
	hasMore: false,
	messages: [],
	nextBeforeMessageId: null,
});

const isMessageRecord = (value: unknown): value is Record<string, unknown> => (
	typeof value === "object" &&
	value !== null &&
	!Array.isArray(value)
);

const isMessage = (value: unknown): value is MessageDTO => (
	isMessageRecord(value)
	&& typeof value.id === "string"
	&& typeof value.chatId === "string"
	&& typeof value.role === "string"
	&& typeof value.content === "string"
);

const isMessageArray = (value: unknown): value is MessageDTO[] =>
	Array.isArray(value) &&
	value.every(isMessage);

const normalizeInfiniteMessageData = (
	data: InfiniteData<MessagePageDTO> | MessageDTO[] | undefined | null,
): InfiniteData<MessagePageDTO> | undefined => {
	if (!data) {
		return undefined;
	}

	if (isMessageArray(data)) {
		return {
			pageParams: [null],
			pages: [{
				...createEmptyPage(),
				messages: data,
			}],
		};
	}

	return (data.pages === undefined ? undefined : data);
};

export const flattenMessagePages = (data: InfiniteData<MessagePageDTO> | undefined): MessageDTO[] =>
	(data?.pages ?? [])
		.slice()
		.reverse()
		.flatMap((page) => page.messages);

export const appendMessageToMessagePages = (
	data: InfiniteData<MessagePageDTO> | undefined,
	message: MessageDTO,
): InfiniteData<MessagePageDTO> => {
	const normalizedData = normalizeInfiniteMessageData(data);

	if (!normalizedData || normalizedData.pages.length === 0) {
		return {
			pageParams: [null],
			pages: [{
				...createEmptyPage(),
				messages: [message],
			}],
		};
	}

	const pages = Array.from(normalizedData.pages);
	const newestPage = pages[0] ?? createEmptyPage();
	pages[0] = {
		...newestPage,
		messages: [...newestPage.messages, message],
	};

	return {
		...normalizedData,
		pages,
	};
};

export const replaceNewestMessagePage = (
	data: InfiniteData<MessagePageDTO> | undefined,
	page: MessagePageDTO,
): InfiniteData<MessagePageDTO> => {
	const normalizedData = normalizeInfiniteMessageData(data);

	if (!normalizedData || normalizedData.pages.length === 0) {
		return {
			pageParams: [null],
			pages: [page],
		};
	}

	const pages = [page, ...normalizedData.pages.slice(1)];
	return {
		...normalizedData,
		pages,
	};
};

export const useMessagesQuery = (chatId: string | null) => {
	const client = useRemoteCodeClient();

	const query = useInfiniteQuery<MessagePageDTO, Error, InfiniteData<MessagePageDTO>, ReturnType<typeof queryKeys.messages>, string | null>({
		enabled: Boolean(chatId),
		getNextPageParam: (lastPage) => (
			lastPage.hasMore && typeof lastPage.nextBeforeMessageId === "string"
				? lastPage.nextBeforeMessageId
				: undefined
		),
		initialPageParam: null,
		queryFn: async ({ pageParam }) => {
			if (!chatId) {
				return {
					hasMore: false,
					messages: [],
					nextBeforeMessageId: null,
				};
			}

			return await client.listMessagesPage(chatId, {
				beforeMessageId: pageParam ?? undefined,
				limit: MESSAGE_PAGE_SIZE,
			});
		},
		queryKey: queryKeys.messages(chatId),
		select: (data) => normalizeInfiniteMessageData(data) ?? {
			pageParams: [null],
			pages: [createEmptyPage()],
		},
	});

	const messages = useMemo(
		() => flattenMessagePages(query.data),
		[query.data],
	);
	const {
		fetchNextPage,
		hasNextPage,
		isFetchingNextPage,
	} = query;
	const loadOlderMessages = useCallback(async (): Promise<void> => {
		if (!hasNextPage || isFetchingNextPage) {
			return;
		}

		await fetchNextPage();
	}, [fetchNextPage, hasNextPage, isFetchingNextPage]);

	return {
		...query,
		hasOlderMessages: Boolean(hasNextPage),
		isLoadingOlderMessages: isFetchingNextPage,
		loadOlderMessages,
		messages,
	};
};
