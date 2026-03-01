export const queryKeys = {
	chats: (projectId: string | null) => ["chats", projectId] as const,
	messages: (chatId: string | null) => ["messages", chatId] as const,
	projects: ["projects"] as const,
	selection: ["workspace-selection"] as const,
	streamEvents: (chatId: string | null) => ["stream-events", chatId] as const,
	streamingText: (chatId: string | null) => ["streaming-text", chatId] as const,
};
