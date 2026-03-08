import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo, useState } from "react";

import { queryKeys } from "../../../shared/api/query-keys";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import type { MessageDTO, MessagePageDTO } from "../../../shared/api/types";

export const MESSAGE_PAGE_SIZE = 5;

const createEmptyPage = (): MessagePageDTO => ({
	hasMore: false,
	messages: [],
	nextBeforeMessageId: null,
	turns: [],
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

const sortMessagesAscending = (messages: MessageDTO[]): MessageDTO[] =>
	Array.from(messages).sort((left, right) => {
		if (left.createdAt < right.createdAt) {
			return -1;
		}
		if (left.createdAt > right.createdAt) {
			return 1;
		}
		return left.id.localeCompare(right.id);
	});

const upsertMessage = (messages: MessageDTO[], message: MessageDTO): MessageDTO[] => {
	const existingIndex = messages.findIndex((entry) => entry.id === message.id);
	if (existingIndex === -1) {
		return sortMessagesAscending([...messages, message]);
	}

	const nextMessages = Array.from(messages);
	nextMessages[existingIndex] = message;
	return sortMessagesAscending(nextMessages);
};

const trimMessagePage = (messages: MessageDTO[]): {
	hasTrimmedOlderMessages: boolean;
	messages: MessageDTO[];
} => {
	if (messages.length <= MESSAGE_PAGE_SIZE) {
		return {
			hasTrimmedOlderMessages: false,
			messages,
		};
	}

	return {
		hasTrimmedOlderMessages: true,
		messages: messages.slice(-MESSAGE_PAGE_SIZE),
	};
};

const normalizeMessagePage = (page: MessagePageDTO | MessageDTO[] | undefined | null): MessagePageDTO => {
	if (!page) {
		return createEmptyPage();
	}

	if (Array.isArray(page) && page.every(isMessage)) {
		return {
			...createEmptyPage(),
			messages: page,
		};
	}

	return page;
};

export const appendMessageToMessagePage = (
	page: MessagePageDTO | undefined,
	message: MessageDTO,
): MessagePageDTO => {
	const normalizedPage = normalizeMessagePage(page);
	const nextMessages = upsertMessage(normalizedPage.messages, message);
	const trimmedPage = trimMessagePage(nextMessages);
	const oldestVisibleMessageId = trimmedPage.messages[0]?.id ?? null;

	return {
		...normalizedPage,
		hasMore: normalizedPage.hasMore || trimmedPage.hasTrimmedOlderMessages,
		messages: trimmedPage.messages,
		nextBeforeMessageId:
			normalizedPage.hasMore || trimmedPage.hasTrimmedOlderMessages
				? oldestVisibleMessageId
				: normalizedPage.nextBeforeMessageId,
	};
};

export const replaceVisibleMessagePage = (
	current: MessagePageDTO | undefined,
	page: MessagePageDTO,
): MessagePageDTO => normalizeMessagePage(page);

export const useMessagesQuery = (chatId: string | null, options?: { enabled?: boolean }) => {
	const client = useRemoteCodeClient();
	const queryClient = useQueryClient();
	const enabled = options?.enabled ?? true;
	const [pageLoadKind, setPageLoadKind] = useState<"latest" | "older" | null>(null);

	const query = useQuery<MessagePageDTO>({
		enabled: Boolean(chatId) && enabled,
		initialData: createEmptyPage(),
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
		() => normalizeMessagePage(query.data),
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
