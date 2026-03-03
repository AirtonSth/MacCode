import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const projects = sqliteTable("projects", {
	createdAt: text("createdAt").notNull(),
	id: text("id").primaryKey(),
	isFavorite: integer("isFavorite").notNull().default(0),
	name: text("name").notNull(),
	path: text("path").notNull().unique(),
	updatedAt: text("updatedAt").notNull(),
});

export const chats = sqliteTable("chats", {
	diffAdded: integer("diffAdded").notNull().default(0),
	diffRemoved: integer("diffRemoved").notNull().default(0),
	id: text("id").primaryKey(),
	providerThreadId: text("providerThreadId"),

	projectId: text("projectId")
		.notNull()
		.references(() => projects.id, { onDelete: "cascade" }),

	provider: text("provider").notNull(),
	status: text("status").notNull(),
	title: text("title").notNull(),
	updatedAt: text("updatedAt").notNull(),
});

export const messages = sqliteTable("messages", {
	chatId: text("chatId")
		.notNull()
		.references(() => chats.id, { onDelete: "cascade" }),

	content: text("content").notNull(),
	createdAt: text("createdAt").notNull(),
	id: text("id").primaryKey(),
	role: text("role").notNull(),
});

export const workspaceSelection = sqliteTable("workspace_selection", {
	id: text("id").primaryKey(),
	selectedProjectId: text("selectedProjectId").references(() => projects.id, { onDelete: "set null" }),
	selectedChatId: text("selectedChatId").references(() => chats.id, { onDelete: "set null" }),
	permissionMode: text("permissionMode"),
	selectedModel: text("selectedModel"),
	selectedReasoningEffort: text("selectedReasoningEffort"),
	updatedAt: text("updatedAt").notNull(),
});

export const terminalCommands = sqliteTable("terminal_commands", {
	id: text("id").primaryKey(),
	chatId: text("chatId")
		.notNull()
		.references(() => chats.id, { onDelete: "cascade" }),
	command: text("command").notNull(),
	shell: text("shell").notNull(),
	cwd: text("cwd").notNull(),
	status: text("status").notNull(),
	exitCode: integer("exitCode"),
	durationMs: integer("durationMs"),
	startedAt: text("startedAt").notNull(),
	finishedAt: text("finishedAt"),
});

export const terminalEntries = sqliteTable("terminal_entries", {
	id: integer("id").primaryKey({ autoIncrement: true }),
	commandId: text("commandId")
		.notNull()
		.references(() => terminalCommands.id, { onDelete: "cascade" }),
	chatId: text("chatId")
		.notNull()
		.references(() => chats.id, { onDelete: "cascade" }),
	stream: text("stream").notNull(),
	data: text("data").notNull(),
	createdAt: text("createdAt").notNull(),
});

export const workspaceEvents = sqliteTable("workspace_events", {
	seq: integer("seq").primaryKey({ autoIncrement: true }),
	type: text("type").notNull(),
	payload: text("payload").notNull(),
	originClientId: text("originClientId"),
	requestId: text("requestId"),
	createdAt: text("createdAt").notNull(),
});

export const chatStreamSnapshots = sqliteTable("chat_stream_snapshots", {
	chatId: text("chatId")
		.primaryKey()
		.references(() => chats.id, { onDelete: "cascade" }),
	partialText: text("partialText").notNull().default(""),
	updatedAt: text("updatedAt").notNull(),
});

export const chatStreamEvents = sqliteTable("chat_stream_events", {
	id: integer("id").primaryKey({ autoIncrement: true }),
	chatId: text("chatId")
		.notNull()
		.references(() => chats.id, { onDelete: "cascade" }),
	eventJson: text("eventJson").notNull(),
	turnId: text("turnId").notNull(),
	createdAt: text("createdAt").notNull(),
});

export const serverMetadata = sqliteTable("server_metadata", {
	key: text("key").primaryKey(),
	value: text("value").notNull(),
	updatedAt: text("updatedAt").notNull(),
});

export type ChatRow = typeof chats.$inferSelect;

export type MessageRow = typeof messages.$inferSelect;
export type ProjectRow = typeof projects.$inferSelect;
export type WorkspaceSelectionRow = typeof workspaceSelection.$inferSelect;
export type TerminalCommandRow = typeof terminalCommands.$inferSelect;
export type TerminalEntryRow = typeof terminalEntries.$inferSelect;
export type WorkspaceEventRow = typeof workspaceEvents.$inferSelect;
export type ChatStreamSnapshotRow = typeof chatStreamSnapshots.$inferSelect;
export type ChatStreamEventRow = typeof chatStreamEvents.$inferSelect;
export type ServerMetadataRow = typeof serverMetadata.$inferSelect;

export class DatabaseSchema {
	static readonly projects = projects;

	static readonly chats = chats;

	static readonly messages = messages;

	static readonly workspaceSelection = workspaceSelection;

	static readonly terminalCommands = terminalCommands;

	static readonly terminalEntries = terminalEntries;

	static readonly workspaceEvents = workspaceEvents;

	static readonly chatStreamSnapshots = chatStreamSnapshots;

	static readonly chatStreamEvents = chatStreamEvents;

	static readonly serverMetadata = serverMetadata;
}
