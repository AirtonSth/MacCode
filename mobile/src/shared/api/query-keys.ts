export const queryKeys = {
	chatContext: (chatId: string | null) => ["chat-context", chatId] as const,
	chats: (projectId: string | null) => ["chats", projectId] as const,
	messages: (chatId: string | null | undefined) => ["messages-v2", chatId ?? null] as const,
	projects: ["projects"] as const,
	projectGitStatusRoot: ["project-git-status"] as const,
	projectGitStatus: (projectId: string | null) => ["project-git-status", projectId] as const,
	projectGitBranchesRoot: ["project-git-branches"] as const,
	projectGitBranches: (projectId: string | null) => ["project-git-branches", projectId] as const,
	serverHealth: (baseUrl: string, token: string) => ["mobile-server-health", baseUrl, token] as const,
	selection: ["workspace-selection"] as const,
	streamTurn: (chatId: string | null) => ["stream-turn", chatId] as const,
};
