export const queryKeys = {
	chats: (projectId: string | null) => ["chats", projectId] as const,
	messages: (chatId: string | null) => ["messages", chatId] as const,
	projects: ["projects"] as const,
	selection: ["workspace-selection"] as const,
	streamTurn: (chatId: string | null) => ["stream-turn", chatId] as const,
};
