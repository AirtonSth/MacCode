import type { MessageDTO } from "./useWorkspaceStore";

type ErrorSource = "rest" | "ws";

export const DEFAULT_DRAFT_THREAD_TITLE = "Untitled conversation";

const PLACEHOLDER_THREAD_TITLES = new Set([
	"new chat",
	"new thread",
	DEFAULT_DRAFT_THREAD_TITLE.toLowerCase(),
]);

const normalizeTitleText = (value: string): string => value.trim().replace(/\s+/gu, " ");

export const deriveThreadTitleFromMessage = (text: string, maxLength = 72): string => {
	const firstLine = text
		.split(/\r?\n/gu)
		.map(normalizeTitleText)
		.find((line) => line.length > 0);

	const normalized = firstLine ?? normalizeTitleText(text);
	if (normalized.length === 0) {
		return DEFAULT_DRAFT_THREAD_TITLE;
	}

	if (normalized.length <= maxLength) {
		return normalized;
	}

	return `${normalized.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`;
};

export const isPlaceholderThreadTitle = (title: string | null | undefined): boolean => {
	if (typeof title !== "string") {
		return true;
	}

	return PLACEHOLDER_THREAD_TITLES.has(normalizeTitleText(title).toLowerCase());
};

export interface SendMessageInput {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	selectedChatExists?: boolean;
	selectedChatProvider?: "fake" | "codex" | "claude" | null;
	text: string;
	createChatId: () => Promise<string | null>;
	hasOpenWebSocket: boolean;
	onAppendMessage: (message: MessageDTO) => void;
	onClearStreaming: (chatId: string) => void;
	onCreateMessageError: (message: string, source: ErrorSource, code: string) => void;
	onSetSending: (chatId: string, sending: boolean) => void;
	onSendUserMessage: (chatId: string, text: string) => void;
	generateMessageId?: () => string;
	createTimestamp?: () => string;
}

export interface SendMessageOutput {
	chatId: string | null;
	sent: boolean;
	createdNewChat: boolean;
}

export const buildUserMessage = (
	params: Pick<SendMessageInput, "text" | "generateMessageId" | "createTimestamp"> & {
		chatId: string;
	},
): MessageDTO => {
	return {
		id: params.generateMessageId?.() ?? crypto.randomUUID(),
		chatId: params.chatId,
		content: params.text,
		createdAt: params.createTimestamp?.() ?? new Date().toISOString(),
		role: "user",
	};
};

export const sendWorkspaceMessage = async (
	input: SendMessageInput,
): Promise<SendMessageOutput> => {
	if (!input.selectedProjectId) {
		input.onCreateMessageError("Select a project before sending a message", "rest", "missing_project");
		return {
			chatId: null,
			sent: false,
			createdNewChat: false,
		};
	}

	let chatId = input.selectedChatId;
	let createdNewChat = false;
	const shouldCreateNewChat =
		!chatId ||
		input.selectedChatProvider === "fake" ||
		input.selectedChatExists === false;

	if (shouldCreateNewChat) {
		const created = await input.createChatId();
		if (!created) {
			return {
				chatId: null,
				sent: false,
				createdNewChat: false,
			};
		}

		chatId = created;
		createdNewChat = true;
	}

	if (!chatId) {
		return {
			chatId: null,
			sent: false,
			createdNewChat,
		};
	}

	input.onSetSending(chatId, true);
	input.onAppendMessage(
		buildUserMessage({
			chatId,
			createTimestamp: input.createTimestamp,
			generateMessageId: input.generateMessageId,
			text: input.text,
		}),
	);
	input.onClearStreaming(chatId);

	if (!input.hasOpenWebSocket) {
		input.onCreateMessageError("WebSocket client is not ready", "ws", "not_ready");
		input.onSetSending(chatId, false);
		return {
			chatId,
			sent: false,
			createdNewChat,
		};
	}

	input.onSendUserMessage(chatId, input.text);
	return {
		chatId,
		sent: true,
		createdNewChat,
	};
};
