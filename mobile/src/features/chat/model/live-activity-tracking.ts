import type {
	ActiveThreadSummaryDTO,
	ChatDTO,
} from "../../../shared/api/types";

export interface TrackedLiveActivityChat {
	chatId: string;
	chatTitle: string | undefined;
}

export interface TrackedLiveActivityChatReconciliation {
	addedChatIds: string[];
	removedChatIds: string[];
}

interface ResolveTrackedLiveActivityChatsInput {
	activeThreads: readonly ActiveThreadSummaryDTO[];
	selectedChat: Pick<ChatDTO, "id" | "isActive" | "status" | "title"> | null;
	selectedChatId: string | null;
}

const isChatRunning = (chat: Pick<ChatDTO, "isActive" | "status"> | null): boolean =>
	Boolean(chat) && (chat!.isActive || chat!.status === "running");

export const resolveTrackedLiveActivityChats = (
	input: ResolveTrackedLiveActivityChatsInput,
): TrackedLiveActivityChat[] => {
	const trackedChats = new Map<string, TrackedLiveActivityChat>();

	for (const thread of input.activeThreads) {
		trackedChats.set(thread.id, {
			chatId: thread.id,
			chatTitle: thread.title,
		});
	}

	if (
		input.selectedChatId
		&& input.selectedChat
		&& input.selectedChat.id === input.selectedChatId
		&& isChatRunning(input.selectedChat)
	) {
		trackedChats.set(input.selectedChatId, {
			chatId: input.selectedChatId,
			chatTitle: input.selectedChat.title,
		});
	}

	return Array.from(trackedChats.values());
};

export const reconcileTrackedLiveActivityChats = (input: {
	nextTrackedChats: readonly TrackedLiveActivityChat[];
	previousTrackedChatIds: ReadonlySet<string>;
}): TrackedLiveActivityChatReconciliation => {
	const nextTrackedChatIds = new Set(input.nextTrackedChats.map((trackedChat) => trackedChat.chatId));
	const addedChatIds: string[] = [];
	const removedChatIds: string[] = [];

	for (const trackedChat of input.nextTrackedChats) {
		if (!input.previousTrackedChatIds.has(trackedChat.chatId)) {
			addedChatIds.push(trackedChat.chatId);
		}
	}

	for (const previousTrackedChatId of input.previousTrackedChatIds) {
		if (!nextTrackedChatIds.has(previousTrackedChatId)) {
			removedChatIds.push(previousTrackedChatId);
		}
	}

	return {
		addedChatIds,
		removedChatIds,
	};
};
