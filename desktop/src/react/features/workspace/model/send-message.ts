import type { MessageDTO } from "./useWorkspaceStore";

type ErrorSource = "rest" | "ws";

export interface SendMessageInput {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	selectedChatProvider?: "fake" | "codex" | null;
	text: string;
	createChatId: () => Promise<string | null>;
	hasOpenWebSocket: boolean;
	onAppendMessage: (message: MessageDTO) => void;
	onClearStreaming: (chatId: string) => void;
	onCreateMessageError: (message: string, source: ErrorSource, code: string) => void;
	onSetSending: (sending: boolean) => void;
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
	const shouldCreateNewChat = !chatId || input.selectedChatProvider === "fake";

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

	input.onSetSending(true);
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
		input.onSetSending(false);
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
