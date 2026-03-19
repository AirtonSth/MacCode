import type { MessageDTO, MessagePageDTO } from "../../../shared/api/types";

export const MESSAGE_PAGE_SIZE = 25;

export const createEmptyPage = (): MessagePageDTO => ({
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

export const normalizeMessagePage = (page: MessagePageDTO | MessageDTO[] | undefined | null): MessagePageDTO => {
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

export const getPlaceholderMessagePage = (
	previousPage: MessagePageDTO | undefined,
	cachedPage: MessagePageDTO | undefined,
): MessagePageDTO | undefined => previousPage ?? cachedPage;
