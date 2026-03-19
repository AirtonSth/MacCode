import type { MessageDTO, MessagePageDTO } from "../../../shared/api/remotecode-http";
import { createEmptyMessageWindow, type MessageWindowState } from "./useWorkspaceStore";

export type MessageWindowCache = Record<string, MessageWindowState | undefined>;

interface ResolveSelectedMessageWindowInput {
	selectedChatId: string | null;
	liveWindow: MessageWindowState;
	cache: MessageWindowCache;
}

interface ResolvedSelectedMessageWindow {
	window: MessageWindowState;
	hasHydratedWindow: boolean;
	isLiveWindow: boolean;
}

const sortMessagesAscending = (messages: MessageDTO[]): MessageDTO[] =>
	[...messages].sort((left, right) => {
		if (left.createdAt < right.createdAt) {
			return -1;
		}
		if (left.createdAt > right.createdAt) {
			return 1;
		}
		return left.id.localeCompare(right.id);
	});

const upsertMessageInList = (messages: MessageDTO[], message: MessageDTO): MessageDTO[] => {
	const existingIndex = messages.findIndex((entry) => entry.id === message.id);
	if (existingIndex === -1) {
		return sortMessagesAscending([...messages, message]);
	}

	const nextMessages = [...messages];
	nextMessages[existingIndex] = message;
	return sortMessagesAscending(nextMessages);
};

const trimMessages = (messages: MessageDTO[], pageSize: number): { hasTrimmedOlderMessages: boolean; messages: MessageDTO[] } => {
	if (messages.length <= pageSize) {
		return {
			hasTrimmedOlderMessages: false,
			messages,
		};
	}

	return {
		hasTrimmedOlderMessages: true,
		messages: messages.slice(-pageSize),
	};
};

export const appendMessageToMessagePage = (
	page: MessagePageDTO,
	message: MessageDTO,
	pageSize: number,
): MessagePageDTO => {
	const nextMessages = upsertMessageInList(page.messages, message);
	const trimmedWindow = trimMessages(nextMessages, pageSize);
	const oldestVisibleMessageId = trimmedWindow.messages[0]?.id ?? null;

	return {
		...page,
		hasMore: page.hasMore || trimmedWindow.hasTrimmedOlderMessages,
		messages: trimmedWindow.messages,
		nextBeforeMessageId:
			page.hasMore || trimmedWindow.hasTrimmedOlderMessages
				? oldestVisibleMessageId
				: page.nextBeforeMessageId,
	};
};

export const mergeBufferedMessagesIntoPage = (
	page: MessagePageDTO,
	bufferedMessages: MessageDTO[],
	pageSize: number,
): MessagePageDTO => {
	return bufferedMessages.reduce(
		(currentPage, message) => appendMessageToMessagePage(currentPage, message, pageSize),
		page,
	);
};

export const pruneBufferedMessages = (
	bufferedMessages: MessageDTO[],
	serverMessages: MessageDTO[],
): MessageDTO[] => {
	const serverMessageIds = new Set(serverMessages.map((message) => message.id));
	return bufferedMessages.filter((message) => !serverMessageIds.has(message.id));
};

export const cacheLatestMessageWindow = (
	cache: MessageWindowCache,
	messageWindow: MessageWindowState,
): MessageWindowCache => {
	if (!messageWindow.chatId || messageWindow.mode !== "latest") {
		return cache;
	}

	if (cache[messageWindow.chatId] === messageWindow) {
		return cache;
	}

	return {
		...cache,
		[messageWindow.chatId]: messageWindow,
	};
};

export const resolveSelectedMessageWindow = ({
	selectedChatId,
	liveWindow,
	cache,
}: ResolveSelectedMessageWindowInput): ResolvedSelectedMessageWindow => {
	if (!selectedChatId) {
		return {
			hasHydratedWindow: false,
			isLiveWindow: false,
			window: createEmptyMessageWindow(),
		};
	}

	if (liveWindow.chatId === selectedChatId) {
		return {
			hasHydratedWindow: true,
			isLiveWindow: true,
			window: liveWindow,
		};
	}

	const cachedWindow = cache[selectedChatId];
	if (cachedWindow) {
		return {
			hasHydratedWindow: true,
			isLiveWindow: false,
			window: cachedWindow,
		};
	}

	return {
		hasHydratedWindow: false,
		isLiveWindow: false,
		window: createEmptyMessageWindow(selectedChatId),
	};
};
